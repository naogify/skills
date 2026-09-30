#!/usr/bin/env bash
# 稼働中の全ミッションを横断して、部下の状況と人間の判断が要るものを 1 画面で出す（読み取り専用）。
#   status.sh                    ~/.claude/commander/*/ のうち撤収されていない部下がいるミッション全部
#   status.sh <mission-dir>...   指定したミッションだけ
#
# 「部下の状況を教えて、自分の判断が必要なことがあれば教えて」を 1 コマンドにするためのもの。
# board.sh（1 ミッションの盤面）・inbox.sh（新着だけ・既読を記録する）と違い、
#   - 全ミッションを一度に見る
#   - 何も書き換えない（inbox.state も reported.log も触らない。何度回しても結果が変わらない）
# 出すもの: (a) 稼働中の部下 (b) 人間の判断が要るもの (c) 落ちている部下 (d) 人間へ未報告の完了
# 「返事待ち（人間が決めることではない、誰から何を）」は会話の文脈にしか無いのでここでは出さない。
# COMMANDER_HOME で ~/.claude/commander を差し替えられる（テスト用）。
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "status: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq が無い"

. "$(cd "$(dirname "$0")" && pwd)/claude-screen.sh"

HOME_DIR=${COMMANDER_HOME:-$HOME/.claude/commander}
STALE_MIN=${COMMANDER_STALE_MIN:-30}

