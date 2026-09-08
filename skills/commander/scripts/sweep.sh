#!/usr/bin/env bash
# ターンの最初と最後に必ず回す掃除機。REPORT を書いて待機している未撤収の部下・
# 人間へ未報告の完了・見張り（watch.sh）の不在を、意志ではなく機械的に1画面で突き付ける。
#   sweep.sh <mission-dir> [--auto]
#
# --auto を付けると、REPORT.md がある部下について verify.sh → 通れば retire.sh まで自動で回す。
# **稼働中の部下を撤収してしまうので、動作確認以外の目的で不用意に付けない。**
#
# 終了コード: 0=処理すべきものが無い / 1=未処理（要対応）がある / 2=呼び出しエラー
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "sweep: $*" >&2; exit 2; }
[ $# -ge 1 ] || die "usage: sweep.sh <mission-dir> [--auto]"
MISSION=$1; AUTO=${2:-}
[ -d "$MISSION" ] || die "mission ディレクトリが無い: $MISSION"
ROSTER="$MISSION/roster.jsonl"
[ -s "$ROSTER" ] || die "部下がいない: $ROSTER"
command -v jq >/dev/null || die "jq が無い"
HERE="$(cd "$(dirname "$0")" && pwd)"

pending=0
printf '=== sweep: %s ===\n' "$MISSION"

# ── 1. 稼働中（未撤収）の部下を洗い出し、REPORT があるのに撤収されていない部下を先頭に突き付ける ──
starred=""
detail=""
active_count=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  no=$(printf '%s' "$row" | jq -r '.no'); name=$(printf '%s' "$row" | jq -r '.name')
  WDIR="$MISSION/workers/$no"
  [ -f "$WDIR/RETIRED" ] && continue
  active_count=$((active_count+1))

  rep=""; que=""; blk=""
  for f in REPORT QUESTION BLOCKED; do
    p="$WDIR/$f.md"
    [ -s "$p" ] || continue
    mt=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$p" 2>/dev/null || stat -c '%y' "$p" 2>/dev/null | cut -c1-16)
    case "$f" in
      REPORT)   rep="更新:${mt}" ;;
      QUESTION) que="更新:${mt}" ;;
      BLOCKED)  blk="更新:${mt}" ;;
    esac
  done

  if [ -n "$rep" ]; then
    starred="${starred}★ 部下${no} ${name}: REPORT.md あり（${rep}）だが未撤収\n"
  fi
  detail="${detail}部下${no} ${name}\n"
  detail="${detail}  REPORT.md:   ${rep:-なし}\n"
  detail="${detail}  QUESTION.md: ${que:-なし}\n"
  detail="${detail}  BLOCKED.md:  ${blk:-なし}\n"
done < "$ROSTER"

if [ -n "$starred" ]; then
  printf -- '--- ★ REPORT があるのに撤収されていない部下（最優先） ---\n'
  printf '%b' "$starred"
  pending=1
fi

printf -- '--- 稼働中の部下（%s 人） ---\n' "$active_count"
[ -n "$detail" ] && printf '%b' "$detail"

# ── 2. completed.log と reported.log の差分（★人間へ未報告の完了）──
# inbox.sh と同じロジック。inbox.sh は「新しい動きがあったとき」しか呼ばれないため、
# 動きが無いまま完了報告だけが放置されるケースを sweep.sh 側でも独立に検出する。
#
# 突き合わせは FILENAME で行う（`NR==FNR` ではない）。`reported.log` がまだ 1 行も無いとき、
# `NR==FNR` は 2 番目のファイルの最初の行でも真になってしまい、最初の未報告完了を
# 誤って握りつぶす（inbox.sh で実際に検証した落とし穴。同じ形に揃える）。
if [ -s "$MISSION/completed.log" ]; then
  unrep=$(awk -F'\t' -v rep="${MISSION}/reported.log" \
    'FILENAME==rep{seen[$2]=1;next} !($2 in seen)' \
    "${MISSION}/reported.log" "$MISSION/completed.log" 2>/dev/null \
    || cat "$MISSION/completed.log")
  if [ -n "$unrep" ]; then
    printf -- '--- ★人間へ未報告の完了（報告したら reported.sh で記録する） ---\n'
    printf '%s\n' "$unrep" | sed 's/^/  /'
    pending=1
  fi
fi

# ── 3. 稼働中の部下がいるのに watch.sh（見張り）が立っていなければ警告する ──
if [ "$active_count" -gt 0 ]; then
  if pgrep -f "watch[0-9]*\.sh.*${MISSION}" >/dev/null 2>&1; then
    printf -- '--- 見張り: watch.sh が稼働中 ---\n'
  else
    printf -- '--- ⚠ 見張り不在: 稼働中の部下が %s 人いるのに watch.sh が見つからない ---\n' "$active_count"
    printf '    bash %s/watch.sh "%s" をバックグラウンドで張り直すこと\n' "$HERE" "$MISSION"
    pending=1
  fi
fi

# ── --auto: REPORT のある部下を検収・撤収する ──
if [ "$AUTO" = "--auto" ]; then
  printf -- '--- --auto: REPORT のある部下を検収・撤収する ---\n'
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    no=$(printf '%s' "$row" | jq -r '.no')
    WDIR="$MISSION/workers/$no"
    [ -f "$WDIR/RETIRED" ] && continue
    [ -s "$WDIR/REPORT.md" ] || continue
    printf '部下%s を検収する\n' "$no"
    if bash "$HERE/verify.sh" "$MISSION" "$no"; then
      printf '部下%s を撤収する\n' "$no"
      bash "$HERE/retire.sh" "$MISSION" "$no" || printf 'warn: 部下%s の撤収に失敗した\n' "$no" >&2
    else
      printf '部下%s は検収を通らなかった（撤収しない。差し戻すこと）\n' "$no"
    fi
  done < "$ROSTER"
fi

if [ "$pending" = "1" ]; then
  printf '判定: 未処理あり（他の何よりも先に対応する）\n'; exit 1
else
  printf '判定: 未処理なし\n'; exit 0
fi
