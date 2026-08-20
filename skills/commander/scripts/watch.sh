#!/usr/bin/env bash
# 稼働中の部下に新しい動きが出るまで待ち、出たら終了する。
#   watch.sh <mission-dir> [最大待ち秒(既定 3600)] [間隔秒(既定 60)]
#
# これを Bash ツールの run_in_background で走らせる。プロセスが終了すると
# ハーネスが司令官を呼び戻すので、「部下が終わったのに司令官が気付かない」が構造的に起きない。
# inbox は --peek で見る（消化しない）ので、呼び戻された司令官が改めて読める。
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "watch: $*" >&2; exit 2; }
[ $# -ge 1 ] || die "usage: watch.sh <mission-dir> [max-sec] [interval-sec]"
MISSION=$1; MAX=${2:-3600}; IV=${3:-60}
[ -d "$MISSION" ] || die "mission ディレクトリが無い: $MISSION"
ROSTER="$MISSION/roster.jsonl"
[ -s "$ROSTER" ] || die "部下がいない: $ROSTER"
INBOX="$(cd "$(dirname "$0")" && pwd)/inbox.sh"

waited=0
while :; do
  # 稼働中（未撤収）の部下がいなければ、見張る理由が無い
  active=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    no=$(printf '%s' "$row" | jq -r '.no')
    [ -f "$MISSION/workers/$no/RETIRED" ] || active=$((active+1))
  done < "$ROSTER"
  if [ "$active" = "0" ]; then
    printf 'watch: 稼働中の部下がいない。監視を終了する\n'; exit 0
  fi

  # まず --peek で有無だけ見る。あったら「消化して」中身を出す。
  # --peek のまま終わると、司令官が処理しても消化されないので同じ報告で即再発火する
  # （実際に無限に発火した）。中身はこの出力で司令官に届くので、消化して問題ない。
  if [ -n "$(bash "$INBOX" "$MISSION" --peek 2>/dev/null)" ]; then
    printf 'watch: 新しい動きを検知（稼働 %s 人）。以下を処理すること\n' "$active"
    bash "$INBOX" "$MISSION" 2>/dev/null | head -60
    exit 0
  fi

  # 沈黙の検知: 報告が無いまま長時間経った部下を知らせる（agent hook の通知に頼らない）
  stalled=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    no=$(printf '%s' "$row" | jq -r '.no')
    [ -f "$MISSION/workers/$no/RETIRED" ] && continue
    st=$(printf '%s' "$row" | jq -r '.started_at // ""')
    [ -n "$st" ] || continue
    ep=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$st" +%s 2>/dev/null) || continue
    mins=$(( ( $(date +%s) - ep ) / 60 ))
    if [ "$mins" -ge 60 ] && [ ! -s "$MISSION/workers/$no/REPORT.md" ] \
       && [ ! -s "$MISSION/workers/$no/PLAN.md" ]; then
      stalled="${stalled}${no}(${mins}分) "
    fi
  done < "$ROSTER"
  if [ -n "$stalled" ]; then
    printf 'watch: 60分以上 報告が無い部下がいる: %s\n' "$stalled"
    printf 'watch: 画面を見て介入するか判断すること（cmux read-screen）\n'
    exit 0
  fi

  waited=$((waited+IV))
  if [ "$waited" -ge "$MAX" ]; then
    printf 'watch: %s 秒待ったが動きなし（稼働 %s 人）。監視を張り直すこと\n' "$MAX" "$active"
    exit 0
  fi
  sleep "$IV"
done
