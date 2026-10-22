# デプロイレポート

> 生成日時: YYYY-MM-DD HH:MM / コミット: <短いハッシュ> / 判定: 成功 | 失敗 | 未実施 (<理由の区分>) | デプロイなし

## 1. デプロイ前の状態

| 項目 | 内容 |
|------|------|
| 検証レポートの判定 | <docs/verification-report.md の判定> |
| blocked のタスク | <件数。なければ 0> |
| deploy.allowWithIssues | <true / false> |

## 2. デプロイ先ごとの結果

`devflow-deploy.ps1 status` と `.devflow/deploy-log.md` から。ログは中身を写さず、パスだけを書く。

| 順 | デプロイ先 | 結果 | コミット | 日時 | ログ |
|----|------------|------|----------|------|------|

結果: success / deploy-failed / smoke-failed / rolled-back / rollback-failed / 未実行

## 3. 切り戻し

<なければ「なし」。rollback-failed や rollbackCommand 未設定で戻せなかったものは、人が手で戻す必要があることを先頭に書く>

## 4. 人がすること

<成功なら「なし」。未実施・失敗の理由と直し方、再開の方法 (`/dev-flow redo deployment`) を書く>

## 5. 公開後に人が確認すること

`docs/verification-report.md` の「3. 人が確認する項目」のうち、公開した環境で確かめるもの。

| ID | 内容 | 確認する環境 |
|----|------|--------------|

<なければ「なし」>
