#!/usr/bin/env bash
# 部下の作業状況を 1 画面で出す（人間にそのまま見せる用）。
#   board.sh <mission-dir>
# 数値はすべて cmux から実測した値。推測で埋めない。
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "board: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: board.sh <mission-dir>"
MISSION=$1

# 新形式（STATUS.md）の1行目から状態を読む。旧形式（REPORT/QUESTION/BLOCKED/PLAN.md）と
# 共存する過渡期のため、STATUS.md が無い部下は今まで通り旧形式のファイルで判定する。
status_state() {
  [ -s "$1" ] || return 1
  case "$(LC_ALL=C head -n1 "$1" 2>/dev/null)" in
    "STATE: done")         printf 'done\n' ;;
    "STATE: needs-answer") printf 'needs-answer\n' ;;
    "STATE: in-progress")  printf 'in-progress\n' ;;
    *) return 1 ;;
  esac
}
[ -d "$MISSION" ] || die "mission ディレクトリが無い: $MISSION"
ROSTER="$MISSION/roster.jsonl"
[ -s "$ROSTER" ] || die "部下がいない: $ROSTER"

# QUESTION.md / BLOCKED.md を「放置されている」とみなす経過分数。
# 実際に QUESTION.md が 4 日間気づかれなかった事故があるので、既定は短めの 30 分にする
# （sweep.sh と揃える。COMMANDER_STALE_MIN で上書きできる）。
STALE_MIN=${COMMANDER_STALE_MIN:-30}
# 1人の部下に何件も積み増しされていないかの目安。積み増しは直列化と REPORT の停滞を招く
# （事故: 1部下に10件積んで報告が最初の1件のまま止まった）。COMMANDER_TODO_OVERLOAD で上書きできる。
TODO_OVERLOAD=${COMMANDER_TODO_OVERLOAD:-6}

stale_suffix() { # $1=ファイルパス。放置分数がしきい値以上なら警告文字列を返す
  p="$1"
  mt_epoch=$(stat -f '%m' "$p" 2>/dev/null || stat -c '%Y' "$p" 2>/dev/null)
  [ -n "${mt_epoch:-}" ] || return 0
  mins=$(( ( $(date -u +%s) - mt_epoch ) / 60 ))
  if [ "$mins" -ge "$STALE_MIN" ] 2>/dev/null; then
    printf ' ⚠ %s分放置（%s分以上は警告）' "$mins" "$STALE_MIN"
  fi
}

# 人間から「今どうなってる？」と聞かれたときに、まずここだけ読めば済むようにする banner。
# 実際の事故: 部下が REPORT.md / QUESTION.md を書いていたのに、司令官はワークスペース一覧と
# 報告ファイルの有無しか見ておらず、QUESTION.md の中身（4日放置）に気付かなかった。
# per-worker の詳細に埋もれさせず、先頭にまとめて突き付ける。
must_see=""

bar() { # $1=0.0-1.0  $2=幅
  awk -v p="${1:-0}" -v w="${2:-24}" 'BEGIN{
    if (p=="" || p=="none") p=0; p=p+0;
    if (p<0) p=0; if (p>1) p=1;
    f=int(p*w+0.5); s="";
    for(i=0;i<f;i++) s=s "\xe2\x96\x88";      # █
    for(i=f;i<w;i++) s=s "\xe2\x96\x91";      # ░
    printf "%s %3d%%", s, int(p*100+0.5);
  }'
}

WS_JSON=$(cmux workspace list --json 2>&1) || die "workspace list 失敗: $WS_JSON"

n_total=0; n_active=0; n_retired=0; n_attn=0; n_done=0; sum=0
lines=""

