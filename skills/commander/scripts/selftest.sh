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

# 7) 全スクリプトの構文
for f in "$D"/*.sh; do
  bash -n "$f" 2>/dev/null || bad "構文エラー: $(basename "$f")"
done
ok '全スクリプトの構文チェック完了'

if [ "$fail" = "0" ]; then printf '判定: 退行なし\n'; exit 0; else printf '判定: 退行あり（直すまでスキルを使わない）\n'; exit 1; fi
