#!/usr/bin/env bash
#
# Developer ID Application 証明書を用意する手伝いをする。
# ブラウザでの操作（Apple へのログインとアップロード）以外をこのスクリプトが受け持つ。
#
#   ./scripts/setup-developer-id.sh csr       秘密鍵と申請ファイル（CSR）を作り、発行ページを開く
#   ./scripts/setup-developer-id.sh install   ダウンロードした .cer をキーチェーンに入れる
#   ./scripts/setup-developer-id.sh check     入っているか確認する
#
# ⚠️ 秘密鍵はリポジトリの外（~/.abvoice-signing/）に置き、キーチェーンに入れ終わったら消す。
#    リポジトリには何も書き込まない。
#
set -euo pipefail

WORK_DIR="${HOME}/.abvoice-signing"
KEY_FILE="${WORK_DIR}/developer-id.key"
CSR_FILE="${WORK_DIR}/developer-id.certSigningRequest"
ISSUE_URL="https://developer.apple.com/account/resources/certificates/add"
INTERMEDIATE_URL="https://www.apple.com/certificateauthority/"

has_identity() {
  security find-identity -v -p codesigning | grep -q "Developer ID Application"
}

cmd_check() {
  if has_identity; then
    echo "OK: Developer ID Application 証明書が入っています。"
    security find-identity -v -p codesigning | grep "Developer ID Application"
  else
    echo "まだ入っていません。"
    return 1
  fi
}

cmd_csr() {
  if has_identity; then
    echo "すでに Developer ID Application 証明書が入っています。作り直す必要はありません。"
    return 0
  fi
  # ⚠️ 上書きしない。アップロード済みの CSR と対になる秘密鍵を消すと、発行された証明書が使えなくなる。
  if [ -f "${KEY_FILE}" ]; then
    echo "秘密鍵がすでにあります: ${KEY_FILE}"
    echo "前回の続きなら、発行ページでこの申請ファイルをアップロードしてください:"
    echo "  ${CSR_FILE}"
  else
    mkdir -p "${WORK_DIR}"
    chmod 700 "${WORK_DIR}"
    openssl genrsa -out "${KEY_FILE}" 2048 2>/dev/null
    chmod 600 "${KEY_FILE}"
    # CSR の名前とメールは Apple 側で使われない（証明書にはアカウントの情報が入る）。
    openssl req -new -key "${KEY_FILE}" -out "${CSR_FILE}" -subj "/CN=AbVoice Developer ID/C=JP"
    echo "申請ファイルを作りました: ${CSR_FILE}"
  fi

  open -R "${CSR_FILE}"
  open "${ISSUE_URL}"

  cat <<'GUIDE'

ブラウザでやること（3 クリック）:
  1. 「Developer ID Application」を選んで Continue
  2. 「Choose File」で、いま Finder に表示されている申請ファイルを選んで Continue
     （Profile Type を聞かれたら「G2 Sub-CA」のまま）
  3. 「Download」を押す（ダウンロードフォルダに .cer が入る）

終わったら次を実行:
  ./scripts/setup-developer-id.sh install
GUIDE
}

cmd_install() {
  local cer="${1:-}"
  if [ -z "${cer}" ]; then
    # ダウンロードフォルダのいちばん新しい .cer を使う。
    cer="$(ls -t "${HOME}/Downloads"/*.cer 2>/dev/null | head -1 || true)"
  fi
  if [ -z "${cer}" ] || [ ! -f "${cer}" ]; then
    echo "ダウンロードフォルダに .cer が見つかりません。パスを指定してください:" >&2
    echo "  ./scripts/setup-developer-id.sh install /path/to/developerID_application.cer" >&2
    return 1
  fi
  if [ ! -f "${KEY_FILE}" ]; then
    echo "秘密鍵がありません: ${KEY_FILE}" >&2
    echo "先に ./scripts/setup-developer-id.sh csr を実行してください。" >&2
    return 1
  fi

  local keychain
  keychain="$(security default-keychain -d user | tr -d ' "')"

  echo "証明書: ${cer}"
  echo "キーチェーン: ${keychain}"
  security import "${KEY_FILE}" -k "${keychain}" -T /usr/bin/codesign
  security import "${cer}" -k "${keychain}"

  if has_identity; then
    rm -f "${KEY_FILE}" "${CSR_FILE}"
    rmdir "${WORK_DIR}" 2>/dev/null || true
    echo
    echo "完了しました。秘密鍵の一時ファイルは消しました（キーチェーンに入っています）。"
    security find-identity -v -p codesigning | grep "Developer ID Application"
    echo
    echo "⚠️ 初めて署名するときに「codesign がキーチェーンを使おうとしています」と聞かれます。"
    echo "   ログインパスワードを入れて「常に許可」を押してください。"
  else
    echo >&2
    echo "キーチェーンには入りましたが、署名に使える状態になっていません。" >&2
    echo "中間証明書（Developer ID - G2）が無い可能性があります。次のページから" >&2
    echo "「Developer ID - G2」をダウンロードしてダブルクリックし、もう一度 check を実行してください:" >&2
    echo "  ${INTERMEDIATE_URL}" >&2
    echo "  ./scripts/setup-developer-id.sh check" >&2
    return 1
  fi
}

case "${1:-}" in
  csr) cmd_csr ;;
  install) cmd_install "${2:-}" ;;
  check) cmd_check ;;
  *)
    echo "使い方: $0 {csr|install [.cer のパス]|check}" >&2
    exit 1
    ;;
esac
