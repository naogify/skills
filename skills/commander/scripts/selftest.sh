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

# 6c-2) 統合担当テンプレに UI・UX検収台帳へ載せる指示が残っているか
#       この 2 行が消えると、統合 PR が台帳に並ばず人間が確認すべき PR に気付けない。
#       文言は消えても動作は壊れないので、検査で固定する。
I="$D/../templates/integrator-prompt.md"
if LC_ALL=C grep -aq 'ui-check' "$I" 2>/dev/null \
   && LC_ALL=C grep -aq 'gh label create ui-check' "$I" 2>/dev/null \
   && LC_ALL=C grep -aq 'プレビュー: <URL>' "$I" 2>/dev/null; then
  ok '統合担当テンプレは ui-check ラベルとプレビュー行を指示している'
else
  bad '統合担当テンプレから UI・UX検収台帳の指示が消えている（ui-check ラベル / gh label create / プレビュー行）'
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

# 6e-2) 事故4 の一次防止: 禁止事項が `Task` ツールを名指ししているか
#     「さらに別のエージェントに再委任しない」だけでは解釈の幅があり、部下が `Task` ツールで
#     レビュー用サブエージェントを起動して 3日20時間 残留させた実例がある。
if LC_ALL=C grep -aq '`Task` ツールで別のサブエージェントを起動しない' "$D/../templates/worker-prompt.md" 2>/dev/null \
   && LC_ALL=C grep -aq '`Task` ツールで別のサブエージェントを起動しない' "$D/../templates/integrator-prompt.md" 2>/dev/null; then
  ok '部下・統合担当テンプレの禁止事項が `Task` ツールを名指ししている（事故4 の一次防止）'
else
  bad '禁止事項が `Task` ツールを名指ししていない（解釈の幅が残ったまま。事故4 の再発防止が抜けている）'
fi

# 6e-3) 事故7 の一次防止: 最終成果物での検証原則が部下テンプレに書かれているか
if LC_ALL=C grep -aq '検証は利用者が見る最終成果物そのもので行う' "$D/../templates/worker-prompt.md" 2>/dev/null \
   && LC_ALL=C grep -aq '間接的な兆候から進捗や成否を推測しない' "$D/../templates/worker-prompt.md" 2>/dev/null; then
  ok '部下テンプレに「検証は最終成果物で・一次情報を見る」原則が書かれている（事故7 の一次防止）'
else
  bad '部下テンプレに最終成果物検証の原則が無い（事故7 の再発防止が抜けている）'
fi

# 6e-4) ADDENDUM の一次防止: 見張りの自作禁止と、司令官の役割定義がSKILL.mdに明記されているか
if LC_ALL=C grep -aq '見張りを自作しない' "$D/../SKILL.md" 2>/dev/null \
   && LC_ALL=C grep -aq '通知を受け、部下に割り振り、人間に報告する' "$D/../SKILL.md" 2>/dev/null \
   && LC_ALL=C grep -aq '生の `cmux send` は使わない' "$D/../SKILL.md" 2>/dev/null; then
  ok 'SKILL.md は見張りの自作禁止・司令官の役割定義・send.sh の使用を明記している（ADDENDUM の一次防止）'
else
  bad 'SKILL.md に見張り自作禁止 / 役割定義 / send.sh 使用の明記が無い（ADDENDUM の再発防止が抜けている）'
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

# 6l) 重大3 の退行検査: inbox.sh の「片付け漏れ検知」が部下番号をそのままPR番号として扱わないか。
#     実際の事故: 部下8 → 別件でマージ済みの無関係な既存 PR #8 に衝突し、「マージ済みなのに
#     撤収されていない」と誤検知した。この誤報に従って retire.sh を回すと作業中の worktree ごと
#     成果を破棄しかねない。部下番号が若いうちは既存PRとほぼ必ず衝突する構造的なバグだった。
#     PR.md を持たない部下（＝そもそもPRが存在しない）で、gh pr view を一切呼ばず
#     「片付け漏れ」も出ないことを確認する（gh を差し替えて呼び出し自体を検知する）。
g4="$SANDBOX/g4"; mkdir -p "$g4/bin"
mission="$g4/mission"
mkdir -p "$mission/workers/8"
gh_called="$g4/gh-called.log"; : > "$gh_called"
cat > "$g4/bin/gh" <<GHSTUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_called"
printf '"MERGED"\n'
GHSTUB
chmod +x "$g4/bin/gh"
jq -nc '{no:"8",name:"g4",ws_ref:"",ws_id:"",repo:"naogify/skills"}' > "$mission/roster.jsonl"
out4=$(PATH="$g4/bin:$PATH" bash "$D/inbox.sh" "$mission" --peek --no-ledger 2>&1)
if [ ! -s "$gh_called" ] && ! printf '%s' "$out4" | grep -q '片付け漏れ'; then
  ok '重大3 退行検査: PR.md が無い部下を部下番号=PR番号と誤認識しない（gh を呼ばず片付け漏れも出ない）'
