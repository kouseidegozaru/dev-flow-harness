# フェーズ 7: デプロイ (完全自動)

検証フェーズに続けて、同じオーケストレーターのセッションで自動で実行する。**ユーザーには質問しない。**
デプロイ先 (`.devflow/config.json` の `deploy.targets`) へ上から順にデプロイし、公開後の確認まで行って、結果を `docs/deployment-report.md` に残す。

デプロイの実行・順序の確認・失敗時の切り戻し・記録は、すべて `scripts/devflow-deploy.ps1` が機械的に行う。
**オーケストレーターはデプロイのコマンド (`deploy.targets` の command など) を直接実行しない。** MCP で行うデプロイ先 (`kind: agent`) だけは、
`devflow-deploy.ps1 all` が出した手順どおりに MCP のツールで行い、結果をスクリプトに記録する。失敗しても、コードや設定を直して再実行しない
(直すかどうかは人が決める。最終レポートで報告する)。

## 入力

- `scripts/devflow-deploy.ps1` の標準出力、`.devflow/deploy-log.md`
- `docs/verification-report.md` の冒頭 (判定) と「3. 人が確認する項目」(レポートに転記するため)
- `docs/03-basic-design/architecture.md` の「デプロイ」節 (デプロイ先が設定されていないときだけ)

## 進め方

1. `pwsh -NoProfile -File scripts/devflow-state.ps1 start-phase`
2. 秘密の値をそろえる:

   ```bash
   pwsh -NoProfile -File scripts/devflow-deploy.ps1 secrets
   ```

   環境変数にない値は vault (`deploy.vault`) から取り出される。exit 1 (足りない) なら、足りない値ごとに、出力の「入手方法」どおりに
   MCP・CLI で読み出し、`devflow-deploy.ps1 set-secret <NAME> -Value '<値>'` で vault に保存する (次からのデプロイでも使われる)。
   入手方法が「ユーザーが vault に入れる」のもの、読み出せなかったもの、vault の認証の値がないものは、そのまま次へ進む (手順 3 の plan が exit 1 になり、レポートに載る)
3. 確認:

   ```bash
   pwsh -NoProfile -File scripts/devflow-deploy.ps1 plan
   ```

   | 終了コード | 意味 | 次 |
   |------------|------|----|
   | 0 | 実行できる | 手順 4 |
   | 3 | デプロイ先が設定されていない | `architecture.md` の「デプロイ」節が「なし」なら、判定「デプロイなし」でレポートを書いて手順 5 へ。デプロイ先が書かれているなら詳細設計の漏れなので、判定「未実施 (設定なし)」で手順 5 へ |
   | 4 | 検証の結果が前提を満たさない (判定が「漏れなし」でない、blocked のタスクがある) | デプロイしない。判定「未実施 (検証の結果)」で手順 5 へ |
   | 1 | 実行できない (コマンドがない、秘密の値がない、コードに未コミットの変更がある) | デプロイしない。判定「未実施 (環境)」で、出力の理由をレポートに書いて手順 5 へ。秘密の値がないときは、どの値を vault のどこに入れればよいかを書く |

   コードに未コミットの変更がある、と出た場合も、自分でコミットしない (検証していない変更をデプロイしないため)。

