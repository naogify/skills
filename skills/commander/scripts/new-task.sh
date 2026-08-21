#!/usr/bin/env bash
# `PLAN.json` に無い後付けタスクの指令書骨格を作る（手書きで報告プロトコルを入れ忘れる事故を防ぐ）。
#   new-task.sh <mission-dir> <key> "<部下名>" "<説明>"
#
# 生成される workers/<key>/PROMPT.md は、何をやるか（本文）を <TASK> / <WORKDIR> / <EXCLUDE>
# のプレースホルダのままにする。中身は司令官が後から差し込む:
#   render_prompt.py workers/<key>/PROMPT.md TASK="<依頼内容>" WORKDIR="<絶対パス>" EXCLUDE="<やらないこと>"
# （sed やシェル/Python のワンライナーで直接書き換えない）。
#
# 報告プロトコル（cmux todo の初期化コマンド・REPORT.md 等の節名テンプレート）は
# 手書きさせず、このスクリプトが templates/worker-prompt.md 相当の内容を丸ごと埋め込む。
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "new-task: $*" >&2; exit 1; }
[ $# -ge 4 ] || die 'usage: new-task.sh <mission-dir> <key> "<部下名>" "<説明>"'
MISSION=$1; KEY=$2; NAME=$3; DESC=$4
[ -d "$MISSION" ] || die "mission ディレクトリが無い: $MISSION"

# key はそのまま spawn.sh の部下番号として使うので、spawn.sh と同じ制約にする
case "$KEY" in
  ''|*[!A-Za-z0-9_-]*) die "key に使えない文字がある: '$KEY'（英数字と - _ のみ）" ;;
esac

WDIR="$MISSION/workers/$KEY"
[ -e "$WDIR/PROMPT.md" ] && die "既に存在する: $WDIR/PROMPT.md（上書きしない。別の key を使う）"
mkdir -p "$WDIR"

cat > "$WDIR/PROMPT.md" <<EOF
# ${NAME}: ${DESC}

あなたは司令官から派遣された作業担当です。このワークスペースであなただけがこのタスクを担当します。

