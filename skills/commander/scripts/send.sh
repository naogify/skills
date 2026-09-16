#!/usr/bin/env bash
# 部下に指示を送る。「入力欄に置いただけで Enter を押さず、部下が気づかないまま止まる」事故を
# 構造的に防ぐラッパー。
#   send.sh <mission-dir> <no> <text>
#   send.sh <mission-dir> <no> --stdin        （本文を標準入力から読む。下記参照）
#
# 生の `cmux send` は入力欄にテキストを置くだけで Enter を押さない。押し忘れると部下は
# 「指示が来ていない」まま止まり、司令官は「指示を出した」と思い込む
# （実際に部下2人が約1時間半アイドルした。入力欄の `❯` の直後に本文が見えたまま放置された）。
# `cmux send` の戻り値 `OK` は「ソケットが受け取った」ことの証拠でしかなく、
# 入力欄に届いたか・Enter が効いたかの証拠にはならない。
#
# このラッパーは cmux send → cmux send-key enter → 数秒待って read-screen で入力欄が
# 空になったか確認、を1コマンドにする。空になっていなければ enter を再送し、
# 既定回数（4回）試しても入力欄に居座っていればエラー終了する（司令官に画面を見させる）。
#
# 本文に `` ` `` や `$` を含めたいときは --stdin を使い、シングルクォート区切りの
# ヒアドキュメントで渡す（呼び出し側のシェルが展開しないので安全）:
#   bash send.sh "$MISSION" 12 --stdin <<'MSG'
#   検収が通りました。`gh pr merge` でマージしてください（squash は使わない）。
#   MSG
#
# 終了コード: 0=届いた（入力欄が空になった、または処理中でキューに積まれた）
#             1=既定回数試しても入力欄に本文が残ったまま（要介入）
#             2=呼び出しエラー
#             3=相手が Claude セッションに見えない（bash プロンプトだけ等）ため送信していない、
#               または送信後に Claude の UI が画面から消えた（要介入。部下が落ちている可能性）
#
# 事故: `spawn.sh` が信頼ダイアログで "No, exit" を選んでしまい部下が即終了し、
# bash プロンプトだけが残った状態に `send.sh` が2回とも「届いた」と報告した
# （入力欄が空かどうかしか見ておらず、bash プロンプトも打ち込んだ文字を実行して
#  消費するので「空になった」に見えてしまう）。これを塞ぐため、送信前後で
# 「画面に Claude の UI が実際に見えているか」を確認する（`claude_ui_present`）。
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "send: $*" >&2; exit 2; }
[ $# -ge 3 ] || die "usage: send.sh <mission-dir> <no> <text> | send.sh <mission-dir> <no> --stdin"
MISSION=$1; NO=$2; shift 2

command -v cmux >/dev/null || die "cmux が無い"
command -v jq   >/dev/null || die "jq が無い"
[ -d "$MISSION" ] || die "mission ディレクトリが無い: $MISSION"
ROSTER="$MISSION/roster.jsonl"
[ -s "$ROSTER" ] || die "roster が無い: $ROSTER"

row=$(jq -c --arg no "$NO" 'select((.no|tostring)==$no)' "$ROSTER" | tail -1)
[ -n "$row" ] || die "部下 $NO が roster にいない"
REF=$(printf '%s' "$row" | jq -r '.ws_ref // ""')
NAME=$(printf '%s' "$row" | jq -r '.name // ""')
[ -n "$REF" ] && [ "$REF" != "null" ] || die "roster に ws_ref が無い（部下 $NO）"
[ -f "$MISSION/workers/$NO/RETIRED" ] && die "部下 $NO は撤収済み（RETIRED）。送信先を確認する"

if [ "$1" = "--stdin" ]; then
  TEXT=$(cat)
else
  TEXT=$1
fi
[ -n "$TEXT" ] || die "本文が空"

# 入力欄が空（=送信できた）かどうかの判定。
# このハーネスの入力欄プロンプトは `❯`（U+276F）であることを実機で確認済み
# （素の `>` ではない。cmux-api.md / SKILL.md が例に挙げている `^ *> ` は一致しない）。
# 念のため両方の文字を見る。「プロンプト文字の直後に空白以外の文字が続く」行が
# あれば、本文がまだ入力欄に居座っている＝未送信。
prompt_has_text() {
  printf '%s' "$1" | grep -E '^[[:space:]]*[❯>][[:space:]]+[^[:space:]]' >/dev/null 2>&1
}

# 「入力欄は空に見えるが、折り返された本文の続きが ❯ の付かない行として画面の
# どこかに残っている」ケースを拾うための断片抽出（実際に3回、これで見逃した）。
# 先頭の空でない行の先頭24文字を断片として使う。
text_fragment() {
  local text=$1 line
  while IFS= read -r line; do
    case "$line" in
      *[![:space:]]*)
        line="${line#"${line%%[![:space:]]*}"}"
        printf '%s' "${line:0:24}"
        return
        ;;
    esac
  done <<EOF
$text
EOF
}