else
  bad '重大3 の退行: PR.md が無いのに gh pr view を呼ぶ、または片付け漏れを誤検知する'
  printf '%s\n' "$out4" | sed 's/^/      /' | head -6
  printf '      gh呼び出し: %s\n' "$(cat "$gh_called")"
fi

# 6m) 構造検査: SKILL.md が「バックグラウンド完了通知の本文には watch.sh の中身が乗らない」ことと
#     「読み飛ばさず出力を読む」手順を明記しているか。
#     実際の事故: 通知本文が "Background command ... completed (exit code 0)" の定型文だけで、
#     watch.sh が検知した中身（5人分の報告）が乗っておらず、司令官が「ただの完了通知」と
#     読み飛ばして約20分報告に気付かなかった。ハーネス側の制約でスクリプトからは直せないため、
#     手順（SKILL.md）側で「必ず出力を読む」を固定しておく必要がある。
if LC_ALL=C grep -aq '完了通知の本文は空っぽ' "$D/../SKILL.md" 2>/dev/null \
   && LC_ALL=C grep -aq 'その場で出力を読む' "$D/../SKILL.md" 2>/dev/null; then
  ok 'SKILL.md はバックグラウンド完了通知を読み飛ばさない手順を明記している（事故1 の再発防止）'
else
  bad 'SKILL.md に「完了通知は読み飛ばさず出力を読む」手順が無い（事故1 の再発防止が抜けている）'
fi

# 6n) 実機テスト: watch.sh の is_active() が「稼働中」の画面を正しく「稼働中」と判定するか。
#     ここを誤って「待ち」と判定すると、正当にブロック中の部下を毎ポーリング停止扱いにして
#     事故2（同じ部下について繰り返し誤検知する）を再発させる。
#     `Running 1 shell command · 35s…` は実際に踏んだケース: 部下が
#     `gh pr checks 564 --watch --interval 30` をフォアグラウンドで実行中で正しく
#     ブロックしていたにもかかわらず、時間が先頭に来ない画面形式のため既存の時間パターン・
#     spinner パターンのどちらにも一致せず「止まっている」と誤報し、司令官が健全な部下に
#     割り込むきっかけになった。
is_active_src=$(sed -n '/^is_active() {/,/^}/p' "$D/watch.sh")
if [ -z "$is_active_src" ]; then
  bad 'watch.sh から is_active() を抽出できない（関数定義が変わった？ selftest も追随させる）'
else
  (
    eval "$is_active_src"
    r=0
    is_active '✻ Cooking… (3m 21s · ↓ 4.2k tokens)'                       || r=1
    is_active 'Waiting for 2 background agent to finish'                  || r=1
    is_active 'esc to interrupt'                                          || r=1
    is_active 'ctrl+b to run in background'                               || r=1
    is_active 'Running 1 shell command · 35s…'                            || r=1
    is_active 'watch: 司令官が gh pr checks で外側の状態を確認し、待っている' && r=1
    exit $r
  )
  if [ $? = 0 ]; then
    ok 'watch.sh の is_active() は稼働中パターンと本物の「待ち」を正しく区別する（フォアグラウンドのシェル実行含む）'
  else
    bad 'watch.sh の is_active() の判定が退行している（事故2 / フォアグラウンド実行の誤検知の再発防止ロジック）'
  fi
fi

# 6o) 重大2(watch) の退行検査: 同じ画面のまま止まっている部下を 2 回連続で報告しないか
#     （事故2: 既に処理済みの古い状態を同じ部下について何度も通知し続け、司令官が
#     「通知はどうせ空振り」と学習して事故1 の読み飛ばしに直結した）。
#     watch.sh 本体（sleep 20 を含む while ループ）を丸ごとは動かさず、実装から
#     「1 回観測 → 20 秒後にもう 1 回 → 既読(STALL_STATE)と突き合わせて報告」の
#     ブロックをそのまま抽出して検証する（sleep はテスト用に無効化する）。
g5="$SANDBOX/g5"; mkdir -p "$g5/bin"
mission5="$g5/mission"; mkdir -p "$mission5/workers/42"
jq -nc '{no:"42",name:"g5",ws_ref:"workspace:99",ws_id:""}' > "$mission5/roster.jsonl"
screen_file="$g5/screen.txt"
cat > "$g5/bin/cmux" <<'CMUXSTUB'
#!/usr/bin/env bash
if [ "$1" = "read-screen" ]; then cat "$SCREEN_TEXT_FILE" 2>/dev/null; fi
exit 0
CMUXSTUB
chmod +x "$g5/bin/cmux"
stall_state="$mission5/watch.stall.state"; : > "$stall_state"
scan_waiting_src=$(sed -n '/^scan_waiting() {/,/^}/p' "$D/watch.sh")
dedup_src=$(sed -n '/^  first="\$(scan_waiting)"$/,/^  fi$/p' "$D/watch.sh")
if [ -z "$scan_waiting_src" ] || [ -z "$dedup_src" ]; then
  bad 'watch.sh から scan_waiting() / 既読つき停止検知ブロックを抽出できない（実装が変わった？ selftest も追随させる）'
