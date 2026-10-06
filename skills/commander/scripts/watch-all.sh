#!/usr/bin/env bash
# 稼働中の全ミッションの部下を 1 本で見張り、司令官が動くべきことが起きたら知らせる。
#   watch-all.sh [--follow] [--interval 秒(既定 30)] [--max 秒(既定 3600)] [mission-dir...]
#
# ミッションを指定しなければ $COMMANDER_HOME（既定 ~/.claude/commander）配下の、撤収されていない
# 部下がいるミッション全部を見る。ミッション一覧と roster は**毎周読み直す**ので、部下を足しても
# ミッションを増やしても張り直しは要らない。
#
# 知らせるのは次の 4 種類だけ（1 件 = 1 行。行頭は "watch-all: "）:
#   done          STATUS.md が STATE: done になった（旧形式 REPORT.md の出現・更新も同じ扱い）
#   needs-answer  STATUS.md が STATE: needs-answer になった（旧形式 QUESTION.md / BLOCKED.md も同じ扱い）
#   dead          claude が動いていない（素のシェルに戻った=absent / 確認ダイアログで止まった=dialog）
#   unsent        入力欄に送ったはずの指示が残っている（長文が "[Pasted text ...]" のまま、
#                 または send.sh が最後に送った本文の先頭が入力欄に居座っている）
# STATE: in-progress の更新・todo の更新・「手が空いた」では知らせない（watch.sh のノイズの元）。
#
# 2 つの使い方:
#   既定      : 1 件以上見つけたらまとめて出し、最後に REARM: 行（張り直す正確なコマンド）を出して終わる。
#               Bash の run_in_background で走らせる用。--max 秒動きが無ければ REARM: を出して終わる
#   --follow  : 終わらずに、見つけるたびに行を出し続ける。Monitor ツール（persistent）に渡す用。
#               張り直しが要らない
#
# 同じ出来事は二度知らせない。既読は各ミッションの watch-all.seen に持つ
# （done / needs-answer はファイルの更新時刻ごとに 1 回。dead / unsent は WATCH_ALL_RENOTIFY_SEC
#  （既定 30 分）経つまで再通知しない）。張り直した瞬間に同じ内容で即発火することは無い。
#
# 事故（2026-10-05）: 司令官は 3 ミッションを同時に見張るため、1 ミッション用の watch.sh を使わず
# 自作のループ（STATUS.md の mtime を 30 秒ごとに比べる）を run_in_background で回していた。
# 部下を足すたびに止めて張り直していたところ、張り直しの 1 回が auto mode の分類器に拒否され、
# 見張りが無いまま人間に言われるまで部下の完了に気付かなかった。
# 「複数ミッションを 1 本で」「部下が増えても張り直し不要」「スキルの固定のスクリプト」を満たす
# 見張りがスキルに無かったことが自作の原因なので、それをここで用意する。
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "watch-all: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq が無い"

HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/watch-all.sh"
. "$HERE/claude-screen.sh"

HOME_DIR=${COMMANDER_HOME:-$HOME/.claude/commander}
RENOTIFY=${WATCH_ALL_RENOTIFY_SEC:-1800}
RECHECK=${WATCH_ALL_RECHECK_SEC:-5}

FOLLOW=0; IV=30; MAX=3600; ARGS_MISSIONS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --follow)   FOLLOW=1 ;;
    --interval) shift; IV=${1:-}; case "$IV" in ''|*[!0-9]*) die "--interval は秒数" ;; esac ;;
    --max)      shift; MAX=${1:-}; case "$MAX" in ''|*[!0-9]*) die "--max は秒数" ;; esac ;;
    --*)        die "unknown option: $1" ;;
    *)          [ -d "$1" ] || die "mission ディレクトリが無い: $1"
                ARGS_MISSIONS+=("$(cd "$1" && pwd)") ;;
  esac
  shift
done

