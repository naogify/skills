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
MISSION=$1; PEEK=${2:-}; LEDGER=${3:-}
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

# 担当 PR が既にマージ / クローズされているのに撤収されていない部下を突き付ける。
# 司令官がマージした後に撤収を忘れ、ワークスペースと worktree が残り続けた実害がある。
stale=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  no=$(printf '%s' "$row" | jq -r '.no'); rp=$(printf '%s' "$row" | jq -r '.repo // ""')
  [ -f "$MISSION/workers/$no/RETIRED" ] && continue
  # PR番号は workers/<no>/PR.md の実物から読む。部下番号をそのままPR番号として使うと、
  # 無関係な既存PR（例: 部下8 → 別件でマージ済みの PR #8）に衝突して「マージ済み」と
  # 誤検知し、作業中の部下を撤収＝worktreeごと破棄させかねない（実際に誤報が出た）。
  prf="$MISSION/workers/$no/PR.md"
  [ -f "$prf" ] || continue
  prnum=$(LC_ALL=C grep -aoE 'pull/[0-9]+' "$prf" 2>/dev/null | head -1 | sed 's|pull/||')
  [ -n "$prnum" ] || prnum=$(LC_ALL=C grep -aoE '#[0-9]+' "$prf" 2>/dev/null | head -1 | tr -d '#')
  case "$prnum" in ''|*[!0-9]*) continue ;; esac
  [ -n "$rp" ] || continue
  # roster.jsonl の repo は基本 slug（owner/name）で入っている。過去の形式でローカルパスが
  # 渡されていた場合だけ git remote から slug を導出する（slug 前提だと git -C がパスとして
  # 解釈できず fatal で落ち、この片付け漏れ検知自体が丸ごと動かなくなっていた）。
  slug="$rp"
  if [ -d "$rp" ]; then
    slug=$(git -C "$rp" remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+)(\.git)?$#\1#; s#\.git$##')
  fi
  [ -n "$slug" ] || continue
  st=$(gh pr view "$prnum" --repo "$slug" --json state --jq '.state' 2>/dev/null)
  case "$st" in MERGED|CLOSED) stale="${stale}  ⬛ 部下${no}: PR #${prnum} は ${st} 済みなのに撤収されていない"$'\n' ;; esac
done < "$ROSTER"
if [ -n "$stale" ]; then
  out="${out}★片付け漏れ（retire.sh を回す）"$'\n'"${stale}"$'\n'
fi

# 人間へ未報告の完了を最初に出す。「作業中は黙る」と「撤収は聞かない」を組み合わせると
# 「完了も黙る」になりがちなので、構造的に突き付ける（実際に報告漏れが起きた）。
#
# 突き合わせは FILENAME で行う（`NR==FNR` ではない）。`reported.log` がまだ 1 行も無い
# （ミッション最初の完了報告がまだ人間に伝わっていない、一番検知したい瞬間）とき、
# `NR==FNR` は「1 番目のファイルが 0 行なら 2 番目のファイルの最初の行でも NR==FNR が
# 真になる」という awk の落とし穴を踏み、その 1 行を誤って `seen` に入れて握りつぶす
# （検証: 空の reported.log に対して `NR==FNR` は最初の未報告完了を出力しない）。
if [ "$LEDGER" != "--no-ledger" ] && [ -s "$MISSION/completed.log" ]; then
  unrep=$(awk -F'\t' -v rep="${MISSION}/reported.log" \
    'FILENAME==rep{seen[$2]=1;next} !($2 in seen)' \
    "${MISSION}/reported.log" "$MISSION/completed.log" 2>/dev/null \
    || cat "$MISSION/completed.log")
  if [ -n "$unrep" ]; then
    out="${out}★人間へ未報告の完了（報告したら reported.log に追記する）"$'\n'
    while IFS=$'\t' read -r at no nm dg; do
      [ -n "$no" ] && out="${out}  ✔ 部下${no} ${nm}（${at}）"$'\n'
      [ -n "${dg:-}" ] && out="${out}      成果物: ${dg}"$'\n'
    done <<< "$unrep"
    out="${out}  → **他の作業より先に、これを人間に報告する**"$'\n'
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
            *Completed*|*完了*)
              # cmux の agent hook 通知は、部下がまだ作業中（画面に "Forging…" 等が出ている）
              # でも "Completed" を出すことがある（実際に 6 回以上、全部が誤検知だった）。
              # 画面が本当に停止しているかを軽く裏取りしてから出す。「esc to interrupt」が
              # 見えるならまだ動いているので、この行自体を出さない（ノイズを減らす方が
              # 検知能力は上がる。裏取りできない＝画面が読めない場合は空振りより実害の方が
              # 大きいので出す側に倒す）。
              scr2=$(cmux read-screen --workspace "$ref" --lines 6 2>/dev/null)
              case "$scr2" in
                *"esc to interrupt"*) : ;;
                *) buf="${buf}  ⏹ 手が空いた（${s}）— REPORT が無いなら異常終了か待機中"$'\n' ;;
              esac ;;
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
  # 今回触らなかったキー（撤収済みの部下など）の行を落とさずに引き継ぐ。
  # FILENAME で突き合わせる（`NR==FNR` は 1 番目のファイルが 0 行だと 2 番目の最初の行でも
  # 真になる。上の未報告完了の突き合わせと同じ落とし穴なので同じ形に揃える）。
  awk -F'\t' -v new="$NEW_STATE" 'FILENAME==new{seen[$1]=1;next} !($1 in seen)' "$NEW_STATE" "$STATE" >> "$NEW_STATE" \
    || die "状態ファイルの引き継ぎに失敗"
  cp "$NEW_STATE" "$STATE" || die "状態ファイルの更新に失敗"
fi

printf '%s' "$out"
