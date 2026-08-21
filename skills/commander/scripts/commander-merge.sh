#!/usr/bin/env bash
# 司令官が部下を飛ばして直接マージするための例外処理。
#
# 司令官が直接マージしてよいのは次の 2 ケースだけ（SKILL.md 参照）:
#   (1) 部下が復旧不能（プロセスが死んだ / 何度押しても反応しない）
#   (2) 担当部下が居ない PR に、人間から直接マージ指示が来た
#
#   commander-merge.sh <owner/repo> <PR番号> "<理由>" [--mission <mission-dir>]
#
# 司令官が直接 `gh pr merge` を叩くと completed.log に残らず、人間への報告が漏れる経路になる。
# このスクリプトは --mission を渡された場合に限り completed.log へ明記して追記する。
#
# 終了コード: 0=マージ成功 / 1=ゲートで却下 or マージ失敗 / 2=呼び出しエラー
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "commander-merge: $*" >&2; exit 2; }
[ $# -ge 3 ] || die 'usage: commander-merge.sh <owner/repo> <PR番号> "<理由>" [--mission <mission-dir>]'
REPO=$1; PR=$2; REASON=$3; shift 3
MISSION=""
if [ "${1:-}" = "--mission" ]; then MISSION=${2:-}; fi

command -v gh >/dev/null || die "gh が無い"
command -v jq >/dev/null || die "jq が無い"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -x "$HERE/mergeable.sh" ] || die "mergeable.sh が無い（同じディレクトリに置く）"

printf '司令官が直接マージする例外処理: %s #%s\n' "$REPO" "$PR"
printf '理由: %s\n' "$REASON"

bash "$HERE/mergeable.sh" "$REPO" "$PR"
gate=$?
if [ "$gate" != "0" ]; then
  printf '判定: mergeable.sh のゲートを通過しなかった。マージしない\n' >&2
  exit 1
fi

out=$(gh pr merge "$PR" --repo "$REPO" --merge 2>&1) || die "gh pr merge に失敗した: $out"
printf '%s\n' "$out"

result=$(gh pr view "$PR" --repo "$REPO" --json state,mergedAt,mergeCommit 2>/dev/null) \
  || die "マージ後の確認に失敗した（gh pr view）"
st=$(printf '%s' "$result" | jq -r '.state')
[ "$st" = "MERGED" ] || die "gh pr merge は成功と返したが state が MERGED になっていない（state=${st}）"
sha=$(printf '%s' "$result" | jq -r '.mergeCommit.oid // "?"')
printf 'マージ確認: state=MERGED mergeCommit=%s\n' "$sha"

if [ -n "$MISSION" ] && [ -d "$MISSION" ]; then
  printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "pr${PR}" \
    "司令官直接マージ" \
    "司令官が直接実行（理由: ${REASON}）。PR ${REPO}#${PR}、マージ commit ${sha}" \
    >> "$MISSION/completed.log"
  printf 'completed.log に記録した: %s/completed.log\n' "$MISSION"
else
  printf 'warn: --mission が指定されていないので completed.log に記録していない。\n' >&2
  printf '      人間への報告にこのマージを「例外として司令官が実行した」と手で明記すること\n' >&2
fi
