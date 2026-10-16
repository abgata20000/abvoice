#!/usr/bin/env bash
#
# AbVoice Local を .app にして署名するまでを 1 本で行う（開発用）。
# 配布用（公証・.dmg）は scripts/release.sh を使う。
#
#   ./build.sh              リリースビルド → dist/AbVoice Local.app
#   ./build.sh debug        デバッグビルド
#   ./build.sh --install    ビルド後に /Applications へ配置
#
# 署名 ID は次の順で決める:
#   1. 環境変数 ABVOICE_SIGN_ID
#      （ABVOICE_SIGN_TIMESTAMP=1 を一緒に渡すと secure timestamp 付きで署名する。scripts/release.sh が使う）
#   2. Developer ID Application（推奨。⚠️ これだと再ビルドしても権限が外れない）
#   3. Apple Development（同じ証明書を使い続ける限り権限は保たれる）
#   4. ad-hoc（⚠️ 再ビルドのたびにアクセシビリティ権限を付け直すことになる）
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIGURATION="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug) CONFIGURATION="debug" ;;
    release) CONFIGURATION="release" ;;
    --install) INSTALL=1 ;;
    *) echo "不明な引数: $arg" >&2; exit 1 ;;
  esac
done

APP_NAME="AbVoice Local"
EXECUTABLE="AbVoiceLocal"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"

# Apple シリコン専用（Intel 向けはビルドしない）。
echo "==> swift build (${CONFIGURATION})"
swift build -c "${CONFIGURATION}" --arch arm64 --disable-sandbox

PRODUCTS_DIR="$(swift build -c "${CONFIGURATION}" --arch arm64 --show-bin-path)"
BIN_PATH="${PRODUCTS_DIR}/${EXECUTABLE}"
if [ ! -x "${BIN_PATH}" ]; then
  echo "実行ファイルが見つかりません: ${BIN_PATH}" >&2
  exit 1
fi

echo "==> .app を組み立て"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"
# ⚠️ 依存ライブラリのリソース（*.bundle）を必ず一緒に入れる。
#    ライブラリは実行時に Contents/Resources/ から探し、見つからないとその場でアプリが落ちる
#    （ビルドした場所へは探しに行かない）。1 つも無いのは想定外なので止める。
BUNDLE_COUNT=0
for bundle in "${PRODUCTS_DIR}"/*.bundle; do
  [ -d "${bundle}" ] || continue
  cp -R "${bundle}" "${APP_DIR}/Contents/Resources/"
  BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done
if [ "${BUNDLE_COUNT}" -eq 0 ]; then
  echo "依存ライブラリのリソース（*.bundle）が見つかりません: ${PRODUCTS_DIR}" >&2
  exit 1
fi
# アイコンは生成済みのものをコピーするだけ（作り直しは swift Resources/make-icon.swift）
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
else
  echo "!! Resources/AppIcon.icns がありません。swift Resources/make-icon.swift で生成してください。"
fi

# 署名 ID を決める
SIGN_ID="${ABVOICE_SIGN_ID:-}"
if [ -z "${SIGN_ID}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)"
fi
if [ -z "${SIGN_ID}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"' || true)"
  if [ -n "${SIGN_ID}" ]; then
    echo "!! Developer ID Application が見つかりません。Apple Development で署名します。"
    echo "!! 証明書を入れ替えるとアクセシビリティ権限が外れます（同じ証明書を使い続ける限りは保たれます）。"
  fi
fi

if [ -z "${SIGN_ID}" ]; then
  echo "!! 署名できる証明書がありません。ad-hoc 署名にフォールバックします。"
  echo "!! ⚠️ ad-hoc だと再ビルドのたびにアクセシビリティ権限を付け直すことになります。"
  codesign --force --sign - \
    --entitlements Resources/AbVoiceLocal.entitlements \
    --options runtime \
    "${APP_DIR}"
else
  # ⚠️ 開発用は secure timestamp を付けない（オフラインでもビルドできるように）。
  #    公証には secure timestamp が必須なので、配布用（scripts/release.sh）だけ付ける。
  TIMESTAMP_FLAG="--timestamp=none"
  if [ "${ABVOICE_SIGN_TIMESTAMP:-0}" = "1" ]; then
    TIMESTAMP_FLAG="--timestamp"
  fi
  echo "==> codesign (${TIMESTAMP_FLAG})"
  codesign --force --sign "${SIGN_ID}" \
    --entitlements Resources/AbVoiceLocal.entitlements \
    --options runtime \
    "${TIMESTAMP_FLAG}" \
    "${APP_DIR}"
fi

codesign --verify --verbose=2 "${APP_DIR}"

echo "==> できあがり: ${APP_DIR}"

if [ "${INSTALL}" -eq 1 ]; then
  echo "==> /Applications へ配置"
  # 起動中だと差し替えに失敗するので先に落とす
  pkill -x "${EXECUTABLE}" 2>/dev/null || true
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
  echo "==> /Applications/${APP_NAME}.app"
fi
