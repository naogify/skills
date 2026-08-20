# naogify skills

Claude Code の個人用スキルを配布するための marketplace。

## 収録スキル

| スキル | 用途 |
|---|---|
| `commander` | cmux のワークスペースを部下として並列に立ち上げ、複数タスクを同時に走らせて指揮する |

## 導入

```
/plugin marketplace add naogify/skills
/plugin install commander@naogify
```

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
- `commander` は `cmux`（https://cmux.com）が必要です。macOS 専用。
