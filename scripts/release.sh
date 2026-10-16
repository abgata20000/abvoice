#!/usr/bin/env bash
#
# 配布用の .dmg を作る（署名 → 公証 → staple → .dmg → 公証 → staple → 検証）。
#
#   NOTARY_PROFILE=<プロファイル名> ./scripts/release.sh 0.1.0             .dmg まで作る
#   NOTARY_PROFILE=<プロファイル名> ./scripts/release.sh 0.1.0 --publish   さらに GitHub Releases に下書きで置く
#   ./scripts/release.sh 0.1.0 --skip-notarize                            公証なしで流れだけ確かめる（配布しないこと）
#
# 公証の認証情報は、あらかじめ Keychain に入れておく（リポジトリにも環境変数にも書かない）:
#   xcrun notarytool store-credentials <プロファイル名> --apple-id <Apple ID> --team-id <Team ID>
#   （App 用パスワードを聞かれる。appleid.apple.com で発行したものを入れる）
#
# ⚠️ Developer ID Application の証明書で署名する。Apple Development や ad-hoc では配布できない。
# ⚠️ secure timestamp 付きで署名する（無いと公証が通らない）。
#
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
shift || true
PUBLISH=0
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --skip-notarize) NOTARIZE=0 ;;
    *) echo "不明な引数: $arg" >&2; exit 1 ;;
  esac
done

if [ -z "${VERSION}" ]; then
  echo "使い方: NOTARY_PROFILE=<プロファイル名> $0 <バージョン> [--publish] [--skip-notarize]" >&2
  exit 1
fi
if [ "${NOTARIZE}" -eq 1 ] && [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "NOTARY_PROFILE（notarytool store-credentials で作ったプロファイル名）を指定してください。" >&2
  exit 1
fi
if [ "${PUBLISH}" -eq 1 ] && [ "${NOTARIZE}" -eq 0 ]; then
  echo "公証していないものは公開できません（--publish と --skip-notarize は一緒に使えません）。" >&2
  exit 1
fi

# バージョンは Info.plist を正とし、指定と一致させる。
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [ "${PLIST_VERSION}" != "${VERSION}" ]; then
  echo "Resources/Info.plist の CFBundleShortVersionString（${PLIST_VERSION}）と指定（${VERSION}）が違います。" >&2
  exit 1
fi

# ⚠️ コミットしていない変更が入った配布物を作らない（タグと中身がずれる）。
if [ "${PUBLISH}" -eq 1 ] && [ -n "$(git status --porcelain)" ]; then
  echo "コミットしていない変更があります。コミットしてから公開してください。" >&2
  exit 1
fi

SIGN_ID="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)"
if [ -z "${SIGN_ID}" ]; then
  echo "Developer ID Application の証明書がありません（./scripts/setup-developer-id.sh を参照）。" >&2
  exit 1
fi

APP_NAME="AbVoice Local"
APP="dist/${APP_NAME}.app"
DMG="dist/AbVoice-Local-${VERSION}.dmg"
ZIP="dist/AbVoice-Local-${VERSION}-notarize.zip"

echo "==> ビルドと署名（Developer ID / secure timestamp）"
ABVOICE_SIGN_ID="${SIGN_ID}" ABVOICE_SIGN_TIMESTAMP=1 ./build.sh release
codesign --verify --deep --strict --verbose=2 "${APP}"

notarize() {
  local target="$1"
  echo "==> 公証に出す: ${target}"
  xcrun notarytool submit "${target}" --keychain-profile "${NOTARY_PROFILE}" --wait
}

if [ "${NOTARIZE}" -eq 1 ]; then
  # ⚠️ zip は公証に出せるが staple できない。zip を出したあと .app 自体に staple する。
  rm -f "${ZIP}"
  ditto -c -k --keepParent "${APP}" "${ZIP}"
  notarize "${ZIP}"
  rm -f "${ZIP}"
  xcrun stapler staple "${APP}"
fi

echo "==> .dmg を作る"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
codesign --force --sign "${SIGN_ID}" --timestamp "${DMG}"

if [ "${NOTARIZE}" -eq 1 ]; then
  notarize "${DMG}"
  xcrun stapler staple "${DMG}"

  echo "==> 検証"
  xcrun stapler validate "${APP}"
  xcrun stapler validate "${DMG}"
  spctl -a -t exec -vv "${APP}"
  spctl -a -t open --context context:primary-signature -vv "${DMG}"
else
  echo "!! 公証を省きました。この .dmg は配布しないでください（ほかの Mac では開けません）。"
fi

ls -la "${DMG}"

if [ "${PUBLISH}" -eq 1 ]; then
  echo "==> GitHub Releases に下書きで置く（v${VERSION}）"
  # ⚠️ 下書きにする。中身を確かめてから、GitHub の画面で公開する。
  gh release create "v${VERSION}" "${DMG}" --draft --title "AbVoice Local ${VERSION}" --generate-notes
fi
