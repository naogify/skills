#!/usr/bin/env bash
# 部下を 1 人起動する。
#   spawn.sh <mission-dir> <no> <部下名> <説明> <cwd> [worktree] [repo] [base]
# [repo] は GitHub の slug（owner/name。gh --repo に渡す形）で渡す。ローカルパスではない
# （retire.sh が repo を機械的に扱えるのは worktree から git で導出した値だけで、
#  ここで渡した文字列をパスとして使うことはない）。
# 事前に <mission>/workers/<no>/PROMPT.md を書いておくこと。
# 起動できたら "OK workspace:<N>" と ref を出し、roster.jsonl に 1 行追記する。
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

# 起動直後に出うる罠を自動で通す。1 ターンで両方出ることがあるので、
# 「走り始めた」と確認できるまでループを続ける（片方を処理したら break で抜けない）。
#
# 罠 1: 新しいディレクトリでは "Do you trust this folder?" で止まる → Enter で通る。
# 罠 2: `--dangerously-skip-permissions` を付けると実際に出るのは
#   "Bypass Permissions" の 2 択（"1. No, exit" / "2. Yes, I accept"）であって
#   "trust this folder" ではない。既定で `1. No, exit` にカーソルが乗っているため、
#   Enter だけ送ると **部下が即死する**（実際に起きた）。down → Enter で
#   `2. Yes, I accept` を選ぶ必要がある。
for _ in 1 2 3 4 5 6 7 8; do
  sleep 3
  scr=$(cmux read-screen --workspace "$ref" --lines 20 2>/dev/null)
  case "$scr" in
    *"esc to interrupt"*|*"Bypassing Permissions"*) break ;;  # 既に起動して走っている
  esac
  case "$scr" in
    *"No, exit"*"Yes, I accept"*|*"Bypass Permissions mode"*)
      cmux send-key --workspace "$ref" down  >/dev/null 2>&1
      cmux send-key --workspace "$ref" enter >/dev/null 2>&1
      continue ;;
  esac
  case "$scr" in
    *"trust this folder"*)
      cmux send-key --workspace "$ref" enter >/dev/null 2>&1
      continue ;;
  esac
done

printf 'OK %s  %s\n' "$ref" "$NAME"
printf 'ヒント: cmux read-screen --workspace %s --lines 20 で claude の起動を確認する\n' "$ref"
