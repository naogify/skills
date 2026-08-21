# push / マージ前に司令官が自分で叩く確認

**部下の自己申告は根拠にしない。** 「CI 通った」「approve もらった」は読み捨てて、司令官が `gh` を叩く。
これが司令官に残された唯一の検収であり、省略したら並列指揮ではなく無検査になる。

## まず `scripts/mergeable.sh` を通す

下の 1〜4 を1画面にまとめて機械的に判定するラッパーが `scripts/mergeable.sh <owner/repo> <PR番号>`。
exit 0 ならマージしてよい、exit 1 なら差し戻す。

**人間から「マージして」「ok」と言われた場合も同じゲートを通す。** 人間の「ok」は設計内容への
承認であって、未解決の指摘を無視してよいという意味ではない（PR #418 で「レビューが出ている
以上マージできないので修正して」と差し戻された実例がある）。exit 1 ならマージではなく
部下への修正指示を出す。

## 0. 差し戻しの後の報告は、対象が進んだかを先に見る

```bash
git -C <worktree> log --oneline origin/<base>..HEAD   # 差し戻し分の commit が増えているか
```

差し戻し前と同じ head SHA なら、**指示が届いていないまま書かれた古い報告**。
中身の緑さは一切見ずに無効化し、指示を届け直す（`cmux send` の罠）。

## 1. CI が全部緑か

```bash
PR=<番号>; REPO=<owner/repo>
gh pr checks "$PR" --repo "$REPO"
```

## 2. 最新 head に対するレビューが実在するか

SHA 完全一致で見る。`--paginate` 必須。**空は失敗**（未レビュー）。

```bash
NEW=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid') \
  || { echo "query failed — NOT reviewed"; exit 1; }
reviews=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" \
  --jq ".[] | select(.commit_id == \"$NEW\") | \"\(.user.login):\(.state)\"") \
  || { echo "query failed — NOT reviewed"; exit 1; }
[ -n "$reviews" ] || { echo "NOT reviewed at $NEW"; exit 1; }
printf '%s\n' "$reviews"
```

CodeRabbit の緑は「レビュー済み」を意味しない（レートリミット中は指摘 0 件でも pass）。
check description が `Review rate limited` なら未レビュー、`Review completed` なら実処理済。

## 3. 承認が失効していないか / マージ可能か

```bash
gh pr view "$PR" --repo "$REPO" --json reviewDecision,mergeStateStatus \
  --jq '"reviewDecision=\(.reviewDecision) mergeState=\(.mergeStateStatus)"'
```

`mergeState=BLOCKED` は org ruleset の `require_last_push_approval` が原因のことがある
（approve 後に push すると、その push を承認した人が居ないので閉まる）。
**最後の push より後の approve** が必要なので、人間のレビュワーに再 approve を依頼する。
司令官が bypass を探しに行かない。

## 4. 未解決レビュースレッドが残っていないか

```bash
gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){
    pullRequest(number:$n){ reviewThreads(first:100){ nodes{ isResolved isOutdated
      comments(first:1){ nodes{ author{login} path body } } } } } } }' \
  -F o=<owner> -F r=<repo> -F n="$PR" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)
        | "UNRESOLVED \(.comments.nodes[0].path): \(.comments.nodes[0].author.login)"'
```

## 5. 対の PR が必要でないか

`scgp-app` と `scgp-api` は**対の PR で開発される**。app 側だけマージすると機能が成立しない。
CI もレビュー bot も検出しないので、api の main を `git grep` して確認する。

## 判定

どれか 1 つでも赤・空なら **GO を出さず部下に差し戻す**（`mergeable.sh` の exit 1 と同じ）。
全部揃ったら**人間に諮る**（PR 番号 / CI 結果 / 誰の approve か / 指摘の処理内訳を 3〜5 行）。
**人間の明示指示を受けてから**マージ GO を送る。