else
  run5() {
    (
      MISSION="$mission5" ROSTER="$mission5/roster.jsonl" STALL_STATE="$stall_state"
      SCREEN_TEXT_FILE="$screen_file"
      export MISSION ROSTER STALL_STATE SCREEN_TEXT_FILE PATH="$g5/bin:$PATH"
      eval "$is_active_src"
      eval "$scan_waiting_src"
      sleep() { :; }  # 20 秒待たせない
      rearm_line() { :; }  # dedup_src が呼ぶ。このテストでは中身を見ないのでスタブでよい
      eval "$dedup_src"
    )
  }
  printf '待ち画面その1（待っています）\n' > "$screen_file"
  out5a=$(run5)
  out5b=$(run5)  # 同じ画面のまま2回目 → 既読のはずなので再報告しないこと
  printf '待ち画面その2（内容が変わった。待っています）\n' > "$screen_file"
  out5c=$(run5)  # 画面が変わった → 新規の停止として報告すること
  if printf '%s' "$out5a" | grep -q '42' \
     && ! printf '%s' "$out5b" | grep -q '42' \
     && printf '%s' "$out5c" | grep -q '42'; then
    ok 'watch.sh の停止検知は同じ画面を再報告せず、画面が変われば新規として報告する'
  else
    bad '重大2(watch) の退行: 同じ停止を繰り返し報告する、または画面が変わっても報告されない'
    printf '      1回目: %s\n' "$out5a" | head -3
    printf '      2回目(同じ画面): %s\n' "$out5b" | head -3
    printf '      3回目(画面変化): %s\n' "$out5c" | head -3
  fi
fi

# 6p) バグB の退行検査: roster.worktree が空でも、cwd 自体が worktree なら削除されるか。
#     読み取り専用タスクの部下を spawn.sh に worktree 引数を空で渡して起動すると roster の
#     worktree は空だが、実際には cwd が worktree ということがある。wt が空だからと丸ごと
#     スキップすると「撤収完了」と表示したまま worktree が残り続ける（実際に起きた。
#     司令官が手で消す羽目になった）。
g6="$SANDBOX/g6"; mkdir -p "$g6"
repo="$g6/repo"; wt="$g6/wt"; mission="$g6/mission"
git init -q "$repo" \
  && git -C "$repo" config user.email t@t.example \
  && git -C "$repo" config user.name t \
  && git -C "$repo" commit -q --allow-empty -m init \
  && git -C "$repo" worktree add -q "$wt" -b g6-branch >/dev/null 2>&1
mkdir -p "$mission/workers/1"
printf '## 結論\nテスト\n## テスト\n1 passed\n' > "$mission/workers/1/REPORT.md"
jq -nc --arg cwd "$wt" \
  '{no:"1",name:"g6",ws_ref:"",ws_id:"",worktree:"",repo:"",base:"main",cwd:$cwd}' \
  > "$mission/roster.jsonl"
bash "$D/retire.sh" "$mission" 1 >"$g6/out.log" 2>&1
if [ ! -d "$wt" ] && [ -f "$mission/workers/1/RETIRED" ]; then
  ok 'バグB 退行検査: roster.worktree が空でも cwd 自体が worktree なら削除して RETIRED を書く'
else
  bad 'バグB の退行: roster.worktree が空だと cwd が worktree でも削除されない（無言の worktree リーク）'
  sed 's/^/      /' "$g6/out.log" | head -6
fi

# 6q) バグC の退行検査: reported.sh で記録した完了は inbox.sh の
#     「★人間へ未報告の完了」に二度と出ないか（reported.log の形式をタブ区切り・
#     第2フィールド=部下番号に機械的に揃える。手書きで半角スペース区切りにすると
#     第2フィールドが一致せず、同じ完了が何度も再提示され続けた実害がある）。
g7="$SANDBOX/g7"; mkdir -p "$g7/workers/1"
mission="$g7"
jq -nc '{no:"1",name:"g7",ws_ref:"",ws_id:""}' > "$mission/roster.jsonl"
printf '%s\t1\tg7\tテスト完了\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$mission/completed.log"
before=$(bash "$D/inbox.sh" "$mission" --peek 2>&1)
bash "$D/reported.sh" "$mission" 1 g7 >/dev/null 2>&1
after=$(bash "$D/inbox.sh" "$mission" --peek 2>&1)
if printf '%s' "$before" | grep -q '★人間へ未報告の完了' \
   && ! printf '%s' "$after" | grep -q '★人間へ未報告の完了'; then
  ok 'バグC 退行検査: reported.sh で記録した完了は「未報告」に二度と出ない（reported.log の形式）'
