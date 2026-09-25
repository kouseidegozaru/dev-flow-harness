# フェーズ 6: 検証 (完全自動)

実装ループの最後に自動で実行する。**ユーザーには質問しない。**
設計で決めたことがすべて実装されているかを、機械チェックと監査で確認し、漏れがあれば追加タスクにして実装フェーズに戻す。

## 入力

- `.devflow/state.json` (検証ラウンド数)、`.devflow/handoff.md`
- `scripts/devflow-trace.ps1` の出力、`.devflow/audit-plan.json`
- 監査結果 (implementation-auditor サブエージェントの報告)

オーケストレーターは設計ファイルやソースコードを自分で読み込まない。読むのは監査の単位を決める index.md と、スクリプト・サブエージェントの出力だけ。

## 進め方

### 1. ラウンドを進める

```bash
pwsh -NoProfile -File scripts/devflow-state.ps1 verification-round
```

exit 4 (最大ラウンド数 `maxVerificationRounds` を超えた) なら、手順 2〜4 を飛ばして「5. 最終レポート」へ進み、
残りの漏れを「未解決」として報告する。

### 2. 機械チェック

```bash
pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode full -AuditPlan
```

全テストの実行、TODO/スタブの検索、ID の網羅性をまとめて検査し、`docs/traceability.md`、`.devflow/trace-result.json`、
`.devflow/audit-plan.json` (監査の単位) を書き出す。出力された漏れを控えておく。

### 3. 監査

`.devflow/audit-plan.json` の `units` の各単位 (設計のまとまり: 画面、API リソース、モジュールなど) ごとに
`implementation-auditor` サブエージェントを起動する (互いに独立なので並列でよい)。

- ラウンド 1: 全単位を監査する
- ラウンド 2 以降: 前ラウンドで追加したタスクの担当 ID を含む単位、および前ラウンドの監査で漏れが出た単位だけを監査する

各起動に渡すのは、その単位の `designFiles`・`upstreamFiles`・`codeFiles`・`testFiles` のパスと `ids` だけ。依頼文:

> 次の設計ファイルとコードだけを読み、設計がコードに漏れなく正しく反映されているか監査せよ。
> 設計: <designFiles> / 上流: <upstreamFiles> / コード: <codeFiles> / テスト: <testFiles> / 対象 ID: <ids (検証方法付き)>
> 確認すること: (1) 設計に書かれた内容がすべてコードに反映されているか (ID がテスト名にあっても中身が不十分なケースを含む)
> (2) review 種別の ID が実装されているか (3) 設計と異なる実装がないか。

### 4. 漏れの処理

機械チェックと監査の漏れを 1 つの一覧にまとめる。次は **追加タスクにしない** (最終レポートに載せるだけ):

- blocked のタスクに起因するもの (その ID を担当するタスクがすべて blocked)
- `manual` の ID

それ以外の漏れがあれば:

1. 漏れを実装単位にまとめ、追加タスク `TASK-V<ラウンド>-<連番>` を `docs/04-detailed-design/tasks/` に作る
   (`templates/task.md` の形式。担当ID に漏れた ID を入れ、テストケースに「監査で見つかった不足を検出するテスト」を具体的に書く。
   参照すべき設計ファイルには audit-plan の該当単位の designFiles を入れる)。
   漏れが設計の不備 (設計どおりでは実装できない) に起因する場合は、タスクにせず blocked 相当の未解決として記録する
2. `tasks/index.md` に状態 `todo` で追記し、`devflow-state.ps1 add-verification-task <TASK-ID>` で記録する
3. `devflow-trace.ps1 -Mode design` が exit 0 であることを確かめる (追加タスクの書式の確認)
4. `.devflow/verification-log.md` に、このラウンドで見つけた漏れと追加タスクを追記する (最終レポートの材料)
5. `devflow-commit.ps1 -Kind docs -Scope verification -Message "検証ラウンド <r>: 追加タスク <n> 件"`
6. `devflow-state.ps1 set-phase implementation` で実装フェーズに戻し、[05-implementation.md](05-implementation.md) に従って追加タスクを実装する。
   実装フェーズが終わると再びこの検証フェーズに戻る

漏れが 0 件 (追加タスクにするものがない) なら次へ。

### 5. 最終レポート

`docs/verification-report.md` を `templates/verification-report.md` の形で書く:

- 全 ID の網羅状況 (`docs/traceability.md` へのリンクと集計)
- blocked のまま残ったタスクとその理由 (`.devflow/blocked.md` から)
- `manual` 種別の手動確認が必要な項目 (trace-result.json の `manual`)
- 監査で見つかって修正した漏れの一覧 (`.devflow/verification-log.md` から)
- 未解決の漏れ (最大ラウンド超過、設計の不備) があればその一覧

そして:

```bash
pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase verification
pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind docs -Scope verification -Message "検証レポート"
```

phase が `done` になり、外部ループは終了する。

## 完了条件

- [ ] `devflow-trace.ps1 -Mode full` の漏れが、blocked 起因のものだけ (または 0 件)。あるいは最大ラウンドに達した
- [ ] 最新ラウンドの監査で、追加タスクにすべき漏れが 0 件
- [ ] `docs/verification-report.md` に上の 5 項目がある
- [ ] phase が `done` になり、コミット済み

## セッションの終え方

[05-implementation.md の「セッションの終え方」](05-implementation.md#セッションの終え方) と同じ。
handoff.md には検証ラウンド番号、監査済みの単位、まだ監査していない単位を書く。
