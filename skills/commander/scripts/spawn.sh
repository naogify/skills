#!/usr/bin/env bash
# 部下を 1 人起動する。
#   spawn.sh <mission-dir> <no> <部下名> <説明> <cwd> [worktree] [repo] [base]
# [repo] は GitHub の slug（owner/name。gh --repo に渡す形）で渡す。ローカルパスではない
# （retire.sh が repo を機械的に扱えるのは worktree から git で導出した値だけで、
#  ここで渡した文字列をパスとして使うことはない）。
# 事前に <mission>/workers/<no>/PROMPT.md を書いておくこと。
# 起動できたら "OK workspace:<N>" と ref を出し、roster.jsonl に 1 行追記する。
#
# roster.jsonl への追記は「起動が本当に成立したか」を確認する前に行う。ワークスペース自体は
# 作られている（cmux 上に存在する）以上、retire.sh / board.sh から見えないと片付けられない
# ままになるため（roster に無いワークスペースは retire.sh が扱えない）。
# 起動確認に失敗した場合（信頼ダイアログで止まった・タイムアウトした）は roster には残したまま
# 終了コード 1 で失敗させ、<mission>/workers/<no>/SPAWN_FAILED に理由を書く。
# 「OK」が出た行だけが起動成功の証拠。
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "spawn: $*" >&2; exit 1; }

[ $# -ge 5 ] || die "usage: spawn.sh <mission-dir> <no> <name> <description> <cwd> [worktree] [repo] [base]"
MISSION=$1; NO=$2; NAME=$3; DESC=$4; CWD=$5; WT=${6:-}; REPO=${7:-}; BASE=${8:-}

command -v cmux >/dev/null || die "cmux が無い"
command -v jq   >/dev/null || die "jq が無い"
[ -d "$MISSION" ] || die "mission ディレクトリが無い: $MISSION"
[ -d "$CWD" ]     || die "作業場が無い: $CWD"

# 部下番号はファイルパスとJSONキーに使うので、安全な文字だけ許す
case "$NO" in
  ''|*[!A-Za-z0-9_-]*) die "部下番号に使えない文字がある: '$NO'（英数字と - _ のみ）" ;;
esac

# 同じ番号で二重起動すると roster が重複し、retire が別人を消しうる
if [ -s "$MISSION/roster.jsonl" ] \
   && jq -e --arg no "$NO" 'select((.no|tostring)==$no)' "$MISSION/roster.jsonl" >/dev/null 2>&1; then
  if [ -f "$MISSION/workers/$NO/RETIRED" ]; then
    die "部下番号 $NO は撤収済みとして記録がある。別の番号を使う"
  fi
  die "部下番号 $NO は既に roster にいる（二重起動）"
fi

WDIR="$MISSION/workers/$NO"
[ -s "$WDIR/PROMPT.md" ] || die "$WDIR/PROMPT.md が無い（空も不可）。指令書を先に書く"

# 指令書の検品。報告プロトコルが欠けた部下は「報告の仕方を知らない部下」になり、
# 司令官が永久に待つ。他の部下の PROMPT を切り貼りすると宛先ディレクトリがズレるのでそれも見る。
# 文字化けの判定は grep 系より先に行う。不正バイトがあると grep が一致せず、
# 「流用の可能性」という誤った診断が出る（実際に出た）。
# iconv は環境によって "Inappropriate ioctl for device" で落ちて誤検知するので使わない。
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import sys;open(sys.argv[1],"rb").read().decode("utf-8")' "$WDIR/PROMPT.md" 2>/dev/null \
    || die "$WDIR/PROMPT.md に不正なバイト列がある（文字化け）。作り直す"
else
  printf 'warn: python3 が無いので PROMPT.md の文字化け検査を省略した\n' >&2
fi
grep -q 'cmux todo' "$WDIR/PROMPT.md" \
  || die "$WDIR/PROMPT.md に報告プロトコルが無い（cmux todo が出てこない）。templates/ から作り直す"
grep -qF "$WDIR" "$WDIR/PROMPT.md" \
  || die "$WDIR/PROMPT.md の報告先が自分のディレクトリ($WDIR)になっていない。他の部下の指令書を流用した可能性"
grep -q '検証' "$WDIR/PROMPT.md" \
  || die "$WDIR/PROMPT.md に検証の節が無い（templates/worker-prompt.md から作り直す。「編集したファイルを読み返すのは検証ではない」を必ず含める）"

MODEL=${COMMANDER_MODEL:-sonnet}

cat > "$WDIR/run.sh" <<RUN
#!/usr/bin/env bash
set -euo pipefail
cd "$CWD"
exec claude --model $MODEL --dangerously-skip-permissions \\
  --name "$NAME" "\$(cat '$WDIR/PROMPT.md')"
RUN
chmod +x "$WDIR/run.sh"

