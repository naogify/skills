#!/usr/bin/env bash
# 部下を撤収する（ワークスペース削除 + worktree 削除）。不可逆なので先に検証する。
#   retire.sh <mission-dir> <no> [--force]
# --force は人間が明示的に「作業を捨ててよい」と言ったときだけ使う。
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "retire: $*" >&2; exit 1; }
hold() { printf '撤収しない: %s\n' "$*" >&2; exit 3; }

[ $# -ge 2 ] || die "usage: retire.sh <mission-dir> <no> [--force]"
MISSION=$1; NO=$2; FORCE=${3:-}
ROSTER="$MISSION/roster.jsonl"
[ -s "$ROSTER" ] || die "roster が無い: $ROSTER"

row=$(jq -c --arg no "$NO" 'select((.no|tostring)==$no)' "$ROSTER" | tail -1)
[ -n "$row" ] || die "部下 $NO が roster にいない"
name=$(printf '%s' "$row" | jq -r '.name')
ref=$(printf  '%s' "$row" | jq -r '.ws_ref')
wt=$(printf   '%s' "$row" | jq -r '.worktree // ""')
repo=$(printf '%s' "$row" | jq -r '.repo // ""')
base=$(printf '%s' "$row" | jq -r '.base // ""')
WDIR="$MISSION/workers/$NO"

if [ "$FORCE" != "--force" ]; then
  if [ ! -s "$WDIR/REPORT.md" ] && [ ! -s "$WDIR/PLAN.md" ]; then
    hold "REPORT.md も PLAN.md も無い（まだ終わっていない）: $WDIR"
  fi
  [ -s "$WDIR/QUESTION.md" ] && hold "QUESTION.md が残っている（未回答）: $WDIR/QUESTION.md"
  [ -s "$WDIR/BLOCKED.md" ]  && hold "BLOCKED.md が残っている（人間の判断待ち）: $WDIR/BLOCKED.md"

  if [ -n "$wt" ] && [ -d "$wt" ]; then
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
    [ -z "$dirty" ] || hold "未 commit の変更が残っている: $wt"$'\n'"$dirty"
    # 「未 push」は upstream（origin/<同名ブランチ>）と比べる。
    # origin/<base> と比べると squash マージ後に誤検知する
    # （squash では元の commit が base の祖先にならないため、マージ済みでも「未 push」に見える）。
    up=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    if [ -n "$up" ]; then
      ahead=$(git -C "$wt" log --oneline "$up..HEAD" 2>/dev/null)
      [ -z "$ahead" ] || hold "未 push の commit が残っている（$up 比）: $wt"$'\n'"$ahead"
    else
      # upstream が無い = リモートブランチが消えている。
      # マージ時の --delete-branch でこうなるのが通常。念のため人間に見える形で出す。
      printf 'warn: upstream が無い（リモートブランチが削除済み＝マージ済みの可能性）。\n' >&2
      printf '      未 push の判定は行わず、未 commit の変更のみで判断した: %s\n' "$wt" >&2
    fi
  fi
fi

# worktree が消える前にブランチ名を控える（detached なら空になる）
BR=""
if [ -n "$wt" ] && [ -d "$wt" ]; then
  BR=$(git -C "$wt" branch --show-current 2>/dev/null)
fi

# ── 撤収前の資源を記録（解放できたかを後で比べる） ──
before_rss=$(ps -o rss= -p $(pgrep -f "$WDIR/run.sh" 2>/dev/null | tr '\n' ',' | sed 's/,$//') 2>/dev/null \
  | awk '{s+=$1} END{printf "%.0f", s/1024}')
before_swap=$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')

if [ -n "$ref" ]; then
  out=$(cmux close-workspace --workspace "$ref" 2>&1) || printf 'warn: close-workspace 失敗（既に閉じている？）: %s\n' "$out" >&2
  printf 'ワークスペースを閉じた: %s (%s)\n' "$ref" "$name"
fi

# ── 部下のプロセスが本当に死んだか確認する（死んでいないとメモリが返らない） ──
# ワークスペースを閉じてもプロセスが残ることがある。RSS が返るのはプロセスが終わったときだけ。
leftover=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  leftover=$(pgrep -f "$WDIR/run.sh" 2>/dev/null | tr '\n' ' ')
  [ -z "$leftover" ] && break
  sleep 1
done
if [ -n "$leftover" ]; then
  if [ "$FORCE" = "--force" ]; then
    kill $leftover 2>/dev/null; sleep 2
    still=$(pgrep -f "$WDIR/run.sh" 2>/dev/null | tr '\n' ' ')
    [ -n "$still" ] && kill -9 $still 2>/dev/null
    printf '居残っていた部下のプロセスを終了した: %s\n' "$leftover"
  else
    printf 'warn: 部下のプロセスが残っている (PID %s)。メモリが返らない。\n' "$leftover" >&2
    printf '      確認: ps -o pid,rss,command -p %s\n' "${leftover%% *}" >&2
    printf '      終了: kill %s（自分の部下だと確認してから）\n' "$leftover" >&2
  fi
fi

if [ -n "$wt" ] && [ -d "$wt" ]; then
  root=${repo:-$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##')}
  if [ "$FORCE" = "--force" ]; then
    git -C "$wt" worktree remove --force "$wt" 2>/dev/null \
      || git -C "${root:-.}" worktree remove --force "$wt" \
      || printf 'warn: worktree 削除に失敗: %s\n' "$wt" >&2
  else
    git -C "${root:-$wt}" worktree remove "$wt" || die "worktree 削除に失敗（未コミットの変更が残っている可能性）: $wt"
  fi
  [ -n "${root:-}" ] && git -C "$root" worktree prune 2>/dev/null
  printf 'worktree を削除した: %s\n' "$wt"
  printf 'ヒント: マージ済みならブランチも消す → git -C %s branch -d <branch>（-D は使わない）\n' "${root:-<repo>}"
fi

# ── マージ済みブランチを消す（-d は未マージなら拒否するので安全） ──
if [ -n "$repo" ] && [ -d "$repo" ]; then
  if [ -n "$BR" ]; then
    if git -C "$repo" branch -d "$BR" 2>/dev/null; then
      printf 'マージ済みブランチを削除した: %s\n' "$BR"
    else
      printf '未マージなのでブランチは残した: %s\n' "$BR"
    fi
  fi
  git -C "$repo" worktree prune 2>/dev/null
fi

date -u +%Y-%m-%dT%H:%M:%SZ > "$WDIR/RETIRED"

# 完了台帳に追記する。inbox.sh がこれと reported.log を比べて
# 「人間に未報告の完了」を毎回突き付けるので、報告漏れが構造的に起きない。
printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NO" "$name" >> "$MISSION/completed.log"

# ── 解放できた資源を実測して出す ──
after_swap=$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
printf '撤収完了: 部下%s %s\n' "$NO" "$name"
[ -n "${before_rss:-}" ] && [ "${before_rss:-0}" != "0" ] \
  && printf '  返したメモリ: 約 %s MB（部下のプロセス分）\n' "$before_rss"
if [ -n "${before_swap:-}" ] && [ -n "${after_swap:-}" ]; then
  printf '  スワップ: %s MB → %s MB\n' "$before_swap" "$after_swap"
  printf '  ※スワップは「解放するコマンド」が無い。プロセスが終われば退避ページは解放されるが、\n'
  printf '    macOS はスワップファイルを縮めないので used はすぐ下がらない。判断は preflight.sh で行う。\n'
fi
