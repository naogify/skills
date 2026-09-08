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
cwd=$(printf  '%s' "$row" | jq -r '.cwd // ""')
WDIR="$MISSION/workers/$NO"

# ── `worktree` が空でも、cwd 自体が worktree なら削除対象として拾う ──
# 読み取り専用タスクの部下を `spawn.sh ... "$CWD" "" "" ""`（worktree 引数を空）で
# 起動すると roster.jsonl の worktree は空になるが、実際には cwd が worktree ということが
# ある。`wt` が空だからと丸ごとスキップすると、「撤収完了」と表示したまま worktree が
# 残り続ける（実際に起きた。司令官が手で消す羽目になった）。
# メインの作業ツリーかどうかは `git rev-parse --git-dir` と `--git-common-dir` が
# 一致するかで判定できる（一致すればメイン、異なれば worktree 側のリンク）。
if { [ -z "$wt" ] || [ ! -d "$wt" ]; } && [ -n "$cwd" ] && [ -d "$cwd" ]; then
  gd=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null)
  gcd=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
  if [ -n "$gd" ] && [ -n "$gcd" ] && [ "$gd" != "$gcd" ]; then
    wt="$cwd"
    printf 'note: roster の worktree が空だったが cwd 自体が worktree だったので削除対象にする: %s\n' "$wt" >&2
  fi
fi

# ── `repo` フィールドの解釈 ──
# `spawn.sh` の usage 上は「gh --repo に渡す slug（owner/name）」の意味で、roster.jsonl の
# 実データも全部 slug（例: "cabinetwork/internal-apps-v1"）。しかし過去のコードは repo を
# そのままパスとして git -C に渡していたため、slug が来ると `git -C '<slug>' ...` が
# fatal で落ちていた（実際に落ちて、ワークスペースだけ閉じて worktree が残った）。
# ここでは既存のディレクトリだけを「パスとして渡された repo」とみなし、それ以外は slug として扱う
# （どちらの形式が来ても壊れないようにする）。
root=""
slug="$repo"
if [ -n "$repo" ] && [ -d "$repo" ]; then
  # 過去の形式・手動指定でローカルパスが渡された場合はそのまま root として使う
  root="$repo"
  slug=$(git -C "$repo" remote get-url origin 2>/dev/null \
           | sed -E 's#.*[:/]([^/]+/[^/]+)(\.git)?$#\1#; s#\.git$##')
  [ -n "$slug" ] || slug="$repo"
fi
# リポジトリのルートは worktree から機械的に導出できる。repo が slug（パスでない）場合は
# ここが唯一の root の出処になる。
if [ -z "$root" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
  root=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##')
fi
# slug がまだ無ければ worktree の origin から取る（gh pr view / gh api に使う）
if [ -z "$slug" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
  slug=$(git -C "$wt" remote get-url origin 2>/dev/null \
           | sed -E 's#.*[:/]([^/]+/[^/]+)(\.git)?$#\1#; s#\.git$##')
fi

if [ "$FORCE" != "--force" ]; then
  if [ ! -s "$WDIR/REPORT.md" ] && [ ! -s "$WDIR/PLAN.md" ]; then
    # 報告が無くても、担当 PR が既にマージ / クローズされていれば完了と見なす
    # （司令官が部下を飛ばしてマージした場合、REPORT は書かれない）。
    prnum=$(printf '%s' "$NO" | sed 's/^f//')
    prstate=""
    case "$prnum" in
      ''|*[!0-9]*) : ;;
      *) [ -n "$slug" ] && prstate=$(gh pr view "$prnum" --repo "$slug" --json state --jq '.state' 2>/dev/null) ;;
    esac
    case "$prstate" in
      MERGED|CLOSED) printf '報告は無いが PR #%s は %s なので完了と見なす\n' "$prnum" "$prstate" ;;
      *) hold "REPORT.md も PLAN.md も無く、PR も未マージ（まだ終わっていない）: $WDIR" ;;
    esac
  fi
  [ -s "$WDIR/QUESTION.md" ] && hold "QUESTION.md が残っている（未回答）: $WDIR/QUESTION.md"
  [ -s "$WDIR/BLOCKED.md" ]  && hold "BLOCKED.md が残っている（人間の判断待ち）: $WDIR/BLOCKED.md"

  if [ -n "$wt" ] && [ -d "$wt" ]; then
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
    [ -z "$dirty" ] || hold "未 commit の変更が残っている: $wt"$'\n'"$dirty"

    # 未 push 判定の前に fetch する。fetch せずに古い ref のまま比べると、
    # PR がマージされた直後（＝いちばん撤収したいタイミング）に必ず「未 push」と誤判定する。
    # `@{u}`（upstream）が origin/<base> を指すよう設定されたブランチ（`git worktree add -b <br>
    # origin/<base>` で作ると既定でこうなる）では、fetch していない origin/<base> は
    # マージ済みの commit を反映しておらず、実際に PR マージ直後に誤判定した実害がある。
    if fetch_out=$(git -C "$wt" fetch origin 2>&1); then
      :
    else
      printf 'warn: git fetch origin に失敗した。以降の未 push 判定は古い ref に基づく可能性がある\n' >&2
      printf '      %s\n' "$fetch_out" >&2
    fi

    # 「未 push」は upstream（`@{u}`）と比べる。origin/<base> と比べると squash マージ後に
    # 誤検知する（squash では元の commit が base の祖先にならないため、マージ済みでも
    # 「未 push」に見える）。fetch は上の一手で済ませてあるので、ここでは新しい ref で比べる。
    up=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    if [ -n "$up" ]; then
      ahead=$(git -C "$wt" log --oneline "$up..HEAD" 2>/dev/null)
      [ -z "$ahead" ] || hold "未 push の commit が残っている（$up 比。直前に fetch 済み）: $wt"$'\n'"$ahead"
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

