# フェーズ 6: 検証 (完全自動)

実装フェーズに続けて、同じオーケストレーターのセッションで自動で実行する。**ユーザーには質問しない。**
設計で決めたことがすべて実装されているかを機械チェック (`devflow-trace.ps1 -Mode full`) で確認し、漏れがあれば追加タスクにして実装フェーズに戻す。

コードを読んで突き合わせる監査は行わない (トークン消費が大きいため)。`review` 種別の ID は、実装時に `tdd-implementer` が
完了条件として自己確認し、`.devflow/review-log.md` に記録している (記録がなければ trace が REVIEW-NOT-RECORDED を出す)。最終レポートで、その記録とともに人が確認する項目として一覧にする。

## 入力

- `.devflow/state.json` (検証ラウンド数)、`.devflow/handoff.md`
- `scripts/devflow-trace.ps1` の標準出力

オーケストレーターは設計ファイルやソースコードを自分で読み込まない。**`.devflow/trace-result.json` も Read しない** (大きい)。
読むのはスクリプトの出力と、`.devflow/verification-log.md`・`handoff.md` だけ。
追加タスクを書くときに限り、漏れた ID の定義行 (trace の出力の `(<ファイル>:<行>)`) と、元の担当タスクのファイルを読んでよい。

## 進め方

### 1. ラウンドを進める

```bash
pwsh -NoProfile -File scripts/devflow-state.ps1 verification-round
```

ラウンドの途中から再開して再実行しても、ラウンドは進まない (同じ番号が出る)。
exit 4 (最大ラウンド数 `maxVerificationRounds` を超えた) なら、手順 2〜3 を飛ばして「4. 最終レポート」へ進み、
残りの漏れを「未解決」として報告する。

### 2. 機械チェック

```bash
pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode full
```

全テストの実行、TODO/スタブの検索、ID の網羅性をまとめて検査し、`docs/traceability.md` と `.devflow/trace-result.json` を書き出す。
標準出力に、漏れの種類ごとに `<ID> <内容> (<定義ファイル>:<行>) 担当: <タスク>` が並ぶ。

### 3. 漏れの処理

次は **追加タスクにしない** (最終レポートに載せるだけ):

- blocked のタスクに起因するもの (その ID を担当するタスクがすべて blocked)
- `manual` の ID

それ以外の漏れがあれば:

1. 漏れを実装単位 (目安: 元の担当タスクごと) にまとめ、追加タスク `TASK-V<ラウンド>-<連番>` を `docs/04-detailed-design/tasks/` に作る
   (`templates/task.md` の形式)。
   - 担当ID: 漏れた ID
   - 参照すべき設計: 漏れた ID の定義行を含む節と、元の担当タスクのファイル (テストケースや作るファイルが書かれている)
   - テストケース: 漏れた ID ごとに 1 行書き、元の担当タスクのテストケースを指す (例: `- [REQ-TODO-004] TASK-015 のテストケース #1〜4`)。
     同じ内容は書き写さないが、行には必ず漏れた ID を書く (trace がテストケース節の ID を数えるため。ないと TASK-NO-TESTCASE になる)
   - 依存: 空にする (元の担当タスクは done 済み)。タスクファイルと `tasks/index.md` の依存欄をそろえる
   - 漏れが設計の不備 (設計どおりでは実装できない) に起因する場合は、タスクにせず未解決として記録する
2. `tasks/index.md` に状態 `todo` で追記し、`devflow-state.ps1 add-verification-task <TASK-ID>` で記録する
3. `devflow-trace.ps1 -Mode design` が exit 0 であることを確かめる (追加タスクの書式の確認)
4. `.devflow/verification-log.md` の「## ラウンド <r>」節に、見つけた漏れと追加タスクを追記する (最終レポートの材料)
5. `devflow-commit.ps1 -Kind docs -Scope verification -Message "検証ラウンド <r>: 追加タスク <n> 件"`
6. `devflow-state.ps1 set-phase implementation -KeepVerification` で実装フェーズに戻し (このラウンドを閉じる。`-KeepVerification` を付けないと検証の記録が初期化される)、[05-implementation.md](05-implementation.md) の手順 4 から続けて、
   実装担当に追加タスクを実装させる。実装フェーズが終わると再びこの検証フェーズに戻る

漏れが 0 件 (追加タスクにするものがない) なら次へ。

### 4. 最終レポート

`docs/verification-report.md` を `templates/verification-report.md` の形で書く:

- 全 ID の網羅状況 (`docs/traceability.md` の集計を転記)
- blocked のまま残ったタスクとその理由 (対象は `impl-status` で今も blocked のタスクだけ。理由は `.devflow/blocked.md` のそのタスクの最後の記録から。「解除」の記録があるものは載せない)
- 人が確認する項目: `manual` 種別と `review` 種別の ID (`docs/traceability.md` の一覧から。review は `.devflow/review-log.md` の自己確認の記録を添える)
- 検証で見つかって修正した漏れの一覧 (`.devflow/verification-log.md` から)
- 未解決の漏れ (最大ラウンド超過、設計の不備) があればその一覧

そして:

```bash
pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase verification
pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind docs -Scope verification -Message "検証レポート"
pwsh -NoProfile -File scripts/devflow-state.ps1 run stop
```

phase が `done` になる。ユーザーに最終レポートの要点 (漏れ・blocked・人が確認する項目) を伝えて終える。

## 完了条件

- [ ] `devflow-trace.ps1 -Mode full` の漏れが、blocked 起因・manual のものだけ (または 0 件)。あるいは最大ラウンドに達した
- [ ] `docs/verification-report.md` に上の 5 項目がある
- [ ] phase が `done` になり、コミット済み

## コンテキストが圧縮されたとき

会話の記憶に頼らず、`.devflow/verification-log.md` と `devflow-state.ps1 show` (検証ラウンド数) から、どの手順まで終えたかを確かめて続ける。