if [ $# -ge 1 ]; then
  MISSIONS=("$@")
else
  MISSIONS=()
  for d in "$HOME_DIR"/*/; do
    [ -s "${d}roster.jsonl" ] && MISSIONS+=("${d%/}")
  done
fi

status_state() { # STATUS.md の 1 行目から状態を読む（board.sh と同じ規則）
  [ -s "$1" ] || return 1
  case "$(LC_ALL=C head -n1 "$1" 2>/dev/null)" in
    "STATE: done")         printf 'done\n' ;;
    "STATE: needs-answer") printf 'needs-answer\n' ;;
    "STATE: in-progress")  printf 'in-progress\n' ;;
    *) return 1 ;;
  esac
}

age_min() { # $1=ファイル。更新からの経過分
  local mt
  mt=$(stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null)
  [ -n "${mt:-}" ] || return 1
  printf '%d\n' $(( ( $(date -u +%s) - mt ) / 60 ))
}

first_line() { # 見出しと STATE 行を飛ばした最初の中身 1 行（60 字まで）
  LC_ALL=C grep -av '^STATE:\|^#\|^[[:space:]]*$' "$1" 2>/dev/null | head -1 | cut -c1-60
}

WS_JSON=$(cmux workspace list --json 2>/dev/null) || WS_JSON=''
printf '%s' "$WS_JSON" | jq -e '.workspaces' >/dev/null 2>&1 || WS_JSON=''

table=""; decide=""; down=""; unrep=""
n_active=0; n_mission=0

for MISSION in "${MISSIONS[@]:-}"; do
  [ -n "$MISSION" ] || continue
  ROSTER="$MISSION/roster.jsonl"
  [ -s "$ROSTER" ] || continue
  mname=$(basename "$MISSION")
  mission_active=0

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    no=$(printf   '%s' "$row" | jq -r '.no')
    name=$(printf '%s' "$row" | jq -r '.name')
    ref=$(printf  '%s' "$row" | jq -r '.ws_ref // ""')
    wid=$(printf  '%s' "$row" | jq -r '.ws_id // ""')
    WDIR="$MISSION/workers/$no"
    [ -f "$WDIR/RETIRED" ] && continue
    mission_active=1
    tag="${mname} 部下${no} ${name}"

    # (c) 落ちている: ワークスペースが無い。cmux が読めないときは断定しない
    if [ -n "$WS_JSON" ]; then
      alive=$(printf '%s' "$WS_JSON" | jq -r --arg id "$wid" '[.workspaces[] | select(.id==$id)] | length')
      if [ "$alive" = "0" ]; then
        down="${down}  ⚠ ${tag} — ワークスペースが無い（${ref:-ref 不明}）。retire.sh で締めるか再起動する"$'\n'
        continue
      fi
    fi
    n_active=$((n_active+1))

    # claude が動いていない: 画面がシェルのプロンプトに戻っている／確認ダイアログで止まっている。
    # 報告ファイルの有無より先に判定し、表の状態も上書きする（落ちた部下は報告を書かない）
    dead=""
    if [ -n "$ref" ]; then
      scr=$(cmux read-screen --workspace "$ref" --lines 8 2>/dev/null)
      if [ -n "$scr" ]; then
        case "$(claude_screen_state "$scr")" in
          absent) dead="💀claude停止"
                  down="${down}  ⚠ ${tag} — claude が動いていない（画面が素のシェルに戻っている）。cmux read-screen で確認し、run.sh を打ち直すか retire.sh で締める"$'\n' ;;
          dialog) dead="⚠ダイアログ停止"
                  down="${down}  ⚠ ${tag} — 確認ダイアログで止まっている。画面を確認し、Yes を選ぶ（Enter だけ送らない。既定が No, exit のことがある）"$'\n' ;;
        esac
      fi
    fi

    # 状態と待っているもの。STATUS.md（新形式）を先に見て、無ければ旧形式の報告ファイル
    state=""; wait_for=""; file=""
    sst=""; [ -s "$WDIR/STATUS.md" ] && sst=$(status_state "$WDIR/STATUS.md")
    if [ -s "$WDIR/STATUS.md" ]; then
      case "$sst" in
        needs-answer) state="❓確認待ち"; file="$WDIR/STATUS.md"; wait_for="司令官/人間の回答" ;;
        done)         state="✅検収待ち"; file="$WDIR/STATUS.md"; wait_for="検収・撤収" ;;
        in-progress)  state="▶作業中" ;;
        *)            state="⚠STATUS.md形式不正"; wait_for="STATE: 行の修正" ;;
      esac
    elif [ -s "$WDIR/BLOCKED.md" ];  then state="⛔行き詰まり"; file="$WDIR/BLOCKED.md";  wait_for="人間の判断"
    elif [ -s "$WDIR/QUESTION.md" ]; then state="❓確認待ち";   file="$WDIR/QUESTION.md"; wait_for="司令官/人間の回答"
    elif [ -s "$WDIR/PLAN.md" ];     then state="📋編成案あり"; file="$WDIR/PLAN.md";     wait_for="編成案の承認"
    elif [ -s "$WDIR/REPORT.md" ];   then state="✅検収待ち";   file="$WDIR/REPORT.md";   wait_for="検収・撤収"
    else
      lane=""
      [ -n "$ref" ] && lane=$(cmux workspace status --json --workspace "$ref" 2>/dev/null | jq -r '.effective // ""' 2>/dev/null)
      case "$lane" in
        working) state="▶作業中" ;;
        review)  state="👀レビュー待ち" ;;
        todo)    state="⏸待機" ;;
        "")      state="? 不明" ;;
        *)       state="$lane" ;;
      esac
    fi

    age=""; [ -n "$file" ] && age=$(age_min "$file")
    stale=""
    if [ -n "$age" ] && [ "$age" -ge "$STALE_MIN" ] 2>/dev/null; then stale="（${age}分放置）"; fi
    detail=""; [ -n "$file" ] && detail=$(first_line "$file")
    [ -z "$dead" ] || { state="$dead"; wait_for="復旧（claude が動いていない）"; }
    table="${table}  ${tag} | ${state}${stale} | ${wait_for:--}"$'\n'

    # (b) 人間の判断が要るもの: 確認待ち・行き詰まり・編成案・検収待ち
    case "$state" in
      ⛔*|❓*|📋*) decide="${decide}  ${state} ${tag}${stale}${detail:+ — $detail}"$'\n' ;;
      ✅*)        decide="${decide}  ${state} ${tag}${stale}: 検収して撤収/マージの GO を取る"$'\n' ;;
    esac
  done < "$ROSTER"

  # (d) 人間へ未報告の完了（completed.log − reported.log。inbox.sh と同じ突き合わせ）
  if [ -s "$MISSION/completed.log" ]; then
    # reported.log がまだ無いとき awk は存在しないファイルで落ちるので /dev/null に差し替える
    rep="$MISSION/reported.log"; [ -f "$rep" ] || rep=/dev/null
    u=$(awk -F'\t' -v rep="$rep" \
      'FILENAME==rep{seen[$2]=1;next} !($2 in seen){print $2 "\t" $3}' \
      "$rep" "$MISSION/completed.log" 2>/dev/null)
    while IFS=$'\t' read -r no nm; do
      [ -n "$no" ] && unrep="${unrep}  ✔ ${mname} 部下${no} ${nm}"$'\n'
    done <<< "$u"
  fi
  if [ "$mission_active" = "1" ]; then n_mission=$((n_mission+1)); fi
done

printf '\n━━━ 状況 ━━━ 稼働ミッション %d ・ 稼働中の部下 %d\n' "$n_mission" "$n_active"
printf '\n【落ちている部下】（最優先。claude が動いていない／ワークスペースが無い）\n'
if [ -n "$down" ]; then printf '%s' "$down"; else printf '  なし\n'; fi
if [ -n "$unrep" ]; then
  printf '\n【人間へ未報告の完了】（報告したら reported.sh で記録する）\n%s' "$unrep"
fi
printf '\n【稼働中の部下】（ミッション 部下 担当 | 状態 | 待っているもの）\n'
if [ -n "$table" ]; then printf '%s' "$table"; else printf '  なし\n'; fi
printf '\n【人間の判断が要るもの】\n'
if [ -n "$decide" ]; then printf '%s' "$decide"; else printf '  なし\n'; fi
printf '\n'