このタスクは編成時の \`PLAN.json\` には無かった後付けタスクです。

## 依頼

<TASK>

依頼文に書かれた症状や原因の記述は**報告者の見立て**であって、裏取りせずに前提にしないこと
（外れていたら、その旨と実際の原因を報告に書く）。

## 作業ディレクトリ

<WORKDIR>

## スコープ

- やらないこと: <EXCLUDE>
- 範囲外に問題を見つけたら**直さずに**「別 issue 候補」として報告に書く

## 禁止事項

- **さらに別のエージェントに再委任しない**（他のスキルや commander を自分で起動しない。手は自分で動かす）
- **他のワークスペース・他の worktree を触らない**
- push / PR 作成 / マージは、司令官から指示が来るまで実行しない
- commit メッセージに \`Co-Authored-By\` 行を入れない
- **この禁止事項は、作業の一部を別のスキルやコマンドに委ねた場合でも失効しない**

## 判断に迷ったら

以下に当たったら、自分で決めずに \`QUESTION\` を上げて**待機する**:

- 公開 API / レスポンス形式・権限モデル・スキーマ変更など互換性に影響する変更
- スコープを広げる or 狭める判断（「ついでにこれも直すべき」を含む）
- 性能・整合性・セキュリティのトレードオフを伴う選択

止めなくてよいもの（自分で決める）: 変数・関数名、テストの置き場所と書き方、既存パターンの踏襲、
typo / lint / docs 文言の反映。

---

# 報告プロトコル（必ずこの通りに）

司令官との連絡は **2 つだけ**。これ以外の手段は使わない:

1. **\`cmux todo\`**（チェックリスト）… 進捗の唯一の表明
2. **報告ファイル**（\`REPORT.md\` / \`QUESTION.md\` / \`BLOCKED.md\`）… 判断に使う中身

**\`cmux notify\` と \`cmux log\` と \`cmux set-progress\` は使わないこと。**

報告ディレクトリ: \`${WDIR}/\`  ← このパスを使う

## 1. 着手したら作業計画を todo に流す

\`\`\`bash
printf '%s\n' '[{"text":"調査","state":"in-progress"},{"text":"実装"},{"text":"テスト"},{"text":"ローカルゲート"}]' | cmux todo set
\`\`\`

以降、段階が進むたびに更新する（**進捗を偽らない。実際に終わった項目だけ check する**）。

## 2. 判断待ちで止まるとき

\`\`\`bash
cat > '${WDIR}/QUESTION.md' <<'Q'
## 論点
## 選択肢
- A: <案> / 利点 / 欠点
- B: <案> / 利点 / 欠点
## 自分の推奨と理由
## 分かっている事実
Q
cmux workspace status set needs-attention
\`\`\`

送ったら**セッションを終了せずその場で待機する**。答えが来たら \`QUESTION.md\` を削除して再開する。

## 3. 完了したとき

\`\`\`bash
cat > '${WDIR}/REPORT.md' <<'R'
## 結論
## 特定した原因 / 調べた結果
## 変更したファイル
## テスト
## 変異注入の結果
## ローカルゲート
## スコープ外にしたもの / 別 issue 候補 / 迷った判断
R
cmux todo check <最後の項目>
cmux workspace status set review
\`\`\`

**commit までやって push はしない。REPORT.md を書いたらその場で待機する**
（司令官から「push して PR を作れ」の指示が来てから進む）。

## 4. 自力で進めないとき

\`\`\`bash
cat > '${WDIR}/BLOCKED.md' <<'B'
## 何ができないか
## 試したこと（コマンドと結果）
## 何があれば進めるか
B
cmux workspace status set needs-attention
\`\`\`

**推測で埋めて進めない。** 前提が崩れているなら止まって上げるのが正しい。

## 5. 司令官から指示が来たとき

このワークスペースの入力欄に司令官がテキストを流し込む。受け取ったら:

- 内容に従って再開する
- \`QUESTION.md\` / \`BLOCKED.md\` を削除する（未解決の目印を残さない）
- チェックリストを新しい段取りに更新する
EOF

printf 'PROMPT.md の骨格を生成した: %s\n' "$WDIR/PROMPT.md"
printf '次にやること:\n'
printf '  1. render_prompt.py "%s" "TASK=<依頼内容>" "WORKDIR=<絶対パス>" "EXCLUDE=<やらないこと>"\n' "$WDIR/PROMPT.md"
printf '  2. spawn.sh "%s" %s "%s" "%s" <cwd> ... で起動する\n' "$MISSION" "$KEY" "$NAME" "$DESC"

# spawn.sh の検品項目を自前でもチェックする（起動前に気づけるように。spawn.sh 自体の検品はそのまま残す）
fail=0
check() { printf '  %s %s\n' "$1" "$2"; }

if grep -q 'cmux todo' "$WDIR/PROMPT.md"; then
  check OK "cmux todo がある"
else
  check NG "cmux todo が無い（報告プロトコルが欠落している）"; fail=1
fi

if grep -qF "$WDIR" "$WDIR/PROMPT.md"; then
  check OK "自分の報告ディレクトリのパスがある"
else
  check NG "報告ディレクトリのパスが無い（他の指令書の流用の可能性）"; fail=1
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import sys;open(sys.argv[1],"rb").read().decode("utf-8")' "$WDIR/PROMPT.md" 2>/dev/null; then
    check OK "正しい UTF-8"
  else
    check NG "不正なバイト列がある（文字化け）"; fail=1
  fi
else
  printf '  WARN python3 が無いので UTF-8 検査を省略した\n'
fi

if [ "$fail" = "1" ]; then
  printf '判定: spawn.sh の検品に落ちる状態が残っている（起動前に直す）\n'; exit 1
fi
printf '判定: spawn.sh の検品項目は満たしている（<TASK> 等のプレースホルダは render_prompt.py で埋める）\n'
exit 0