else
  bad 'バグC の退行: reported.sh で記録しても「未報告」が消えない（reported.log の形式が inbox.sh と食い違っている）'
  printf '      記録前: %s\n' "$before" | head -3
  printf '      記録後: %s\n' "$after" | head -3
fi

# 6r) 事故5 の退行検査: retire.sh が PR.md の実物の PR 番号でマージ確認し、
#     部下番号をそのまま PR 番号として使わないか。
#     実際の事故: 部下43・44 が PR.md（PR #29・#30、いずれもマージ済み）だけを書いて
#     REPORT.md も PLAN.md も書かずに止まったが、retire.sh は部下番号（43・44）を
#     PR 番号として `gh pr view` に渡していたため無関係な結果になり、
#     「REPORT.md も PLAN.md も無く、PR も未マージ」と誤判定して撤収を拒否した。
#     人間は「作業を捨ててよい」ときのフラグである --force を使わざるを得なかった。
#     部下番号(5)を渡されたら気づけるよう、gh スタブは PR.md 記載の番号(999)にだけ反応する。
g8="$SANDBOX/g8"; mkdir -p "$g8/bin"
mission="$g8/mission"; mkdir -p "$mission/workers/5"
printf 'PR: https://github.com/acme/demo/pull/999 をマージ待ち\n' > "$mission/workers/5/PR.md"
jq -nc '{no:"5",name:"g8",ws_ref:"",ws_id:"",repo:"acme/demo",base:"main"}' > "$mission/roster.jsonl"
cat > "$g8/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
# 引数に PR.md 記載の 999 が含まれるときだけ MERGED を返す（gh --jq は -r 相当でクォート無し）。
# 部下番号(5)や無関係な番号を渡された場合は空を返す（＝未マージ扱いのまま）。
if printf '%s\n' "$*" | grep -q '999'; then printf 'MERGED\n'; else printf '\n'; fi
GHSTUB
chmod +x "$g8/bin/gh"
out8=$(PATH="$g8/bin:$PATH" bash "$D/retire.sh" "$mission" 5 2>&1)
rc8=$?
if [ "$rc8" = "0" ] && [ -f "$mission/workers/5/RETIRED" ]; then
  ok '事故5 退行検査: PR.md の実物の PR 番号(#999)でマージ済みと確認し、REPORT.md 無しでも撤収できる'
else
  bad '事故5 の退行: PR.md がマージ済みなのに撤収できない（部下番号をPR番号と誤認識している可能性）'
  printf '%s\n' "$out8" | sed 's/^/      /' | head -6
fi

# 6r-2) 同じ仕組みの逆側: PR.md に書かれた番号がまだ MERGED でなければ、
#       今まで通り撤収を拒否する（「PR.md さえあれば無条件で撤収してよい」に緩めていないかの確認）
g8b="$SANDBOX/g8b"; mkdir -p "$g8b/bin"
mission="$g8b/mission"; mkdir -p "$mission/workers/6"
printf 'PR: https://github.com/acme/demo/pull/1000 をレビュー中\n' > "$mission/workers/6/PR.md"
jq -nc '{no:"6",name:"g8b",ws_ref:"",ws_id:"",repo:"acme/demo",base:"main"}' > "$mission/roster.jsonl"
cat > "$g8b/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf 'OPEN\n'
GHSTUB
chmod +x "$g8b/bin/gh"
out8b=$(PATH="$g8b/bin:$PATH" bash "$D/retire.sh" "$mission" 6 2>&1)
rc8b=$?
if [ "$rc8b" != "0" ] && [ ! -f "$mission/workers/6/RETIRED" ]; then
  ok '事故5 退行検査: PR.md の PR がまだ OPEN なら撤収を拒否する（無条件撤収に緩めていない）'
else
  bad '事故5 の退行: PR.md があるだけで未マージでも撤収してしまう'
  printf '%s\n' "$out8b" | sed 's/^/      /' | head -6
fi