# ── worktree の削除は close-workspace より先に試す（判定を先・破壊を後） ──
# 順序が逆だと、ワークスペースを閉じた後に worktree 削除が失敗し、「部下はもう居ないのに
# worktree は残る」という復旧不能な中途半端な状態になる（`repo` がパスとして扱われて
# fatal で落ち、実際にこの状態になった）。ここで失敗する分には、まだ何も壊していないので
# 安全に die できる。
if [ -n "$wt" ] && [ -d "$wt" ]; then
  if [ "$FORCE" = "--force" ]; then
    git -C "$wt" worktree remove --force "$wt" 2>/dev/null \
      || git -C "${root:-.}" worktree remove --force "$wt" \
      || die "worktree 削除に失敗（--force でも消せない。ワークスペースはまだ閉じていない）: $wt"
  else
    git -C "${root:-$wt}" worktree remove "$wt" \
      || die "worktree 削除に失敗（未コミットの変更が残っている可能性。ワークスペースはまだ閉じていない）: $wt"
  fi
  [ -n "$root" ] && git -C "$root" worktree prune 2>/dev/null
  printf 'worktree を削除した: %s\n' "$wt"
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

# ── マージ済みブランチを消す（-d は未マージなら拒否するので安全） ──
if [ -n "$root" ] && [ -d "$root" ]; then
  if [ -n "$BR" ]; then
    if git -C "$root" branch -d "$BR" 2>/dev/null; then
      printf 'マージ済みブランチを削除した: %s\n' "$BR"
    else
      printf '未マージなのでブランチは残した: %s\n' "$BR"
    fi
  fi
  git -C "$root" worktree prune 2>/dev/null
fi

# ── ここまで来たら撤収は完了している。RETIRED は必ず書く ──
# （途中で die するのは worktree 削除より前だけなので、ここに到達した時点で
# ワークスペースと worktree はもう存在しない。RETIRED を書き忘れると、watch.sh /
# inbox.sh / board.sh が撤収済みの部下を稼働中として扱い続ける）。
date -u +%Y-%m-%dT%H:%M:%SZ > "$WDIR/RETIRED"

# 完了台帳に追記する。inbox.sh がこれと reported.log を比べて
# 「人間に未報告の完了」を毎回突き付けるので、報告漏れが構造的に起きない。
# 成果物のダイジェストを作る。報告に必要な材料を台帳に焼き込む
digest=""
for f in REPORT PLAN POSTED; do
  [ -s "$WDIR/$f.md" ] || continue
  concl=$(LC_ALL=C grep -a -A3 '^## 結論' "$WDIR/$f.md" 2>/dev/null | sed -n '2p' | cut -c1-100)
  [ -n "$concl" ] && digest="${digest}${concl} "
done
refs=$(LC_ALL=C grep -aohE '#[0-9]{2,5}' "$WDIR"/*.md 2>/dev/null | sort -u | tr '\n' ' ')
[ -n "$refs" ] && digest="${digest}[参照: ${refs}]"
digest=$(printf '%s' "$digest" | tr '\t\n' '  ')
printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NO" "$name" "${digest:-（成果物のダイジェストなし）}" >> "$MISSION/completed.log"

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