while IFS= read -r row; do
  [ -n "$row" ] || continue
  no=$(printf   '%s' "$row" | jq -r '.no')
  name=$(printf '%s' "$row" | jq -r '.name')
  ref=$(printf  '%s' "$row" | jq -r '.ws_ref')
  wid=$(printf  '%s' "$row" | jq -r '.ws_id')
  wt=$(printf   '%s' "$row" | jq -r '.worktree // ""')
  started=$(printf '%s' "$row" | jq -r '.started_at // ""')
  n_total=$((n_total+1))
  WDIR="$MISSION/workers/$no"

  if [ -f "$WDIR/RETIRED" ]; then
    n_retired=$((n_retired+1))
    lines="${lines}  ⬛ 部下${no} ${name} — 撤収済み"$'\n'
    continue
  fi

  alive=$(printf '%s' "$WS_JSON" | jq -r --arg id "$wid" '[.workspaces[] | select(.id==$id)] | length')
  if [ "$alive" = "0" ]; then
    lines="${lines}  ⚠ 部下${no} ${name} — ワークスペースが見つからない（${ref} は消えている）"$'\n'
    lines="${lines}      → 人間が閉じたか異常終了。撤収記録が無いので retire.sh で締めるか再起動する"$'\n'
    continue
  fi
  n_active=$((n_active+1))

  # 進捗: 部下が set-progress した値を優先し、無ければ todo の消化率から出す
  sb=$(cmux sidebar-state --workspace "$ref" 2>/dev/null)
  prog_line=$(printf '%s' "$sb" | sed -n 's/^progress=//p' | head -1)
  pct=""; plabel=""
  if [ -n "$prog_line" ] && [ "$prog_line" != "none" ]; then
    pct=${prog_line%% *}
    plabel=$(printf '%s' "$prog_line" | cut -d' ' -f2-)
    [ "$plabel" = "$pct" ] && plabel=""
  fi
  todo=$(cmux todo list --json --workspace "$ref" 2>/dev/null)
  tdone=$(printf '%s' "$todo" | jq -r '.progress.completed // 0' 2>/dev/null); tdone=${tdone:-0}
  ttot=$(printf  '%s' "$todo" | jq -r '.progress.total // 0'     2>/dev/null); ttot=${ttot:-0}
  tnext=$(printf '%s' "$todo" | jq -r '.progress.first_unchecked_text // ""' 2>/dev/null)
  if [ -z "$pct" ] && [ "$ttot" -gt 0 ] 2>/dev/null; then
    pct=$(awk -v d="$tdone" -v t="$ttot" 'BEGIN{printf "%.3f", d/t}')
  fi
  [ -n "$pct" ] || pct=0
  # STATUS.md（新形式）を先に見る。過渡期は無ければ旧形式の報告ファイルで判定する。
  sst=""
  [ -s "$WDIR/STATUS.md" ] && sst=$(status_state "$WDIR/STATUS.md")
  # 報告ファイルが出ているなら完了扱いにする（チェックリストの付け忘れより強い証拠）
  { [ -s "$WDIR/REPORT.md" ] || [ -s "$WDIR/PLAN.md" ] || [ "$sst" = "done" ]; } && pct=1
  sum=$(awk -v s="$sum" -v p="$pct" 'BEGIN{print s+p}')

  # 状態: 報告ファイルが最も強い根拠。無ければ cmux の lane を見る
  lane=$(cmux workspace status --json --workspace "$ref" 2>/dev/null | jq -r '.effective // "unknown"')
  if [ -s "$WDIR/STATUS.md" ]; then
    case "$sst" in
      needs-answer)
        state="❓ 確認待ち（司令官の回答待ち）$(stale_suffix "$WDIR/STATUS.md")"; n_attn=$((n_attn+1))
        smt=$(stat -f '%m' "$WDIR/STATUS.md" 2>/dev/null || stat -c '%Y' "$WDIR/STATUS.md" 2>/dev/null)
        if [ -n "${smt:-}" ]; then
          smins=$(( ( $(date -u +%s) - smt ) / 60 ))
          [ "$smins" -ge "$STALE_MIN" ] 2>/dev/null \
            && must_see="${must_see}  ❓ 部下${no} ${name}: STATUS.md が ${smins}分 未回答のまま（needs-answer）"$'\n'
        fi ;;
      done)
        state="✅ 報告あり（検収待ち）";        n_done=$((n_done+1))
        must_see="${must_see}  ★ 部下${no} ${name}: STATUS.md が done。検収・撤収がまだ"$'\n' ;;
      in-progress)
        if LC_ALL=C grep -aqE 'pull/[0-9]+|#[0-9]+' "$WDIR/STATUS.md" 2>/dev/null
          then state="👀 レビュー対応中"
          else state="▶ 作業中"
        fi ;;
      *) state="⚠ STATUS.md の形式が不正（STATE: 行を確認）"; n_attn=$((n_attn+1)) ;;
    esac
  elif [ -s "$WDIR/BLOCKED.md" ];  then
    state="⛔ 行き詰まり（人間の判断待ち）$(stale_suffix "$WDIR/BLOCKED.md")"; n_attn=$((n_attn+1))
    bmt=$(stat -f '%m' "$WDIR/BLOCKED.md" 2>/dev/null || stat -c '%Y' "$WDIR/BLOCKED.md" 2>/dev/null)
    if [ -n "${bmt:-}" ]; then
      bmins=$(( ( $(date -u +%s) - bmt ) / 60 ))
      [ "$bmins" -ge "$STALE_MIN" ] 2>/dev/null \
        && must_see="${must_see}  ⛔ 部下${no} ${name}: BLOCKED.md が ${bmins}分 人間の判断待ちのまま"$'\n'
    fi
  elif [ -s "$WDIR/QUESTION.md" ]; then
    state="❓ 確認待ち（司令官の回答待ち）$(stale_suffix "$WDIR/QUESTION.md")"; n_attn=$((n_attn+1))
    qmt=$(stat -f '%m' "$WDIR/QUESTION.md" 2>/dev/null || stat -c '%Y' "$WDIR/QUESTION.md" 2>/dev/null)
    if [ -n "${qmt:-}" ]; then
      qmins=$(( ( $(date -u +%s) - qmt ) / 60 ))
      [ "$qmins" -ge "$STALE_MIN" ] 2>/dev/null \
        && must_see="${must_see}  ❓ 部下${no} ${name}: QUESTION.md が ${qmins}分 未回答のまま"$'\n'
    fi
  elif [ -s "$WDIR/PLAN.md" ];     then state="📋 編成案あり（承認待ち）";      n_done=$((n_done+1))
  elif [ -s "$WDIR/REPORT.md" ];   then
    state="✅ 報告あり（検収待ち）";        n_done=$((n_done+1))
    must_see="${must_see}  ★ 部下${no} ${name}: REPORT.md あり。検収・撤収がまだ"$'\n'
  elif [ -s "$WDIR/PR.md" ];       then state="👀 レビュー対応中"
  else
    case "$lane" in
      working)         state="▶ 作業中" ;;
      needs-attention) state="❓ 確認待ち"; n_attn=$((n_attn+1)) ;;
      review)          state="👀 レビュー待ち" ;;
      done)            state="✅ 完了" ; n_done=$((n_done+1)) ;;
      todo)            state="⏸ 待機" ;;
      *)               state="? $lane" ;;
    esac
  fi

  last=$(printf '%s' "$WS_JSON" | jq -r --arg id "$wid" \
    '.workspaces[] | select(.id==$id) | .latest_conversation_message // ""' | tr '\n' ' ')
  last=${last:0:56}
  last=$(printf '%s' "$last" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  label="${no}."; [ "$no" = "0" ] && label="先鋒"
  lines="${lines}  ${label} ${name}   ·   ${ref}"$'\n'
  lines="${lines}     ${state}"$'\n'
  lines="${lines}     $(bar "$pct" 24)"
  [ -n "$plabel" ] && lines="${lines}  ${plabel}"
  lines="${lines}"$'\n'
  [ "$ttot" -gt 0 ] 2>/dev/null && lines="${lines}     todo ${tdone}/${ttot}${tnext:+ — 次: $tnext}"$'\n'
  if [ "$ttot" -ge "$TODO_OVERLOAD" ] 2>/dev/null && [ ! -s "$WDIR/REPORT.md" ] && [ ! -s "$WDIR/PLAN.md" ] && [ "$sst" != "done" ]; then
    must_see="${must_see}  ⚠ 部下${no} ${name}: todo が ${ttot} 件に積み上がっている（積みすぎの疑い。新しい依頼は新しい部下へ）"$'\n'
  fi
  # 経過時間。agent hook を切っているので「手が空いた」通知が来ない。沈黙はここで気付く
  if [ -n "$started" ]; then
    # started_at は UTC(Z)。TZ=UTC を付けないと date -j がローカル時刻として解釈し、
    # JST 環境では 540 分ずれて「45分以上報告なし」を誤検知する
    s_epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$started" +%s 2>/dev/null)
    if [ -n "$s_epoch" ]; then
      mins=$(( ( $(date +%s) - s_epoch ) / 60 ))
      warn=""
      if [ "$mins" -ge 45 ] && [ ! -s "$WDIR/REPORT.md" ] && [ ! -s "$WDIR/PLAN.md" ] && [ "$sst" != "done" ]; then
        warn="   ← 45分以上 報告なし。画面を見る"
        must_see="${must_see}  ⚠ 部下${no} ${name}: 稼働中で ${mins}分 報告なし（画面を見る）"$'\n'
      fi
      lines="${lines}     経過 ${mins}分${warn}"$'\n'
    fi
  fi
  [ -n "$last" ] && lines="${lines}     直近: ${last}"$'\n'
  [ -n "$wt" ] && lines="${lines}     worktree: ${wt}"$'\n'
  lines="${lines}"$'\n'
done < "$ROSTER"

overall=$(awk -v s="$sum" -v n="$n_active" 'BEGIN{ if(n<1){print 0} else {printf "%.3f", s/n} }')

printf '\n'
gname=""
if [ -s "$MISSION/group.ref" ]; then
  gref=$(head -1 "$MISSION/group.ref")
  gname=$(cmux workspace-group list --json 2>/dev/null | jq -r --arg g "$gref" '.groups[]? | select(.ref==$g) | .name' 2>/dev/null)
fi
printf '━━━ 作業状況 ━━━ %s\n' "${gname:-$(basename "$MISSION")}"
printf '  全体 %s   （稼働 %d / 撤収 %d / 全 %d）\n' "$(bar "$overall" 28)" "$n_active" "$n_retired" "$n_total"
printf '  判断待ち %d 件 ・ 検収待ち %d 件\n' "$n_attn" "$n_done"
if [ -n "$must_see" ]; then
  printf '───────────────────────────────────────────────────────────\n'
  printf '  ★ 今すぐ見るべきもの ★\n'
  printf '%s' "$must_see"
fi
printf '───────────────────────────────────────────────────────────\n'
printf '%s' "$lines"
printf '───────────────────────────────────────────────────────────\n'
printf '  詳細: %s\n\n' "$MISSION"
