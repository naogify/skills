#!/usr/bin/env bash
# 部下の完了報告を機械的に検収する（人間の指示を待たずに司令官が回す）。
#   verify.sh <mission-dir> <部下番号>
# 終了コード: 0=検収通過 / 1=差し戻し（部下に直させる）/ 2=呼び出しエラー
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "verify: $*" >&2; exit 2; }
[ $# -ge 2 ] || die "usage: verify.sh <mission-dir> <部下番号>"
MISSION=$1; NO=$2
ROSTER="$MISSION/roster.jsonl"; WDIR="$MISSION/workers/$NO"
[ -s "$ROSTER" ] || die "roster が無い: $ROSTER"
row=$(jq -c --arg no "$NO" 'select((.no|tostring)==$no)' "$ROSTER" | tail -1)
[ -n "$row" ] || die "部下 $NO が roster にいない"
wt=$(printf '%s' "$row" | jq -r '.worktree // ""')
repo=$(printf '%s' "$row" | jq -r '.repo // ""')
base=$(printf '%s' "$row" | jq -r '.base // ""')

fail=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  NG   %s\n' "$1"; fail=1; }

REP="$WDIR/REPORT.md"; [ -s "$REP" ] || REP="$WDIR/PLAN.md"
printf '検収: 部下%s\n' "$NO"

# 1. 報告の実在と中身
if [ -s "$REP" ]; then ok "報告ファイル: $(basename "$REP") ($(wc -c <"$REP" | tr -d ' ') bytes)"
else bad "報告ファイルが無い（REPORT.md / PLAN.md）"; fi
[ -s "$WDIR/QUESTION.md" ] && bad "QUESTION.md が残っている（未回答）"
[ -s "$WDIR/BLOCKED.md" ]  && bad "BLOCKED.md が残っている（人間の判断待ち）"

# 2. 証拠が書かれているか（「テスト通りました」だけの報告を弾く）
if [ -s "$REP" ]; then
  for kw in "結論" "テスト" ; do
    LC_ALL=C grep -aq "${kw}" "$REP" || bad "報告に「${kw}」の節が無い"
  done
  # 変異注入は「部下が自分で commit を積んだとき」だけ要求する。
  # origin/base..HEAD で判定すると、PR head を checkout しただけのレビュー専門の部下にも
  # PR 自身の commit が見えて誤って要求してしまう（実際に誤検知した）。
  start_sha=$(printf '%s' "$row" | jq -r '.start_sha // ""')
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    now_sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    if [ -n "$start_sha" ] && [ -n "$now_sha" ]; then
      if [ "$start_sha" != "$now_sha" ]; then
        LC_ALL=C grep -aq "変異注入" "$REP" && ok "変異注入の記録あり" \
          || bad "変異注入の記録が無い（テストが hollow か検証されていない）"
      else
        ok "コードを書いていない（読み取りタスク）ので変異注入は不要"
      fi
    else
      printf '  WARN start_sha が記録されていないので、変異注入の要否を判定できない\n'
    fi
  fi
  # 生の実行結果らしきものがあるか（数字ゼロの報告は疑う）
  LC_ALL=C grep -aqE "[0-9]+ (passed|tests?|件)" "$REP" && ok "テスト結果の数字あり" || printf '  WARN テスト結果の数字が見つからない\n'
fi

# 3. worktree の状態（コードを書いたタスク）
if [ -n "$wt" ] && [ -d "$wt" ]; then
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  [ "$dirty" = "0" ] && ok "未 commit の変更なし" || bad "未 commit の変更が $dirty 件ある"
  if [ -n "$base" ]; then
    n=$(git -C "$wt" log --oneline "origin/$base..HEAD" 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] 2>/dev/null && ok "origin/$base に対して $n commit" \
      || printf '  WARN origin/%s に対する commit が 0（読み取りタスクなら正常）\n' "$base"
  fi
  # 報告に書かれた commit ハッシュが実在するか
  for h in $(LC_ALL=C grep -aoE '\b[0-9a-f]{7,40}\b' "$REP" 2>/dev/null | sort -u | head -5); do
    git -C "$wt" cat-file -e "$h^{commit}" 2>/dev/null && ok "報告の commit $h は実在する" \
      || printf '  WARN 報告中の %s は commit として解決できない（ハッシュ以外の文字列かもしれない）\n' "$h"
  done
fi

# 4. 「起票した」「投稿した」と書かれた issue / PR が実在するか
#
# api / app のように対の PR で開発が進むリポジトリ群では、報告は自分のリポジトリではない
# 番号を正しく参照することが頻出する（例:「app 側 #467」「geolonia/smartcity-smartmap-v3#527」）。
# 自分のリポジトリだけで照会すると、これらの**正しい**他リポジトリ参照まで
# 「存在しない（捏造かタイポ）」と誤判定して差し戻しを出す（実際に起きた）。
#
# 4a. 明示的に「owner/repo#番号」と書かれた参照は、書かれたリポジトリで直接照会する（設定不要）。
# 4b. それ以外の裸の「#番号」（プローズで「app 側 #467」のように書かれる）は、自分のリポジトリで
#     見つからなければ設定済みの照会先リポジトリでも探す。照会先はここにハードコードせず、
#     環境変数 COMMANDER_XREF_REPOS（空白区切り）か mission ディレクトリの
#     xref-repos.txt（1行1リポジトリ）で設定する（api/app のような対を組むミッションで使う）。
if [ -s "$REP" ] && [ -n "$repo" ]; then
  slug=$(git -C "$repo" remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+)(\.git)?$#\1#; s#\.git$##')
  xref_repos="${COMMANDER_XREF_REPOS:-}"
  [ -s "$MISSION/xref-repos.txt" ] && xref_repos="$xref_repos $(tr '\n' ' ' < "$MISSION/xref-repos.txt")"

  if [ -n "$slug" ]; then
    seen_nums=""
    while IFS= read -r qline; do
      [ -n "$qline" ] || continue
      qrepo="${qline%#*}"; qnum="${qline##*#}"
      qst=$(gh api "repos/${qrepo}/issues/${qnum}" --jq '.state' 2>/dev/null) || qst=""
      if [ -n "${qst:-}" ]; then ok "${qrepo}#${qnum} は実在する（state=${qst}）"
      else bad "${qrepo}#${qnum} が存在しない（報告の捏造かタイポ）"; fi
      seen_nums="${seen_nums} ${qnum}"
    done < <(LC_ALL=C grep -aoE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]{2,5}' "$REP" | sort -u | head -8)

    for num in $(LC_ALL=C grep -aoE '#[0-9]{2,5}' "$REP" | tr -d '#' | sort -u | head -8); do
      case " $seen_nums " in *" $num "*) continue ;; esac  # owner/repo#番号 として既に照会済み
      st=$(gh api "repos/${slug}/issues/${num}" --jq '.state' 2>/dev/null) || st=""
      if [ -n "${st:-}" ]; then ok "#${num} は実在する（state=${st}）"; continue; fi
      found=""
      for xr in $xref_repos; do
        [ -n "$xr" ] || continue
        xst=$(gh api "repos/${xr}/issues/${num}" --jq '.state' 2>/dev/null) || xst=""
        if [ -n "${xst:-}" ]; then
          ok "#${num} は ${xr} に実在する（state=${xst}。他リポジトリ参照）"; found=1; break
        fi
      done
      [ -n "$found" ] || bad "#${num} が存在しない（${slug} と設定済みの照会先で見つからない。捏造かタイポ）"
    done
  fi
fi

if [ "$fail" = "0" ]; then
  printf '判定: 検収通過\n'; exit 0
else
  printf '判定: 差し戻し（部下に直させる。人間に上げる前に司令官が処理する）\n'; exit 1
fi
