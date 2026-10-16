#!/usr/bin/env bash
#
# リポジトリを public に切り替える前に通す。1 つでも当たったら失敗する。
#
#   ./scripts/prepublish-check.sh
#
# 持ち込んではいけない語（内部のアドレス・ホスト名・個人名など）は
# scripts/prepublish-patterns.local に 1 行 1 パターン（grep の拡張正規表現）で書く。
# ⚠️ このファイルはリポジトリに入れない（.gitignore 済み）。パターン自体が内部の情報になるため。
#    空行と # で始まる行は無視する。
#
set -uo pipefail

cd "$(dirname "$0")/.."

PATTERNS="scripts/prepublish-patterns.local"
FAILED=0

fail() {
  echo "NG: $*"
  FAILED=1
}

if [ ! -s "${PATTERNS}" ]; then
  echo "NG: ${PATTERNS} がありません。パターンが無いので確認できません。" >&2
  exit 1
fi
if git ls-files --error-unmatch "${PATTERNS}" >/dev/null 2>&1; then
  echo "NG: ${PATTERNS} が git に入っています。外してください。" >&2
  exit 1
fi

ACTIVE="$(mktemp)"
trap 'rm -f "${ACTIVE}"' EXIT
grep -vE '^[[:space:]]*(#|$)' "${PATTERNS}" > "${ACTIVE}"
echo "パターン: $(wc -l < "${ACTIVE}" | tr -d ' ') 件"

echo "==> 追跡しているファイル"
# バイナリ（アイコンなど）は対象外。
if git grep -n -I -E -f "${ACTIVE}" -- . ; then
  fail "追跡しているファイルに当たりがあります（上の行）"
fi

echo "==> git の全履歴（すべてのブランチ）"
# 作者欄（メールアドレス）は見ない。変更の中身だけを見る（作者欄は GitHub の設定で隠すもの）。
HITS="$(git log --all -p --no-color --format='commit %h' | grep -E -f "${ACTIVE}" | head -20)"
if [ -n "${HITS}" ]; then
  echo "${HITS}"
  fail "履歴に当たりがあります（最初の 20 件）。ファイルから消しても履歴には残っています"
fi

echo "==> Info.plist"
# ⚠️ コメントの中の言及には反応させない。キーとして書かれているかを見る。
if grep -q "<key>NSAllowsArbitraryLoads</key>" Resources/Info.plist; then
  fail "Resources/Info.plist に NSAllowsArbitraryLoads が残っています"
fi

echo "==> LICENSE"
[ -f LICENSE ] || fail "LICENSE がありません"

echo
echo "目視で確かめること: README のスクリーンショットに、自分の履歴・辞書・名前が写っていないか"
echo

if [ "${FAILED}" -ne 0 ]; then
  echo "公開前チェック: 失敗"
  exit 1
fi
echo "公開前チェック: 通過"
