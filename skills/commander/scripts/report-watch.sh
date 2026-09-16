#!/usr/bin/env bash
# 部下からの報告ファイルの出現・更新を検知し、動くたびに1行ずつ出し続ける（live reload方式）。
#   report-watch.sh <mission-dir> [--no-catch-up]
#
# `Monitor` ツールの command として渡す想定。stdout の1行が1通知になる仕組みなので、
# ここで出すのは「司令官が行動すべき1件」だけに絞り、生ログは出さない。
#
# `watch.sh` は「動きが出るまで待って、出たら終了する」設計で、1回発火したら死ぬため
# 司令官が毎回張り直す必要があった。張り直しを怠って部下45・46の報告に気付かなかった事故（事故2）、
# そして「そもそも張らなくなり、14人起動・8人が報告済みでも1件も拾えなかった」事故（事故3、
# 2026-09-15 00:04〜09-16 10:16）を踏まえ、gulp/vite のような常駐 watcher に切り替える。
#
# `Monitor` の `persistent`（セッション終了まで再起動不要）は環境によって使える場合と
# 使えない場合がある（使えない環境では `timeout_ms` 上限＝最大30分で必ず kill され、
# 張り直しが要る）。このスクリプト自体はどちらの環境でも同じに動く。持続時間の面倒は
# `Monitor` を呼ぶ側（司令官）が見る。期限切れは `Monitor` 自身が必ず通知するので、
# 「張り直しを忘れて誰も気付かない」という事故3の核心は、環境によらずこれで防げる。
#
# fswatch があれば FSEvents/inotify ベースで即座に検知する。無い環境では
# 同じ出力契約のままポーリングにフォールバックする。
# どちらで動いているかは stderr に1行出す（stdout に出すと `Monitor` の通知になってしまうため）。
set -uo pipefail

die() { printf 'report-watch: %s\n' "$*" >&2; exit 2; }

MISSION=""
CATCH_UP=1
for arg in "$@"; do
  case "$arg" in
    --no-catch-up) CATCH_UP=0 ;;
    --*) die "unknown option: $arg" ;;
    *)
      if [ -z "$MISSION" ]; then
        MISSION=$arg
      else
        die "usage: report-watch.sh <mission-dir> [--no-catch-up]"
      fi
      ;;
  esac
done
[ -n "$MISSION" ] || die "usage: report-watch.sh <mission-dir> [--no-catch-up]"
[ -d "$MISSION" ] || die "mission ディレクトリが無い: $MISSION"
WORKERS="$MISSION/workers"
[ -d "$WORKERS" ] || die "workers ディレクトリが無い: $WORKERS"

# テスト・チューニング用のノブ（既定値のまま使えば普段は意識しなくてよい）
DEBOUNCE_SEC=${REPORT_WATCH_DEBOUNCE_SEC:-5}
POLL_INTERVAL=${REPORT_WATCH_POLL_INTERVAL:-2}
FORCE_POLL=${REPORT_WATCH_FORCE_POLL:-0}

# 拾うのはこの5種類だけ（判断に使う中身が入るファイル）。PROMPT.md 等の指令書は対象外。
is_report_file() {
  case "$(basename "$1")" in
    REPORT.md|QUESTION.md|BLOCKED.md|PR.md|INTERIM.md) return 0 ;;
    *) return 1 ;;
  esac
}

# 「部下<N> <種別>: <冒頭2行>」の1行にまとめて出す。撤収済み（RETIRED がある）は無視する。
declare -A LAST_EMIT_TIME
emit_report_line() {
  local p="$1" d n kind head1 now prev
  d=$(dirname "$p")
  [ -f "$d/RETIRED" ] && return 0
  [ -s "$p" ] || return 0
  now=$(date +%s)
  prev=${LAST_EMIT_TIME[$p]:-0}
  if [ $((now - prev)) -lt "$DEBOUNCE_SEC" ]; then
    return 0
  fi
  LAST_EMIT_TIME[$p]=$now
  n=$(basename "$d")
  kind=$(basename "$p" .md)
  head1=$(LC_ALL=C grep -av '^[[:space:]]*$' "$p" 2>/dev/null | head -2 | tr '\n' ' ' | cut -c1-150)
  printf '部下%s %s: %s\n' "$n" "$kind" "$head1"
}

# 監視対象の報告ファイルを列挙する（find の1回分）
find_report_files() {
  find "$WORKERS" -mindepth 2 -maxdepth 2 -type f \
    \( -name 'REPORT.md' -o -name 'QUESTION.md' -o -name 'BLOCKED.md' -o -name 'PR.md' -o -name 'INTERIM.md' \) \
    -print0 2>/dev/null
}

get_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }

# --catch-up: 起動前から存在する報告を1回だけ出す。
# `Monitor` は「これから起きる変化」しか拾わないので、仕掛ける前から積もっていた報告は
# ここで出さない限り永遠に流れない（事故3はこれが起きた状態のまま34時間放置された）。
declare -A SEEN_MTIME
run_catch_up() {
  # --no-catch-up でも、ポーリング経路の「初回スキャンは全部 新規 に見える」問題を防ぐため
  # 既存ファイルの mtime だけは必ず記録する（記録しないと、fswatch と違ってポーリングは
  # 最初の1周で既存ファイルを「変化した」と誤検知し、--no-catch-up を無視して出してしまう）。
  # 出すかどうかだけを CATCH_UP で分ける。
  while IFS= read -r -d '' p; do
    SEEN_MTIME["$p"]=$(get_mtime "$p")
    [ "$CATCH_UP" = "1" ] && emit_report_line "$p"
  done < <(find_report_files)
}

watch_with_fswatch() {
  printf 'report-watch: fswatch で監視する（%s）\n' "$WORKERS" >&2
  fswatch -r -0 --event Created --event Updated --event Renamed --event MovedTo "$WORKERS" 2>/dev/null \
  | while IFS= read -r -d '' p; do
      is_report_file "$p" || continue
      emit_report_line "$p"
    done
}

watch_with_polling() {
  printf 'report-watch: fswatch が無いためポーリングにフォールバックする（%s秒間隔）\n' "$POLL_INTERVAL" >&2
  while :; do
    while IFS= read -r -d '' p; do
      local m prev
      m=$(get_mtime "$p")
      prev=${SEEN_MTIME[$p]:-}
      if [ "$prev" != "$m" ]; then
        SEEN_MTIME[$p]=$m
        emit_report_line "$p"
      fi
    done < <(find_report_files)
    sleep "$POLL_INTERVAL"
  done
}

run_catch_up

if [ "$FORCE_POLL" != "1" ] && command -v fswatch >/dev/null 2>&1; then
  watch_with_fswatch
else
  watch_with_polling
fi
