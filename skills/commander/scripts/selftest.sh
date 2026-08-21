#!/usr/bin/env bash
# このスキルのスクリプト自身を検査する。実害が出た罠を踏み直していないかを機械で確かめる。
#   selftest.sh
# 終了コード: 0=全部通過 / 1=1つ以上の退行あり
# スクリプトを編集したら必ず回すこと。
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
fail=0
# 検査対象は自分以外のスクリプト（自分の検査文字列に反応してしまうため）
TARGETS=$(ls "$D"/*.sh | grep -v '/selftest.sh$')
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  NG   %s\n' "$1"; fail=1; }

printf 'commander スクリプト自己検査\n'

# 1) 報告ファイルへの grep は -a（テキスト強制）必須
#    日本語混じりのファイルを grep がバイナリ判定して "Binary file X matches" を返し、
#    それが検出結果として扱われる事故が起きた（issue 番号が "#matches" になった）。
if grep -nE 'grep -[a-zA-Z]*q?E?[a-zA-Z]* +("\$REP"|"\$p"|"\$REP")' "$D/verify.sh" "$D/inbox.sh" 2>/dev/null \
   | grep -v -- '-a' | grep -q .; then
  bad 'report ファイルへの grep に -a が無いものがある（バイナリ誤判定の危険）'
  grep -nE 'grep [^|]*"\$REP"' "$D/verify.sh" | grep -v -- '-a' | head -3
else
  ok 'report ファイルへの grep は全て -a 付き'
fi

# 2) iconv を UTF-8 妥当性判定に使っていない
#    環境によって "Inappropriate ioctl for device" で落ち、正常なファイルを弾いた。
if grep -n '^[^#]*iconv' $TARGETS 2>/dev/null | grep -v '^\s*#' | grep -q .; then
  bad 'iconv を使っている箇所がある（文字化け判定には使えない。python3 で判定する）'
else
  ok 'iconv を判定に使っていない'
fi

# 3) date -j で UTC 文字列を読むときは TZ=UTC 必須
#    付けないとローカル時刻として解釈され、JST では 540 分ずれて誤検知した。
if grep -n "date -j -f '%Y-%m-%dT%H:%M:%SZ'" $TARGETS 2>/dev/null | grep -v 'TZ=UTC' | grep -q .; then
  bad "date -j で UTC 文字列を読む箇所に TZ=UTC が無い（JST で 540 分ずれる）"
  grep -n "date -j -f '%Y-%m-%dT%H:%M:%SZ'" $TARGETS | grep -v 'TZ=UTC' | head -3
else
  ok 'date -j は全て TZ=UTC 付き'
fi

# 4) 部下番号を JSON 数値として書いていない（f341 のような文字列 ID が使えなくなる）
if grep -n -- '--argjson no' $TARGETS 2>/dev/null | grep -q .; then
  bad '--argjson no を使っている（部下番号は文字列。f341 等が roster に入らない）'
else
  ok '部下番号は文字列として扱っている'
fi

# 5) 未 push 判定を origin/<base> で行っていない（squash マージ後に誤検知する）
if grep -n 'origin/\$base\.\.HEAD' "$D/retire.sh" 2>/dev/null | grep -q .; then
  bad 'retire.sh が origin/$base..HEAD で未push判定している（squash マージ後に誤検知）'
else
  ok 'retire.sh の未push判定は upstream 基準'
fi

# 6) 実機テスト: 日本語だけの報告ファイルで verify の grep が誤判定しないか
tmp=$(mktemp -d) || { printf 'mktemp 失敗\n' >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
printf '## 結論\n日本語だけの報告。絵文字あり🔴。\n## テスト\n42 passed\n## 変異注入の結果\n壊して赤を確認した\n' > "$tmp/REPORT.md"
if LC_ALL=C grep -aq "結論" "$tmp/REPORT.md" && LC_ALL=C grep -aqE "[0-9]+ (passed|tests?|件)" "$tmp/REPORT.md"; then
  ok '日本語＋絵文字の報告ファイルを正しく grep できる'
else
  bad '日本語の報告ファイルで grep が一致しない（-a / LC_ALL=C の欠落）'
fi

# 6b) preflight はスワップ割合だけで判定していない
#     macOS はスワップファイルを縮めないので、割合は死んだプロセスの残骸で高止まりする。
#     メモリが 82% 空いている状態で「注意」を出し、不要に作業を待たせた実害がある。
if grep -q 'kern.memorystatus_vm_pressure_level' "$D/preflight.sh" 2>/dev/null \
   && grep -q 'Swapins' "$D/preflight.sh" 2>/dev/null; then
  ok 'preflight は圧力レベルとスワップイン速度で判定している'
else
  bad 'preflight がスワップ割合だけで判定している（残骸で誤警報を出す）'
fi

# 6c) SKILL.md に絶対パスが混入していないか（別マシン・プラグイン配布で壊れる）
# 検査対象は「実行される形」の絶対パスだけ。散文中の言及（バッククォート囲みの説明）は除く
if grep -nE '(bash|sh|source|\.) +~/\.claude/skills/commander' "$D/../SKILL.md" 2>/dev/null | grep -q .; then
  bad 'SKILL.md に ~/.claude/skills/commander の絶対パスがある（配布すると別マシンで動かない）'
  grep -nE '(bash|sh|source|\.) +~/\.claude/skills/commander' "$D/../SKILL.md" | head -3
else
  ok 'SKILL.md は $SKILL 相対で書かれている'
fi

# 6d) 部下テンプレに「CI を待つ」を仕事として書いていないか
#     部下は待てない（ターンが終わると誰も起こさない）。実例: CI 緑・approve 済みで 42 分停止。
if LC_ALL=C grep -aq 'gh pr checks' "$D/../templates/worker-prompt.md" 2>/dev/null \
   && LC_ALL=C grep -aq -- '--watch' "$D/../templates/worker-prompt.md" 2>/dev/null; then
  ok '部下テンプレはブロックするコマンド（gh pr checks --watch）で待つよう指示している'
else
  bad '部下テンプレに CI をブロックして待つ方法が書かれていない（「後で確認」で永久停止する）'
fi

# 6e) 責務分離: マージは部下の仕事として書かれているか
if LC_ALL=C grep -aq 'マージも「あなたの仕事」' "$D/../templates/worker-prompt.md" 2>/dev/null \
   && LC_ALL=C grep -aq 'マージは部下にやらせる' "$D/../SKILL.md" 2>/dev/null; then
  ok 'マージは部下の仕事として定義されている（司令官は検収と GO のみ）'
else
  bad '司令官がマージする設計に戻っている（部下の報告と撤収の引き金が消える）'
fi

# ── ここから下は実際に壊れたデータ・実際の git 履歴を食わせる退行検査。
#    通ることの確認だけでは検品にならないので、失敗すべきケースも用意する。
SANDBOX="$tmp/sandbox"; mkdir -p "$SANDBOX"

# 6f) 重大1 の退行検査（roster.repo に GitHub slug が入っていても撤収できるか）
#     retire.sh が `repo` をパスとして git -C に渡すと、slug は fatal で落ちて
#     ワークスペースだけ閉じ worktree が残ったまま復旧不能になった実害がある。
g1="$SANDBOX/g1"; mkdir -p "$g1"
repo="$g1/repo"; wt="$g1/wt"; mission="$g1/mission"
git init -q "$repo" \
  && git -C "$repo" config user.email t@t.example \
  && git -C "$repo" config user.name t \
  && git -C "$repo" commit -q --allow-empty -m init \
  && git -C "$repo" worktree add -q "$wt" -b g1-branch >/dev/null 2>&1
mkdir -p "$mission/workers/1"
printf '## 結論\nテスト\n## テスト\n1 passed\n' > "$mission/workers/1/REPORT.md"
jq -nc --arg wt "$wt" \
  '{no:"1",name:"g1",ws_ref:"",ws_id:"",worktree:$wt,repo:"cabinetwork/internal-apps-v1",base:"main"}' \
  > "$mission/roster.jsonl"
bash "$D/retire.sh" "$mission" 1 >"$g1/out.log" 2>&1
if [ ! -d "$wt" ] && [ -f "$mission/workers/1/RETIRED" ]; then
  ok '重大1 退行検査: roster.repo が slug（例: "cabinetwork/internal-apps-v1"）でも worktree が消える'
else
  bad '重大1 の退行: repo が slug のとき worktree が消えない、または RETIRED が書かれない'
  sed 's/^/      /' "$g1/out.log" | head -6
fi

# 6g) 重大1 の順序検査（worktree 削除に失敗したら close-workspace 前に die し、
#     RETIRED も worktree も残ったまま止まるか）。git worktree lock で決定的に失敗させる。
g1b="$SANDBOX/g1b"; mkdir -p "$g1b"
repo="$g1b/repo"; wt="$g1b/wt"; mission="$g1b/mission"
git init -q "$repo" \
  && git -C "$repo" config user.email t@t.example \
  && git -C "$repo" config user.name t \
  && git -C "$repo" commit -q --allow-empty -m init \
  && git -C "$repo" worktree add -q "$wt" -b g1b-branch >/dev/null 2>&1
git -C "$repo" worktree lock "$wt" >/dev/null 2>&1
mkdir -p "$mission/workers/1"
printf '## 結論\nテスト\n## テスト\n1 passed\n' > "$mission/workers/1/REPORT.md"
jq -nc --arg wt "$wt" \
  '{no:"1",name:"g1b",ws_ref:"",ws_id:"",worktree:$wt,repo:"acme/demo",base:"main"}' \
  > "$mission/roster.jsonl"
bash "$D/retire.sh" "$mission" 1 >"$g1b/out.log" 2>&1
rc=$?
if [ "$rc" != "0" ] && [ ! -f "$mission/workers/1/RETIRED" ] && [ -d "$wt" ]; then
  ok '重大1 順序検査: worktree 削除に失敗したら RETIRED を書かず worktree も残す（先に壊さない）'
else
  bad '重大1 の順序が退行している: worktree 削除失敗後も RETIRED を書いた、または worktree が消えた'
  sed 's/^/      /' "$g1b/out.log" | head -6
fi

# 6h) 構造検査: retire.sh は worktree 削除を close-workspace より先に呼んでいる
#     （順序が入れ替わると 6g が実質検査できなくなるので、テキスト順序も直接見ておく）
rm_line=$(grep -n 'git .*worktree remove' "$D/retire.sh" | head -1 | cut -d: -f1)
close_line=$(grep -n 'cmux close-workspace' "$D/retire.sh" | head -1 | cut -d: -f1)
if [ -n "$rm_line" ] && [ -n "$close_line" ] && [ "$rm_line" -lt "$close_line" ]; then
  ok 'retire.sh は worktree 削除を close-workspace より先に呼んでいる（判定を先・破壊を後）'
else
  bad 'retire.sh の順序が退行している（close-workspace が worktree 削除より先）'
fi

# 6i) 重大2 の退行検査: fetch していない古い ref のまま「マージ済み」を「未 push」と誤判定しないか。
#     ブランチの upstream が origin/<base> を指す（`worktree add -b <br> origin/<base>` の既定挙動）
#     状態で、PR 相当のマージが origin 側で先に進んだのに手元の origin/<base> がまだ古い、
#     という実際に踏んだ状況を再現する。
g2="$SANDBOX/g2"; mkdir -p "$g2"
origin="$g2/origin.git"; clone="$g2/clone"; wt="$g2/wt"; mission="$g2/mission"
git init -q --bare "$origin"
git clone -q "$origin" "$clone" >/dev/null 2>&1
git -C "$clone" config user.email t@t.example
git -C "$clone" config user.name t
git -C "$clone" commit -q --allow-empty -m init
git -C "$clone" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
git -C "$clone" worktree add -q "$wt" -b g2-branch origin/main >/dev/null 2>&1
git -C "$wt" branch --set-upstream-to=origin/main g2-branch >/dev/null 2>&1
( cd "$wt" && echo work > f.txt && git add f.txt \
    && git -c user.email=t@t.example -c user.name=t commit -q -m work )
merged_sha=$(git -C "$wt" rev-parse HEAD)
# 元 PR 用の scratch ref にだけ push する（$wt の origin/main tracking ref は更新されない）
git -C "$wt" push -q origin HEAD:refs/heads/scratch >/dev/null 2>&1
# 「PR がマージされて origin の main が進んだ」を、$wt からは見えない形で再現する
git -C "$origin" update-ref refs/heads/main "$merged_sha"
mkdir -p "$mission/workers/1"
printf '## 結論\nテスト\n## テスト\n1 passed\n' > "$mission/workers/1/REPORT.md"
jq -nc --arg wt "$wt" \
  '{no:"1",name:"g2",ws_ref:"",ws_id:"",worktree:$wt,repo:"acme/demo",base:"main"}' \
  > "$mission/roster.jsonl"
bash "$D/retire.sh" "$mission" 1 >"$g2/out.log" 2>&1
if [ ! -d "$wt" ] && [ -f "$mission/workers/1/RETIRED" ]; then
  ok '重大2 退行検査: fetch していない古い ref でも、fetch 後に正しく撤収できる'
else
  bad '重大2 の退行: 未 push 判定が fetch していない古い ref のまま誤検知する'
  sed 's/^/      /' "$g2/out.log" | head -8
fi

# 6j) 中3 の退行検査: verify.sh を実際に呼び、UUID（8-4-4-4-12）の断片を commit ハッシュ候補として
#     拾わないか確認する（サンプルテキストへの再実装ではなく verify.sh 自身を実行して見る。
#     拾うと、DB の id を報告に書くタスクで毎回 WARN が出て本物の検知が埋まる。実際に起きた）
g3="$SANDBOX/g3"; mkdir -p "$g3"
repo="$g3/repo"; mission="$g3/mission"
git init -q "$repo" \
  && git -C "$repo" config user.email t@t.example \
  && git -C "$repo" config user.name t \
  && git -C "$repo" commit -q --allow-empty -m init >/dev/null 2>&1
start_sha=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$mission/workers/1"
{
  printf '## 結論\n新規デモ案件 8edd64eb-1c60-4930-9fca-21dc0148addc（コード名 P-1）と 0e68bf99-aaaa-bbbb-cccc-dddddddddddd を確認した。\n'
  printf '## テスト\n1 passed\n'
} > "$mission/workers/1/REPORT.md"
jq -nc --arg wt "$repo" --arg sha "$start_sha" \
  '{no:"1",name:"g3",worktree:$wt,repo:"",base:"main",start_sha:$sha}' \
  > "$mission/roster.jsonl"
verify_out=$(bash "$D/verify.sh" "$mission" 1 2>&1)
if printf '%s' "$verify_out" | grep -qE '(8edd64eb|0e68bf99|21dc0148addc) は commit として解決できない'; then
  bad 'verify.sh が UUID の断片を commit ハッシュ候補として拾ってしまう（誤検知の再発）'
  printf '%s\n' "$verify_out" | grep '解決できない' | sed 's/^/      /' | head -3
else
  ok 'verify.sh は UUID の断片を commit ハッシュ候補として拾わない（verify.sh を実行して確認）'
fi

# 6k) 構造検査: spawn.sh が「trust this folder」と「Bypass Permissions」の両方を処理しているか。
#     Bypass Permissions は Enter だけだと既定の "1. No, exit" が選ばれて部下が即死する
#     （実際に起きた）ので、down → enter を送っているかまで見る。
if grep -q 'trust this folder' "$D/spawn.sh" \
   && grep -qE 'No, exit.*Yes, I accept|Bypass Permissions mode' "$D/spawn.sh" \
   && grep -q 'send-key --workspace "\$ref" down' "$D/spawn.sh"; then
  ok 'spawn.sh は trust-folder と Bypass Permissions の両方を自動で通す'
else
  bad 'spawn.sh が Bypass Permissions（down→enter）を処理していない（Enter だけだと部下が即死する）'
fi

# 7) 全スクリプトの構文
for f in "$D"/*.sh; do
  bash -n "$f" 2>/dev/null || bad "構文エラー: $(basename "$f")"
done
ok '全スクリプトの構文チェック完了'

if [ "$fail" = "0" ]; then printf '判定: 退行なし\n'; exit 0; else printf '判定: 退行あり（直すまでスキルを使わない）\n'; exit 1; fi