# 張り直す正確なコマンド。許可ルール（settings の permissions.allow にある
# "Bash(bash <スキルのパス>/*)" 形式）に前方一致するよう、パスに空白が無い限り引用符で囲まない
# （囲むと "bash \"/Users/..." になり前方一致せず、毎回 auto mode の分類器に回される）。
q() { case "$1" in *[[:space:]\"\'\$\`]*) printf '"%s"' "$1" ;; *) printf '%s' "$1" ;; esac; }
rearm_line() {
  local s m
  s="REARM: bash $(q "$SELF") --interval $IV --max $MAX"
  for m in "${ARGS_MISSIONS[@]:-}"; do [ -n "$m" ] && s="$s $(q "$m")"; done
  printf '%s\n' "$s"
}

# 見張る対象のミッション。指定が無ければ毎周 HOME_DIR から拾い直す。
missions() {
  local d
  if [ "${#ARGS_MISSIONS[@]}" -gt 0 ]; then
    printf '%s\n' "${ARGS_MISSIONS[@]}"; return
  fi
  for d in "$HOME_DIR"/*/; do
    [ -s "${d}roster.jsonl" ] && printf '%s\n' "${d%/}"
  done
}

# 撤収されていない部下を "no<TAB>読む先(ws_id 優先)<TAB>name" で出す。
# ws_ref（workspace:N）は閉じたあと別のワークスペースに使い回されることがあるので、
# 古いミッションの部下が無関係な画面を読まないよう ws_id（UUID）を優先する。
live_workers() {
  local m=$1 no tgt name
  while IFS=$'\t' read -r no tgt name; do
    [ -n "$no" ] || continue
    [ -f "$m/workers/$no/RETIRED" ] && continue
    printf '%s\t%s\t%s\n' "$no" "$tgt" "$name"
  done < <(jq -r '[(.no|tostring), (if (.ws_id // "") != "" then .ws_id else (.ws_ref // "") end), (.name // "")] | @tsv' \
             "$m/roster.jsonl" 2>/dev/null | awk -F'\t' '{last[$1]=$0; if(!seen[$1]++) ord[++n]=$1} END{for(i=1;i<=n;i++) print last[ord[i]]}')
}

mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }

# 報告ファイルから「知らせるべき状態」を出す。"kind<TAB>key<TAB>要約" の行。in-progress は出さない。
report_events() {
  local wd=$1 st f k sum
  if [ -s "$wd/STATUS.md" ]; then
    case "$(LC_ALL=C head -n1 "$wd/STATUS.md")" in
      "STATE: done")         st="done" ;;
      "STATE: needs-answer") st=needs-answer ;;
      *)                     st="" ;;
    esac
    if [ -n "$st" ]; then
      sum=$(LC_ALL=C grep -av '^STATE:\|^#\|^[[:space:]]*$' "$wd/STATUS.md" | head -1 | cut -c1-120)
      printf '%s\tSTATUS:%s:%s\t%s\n' "$st" "$st" "$(mtime "$wd/STATUS.md")" "$sum"
    fi
    return
  fi
  for f in REPORT QUESTION BLOCKED; do
    [ -s "$wd/$f.md" ] || continue
    case "$f" in REPORT) k="done" ;; *) k=needs-answer ;; esac
    sum=$(LC_ALL=C grep -av '^#\|^[[:space:]]*$' "$wd/$f.md" | head -1 | cut -c1-120)
    printf '%s\t%s:%s\t%s(%s.md)\n' "$k" "$f" "$(mtime "$wd/$f.md")" "$sum" "$f"
  done
}

# 画面の 1 回分の観測。"dead<TAB>absent|dialog" / "unsent<TAB>入力欄の先頭" / 何も出さない（正常）。
screen_event() {
  local wd=$1 tgt=$2 scr st box frag
  [ -n "$tgt" ] || return 0
  scr=$(cmux read-screen --workspace "$tgt" --lines 40 2>/dev/null) || return 0
  [ -n "$scr" ] || return 0
  st=$(claude_screen_state "$scr")
  if [ "$st" != "ok" ]; then printf 'dead\t%s\n' "$st"; return 0; fi
  box=$(input_box_text "$scr")
  [ -n "$box" ] || return 0
  case "$box" in
    *"[Pasted text"*) printf 'unsent\t%s\n' "$(printf '%s' "$box" | head -1 | cut -c1-60)"; return 0 ;;
  esac
  # send.sh が最後に送った本文の先頭（LAST_SEND）が入力欄に居座っているか。
  # 入力欄の文字すべてを未送信と見なさないのは、Claude Code が入力欄に薄く出す
  # 入力候補（ゴーストテキスト）が read-screen では普通の文字と区別できないため。
  if [ -s "$wd/LAST_SEND" ]; then
    frag=$(head -c 200 "$wd/LAST_SEND" | tr -s '[:space:]' ' ' | sed 's/^ //' | cut -c1-24)
    if [ "${#frag}" -ge 8 ] && printf '%s' "$box" | tr -s '[:space:]' ' ' | grep -qF -- "$frag"; then
      printf 'unsent\t%s\n' "$(printf '%s' "$box" | head -1 | cut -c1-60)"
    fi
  fi
}

# 既読台帳（ミッションごと）: "no<TAB>key<TAB>epoch"
seen_get() { awk -F'\t' -v no="$2" -v k="$3" '$1==no && $2==k {print $3; f=1} END{exit !f}' "$1/watch-all.seen" 2>/dev/null | tail -1; }
seen_put() {
  local m=$1 no=$2 k=$3 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/watch-all.XXXXXX") || return 1
  { awk -F'\t' -v no="$no" -v k="$k" '!($1==no && $2==k)' "$m/watch-all.seen" 2>/dev/null
    printf '%s\t%s\t%s\n' "$no" "$k" "$(date +%s)"; } > "$tmp"
  mv "$tmp" "$m/watch-all.seen"
}
# 画面由来の出来事（dead/unsent）を通知してよいか。冷却時間内なら 1 を返す。
cooled() {
  local last; last=$(seen_get "$1" "$2" "$3")
  case "${last:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( $(date +%s) - last )) -ge "$RENOTIFY" ]
}

# 1 周分の走査。知らせる行を stdout に出し、出した分は既読にする。稼働中の人数を $ACTIVE に入れる。
ACTIVE=0
scan() {
  local m mb no tgt name wd line kind key sum ev1 ev2 cand=""
  ACTIVE=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    mb=$(basename "$m")
    while IFS=$'\t' read -r no tgt name; do
      ACTIVE=$((ACTIVE+1)); wd="$m/workers/$no"
      while IFS=$'\t' read -r kind key sum; do
        [ -n "$kind" ] || continue
        seen_get "$m" "$no" "$key" >/dev/null && continue
        printf 'watch-all: %s %s 部下%s %s: %s\n' "$kind" "$mb" "$no" "$name" "$sum"
        seen_put "$m" "$no" "$key"
      done < <(report_events "$wd")
      ev1=$(screen_event "$wd" "$tgt")
      [ -n "$ev1" ] && cand="${cand}${m}"$'\t'"${no}"$'\t'"${tgt}"$'\t'"${name}"$'\t'"${ev1}"$'\n'
    done < <(live_workers "$m")
  done < <(missions)

  # 画面由来は、起動直後や送信直後の一瞬を拾わないよう、間をあけてもう一度見て同じだったものだけ知らせる
  [ -n "$cand" ] || return 0
  sleep "$RECHECK"
  while IFS=$'\t' read -r m no tgt name kind sum; do
    [ -n "$m" ] || continue
    ev2=$(screen_event "$m/workers/$no" "$tgt")
    [ "$ev2" = "${kind}"$'\t'"${sum}" ] || continue
    cooled "$m" "$no" "$kind" || continue
    case "$kind" in
      dead)   line="claude が動いていない（${sum}。absent=素のシェルに戻った / dialog=確認ダイアログ）" ;;
      unsent) line="入力欄に未送信の指示が残っている（${sum}）。send.sh <mission> <no> --enter で Enter だけ送り直すか画面を確認する" ;;
    esac
    printf 'watch-all: %s %s 部下%s %s: %s\n' "$kind" "$(basename "$m")" "$no" "$name" "$line"
    seen_put "$m" "$no" "$kind"
  done <<< "$cand"
}

OUTF=$(mktemp "${TMPDIR:-/tmp}/watch-all-out.XXXXXX") || die "mktemp 失敗"
trap 'rm -f "$OUTF"' EXIT
waited=0
while :; do
  scan > "$OUTF"   # サブシェルにしない（ACTIVE を受け取るため）
  out=$(cat "$OUTF")
  if [ "$FOLLOW" = "1" ]; then
    [ -n "$out" ] && printf '%s\n' "$out"
  else
    if [ -n "$out" ]; then
      printf '%s\n' "$out"; rearm_line; exit 0
    fi
    if [ "$ACTIVE" = "0" ]; then
      printf 'watch-all: 稼働中の部下がいない。監視を終了する\n'; exit 0
    fi
    waited=$((waited+IV))
    if [ "$waited" -ge "$MAX" ]; then
      printf 'watch-all: %s 秒待ったが動きなし（稼働 %s 人）。張り直すこと\n' "$MAX" "$ACTIVE"
      rearm_line; exit 0
    fi
  fi
  sleep "$IV"
done