# 6s) 事故2 の退行検査: sweep.sh は長時間放置された QUESTION.md/BLOCKED.md を検知するか。
#     実際の事故: 部下が QUESTION.md を書いて needs-attention にしたまま、司令官が気づかず
#     4日間放置した（部下は指示どおりその場で待機していた）。REPORT の有無だけを見る
#     旧仕様では、QUESTION 単体の放置は「稼働中」の詳細表示に埋もれるだけで検知されなかった。
g9="$SANDBOX/g9"; mkdir -p "$g9/workers/1" "$g9/workers/2" "$g9/workers/3"
mission="$g9"
{
  jq -nc '{no:"1",name:"g9-fresh",ws_ref:"",ws_id:""}'
  jq -nc '{no:"2",name:"g9-stale-question",ws_ref:"",ws_id:""}'
  jq -nc '{no:"3",name:"g9-stale-blocked",ws_ref:"",ws_id:""}'
} > "$mission/roster.jsonl"
printf '## 論点\nついさっき聞いた質問\n' > "$mission/workers/1/QUESTION.md"
printf '## 論点\nずっと前に聞いた質問\n' > "$mission/workers/2/QUESTION.md"
printf '## 何ができないか\nずっと前から行き詰まっている\n' > "$mission/workers/3/BLOCKED.md"
# 部下2・3 の報告ファイルだけ 2 時間前の更新時刻にする（既定しきい値 30 分を超える）
python3 -c "import os,time; t=time.time()-2*3600; os.utime('$mission/workers/2/QUESTION.md', (t,t)); os.utime('$mission/workers/3/BLOCKED.md', (t,t))"
out9=$(bash "$D/sweep.sh" "$mission" 2>&1); rc9=$?
if [ "$rc9" = "1" ] \
   && printf '%s' "$out9" | grep -q '部下2 g9-stale-question: QUESTION.md が' \
   && printf '%s' "$out9" | grep -q '部下3 g9-stale-blocked: BLOCKED.md が' \
   && ! printf '%s' "$out9" | grep -q '部下1 g9-fresh: QUESTION.md が'; then
  ok '事故2 退行検査: sweep.sh は長時間放置された QUESTION/BLOCKED を検知し、新しいものは警告しない'
else
  bad '事故2 の退行: sweep.sh が長時間放置の QUESTION/BLOCKED を検知しない（4日放置の再発防止が抜けている）'
  printf '%s\n' "$out9" | sed 's/^/      /' | head -12
fi

# 6t) 事故2 の退行検査（board.sh 側）: 長時間放置された QUESTION.md に警告サフィックスが付くか。
#     board.sh は cmux を叩くので、必要な分だけ返す最小限の cmux スタブを用意する。
g10="$SANDBOX/g10"; mkdir -p "$g10/bin"
mission="$g10/mission"; mkdir -p "$mission/workers/1"
ws_list_file="$g10/ws-list.json"
jq -nc '{workspaces:[{id:"id1",ref:"workspace:101",current_directory:"",latest_conversation_message:""}]}' > "$ws_list_file"
cat > "$g10/bin/cmux" <<CMUXSTUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "workspace list") cat "$ws_list_file" ;;
  "workspace status") printf '{"effective":"working"}\n' ;;
  *)
    case "\$1" in
      sidebar-state) printf 'progress=none\n' ;;
      todo) printf '{"items":[],"progress":{"completed":0,"total":0}}\n' ;;
      *) printf '{}\n' ;;
    esac ;;
esac
exit 0
CMUXSTUB
chmod +x "$g10/bin/cmux"
jq -nc '{no:"1",name:"g10",ws_ref:"workspace:101",ws_id:"id1",started_at:"2026-01-01T00:00:00Z"}' > "$mission/roster.jsonl"
printf '## 論点\nずっと前に聞いた質問\n' > "$mission/workers/1/QUESTION.md"
python3 -c "import os,time; t=time.time()-2*3600; os.utime('$mission/workers/1/QUESTION.md', (t,t))"
out10=$(PATH="$g10/bin:$PATH" bash "$D/board.sh" "$mission" 2>&1)
if printf '%s' "$out10" | grep -qE '確認待ち.*⚠ [0-9]+分放置'; then
  ok '事故2 退行検査(board.sh): 長時間放置された QUESTION.md に放置分数の警告が付く'
else
  bad '事故2 の退行(board.sh): 長時間放置の QUESTION.md でも盤面に放置時間の警告が出ない'
  printf '%s\n' "$out10" | sed 's/^/      /' | head -12
fi

# 6u) 事故6 の退行検査: mergeable.sh は base より遅れたブランチ（古い main から切った PR）を
#     検出するか。
#     実際の事故: PR #28 が PR #29（11分前にマージ済み）より古い main から切られていたため、
#     PR #28 をマージした瞬間に #29 の変更が巻き戻った。両方とも mergeStateStatus=CLEAN の
#     ままマージできており、旧来の CLEAN/UNSTABLE 判定だけでは検出できなかった。
#     `compare` API の behind_by を機械的に見て、CLEAN でも遅れを検出できるか確認する。
g11="$SANDBOX/g11"; mkdir -p "$g11/bin"
cat > "$g11/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
case "$1" in
  pr)
    case "$2" in
      view)
        cat <<'JSON'
{"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":null,"headRefOid":"headsha123","baseRefName":"main","state":"OPEN"}
JSON
        ;;
      checks) printf '[]\n' ;;
    esac ;;
  api)
    case "$*" in
      *graphql*) printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}\n' ;;
      *"/reviews"*) printf '[]\n' ;;
      *"/compare/"*) cat "$COMPARE_JSON" ;;
      *) printf '{}\n' ;;
    esac ;;