# 入力欄のプロンプト行が空に見えても、送った本文の断片が画面のどこかに
# 残っていれば「届いていない」とみなす。断片が短すぎる（8文字未満）場合は
# 誤検知を避けるため判定しない。
text_residue_present() {
  local scr=$1 frag
  frag=$(text_fragment "$TEXT")
  [ ${#frag} -ge 8 ] || return 1
  printf '%s' "$scr" | grep -qF -- "$frag"
}

# 画面が「Claude セッションのUI」を実際に出しているかを分類する。
# 手がかりは、このスキルの他スクリプト（spawn.sh / watch.sh）が実機で確認済みのものだけを使う
# （未検証の文字列を新たに当てにしない）:
#   - "esc to interrupt"      : 生成中（watch.sh の is_active と同じ）
#   - "tokens)"                : スピナー行 `✻ Cooking… (3m 21s · ↓ 4.2k tokens)` の一部
#   - "Bypassing Permissions"  : `--dangerously-skip-permissions` のモード表示
#   - "❯"                      : 入力欄・選択ダイアログのプロンプト文字（U+276F。素の `>` ではない）
# 既知の限界: bash 側のプロンプトを "❯" に変えるテーマ（starship 等）を使っていると
# 誤検知しうる。この worktree 環境では既定 bash プロンプトの前提で運用する
# （別 issue 候補。PR 本文に明記する）。
#
# "Enter to confirm"（信頼/権限ダイアログの共通フッター。spawn.sh が扱う2種類の
# 起動時ダイアログいずれにも実機で出現を確認済み）が出ているときは "dialog" として
# 別枠にする。ダイアログの上に本文を送るとキーが誤操作になりうるため、
# 「Claude は存在するが送ってはいけない」状態として扱い、送信をブロックする。
screen_state() {
  case "$1" in
    *"Enter to confirm"*) printf 'dialog\n' ;;
    *"esc to interrupt"*|*"tokens)"*|*"Bypassing Permissions"*|*"❯"*) printf 'ok\n' ;;
    *) printf 'absent\n' ;;
  esac
}

# 送信していい状態かを判定し、駄目なら理由付きで stderr に出す。0=送ってよい
verify_claude_present() {
  case "$(screen_state "$1")" in
    ok) return 0 ;;
    dialog)
      printf 'send: 部下%s %s（%s）: 確認ダイアログ（起動時の信頼/権限ダイアログ等）で止まっている。誤操作を避けるため送信しない\n' \
        "$NO" "$NAME" "$REF" >&2
      return 1 ;;
    *)
      printf 'send: 部下%s %s（%s）: 画面に Claude の UI が見当たらない（bash プロンプトだけの可能性）。送信しない\n' \
        "$NO" "$NAME" "$REF" >&2
      return 1 ;;
  esac
}

scr0=$(cmux read-screen --workspace "$REF" --lines 20 2>/dev/null)
if ! verify_claude_present "$scr0"; then
  printf '      cmux read-screen --workspace %s --lines 20 で画面を確認せよ。部下が落ちている可能性がある\n' "$REF" >&2
  exit 3
fi

attempt=0
for attempt in 1 2 3 4; do
  out=$(cmux send --workspace "$REF" "$TEXT" 2>&1) || die "cmux send 自体が失敗した: $out"
  cmux send-key --workspace "$REF" enter >/dev/null 2>&1
  sleep 3
  scr=$(cmux read-screen --workspace "$REF" --lines 12 2>/dev/null)

  # 部下がターン処理中だと queued 表示になる。届いてはいるので成功扱いにする
  # （次のターンで拾われる。SKILL.md 既知の挙動）。
  case "$scr" in
    *queued*)
      printf 'OK 部下%s %s（%s）: ターン処理中のためキューに積まれた（次のターンで届く。試行%s回）\n' \
        "$NO" "$NAME" "$REF" "$attempt"
      exit 0 ;;
  esac

  if ! verify_claude_present "$scr"; then
    printf '      送信前は Claude の UI が見えていたが、送信後の画面（試行%s回目）で見えなくなった。\n' "$attempt" >&2
    printf '      cmux read-screen --workspace %s --lines 20 で画面を確認せよ。部下が落ちている可能性がある\n' "$REF" >&2
    exit 3
  fi

  if ! prompt_has_text "$scr" && ! text_residue_present "$scr"; then
    printf 'OK 部下%s %s（%s）に届いた（入力欄が空になったことを確認。試行%s回）\n' \
      "$NO" "$NAME" "$REF" "$attempt"
    exit 0
  fi
  printf 'send: 試行%s回目: 入力欄に本文が残っている、または画面に断片が残っている。send-key enter を再試行する\n' "$attempt" >&2
done

printf 'send: 部下%s %s（%s）: %s回試しても入力欄に本文が残ったまま。cmux read-screen --workspace %s で画面を確認すること\n' \
  "$NO" "$NAME" "$REF" "$attempt" "$REF" >&2
exit 1
