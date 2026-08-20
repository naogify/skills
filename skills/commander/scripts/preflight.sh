#!/usr/bin/env bash
# 部下を起動する前に、このマシンが何人ぶん抱えられるかを実測する。
#   preflight.sh <起動予定人数> [作業場を作るリポジトリのパス]
# 終了コード: 0=問題なし / 1=注意（人間に報告して判断を仰ぐ） / 2=危険（起動しない）
set -uo pipefail
export CMUX_QUIET=1

N=${1:-1}; REPO=${2:-}
verdict=0; notes=""
note() { notes="${notes}  $1"$'\n'; [ "${2:-0}" -gt "$verdict" ] && verdict=$2; return 0; }

# --- ディスク（worktree + node_modules が効く） ---
target=${REPO:-$HOME}
read -r avail_k cap <<< "$(df -k "$target" | awk 'NR==2{gsub("%","",$5); print $4, $5}')"
avail_g=$(awk -v k="$avail_k" 'BEGIN{printf "%.0f", k/1024/1024}')

# 1 部下ぶんの実費を実測する（既存 worktree の node_modules を基準にする）
per_g=1
if [ -n "$REPO" ] && [ -d "$REPO/node_modules" ]; then
  nm_k=$(du -sk "$REPO/node_modules" 2>/dev/null | awk '{print $1}')
  [ -n "$nm_k" ] && per_g=$(awk -v k="$nm_k" 'BEGIN{printf "%.1f", (k/1024/1024)+0.3}')
fi
need_g=$(awk -v p="$per_g" -v n="$N" 'BEGIN{printf "%.0f", p*n}')

printf 'ディスク: 空き %s GB / 使用率 %s%% （1部下あたり実測 %s GB × %s人 = %s GB 必要）\n' \
  "$avail_g" "$cap" "$per_g" "$N" "$need_g"
[ "$cap" -ge 95 ] 2>/dev/null && note "ディスク使用率 ${cap}% — 危険。worktree を作ると詰まる" 2
[ "$avail_g" -lt "$((need_g * 3))" ] 2>/dev/null && note "空き ${avail_g}GB は必要量 ${need_g}GB の3倍未満 — ビルド生成物で足りなくなる" 1
[ "$avail_g" -lt "$need_g" ] 2>/dev/null && note "空き ${avail_g}GB < 必要 ${need_g}GB — 起動できない" 2

# --- メモリ圧力（macOS の権威ある指標） ---
# スワップの「使用率」だけで判断してはならない。macOS はプロセスが死んでもスワップファイルを
# 縮めないので、割合は死んだプロセスの残骸で高止まりする（メモリが 82% 空いていても 79% を示した）。
# 判定はこの順で行う: 圧力レベル → 実際のスワップイン速度 → 空きメモリ → 割合（参考値）
plevel=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
case "${plevel:-1}" in
  4) note "メモリ圧力が critical（レベル 4）— 起動しない" 2 ;;
  2) note "メモリ圧力が warning（レベル 2）— 並列数を減らす" 1 ;;
esac
printf 'メモリ圧力: レベル %s（1=正常 2=警告 4=危機）\n' "${plevel:-?}"

# 実際にスラッシングしているか（静的な割合ではなく速度で見る）
sw_a=$(vm_stat | awk '/Swapins/{gsub("\\.","",$2); print $2}')
sleep 3
sw_b=$(vm_stat | awk '/Swapins/{gsub("\\.","",$2); print $2}')
if [ -n "$sw_a" ] && [ -n "$sw_b" ]; then
  rate=$(( (sw_b - sw_a) / 3 ))
  printf 'スワップイン: %s 回/秒\n' "$rate"
  [ "$rate" -ge 2000 ] 2>/dev/null && note "スワップイン ${rate} 回/秒 — スラッシング中。起動しない" 2
  [ "$rate" -ge 500 ] 2>/dev/null && [ "$rate" -lt 2000 ] && note "スワップイン ${rate} 回/秒 — 負荷が高い" 1
fi

# スワップの割合は参考値として出すだけ（判定には使わない）
swap=$(sysctl -n vm.swapusage 2>/dev/null)
if [ -n "$swap" ]; then
  st=$(printf '%s' "$swap" | sed -n 's/.*total = \([0-9.]*\)M.*/\1/p')
  su=$(printf '%s' "$swap" | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  if [ -n "$st" ] && [ -n "$su" ]; then
    sp=$(awk -v u="$su" -v t="$st" 'BEGIN{ if(t+0==0){print 0}else{printf "%.0f", u/t*100} }')
    printf 'スワップ: %s%% 使用 (%s / %s MB) ※参考値。死んだプロセスの残骸で高止まりするため判定には使わない\n' "$sp" "$su" "$st"
  fi
fi

# --- 物理メモリの空き ---
free_pct=$(memory_pressure 2>/dev/null | sed -n 's/.*free percentage: *\([0-9]*\)%.*/\1/p' | tail -1)
if [ -n "$free_pct" ]; then
  printf 'メモリ: 空き %s%%\n' "$free_pct"
  [ "$free_pct" -le 10 ] 2>/dev/null && note "メモリ空き ${free_pct}% — 危険" 2
  [ "$free_pct" -le 20 ] 2>/dev/null && [ "$free_pct" -gt 10 ] && note "メモリ空き ${free_pct}% — 注意" 1
fi

# --- 既に走っている部下と worktree ---
running=$(pgrep -x claude 2>/dev/null | wc -l | tr -d ' ')
case "$running" in ''|*[!0-9]*) running=0 ;; esac
cmux_rss=$(cmux memory 2>/dev/null | head -1)
printf '稼働中の claude プロセス: %s 個\n' "$running"
[ -n "$cmux_rss" ] && printf 'cmux 配下: %s\n' "$cmux_rss"
if [ -n "$REPO" ]; then
  wt=$(/usr/bin/git -C "$REPO" worktree list 2>/dev/null | wc -l | tr -d ' ')
  printf 'このリポジトリの worktree: %s 本\n' "$wt"
  [ "$wt" -ge 30 ] 2>/dev/null && note "worktree が ${wt} 本 — 撤収漏れ。先に片付ける" 1
fi
[ "$running" -ge 8 ] 2>/dev/null && note "claude が既に ${running} 個走っている — 報告の信頼性が落ちる" 1

case "$verdict" in
  0) printf '\n判定: OK — %s 人を起動して問題なし\n' "$N" ;;
  1) printf '\n判定: 注意 — 人間に報告して判断を仰ぐこと\n%s' "$notes" ;;
  2) printf '\n判定: 危険 — 起動しない。人間に報告する\n%s' "$notes" ;;
esac
exit $verdict
