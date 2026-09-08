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
STALL_STATE="$MISSION/watch.stall.state"
touch "$STALL_STATE" 2>/dev/null || true

# 画面が「動いている」と判断するパターン。
# これに当たる画面を「待ちで止まった」と判定すると、正当にブロックしている部下を
# 停止扱いにしてしまい、同じ条件で毎ポーリング即再発火する（実際に起きた。司令官のターンを食い潰した）:
#   - `Waiting for N background agent to finish`（自分が起動した background agent の完了待ち。
#     完了すればハーネスが叩き起こすので放置してよい）
#   - `ctrl+b to run in background`（長いシェルコマンドの実行中）
#   - スピナー行（`✻ Cooking… (3m 21s · ↓ 4.2k tokens)` 等。文言は変わるので
#     経過時間の形 `(12s ·` / `(3m 21s ·` で見る）
is_active() {
  case "$1" in
    *"esc to interrupt"*)                return 0 ;;
    *"ctrl+b to run in background"*)      return 0 ;;
    *"Waiting for "*"background agent"*)  return 0 ;;
    *"tokens)"*)                          return 0 ;;
    # `gh pr checks --watch` 等、フォアグラウンドでシェルコマンドを実行中の画面。
    # cmux は「(3m 21s · ...)」のように時間が先頭に来ない形（例:
    # "Running 1 shell command · 35s…"）でも進捗を出すことがあり、下の時間
    # パターンにも spinner 文字にも一致しない。実際にこれを「待ち」と誤判定し、
    # 正しくブロックしている健全な部下に司令官が割り込むきっかけになった。
    *"Running "*"shell command"*)         return 0 ;;
  esac
  printf '%s' "$1" | grep -qE '\([0-9]+m? ?[0-9]*s · ' && return 0
  printf '%s' "$1" | grep -qE '^[[:space:]]*[✻✳✢✽◑◯⏺][[:space:]]' && return 0
  return 1
}

# 「待ち」でターンを終えた候補を1回ぶん観測する。出力は "no<TAB>画面ハッシュ" の行。
# 1回のスナップショットだけで判定すると、画面が切り替わる瞬間を拾って誤検知するため、
# 呼び出し側で間隔をあけて2回呼び、両方で同じ部下が残ったときだけ報告する。
scan_waiting() {
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    no=$(printf '%s' "$row" | jq -r '.no'); ref=$(printf '%s' "$row" | jq -r '.ws_ref')
    [ -f "$MISSION/workers/$no/RETIRED" ] && continue
    [ -s "$MISSION/workers/$no/REPORT.md" ] && continue
    scr=$(cmux read-screen --workspace "$ref" --lines 14 2>/dev/null)
    [ -n "$scr" ] || continue
    is_active "$scr" && continue
    case "$scr" in
      *[Ww]ait*|*待*)
        h=$(printf '%s' "$scr" | cksum | awk '{print $1}')
        printf '%s\t%s\n' "$no" "$h"
        ;;
    esac
  done < "$ROSTER"
}

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
  # 判定からは台帳の催促を除く（未報告が残っている間ずっと即発火してしまい、
  # 本来の「部下の動きを待つ」機能が死ぬ）。本文を出すときは台帳も含める。
  if [ -n "$(bash "$INBOX" "$MISSION" --peek --no-ledger 2>/dev/null)" ]; then
    printf 'watch: 新しい動きを検知（稼働 %s 人）。以下を処理すること\n' "$active"
    bash "$INBOX" "$MISSION" 2>/dev/null | head -60
    exit 0
  fi

  # 「待ち」で止まった部下の検知。
  # 部下は「CI を待つ」と判断してターンを終えることがある。誰も起こさないので永久に止まる。
  # todo が進まないまま一定時間が経ったら、司令官が代わりに外側（CI / PR の状態）を確認して押す。
  #
  # ただし `Waiting for N background agent` やスピナー表示は**正当にブロックしている状態**であり、
  # 単純な `Wait`/`待` 文字列一致だけで停止扱いにすると、同じ画面で毎ポーリング即再発火して
  # 司令官のターンを食い潰す（実際に起きた）。is_active に当たる画面は候補から外し、
  # 間隔をあけて2回観測して両方 stalled のときだけ報告し、同じ (部下, 画面ハッシュ) は再通知しない。
  first="$(scan_waiting)"
  if [ -n "$first" ]; then
    sleep 20
    second="$(scan_waiting)"
    report=""
    while IFS=$'\t' read -r no h; do
      [ -n "$no" ] || continue
      printf '%s' "$second" | grep -q "^${no}	" || continue        # 2回目で消えた=動いた
      grep -q "^${no}	${h}$" "$STALL_STATE" 2>/dev/null && continue  # 同じ停止は再報告しない
      report="${report}${no} "
      printf '%s\t%s\n' "$no" "$h" >> "$STALL_STATE"
    done <<< "$first"
    if [ -n "$report" ]; then
      printf 'watch: 「待ち」でターンを終えて止まっている部下: %s\n' "$report"
      printf 'watch: 司令官が gh pr checks で外側の状態を確認し、済んでいれば cmux send で押すこと\n'
      printf 'watch: 画面が動いていれば誤検知。同じ画面では再通知しないので放置してよい\n'
      exit 0
    fi
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
