#!/usr/bin/env bash
# push / マージの GO を出す前に必ず通すゲート。人間から「マージして」「ok」と言われた場合も同じ。
# 部下の自己申告（「CI 通った」「approve もらった」）は根拠にせず、これで機械的に確かめる。
#   mergeable.sh <owner/repo> <PR番号>
# 終了コード: 0=マージしてよい / 1=マージ不可（差し戻す）/ 2=呼び出しエラー
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "mergeable: $*" >&2; exit 2; }
[ $# -ge 2 ] || die "usage: mergeable.sh <owner/repo> <PR番号>"
REPO=$1; PR=$2
command -v gh >/dev/null || die "gh が無い"
command -v jq >/dev/null || die "jq が無い"

fail=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  NG   %s\n' "$1"; fail=1; }

printf 'マージ可否チェック: %s #%s\n' "$REPO" "$PR"

info=$(gh pr view "$PR" --repo "$REPO" \
  --json mergeStateStatus,mergeable,reviewDecision,headRefOid,state 2>/dev/null) \
  || die "gh pr view に失敗した（PR番号・repo を確認する）"

state=$(printf '%s' "$info" | jq -r '.state')
[ "$state" = "OPEN" ] || bad "PR の state が OPEN でない（state=${state}）"

mss=$(printf '%s' "$info" | jq -r '.mergeStateStatus')
mgbl=$(printf '%s' "$info" | jq -r '.mergeable')
rd=$(printf '%s' "$info" | jq -r '.reviewDecision')
head=$(printf '%s' "$info" | jq -r '.headRefOid')

case "$mss" in
  CLEAN|UNSTABLE) ok "mergeStateStatus=${mss}" ;;
  *) bad "mergeStateStatus=${mss}（CLEAN / UNSTABLE 以外はマージしない）" ;;
esac
printf '  情報 mergeable=%s reviewDecision=%s headRefOid=%s\n' "$mgbl" "${rd:-null}" "$head"

# ── CI の各 check ──
checks=$(gh pr checks "$PR" --repo "$REPO" --json name,state,bucket 2>/dev/null)
if [ -z "$checks" ] || [ "$checks" = "[]" ]; then
  printf '  WARN CI チェックが 1 件も無い\n'
else
  not_green=$(printf '%s' "$checks" | jq -r \
    '.[] | select(.bucket!="pass" and .bucket!="skipping" and .bucket!="neutral") | "\(.name): \(.state) (\(.bucket))"')
  if [ -n "$not_green" ]; then
    bad "CI が緑ではないチェックがある:"
    printf '%s\n' "$not_green" | sed 's/^/    /'
  else
    ok "CI は全部緑（$(printf '%s' "$checks" | jq 'length') 件）"
  fi
fi

# ── 最新 head に対する approve のみを数える（古い head への approve は数えない） ──
reviews=$(gh api --paginate "repos/${REPO}/pulls/${PR}/reviews" 2>/dev/null) || reviews="[]"
approvals=$(printf '%s' "$reviews" | jq -r --arg h "$head" \
  '[.[] | select(.state=="APPROVED" and .commit_id==$h)] | length' 2>/dev/null)
case "$approvals" in
  ''|*[!0-9]*) approvals=0 ;;
esac
if [ "$approvals" -gt 0 ]; then
  ok "最新 head (${head}) への approve が ${approvals} 件ある"
  printf '%s' "$reviews" | jq -r --arg h "$head" \
    '.[] | select(.state=="APPROVED" and .commit_id==$h) | "    approve: \(.user.login)"'
else
  printf '  WARN 最新 head (%s) への approve が無い（古い head への approve は数えない）\n' "$head"
fi

# ── 未解決レビュースレッド ──
threads=$(gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){
    pullRequest(number:$n){ reviewThreads(first:100){ nodes{ isResolved
      comments(first:1){ nodes{ author{login} path line body } } } } } } }' \
  -F o="${REPO%%/*}" -F r="${REPO##*/}" -F n="$PR" 2>/dev/null) || threads=""

if [ -z "$threads" ]; then
  printf '  WARN 未解決レビュースレッドを取得できなかった（graphql 失敗）\n'
else
  unresolved=$(printf '%s' "$threads" | jq -c \
    '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)' 2>/dev/null)
  ucount=$(printf '%s' "$unresolved" | grep -c . 2>/dev/null || echo 0)
  if [ "${ucount:-0}" -gt 0 ] 2>/dev/null; then
    bad "未解決レビュースレッドが ${ucount} 件ある:"
    printf '%s\n' "$unresolved" | jq -r \
      '"    " + (.comments.nodes[0].path // "?") + ":" + ((.comments.nodes[0].line // "?")|tostring) + " (" + (.comments.nodes[0].author.login // "?") + ")"'
  else
    ok "未解決レビュースレッドは 0 件"
  fi
fi

if [ "$fail" = "0" ]; then
  printf '判定: マージしてよい\n'; exit 0
else
  printf '判定: マージ不可（人間から「マージして」「ok」と言われていても、修正を指示する）\n'; exit 1
fi