# ミッションのグループに入れる（あれば）。グループが消えていたら単独で起動する
GROUP=""
[ -s "$MISSION/group.ref" ] && GROUP=$(head -1 "$MISSION/group.ref")
if [ -n "$GROUP" ]; then
  if out=$(cmux new-workspace --name "$NAME" --description "$DESC" --cwd "$CWD" \
             --group "$GROUP" --group-placement end \
             --command "bash '$WDIR/run.sh'" 2>&1); then
    :
  else
    printf 'warn: グループ %s への追加に失敗。単独で起動する\n' "$GROUP" >&2
    GROUP=""
  fi
fi
if [ -z "$GROUP" ]; then
  out=$(cmux new-workspace --name "$NAME" --description "$DESC" --cwd "$CWD" \
          --command "bash '$WDIR/run.sh'" 2>&1) || die "new-workspace 失敗: $out"
fi
ref=$(printf '%s' "$out" | grep -oE 'workspace:[0-9]+' | head -1)
[ -n "$ref" ] || die "ref が取れなかった: $out"

# ref は作り直すたびに変わるので、突き合わせ用の UUID も控える
id=$(cmux workspace list --json | jq -r --arg r "$ref" '.workspaces[] | select(.ref==$r) | .id')
[ -n "$id" ] && [ "$id" != "null" ] || die "workspace の UUID が取れなかった ($ref)"

jq -nc --arg no "$NO" --arg name "$NAME" --arg desc "$DESC" --arg ref "$ref" \
  --arg id "$id" --arg cwd "$CWD" --arg wt "$WT" --arg repo "$REPO" --arg base "$BASE" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg group "${GROUP:-}" \
  --arg start_sha "$(git -C "${WT:-$CWD}" rev-parse HEAD 2>/dev/null)" \
  '{no:$no,name:$name,description:$desc,ws_ref:$ref,ws_id:$id,cwd:$cwd,worktree:$wt,repo:$repo,base:$base,group:$group,start_sha:$start_sha,started_at:$at}' \
  >> "$MISSION/roster.jsonl" || die "roster への追記に失敗"

# 追記できていないと board / inbox / retire から見えない部下になる
jq -e --arg no "$NO" 'select((.no|tostring)==$no)' "$MISSION/roster.jsonl" >/dev/null 2>&1 \
  || die "roster に自分の行が見つからない（追記が失敗している）: $NO"

# サイドバーのピルは付けない（タイトルと重複するだけ。agent hook の
# "Needs input" ピルが本当に見たい情報で、そこにノイズを足さない）
# 進捗バーもログも出さない。サイドバーに出るのは
# タイトル / 説明 / チェックリスト / パス / agent hook の Needs input ピル だけにする

# 起動直後に出うる罠を検出する。1 ターンで両方出ることがあるので、
# 「走り始めた」と確認できるまでループを続ける（片方を処理したら break で抜けない）。
#
# 罠 1: 新しいディレクトリでは信頼ダイアログで止まる。
#   **これは自動で通さない。** 「pre-approves N tool permissions」の警告付き変種
#   （worktree に .claude/settings.local.json がある場合に出る。実例:
#     ⚠ This folder pre-approves 69 tool permissions in .claude/settings.local.json
#     ❯ No, exit
#       Yes, I trust this folder
#   ）はカーソルの既定位置が `No, exit` で、単純に Enter を送ると
#   「Yes, I trust this folder」ではなく「No, exit」が選ばれてセッションが即終了する
#   （実際に起きた事故。部下は一度も動かないまま、97分後に気付かれた。しかも残った
#    bash プロンプトに対して send.sh の旧い判定（入力欄が空かどうかしか見ない）が
#    「届いた」と誤報し続けた。send.sh 側の対策は別途 verify_claude_present で入れてある）。
#   信頼ダイアログの変種ごとに既定カーソル位置を確実に判別する手段が無いため、
#   検出したら自動応答せず起動失敗として扱う（安全側に倒す。無条件の自動承認は
#   任意のディレクトリの .claude/settings.local.json の権限を黙って有効化しうるため避ける）。
# 罠 2: `--dangerously-skip-permissions` を付けると実際に出るのは
#   "Bypass Permissions" の 2 択（"1. No, exit" / "2. Yes, I accept"）であって
#   "trust this folder" ではない。既定で `1. No, exit` にカーソルが乗っているため、
#   Enter だけ送ると **部下が即死する**（実際に起きた）。down → Enter で
#   `2. Yes, I accept` を選ぶ必要がある（こちらは変種が無く、安全に自動化できる）。
#
# 誤検知（実運用）: 8回 × 3秒 = 24秒の固定タイムアウトで「起動確認に失敗した」と
# 誤報したことがある。画面には `✢ Scurrying… (running SessionStart hooks… 5/6 · 25s)`
# の形（Claude Code のスピナー文字 + 経過時間）が出ており、実際は起動処理が進行中だった。
# 「一定時間待って諦める」ではなく「進行中の表示が出ている間は待ち続け、
# 進行中の表示が一度も見えないまま猶予（GRACE_WAIT）が切れたときだけ諦める」に変える
# （無条件に長く待つだけだと、本当に固まっている場合の失敗報告まで遅くなる）。
# 進行中かどうかは watch.sh の is_active() で実機確認済みのパターン
# （スピナー行 / 経過時間つきの `(...)`）を流用する。
# 猶予・上限・間隔は SPAWN_GRACE_WAIT_SEC / SPAWN_MAX_WAIT_SEC / SPAWN_POLL_INTERVAL_SEC
# で変更できる（selftest 用）。
starting_up() {
  case "$1" in
    *"esc to interrupt"*|*"tokens)"*) return 0 ;;
  esac
  # watch.sh の is_active() と同じ2パターン（実機確認済み）をそのまま使う。
  # 経過時間つきの `(3m 21s · ...)` 形と、スピナー行 `✻ Cooking… ...`。
  # 今回の事故の画面 `✢ Scurrying… (running SessionStart hooks… 5/6 · 25s)` は
  # 後者（行頭のスピナー文字）で拾える。
  printf '%s' "$1" | grep -qE '\([0-9]+m? ?[0-9]*s · ' && return 0
  printf '%s' "$1" | grep -qE '^[[:space:]]*[✻✳✢✽◑◯⏺][[:space:]]' && return 0
  return 1
}

