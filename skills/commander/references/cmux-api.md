# cmux コマンド早見表（司令官が使う分だけ）

出力形はこのマシンの cmux（`/Applications/cmux.app`）で実測したもの。
`CMUX_QUIET=1` を付けないとレガシー別名の警告が stdout に混ざるので**必ず付ける**。

公式リファレンス:
- https://cmux.com/ja/docs/api
- `cmux docs api` / `curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/cli-contract.md`

## 前提

- 制御ソケットは既定 `automation.socketControlMode: "cmuxOnly"`。**cmux が spawn したプロセスしか繋がらない**。
  部下（cmux ワークスペース内の claude）は spawn 済みなので通る。司令官も cmux 内から起動されていること。
- ソケットパス: `~/.local/state/cmux/cmux.sock`（`CMUX_SOCKET_PATH` で上書き可）。
- `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` は cmux のターミナルに自動注入され、
  `--workspace` / `--surface` の既定値になる。**部下は引数なしで自分のワークスペースに書ける。**
- ターゲット指定は UUID / 短い ref（`workspace:2`）/ index のいずれか。
  **ref は作り直すたびに変わる**ので、起動時の戻り値を roster に控えて使う。

## 部下の起動

```bash
CMUX_QUIET=1 cmux new-workspace \
  --name "<部下名>" --description "<説明>" \
  --cwd "<作業場>" --command "bash '<run.sh>'" \
  [--env KEY=VALUE] [--focus false]
# → stdout: "OK workspace:49"   （--json を付けても同じ文字列。ref をここから取る）
```

`--command` は「作成後にそのテキスト + Enter をシェルへ送る」。長いコマンドは
クォート事故になるので `run.sh` 経由にする。

## 一覧・状態の取得（読み取り）

```bash
CMUX_QUIET=1 cmux workspace list --json     # 旧: list-workspaces（別名として今も動く）
```

`.workspaces[]` の使えるフィールド:

| フィールド | 中身 |
|---|---|
| `ref` | `workspace:49`（コマンドのターゲットに使う） |
| `id` | UUID（**通知の突き合わせに使う。こちらが安定**） |
| `custom_title` | `--name` で付けた名前 |
| `description` | `--description` |
| `current_directory` | cwd |
| `latest_conversation_message` | 直近のやりとり（盤面の「直近の動き」に使う） |
| `latest_submitted_at` | 直近の投入時刻（ISO8601） |

```bash
CMUX_QUIET=1 cmux workspace status --json --workspace workspace:49
# → {"effective":"working","inferred":"working","override":null,"signals":{...}}
#   lane: todo | working | needs-attention | review | done
CMUX_QUIET=1 cmux sidebar-state --workspace workspace:49
# → key=value の行。progress=0.35 検証中 3/8 / status_count=1 / log_count=0 など（JSON ではない）
CMUX_QUIET=1 cmux todo list --json --workspace workspace:49
# → {"items":[...],"progress":{"completed":0,"total":1,"first_unchecked_text":"..."}}
CMUX_QUIET=1 cmux read-screen --workspace workspace:49 --lines 60   # 画面。--scrollback で全履歴
CMUX_QUIET=1 cmux tree --all                                        # 全ワークスペース/ペイン/サーフェス
```

## 部下 → 司令官（報告チャネル）

部下がソケットに書く。司令官が読む。

```bash
# 部下側（引数なしで自分のワークスペースに紐づく）
cmux notify --title "REPORT" --subtitle "<部下名>" --body "<1行要約>"
cmux set-progress 0.6 --label "テスト実行中 (5/8)"
cmux todo add "原因の特定" ; cmux todo start 1 ; cmux todo check 1
cmux log --level progress --source worker "ローカルゲート通過"
cmux workspace status set needs-attention        # 質問で止まったとき
```

```bash
# 司令官側
CMUX_QUIET=1 cmux list-notifications --json
# → [{"id":"UUID","workspace_id":"UUID","surface_id":"UUID","tab_title":"...",
#     "title":"REPORT","subtitle":"...","body":"...","created_at":"2026-08-20T07:29:28Z","is_read":false}]
CMUX_QUIET=1 cmux mark-notification-read --id <UUID>
CMUX_QUIET=1 cmux dismiss-notification --id <UUID>
CMUX_QUIET=1 cmux list-log --workspace workspace:49 [--limit 20]
# → "[worker] [progress] step1 完了" の行が並ぶ（--json を付けても同じ平文。行をパースする）
#    ログが無いときは "No log entries" の 1 行を返すので、件数に数えないこと
```

