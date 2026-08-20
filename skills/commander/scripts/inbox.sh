#!/usr/bin/env bash
# 部下から上がってきた新しい情報だけを出す（レベルトリガ）。
#   inbox.sh <mission-dir>          出して「見た」ことを記録する
#   inbox.sh <mission-dir> --peek   出すだけ（記録しない。待機ループの条件に使う）
#
# 報告ファイルの出現・更新が唯一の正。部下は notify も log も set-progress も使わない
# （サイドバーを汚さないため）。ここで見るのは:
#   1. 報告ファイル  … REPORT/QUESTION/BLOCKED/PLAN/PR.md。判断に使う中身はここだけ
#   2. チェックリスト … 進捗の表明（board.sh が進捗率に使う）
#   3. cmux 通知     … cmux 自身の agent hook 由来（"Completed" = 手が空いた）。
#      サーフェスごとに最新 1 件しか残らず上書きされるので、判断の根拠にはしない。
#      消化したら dismiss して、サイドバーに通知本文が居座らないようにする
#   4. cmux log      … 部下は使わない前提。人間が手で書いた分があれば拾う
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "inbox: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: inbox.sh <mission-dir> [--peek]"
MISSION=$1; PEEK=${2:-}
[ -d "$MISSION" ] || die "mission ディレクトリが無い: $MISSION"
ROSTER="$MISSION/roster.jsonl"
[ -s "$ROSTER" ] || die "部下がいない: $ROSTER"
command -v jq >/dev/null || die "jq が無い"

STATE="$MISSION/inbox.state"
[ -f "$STATE" ] || : > "$STATE" || die "状態ファイルを作れない: $STATE"
NEW_STATE=$(mktemp "${TMPDIR:-/tmp}/inbox.XXXXXX") || die "mktemp 失敗"
trap 'rm -f "$NEW_STATE"' EXIT

# 状態は TAB 区切りで持つ（キーに | を含むので | は区切りに使えない）
get_state() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$STATE"; }
put_state() { printf '%s\t%s\n' "$1" "$2" >> "$NEW_STATE"; }

NOTES=$(cmux list-notifications --json 2>/dev/null) || NOTES='[]'
out=""

# 人間へ未報告の完了を最初に出す。「作業中は黙る」と「撤収は聞かない」を組み合わせると
# 「完了も黙る」になりがちなので、構造的に突き付ける（実際に報告漏れが起きた）。
if [ -s "$MISSION/completed.log" ]; then
  unrep=$(awk -F'\t' 'NR==FNR{seen[$2]=1;next} !($2 in seen)' \
    "${MISSION}/reported.log" "$MISSION/completed.log" 2>/dev/null \
    || cat "$MISSION/completed.log")
  if [ -n "$unrep" ]; then
    out="${out}★人間へ未報告の完了（報告したら reported.log に追記する）"$'\n'
    while IFS=$'\t' read -r at no nm; do
      [ -n "$no" ] && out="${out}  ✔ 部下${no} ${nm}（${at}）"$'\n'
    done <<< "$unrep"
    out="${out}"$'\n'
  fi
fi

while IFS= read -r row; do
  [ -n "$row" ] || continue
  no=$(printf   '%s' "$row" | jq -r '.no')
  name=$(printf '%s' "$row" | jq -r '.name')
  ref=$(printf  '%s' "$row" | jq -r '.ws_ref')
  wid=$(printf  '%s' "$row" | jq -r '.ws_id')
  WDIR="$MISSION/workers/$no"
  [ -f "$WDIR/RETIRED" ] && continue
  hdr="部下${no} ${name} (${ref})"
  buf=""

  # 1. ログ（追記型）。件数が減っていたら cmux 側で切り詰められたので読み直す
  logs=$(cmux list-log --workspace "$ref" 2>/dev/null | grep -v '^No log entries$') || logs=""
  lcount=$(printf '%s' "$logs" | grep -c . 2>/dev/null)
  case "$lcount" in ''|*[!0-9]*) lcount=0 ;; esac
  key="$no|log"
  prev=$(get_state "$key"); prev=${prev:-0}
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  [ "$lcount" -lt "$prev" ] && prev=0
  if [ "$lcount" -gt "$prev" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] && buf="${buf}     ${l}"$'\n'
    done <<< "$(printf '%s\n' "$logs" | grep . | tail -n "$((lcount-prev))")"
  fi
  put_state "$key" "$lcount"

  # 2. 報告ファイル（判断に使う中身。新規・更新だけ出す）
  for f in BLOCKED QUESTION PLAN REPORT PR; do
    p="$WDIR/$f.md"
    [ -s "$p" ] || continue
    fp=$(stat -f '%z:%m' "$p" 2>/dev/null || stat -c '%s:%Y' "$p" 2>/dev/null)
    key="$no|file:$f"
    if [ "$(get_state "$key")" != "$fp" ]; then
      case "$f" in
        BLOCKED)  buf="${buf}  ⛔ BLOCKED（人間へ差し戻す）: ${p}"$'\n' ;;
        QUESTION) buf="${buf}  ❓ QUESTION（回答が必要）: ${p}"$'\n' ;;
        PLAN)     buf="${buf}  📋 PLAN（編成案。人間の承認を取る）: ${p}"$'\n' ;;
        REPORT)   buf="${buf}  ✅ REPORT（検収する）: ${p}"$'\n' ;;
        PR)       buf="${buf}  📄 PR: $(head -3 "$p" | tr '\n' ' ')"$'\n' ;;
      esac
      buf="${buf}$(sed -n '1,6p' "$p" | sed 's/^/       /')"$'\n'
    fi
    put_state "$key" "$fp"
  done

  # 3. 通知（最新 1 件のみ。上書きされる前提。判断の根拠にはしない）
  note=$(printf '%s' "$NOTES" | jq -c --arg id "$wid" 'map(select(.workspace_id==$id)) | sort_by(.created_at) | last // empty')
  if [ -n "$note" ]; then
    nid=$(printf '%s' "$note" | jq -r '.id')
    key="$no|note"
    if [ "$(get_state "$key")" != "$nid" ]; then
      t=$(printf '%s' "$note" | jq -r '.title'); s=$(printf '%s' "$note" | jq -r '.subtitle // ""')
      b=$(printf '%s' "$note" | jq -r '.body // ""')
      case "$t" in
        REPORT|QUESTION|BLOCKED|PROGRESS|PLAN) buf="${buf}  🔔 [${t}] ${b}"$'\n' ;;
        *)
          case "$s$b" in
            *Completed*|*完了*) buf="${buf}  ⏹ 手が空いた（${s}）— REPORT が無いなら異常終了か待機中"$'\n' ;;
            *[Ww]aiting*|*入力待*) buf="${buf}  ⌨ 入力待ちで止まっている（${s}）"$'\n' ;;
            *) buf="${buf}  • ${t} / ${s} / ${b}"$'\n' ;;
          esac ;;
      esac
    fi
    put_state "$key" "$nid"
  fi

  [ -n "$buf" ] && out="${out}${hdr}"$'\n'"${buf}"$'\n'
done < "$ROSTER"

if [ "$PEEK" != "--peek" ]; then
  # 今回触らなかったキー（撤収済みの部下など）の行を落とさずに引き継ぐ
  awk -F'\t' 'NR==FNR{seen[$1]=1;next} !($1 in seen)' "$NEW_STATE" "$STATE" >> "$NEW_STATE" \
    || die "状態ファイルの引き継ぎに失敗"
  cp "$NEW_STATE" "$STATE" || die "状態ファイルの更新に失敗"
fi

printf '%s' "$out"