esac
GHSTUB
chmod +x "$g11/bin/gh"

echo '{"behind_by":5,"ahead_by":1,"status":"diverged"}' > "$g11/behind.json"
out11a=$(COMPARE_JSON="$g11/behind.json" PATH="$g11/bin:$PATH" bash "$D/mergeable.sh" acme/demo 42 2>&1)
rc11a=$?
if [ "$rc11a" = "1" ] && printf '%s' "$out11a" | grep -q 'コミット遅れている'; then
  ok '事故6 退行検査: mergeable.sh は base より遅れたブランチ（behind_by>0）を検出してマージ不可にする'
else
  bad '事故6 の退行: mergeable.sh が古い base から切られたブランチ（behind_by>0）を見逃す'
  printf '%s\n' "$out11a" | sed 's/^/      /' | head -12
fi

echo '{"behind_by":0,"ahead_by":1,"status":"ahead"}' > "$g11/uptodate.json"
out11b=$(COMPARE_JSON="$g11/uptodate.json" PATH="$g11/bin:$PATH" bash "$D/mergeable.sh" acme/demo 42 2>&1)
if printf '%s' "$out11b" | grep -q 'base(main) の最新コミットを含んでいる'; then
  ok '事故6 退行検査: base に追いついたブランチ（behind_by=0）は OK と判定される'
else
  bad '事故6 の退行: base に追いついているのに新旧比較が OK と判定されない'
  printf '%s\n' "$out11b" | sed 's/^/      /' | head -12
fi

# 6v) ADDENDUM の退行検査: watch.sh の沈黙検知が「張り直すたびに毎回・間を置かず再発火」しないか。
#     実際の事故: 経過分数を spawn 時刻からの単純な差分で判定していたため、いったん 60 分を
#     超えた部下がいる限り、張り直すたびに同じ内容で即 exit するだけの監視になり機能しなかった。
#     司令官はそれを避けて部下ごとの使い捨てスクリプトを自作し、そちらの壊れやすい既読フラグ
#     設計のせいで報告の見落とし事故を起こした（部下30・34・38・39・41、さらに直近で部下45・46）。
#     ここでは沈黙検知ブロックを watch.sh から直接抽出し、以下を確認する:
#       - 同じ 60 分区切りのままなら2回目は再発火しない（バケット・デデュープ）
#       - 新しい区切り（120分）に進めば再発火する
#       - 既読台帳（SILENCE_STATE）を削除しても、次の1回だけ再発火してそこで正しく記録し直す
#         （壊れたままにならない。既読フラグ喪失に強い）
#       - 途中で撤収（RETIRED）された部下は検知対象から外れる
silence_funcs_src=$(sed -n '/^get_silence_bucket() {/,/^}/p' "$D/watch.sh")
silence_block_src=$(sed -n '/^  stalled=""$/,/^  fi$/p' "$D/watch.sh")
if [ -z "$silence_funcs_src" ] || [ -z "$silence_block_src" ]; then
  bad 'watch.sh から沈黙検知の関数・ブロックを抽出できない（実装が変わった？ selftest も追随させる）'