4. デプロイ:

   ```bash
   pwsh -NoProfile -File scripts/devflow-deploy.ps1 all
   ```

   上から順に、デプロイ → 公開後の確認 (`smokeCommand`) を行う。同じコードで成功済みのデプロイ先は飛ばす (再開しても二重にデプロイしない)。
   失敗したらそこで止まり、後のデプロイ先は実行しない。公開後の確認が失敗したときは、`rollbackCommand` があれば自動で切り戻す
   (`deploy.rollbackOnFailure` が false なら切り戻さない)。

   - exit 5 (`AGENT:` と手順が出る): MCP で行うデプロイ先 (`kind: agent`)。次を行い、`all` をもう一度実行する (これを exit 5 が出なくなるまで繰り返す):
     1. 出力の「使うツール」がツール一覧にあるかを確かめる (なければ ToolSearch で探す)。見つからなければ何もせず、
        `devflow-deploy.ps1 finish <name> -Result failed -Note 'MCP 未接続: <ツール>'` を実行する (レポートの「人がすること」に、claude.ai のコネクタの設定でそのサービスを接続することを書く)
     2. 出力の手順どおりに、MCP のツールで行う。**手順にない操作はしない** (別の環境・設定に触れない、失敗しても手順を変えて試し直さない)。
        読み出した秘密の値は、vault か設定先のサービスにだけ書き、リポジトリ (コード・`docs/`・コミット) とレポートには書かない
     3. `devflow-deploy.ps1 finish <name> -Result success|failed -Note '<公開した URL、または失敗の理由>'` で記録する
        (success なら公開後の確認が走る)。出力に `ROLLBACK-BY-AGENT:` が出たら、その手順どおりに MCP で切り戻し、
        `devflow-deploy.ps1 rollback-done <name> -Result success|failed` で記録する。finish が 0 以外なら、`all` を再実行せず exit 1 と同じに扱う
   - exit 0: 判定「成功」
   - exit 1: 判定「失敗」。**再実行しない・コマンドを直接打たない・切り戻しを追加で試さない。** 出力 (失敗したデプロイ先・理由・切り戻しの結果) をレポートに書く。
     そのサービスの MCP がこのセッションにあれば、読み取りのツールだけ (デプロイの状態・ビルドのログ・実行時のエラー) で原因を調べ、
     ユーザーが管理画面を開かずに直せるよう、原因の候補と直し方をレポートに書く (秘密の値は写さない)。MCP で設定を変えたりデプロイし直したりしない
   - exit 3 / 4: 手順 3 の表と同じ

5. **最終レポート** — `docs/deployment-report.md` を `templates/deployment-report.md` の形で書く:
   - 判定と、デプロイしたコミット
   - デプロイ先ごとの結果 (`devflow-deploy.ps1 status` の出力と `.devflow/deploy-log.md` から)
   - 切り戻したもの・切り戻しに失敗したもの (人が手で戻す必要がある)
   - 未実施・失敗の理由と、人がすること (環境変数を設定する、`deploy.targets` を直す、検証の blocked を解消するなど) と再開の方法。
     人がすることは、`architecture.md` の「ユーザーが一度だけする作業」の手順の要点を添えて、そのまま実行できる形で書く
   - 公開後に人が確認すること (`docs/verification-report.md` の「3. 人が確認する項目」のうち、公開した環境で確かめるもの)

   ログ (`.devflow/logs/deploy-*.log`) の中身はレポートに写さない (秘密の値が含まれることがあるため)。ログのパスだけを書く。

6. 完了する (判定が成功でなくても完了する。再実行は人が `/dev-flow redo deployment` で行う):

   ```bash
   pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase deployment
   pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind docs -Scope deployment -Message 'デプロイレポート'
   pwsh -NoProfile -File scripts/devflow-state.ps1 run stop
   ```

   phase が `done` になる。ユーザーに、検証レポートの要点 (漏れ・blocked・人が確認する項目) とデプロイの結果 (判定・公開先・切り戻し・人がすること) を伝えて終える。

## 完了条件

- [ ] `devflow-deploy.ps1 all` が成功した。または、成功しなかった理由がレポートにある
- [ ] `docs/deployment-report.md` に上の項目がすべてある
- [ ] phase が `done` になり、コミット済み

## 止まったあとの再開 (人が行う)

| 判定 | 見るもの | 直し方 |
|------|----------|--------|
| 未実施 (設定なし) | `architecture.md` の「デプロイ」節 | `.devflow/config.json` に `deploy.targets` を書き、`/dev-flow redo deployment` |
| 未実施 (検証の結果) | `docs/verification-report.md` | 漏れ・blocked を解消して検証を通し直す。そのままデプロイしてよいなら `deploy.allowWithIssues` を true にして `/dev-flow redo deployment` |
| 未実施 (環境) | レポートの理由 | 環境変数・ツールを用意して `/dev-flow redo deployment` |
| 失敗 | `.devflow/deploy-log.md`、`.devflow/logs/deploy-*.log` | 原因を直して `/dev-flow redo deployment` (成功済みのデプロイ先は、コードが同じなら飛ばされる)。手で戻すなら `devflow-deploy.ps1 rollback <name>` |

## コンテキストが圧縮されたとき

会話の記憶に頼らず、`devflow-deploy.ps1 status` と `.devflow/deploy-log.md` から、どこまで終えたかを確かめて続ける
(`all` を再実行してよい。同じコードで成功済みのデプロイ先は飛ばされる)。
