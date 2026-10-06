# naogify skills

Claude Code の個人用スキルを配布するための marketplace。

## 収録スキル

| スキル | 用途 |
|---|---|
| `commander` | cmux のワークスペースを部下として並列に立ち上げ、複数タスクを同時に走らせて指揮する |
| `kid-explainer` | PR・issue・コード・仕組みを小学生でもわかるたとえで説明し、before/after を SVG で図解した HTML を Artifact に公開する |

`skills/` 配下のスキルはすべて `commander` プラグインに同梱される（`issue-labeling` と同じく、呼ぶときは `/commander:kid-explainer`）。

## 導入

```
/plugin marketplace add naogify/skills
/plugin install commander@naogify
```

## 使い方

- `/commander:status` — 部下の状況と、人間の判断が必要なことを 3 枠（部下の状況 / 人間が決めること / 返事待ち）でまとめて報告させる。中身は全ミッションを横断する読み取り専用の `skills/commander/scripts/status.sh`
- `/commander:kid-explainer` — 「小学生でもわかるように説明して、before/after を図解して、artifacts にまとめて」と頼むと発火する。骨組みは `skills/kid-explainer/templates/explainer.html`

## 更新を取り込む

```
/plugin marketplace update naogify
/plugin update commander@naogify
```

## 更新を出す

1. スキルを直す（このリポジトリを直接編集する）
2. `bash skills/commander/scripts/selftest.sh` を回して退行がないことを確認する
3. commit して push する
4. 他のマシンで `/plugin marketplace update naogify` → `/plugin update commander@naogify`

## 注意

- **private リポジトリ**です。社内固有の運用（リポジトリのブランチ規約、顧客名、org ruleset の挙動）が
  スキル本文に含まれるため、public にしないこと。
- `commander` は `cmux`（https://cmux.com） が必要です。macOS 専用。

## 許可ルール（commander の見張りが auto mode で止められないように）

commander の見張り（`watch-all.sh`）や送信（`send.sh`）を auto mode の分類器に毎回判定させると、
いつか拒否されて見張りが止まる（2026-10-05 に実際に起きた）。`~/.claude/settings.json` の
`permissions.allow` に、インストール先のスクリプトを前方一致で許可するルールを入れておく:

```json
{
  "permissions": {
    "allow": [
      "Bash(bash /Users/<user>/.claude/plugins/cache/naogify/commander/*)"
    ]
  }
}
```

- `<user>` は自分のユーザー名に置き換える。バージョンごとにパスの途中（ハッシュ）が変わるので末尾は `*` にする
- 前方一致なので、司令官は `bash $SKILL/...` のように変数のまま書かず、引用符でも囲まず、
  展開した絶対パスで呼ぶ（`watch-all.sh` が出す `REARM:` 行はこの形になっている）