else
  g12="$SANDBOX/g12"; mkdir -p "$g12/workers/1" "$g12/workers/2" "$g12/workers/3"
  mission="$g12"
  old130=$(TZ=UTC date -u -v-130M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '130 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --arg t "$old130" '{no:"1",name:"g12-w1",started_at:$t}'  > "$mission/roster.jsonl"
  jq -nc --arg t "$old130" '{no:"2",name:"g12-w2",started_at:$t}' >> "$mission/roster.jsonl"
  jq -nc --arg t "$old130" '{no:"3",name:"g12-retired",started_at:$t}' >> "$mission/roster.jsonl"
  : > "$mission/workers/2/RETIRED"   # 途中で撤収された部下（検知対象から外れるはず）
  SILENCE_STATE="$mission/watch.silence.state"; : > "$SILENCE_STATE"

  run_silence() { # $1=mission
    (
      MISSION="$1"; ROSTER="$1/roster.jsonl"; SILENCE_STATE="$1/watch.silence.state"
      rearm_line() { :; }  # このテストでは呼ばれたことだけ分かればよい
      eval "$silence_funcs_src"
      eval "$silence_block_src"
    )
  }

  out12a=$(run_silence "$mission")           # 130分放置（バケット=2）→ 初回は検知するはず
  out12b=$(run_silence "$mission")           # 直後にもう一度張り直す → 同じバケットなので再発火しないはず
  rm -f "$SILENCE_STATE"                     # 既読台帳を削除（事故3と同種の破壊）
  out12c=$(run_silence "$mission")           # 台帳消失後の1回だけは再発火してよい（それ以降は正しく記録し直す）
  out12d=$(run_silence "$mission")           # 台帳が復元されていれば、また再発火しないはず

  if printf '%s' "$out12a" | grep -q '^watch: 60分以上' && printf '%s' "$out12a" | grep -q '1(' \
     && ! printf '%s' "$out12a" | grep -q '2(' \
     && [ -z "$out12b" ] \
     && printf '%s' "$out12c" | grep -q '^watch: 60分以上' \
     && [ -z "$out12d" ]; then
    ok 'ADDENDUM 退行検査: watch.sh の沈黙検知は同じ60分区切りを再発火せず、台帳喪失後も1回で自己修復する（撤収済み部下は対象外）'
  else
    bad 'ADDENDUM の退行: watch.sh の沈黙検知が張り直すたびに再発火する、または撤収済み部下を誤検知する、もしくは台帳喪失から回復しない'
    printf '      1回目(130分,初回): %s\n' "$out12a" | head -3
    printf '      2回目(同じバケット): %s\n' "$out12b" | head -3
    printf '      3回目(台帳削除直後): %s\n' "$out12c" | head -3
    printf '      4回目(台帳復元後): %s\n' "$out12d" | head -3
  fi

  # 新しい区切り（120分）に進んだら、同じ部下でも再発火することを確認する
  old250=$(TZ=UTC date -u -v-250M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '250 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --arg t "$old250" '{no:"1",name:"g12-w1",started_at:$t}' > "$mission/roster.jsonl"
  out12e=$(run_silence "$mission")
  if printf '%s' "$out12e" | grep -q '^watch: 60分以上'; then
    ok 'ADDENDUM 退行検査: 経過時間が新しい区切り（120分超）に進んだら再発火する'
  else
    bad 'ADDENDUM の退行: 新しい60分区切りに進んでも watch.sh が沈黙を再通知しない'
    printf '      %s\n' "$out12e" | head -3
  fi
fi

# 6w) ADDENDUM の退行検査(board.sh の banner): 「今すぐ見るべきもの」が先頭にまとまって出るか。
#     実際の事故: 司令官が「部下の状況を教えて」と聞かれた際、cmux workspace list と
#     報告ファイルの有無しか見ておらず、QUESTION.md の中身（4日放置）を開いていなかった。
#     board.sh を見れば一目で分かるようにする（人間に報告する前に必ずここを見る運用と対）。
g13="$SANDBOX/g13"; mkdir -p "$g13/bin"
mission="$g13/mission"; mkdir -p "$mission/workers/1" "$mission/workers/2"
ws_list_file="$g13/ws-list.json"
jq -nc '{workspaces:[
  {id:"id1",ref:"workspace:201",current_directory:"",latest_conversation_message:""},
  {id:"id2",ref:"workspace:202",current_directory:"",latest_conversation_message:""}
]}' > "$ws_list_file"
cat > "$g13/bin/cmux" <<CMUXSTUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "workspace list") cat "$ws_list_file" ;;
  "workspace status") printf '{"effective":"working"}\n' ;;
  *)
    case "\$1" in
      sidebar-state) printf 'progress=none\n' ;;
      todo) printf '{"items":[],"progress":{"completed":0,"total":0}}\n' ;;
      *) printf '{}\n' ;;
    esac ;;
esac
exit 0
CMUXSTUB
chmod +x "$g13/bin/cmux"
{
  jq -nc '{no:"1",name:"g13-stale-question",ws_ref:"workspace:201",ws_id:"id1",started_at:"2026-01-01T00:00:00Z"}'
  jq -nc '{no:"2",name:"g13-unretired-report",ws_ref:"workspace:202",ws_id:"id2",started_at:"2026-01-01T00:00:00Z"}'
} > "$mission/roster.jsonl"
printf '## 論点\nずっと前に聞いた質問\n' > "$mission/workers/1/QUESTION.md"
python3 -c "import os,time; t=time.time()-2*3600; os.utime('$mission/workers/1/QUESTION.md', (t,t))"
printf '## 結論\nテスト\n## テスト\n1 passed\n' > "$mission/workers/2/REPORT.md"
out13=$(PATH="$g13/bin:$PATH" bash "$D/board.sh" "$mission" 2>&1)
if printf '%s' "$out13" | grep -q '今すぐ見るべきもの' \
   && printf '%s' "$out13" | grep -qE '部下1 g13-stale-question: QUESTION.md が [0-9]+分 未回答' \
   && printf '%s' "$out13" | grep -q '★ 部下2 g13-unretired-report: REPORT.md あり。検収・撤収がまだ'; then
  ok 'ADDENDUM 退行検査(board.sh banner): 未回答QUESTIONと未撤収REPORTが先頭の「今すぐ見るべきもの」に出る'