### 3 経路の性質（実測。ここを間違えると報告を落とす）

| 経路 | 保持 | 用途 |
|---|---|---|
| `cmux log` → `list-log` | **追記。消えない・順序が残る** | 報告ストリームの本命 |
| `cmux notify` → `list-notifications` | **サーフェスごとに最新 1 件。上書きされる** | 「今すぐ見に来い」の割り込みだけ |
| `set-progress` / `todo` / `workspace status` | 最新値のみ | 盤面の実測値 |
| 報告ファイル（`REPORT.md` 等） | ファイルなので消えない | 判断に使う中身 |

**通知は上書きされる。** 部下が `--title REPORT` を打っても、その後に cmux の agent hook が打つ
`Claude Code / Completed in <dir>` に置き換わって消える（実測で確認済み）。
**通知の取得を報告の受信手段にしてはならない。** 受信は log + 報告ファイルで行う。

cmux 自身が同じ通知枠に流し込むもの（部下の報告ではない）:

| title / subtitle | 意味 |
|---|---|
| `Claude Code` / `Completed in <dir>` | 部下のターンが終わって手が空いた（agent hook 由来） |
| `Claude Code` / `Waiting` | 部下が入力待ちで止まっている |
| `チェックリスト完了` | todo を全部 check した |

**`is_read` を進捗管理に使わない。** cmux はワークスペースが可視になっただけで既読にする。
処理済みの位置は mission ディレクトリ側（`inbox.state`）で管理する。

**通知は title / subtitle / body の 3 つしか運べない。** 詳細はファイル（`REPORT.md` 等）に書かせる。

### 通知の title 規約（このスキルの取り決め）

| title | 意味 | 司令官が次にやること |
|---|---|---|
| `REPORT` | タスク完了。`REPORT.md` に詳細 | 読んで検収 → 人間へ報告 → 撤収 |
| `QUESTION` | 判断待ちで停止。`QUESTION.md` に詳細 | 答えを送る or 人間へ上げる |
| `BLOCKED` | 自力で進めない。`BLOCKED.md` に詳細 | 人間へ差し戻す。撤収しない |
| `PROGRESS` | 節目の通過（任意） | 記録だけ。反応不要 |

`subtitle` には**部下名**を入れさせる（どのワークスペースからでも人間が読める）。
ただし上書きされるので、**同じ内容を必ず `cmux log` にも書かせる**（そちらが残る）:

```bash
cmux log --level success --source worker "REPORT: <1行要約>"
```

## 司令官 → 部下（指示）

```bash
CMUX_QUIET=1 cmux send --workspace workspace:49 "<指示>"
CMUX_QUIET=1 cmux send-key --workspace workspace:49 enter
```

**`send` は Enter を押さない。** テキスト内に `\n` を入れるか `send-key enter` を別に打つ。
`OK` は「ソケットが受け取った」だけで、model に届いた証拠ではない（SKILL.md の罠を参照）。

## 司令官 → 部下のワークスペース（表示メタ）

盤面と cmux サイドバーの見た目を司令官が整えるのに使う。

```bash
CMUX_QUIET=1 cmux set-status task "PR #123 レビュー" --icon bolt.fill --color '#4C8DFF' --workspace workspace:49
CMUX_QUIET=1 cmux set-progress 0.35 --label "検証中 3/8" --workspace workspace:49
CMUX_QUIET=1 cmux rename-workspace --workspace workspace:49 "PR #789 / ISSUE #456"
CMUX_QUIET=1 cmux workspace status set needs-attention --workspace workspace:49   # auto で解除
CMUX_QUIET=1 cmux clear-progress --workspace workspace:49
```

## 撤収

```bash
CMUX_QUIET=1 cmux close-workspace --workspace workspace:49   # → "OK workspace:49"
```

**worktree は消えない。** `git worktree remove` を別に叩く（`retire.sh` がやる）。

## イベントストリーム（任意）

通知のポーリングで足りるが、取りこぼしを厳密に避けたいときはこちら。

```bash
CMUX_QUIET=1 cmux events --category notification --cursor-file "$MISSION/events.seq" --no-heartbeat --limit 1
```

- `--cursor-file` が seq を保存するので、次回はそこから再開できる。
- **イベントが無いとブロックする。** フォアグラウンドで無条件に呼ばない（`--limit` と外側の
  タイムアウトを併用する）。全イベントは `~/.cmuxterm/events.jsonl` にも追記されるので、
  そのファイルを `tail` する手もある。