POLL_INTERVAL=${SPAWN_POLL_INTERVAL_SEC:-3}
MAX_WAIT=${SPAWN_MAX_WAIT_SEC:-180}
GRACE_WAIT=${SPAWN_GRACE_WAIT_SEC:-30}
max_iters=$(( MAX_WAIT / POLL_INTERVAL ));   [ "$max_iters" -ge 1 ]   || max_iters=1
grace_iters=$(( GRACE_WAIT / POLL_INTERVAL )); [ "$grace_iters" -ge 1 ] || grace_iters=1

launched=0
blocked=""
i=0
stuck=0  # 進行中の表示も既知のダイアログも一度も見えないまま連続した回数
while [ "$i" -lt "$max_iters" ]; do
  i=$((i + 1))
  sleep "$POLL_INTERVAL"
  scr=$(cmux read-screen --workspace "$ref" --lines 20 2>/dev/null)
  case "$scr" in
    *"esc to interrupt"*|*"Bypassing Permissions"*) launched=1; break ;;  # 既に起動して走っている
  esac
  case "$scr" in
    *"No, exit"*"Yes, I accept"*|*"Bypass Permissions mode"*)
      cmux send-key --workspace "$ref" down  >/dev/null 2>&1
      cmux send-key --workspace "$ref" enter >/dev/null 2>&1
      stuck=0
      continue ;;
  esac
  case "$scr" in
    *"trust this folder"*)
      # 自動応答しない（罠1参照）。誤ったキーを送るより、ここで止めて人間に委ねる方が安全。
      blocked="trust_dialog"
      break ;;
  esac
  if starting_up "$scr"; then
    stuck=0  # SessionStart hooks 等で起動が進行中。待ち続ける（猶予をリセット）
  else
    stuck=$((stuck + 1))
    [ "$stuck" -lt "$grace_iters" ] || break  # 進行中の表示が一度も無いまま猶予切れ
  fi
done

if [ "$launched" != 1 ]; then
  reason=${blocked:-timeout}
  {
    date -u +%Y-%m-%dT%H:%M:%SZ
    printf '理由: %s\n' "$reason"
    printf '画面:\n%s\n' "$scr"
  } > "$WDIR/SPAWN_FAILED"
  printf 'spawn: 部下%s %s（%s）: 起動確認に失敗した（理由: %s）。roster には追記済みだが Claude が走っている確証が無い\n' \
    "$NO" "$NAME" "$ref" "$reason" >&2
  case "$reason" in
    trust_dialog)
      printf '        信頼ダイアログで止まっている可能性が高い。cmux read-screen --workspace %s --lines 20 で画面を確認し、\n' "$ref" >&2
      printf '        本当に信頼してよいディレクトリだと人間が判断したら手動で応答してから、再度この起動確認を行うこと\n' >&2
      printf '        （自動応答はしない。既定カーソルを誤って選ぶとセッションが即終了するため）\n' >&2
      ;;
    *)
      printf '        進行中の表示が一度も見えないまま %s 秒（最大 %s 秒）待っても起動を確認できなかった。\n' "$GRACE_WAIT" "$MAX_WAIT" >&2
      printf '        cmux read-screen --workspace %s --lines 20 で画面を確認すること\n' "$ref" >&2
      ;;
  esac
  exit 1
fi

printf 'OK %s  %s\n' "$ref" "$NAME"
printf 'ヒント: cmux read-screen --workspace %s --lines 20 で claude の起動を確認する\n' "$ref"