else
  bad 'ADDENDUM の退行(board.sh banner): 「今すぐ見るべきもの」が先頭にまとまって出ない'
  printf '%s\n' "$out13" | sed 's/^/      /' | head -20
fi

# 6x) 事故4 の退行検査: verify.sh が検収時に日単位で残留しているサブエージェントを検出するか。
#     実際の事故: 部下34 が REPORT.md を書き終えて止まっていたのに、`Task` ツールで起動した
#     レビュー用サブエージェント（計7体）が 3日20時間 実行中のまま画面に残っていた。
#     ここでは cmux read-screen を模した合成テキストで検出できるかを確認する
#     （実機で長時間ハングを再現したものではない。詳細は PR 本文の「確定できなかったこと」参照）。
g14="$SANDBOX/g14"; mkdir -p "$g14/bin"
mission="$g14/mission"; mkdir -p "$mission/workers/1" "$mission/workers/2"
repo14="$g14/repo"; git init -q "$repo14" \
  && git -C "$repo14" config user.email t@t.example && git -C "$repo14" config user.name t \
  && git -C "$repo14" commit -q --allow-empty -m init
printf '## 結論\nテスト\n## テスト\n1 passed\n' > "$mission/workers/1/REPORT.md"
printf '## 結論\nテスト\n## テスト\n1 passed\n' > "$mission/workers/2/REPORT.md"
jq -nc --arg wt "$repo14" '{no:"1",name:"g14-stuck",worktree:$wt,ws_ref:"workspace:301",base:""}'  > "$mission/roster.jsonl"
jq -nc --arg wt "$repo14" '{no:"2",name:"g14-clean",worktree:$wt,ws_ref:"workspace:302",base:""}' >> "$mission/roster.jsonl"
cat > "$g14/bin/cmux" <<'CMUXSTUB'
#!/usr/bin/env bash
if [ "$1" = "read-screen" ]; then
  # --workspace の値でどちらの画面を返すか切り替える
  for a in "$@"; do
    case "$a" in
      workspace:301) cat "$SCREEN_STUCK" ; exit 0 ;;
      workspace:302) cat "$SCREEN_CLEAN" ; exit 0 ;;
    esac
  done
fi
exit 0
CMUXSTUB
chmod +x "$g14/bin/cmux"
cat > "$g14/screen-stuck.txt" <<'SCR'
  ⏺ レビュー観点の分解
    ◯ angleA (running · 3d 20h 12m)
    ◯ angleB (running · 3d 20h 05m)
    ● angleC (running · 12m)
SCR
cat > "$g14/screen-clean.txt" <<'SCR'
  ⏺ レビュー観点の分解
    ● angleA (running · 12m)
SCR
out14a=$(SCREEN_STUCK="$g14/screen-stuck.txt" SCREEN_CLEAN="$g14/screen-clean.txt" \
  PATH="$g14/bin:$PATH" bash "$D/verify.sh" "$mission" 1 2>&1)
out14b=$(SCREEN_STUCK="$g14/screen-stuck.txt" SCREEN_CLEAN="$g14/screen-clean.txt" \
  PATH="$g14/bin:$PATH" bash "$D/verify.sh" "$mission" 2 2>&1)
if printf '%s' "$out14a" | grep -q '日単位（1日以上）で実行中のサブエージェントが画面に残っている' \
   && printf '%s' "$out14a" | grep -q 'angleA' \
   && printf '%s' "$out14b" | grep -q '日単位で残留しているサブエージェントは画面上に見当たらない' \
   && ! printf '%s' "$out14b" | grep -q '日単位（1日以上）で実行中のサブエージェントが画面に残っている'; then
  ok '事故4 退行検査: verify.sh は日単位で残留したサブエージェント（合成画面）を検出し、平常時は誤検知しない'
else
  bad '事故4 の退行: verify.sh が長時間残留サブエージェント（合成画面）を検出できない、または平常時に誤検知する'
  printf '      画面あり: %s\n' "$out14a" | head -6
  printf '      画面クリーン: %s\n' "$out14b" | head -6
fi

# 7) 全スクリプトの構文
for f in "$D"/*.sh; do
  bash -n "$f" 2>/dev/null || bad "構文エラー: $(basename "$f")"
done
ok '全スクリプトの構文チェック完了'

if [ "$fail" = "0" ]; then printf '判定: 退行なし\n'; exit 0; else printf '判定: 退行あり（直すまでスキルを使わない）\n'; exit 1; fi
