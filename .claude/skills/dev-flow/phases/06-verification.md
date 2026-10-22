# フェーズ 6: 検証 (完全自動)

実装フェーズに続けて、同じオーケストレーターのセッションで自動で実行する。ユーザーに聞くのは、漏れの処理が終わった後の **最後の 1 回** (手順 4) だけ。
終わったら、続けて同じセッションでデプロイフェーズ ([07-deployment.md](07-deployment.md)) を実行する。
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
exit 4 (最大ラウンド数 `maxVerificationRounds` を超えた) なら、手順 2〜3 を飛ばして「4. 最後の 1 回」へ進み、
残りの漏れを「未解決」として報告する。

### 2. 機械チェック

```bash
pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode full
```

全テストの実行、TODO/スタブの検索、ID の網羅性、決定台帳の照合 (DEC-STALE など)、受け入れ例と受け入れテストの照合をまとめて検査し、`docs/traceability.md` と `.devflow/trace-result.json` を書き出す。
標準出力に、漏れの種類ごとに `<ID> <内容> (<定義ファイル>:<行>) 担当: <タスク>` が並ぶ。

### 3. 漏れの処理

次は **追加タスクにしない** (最終レポートに載せるだけ):

- blocked のタスクに起因するもの (その ID を担当するタスクがすべて blocked か、blocked のタスクに (間接に) 依存して todo のまま。
  TASK-NOT-DONE・REQ-NO-ACCEPTANCE・NO-TEST でも、原因が blocked のタスクの待ちなら同じ。作っても同じ依存で止まるだけなので、最後の 1 回の「止まったタスク」で聞く)
- `manual` の ID
- 警告の EXAMPLE-NOT-IN-AT / EXAMPLE-ORDER (受け入れ例の値が受け入れテストの期待値側にない・順序を確かめていない)。
  照合器の書き方の差で正しいテストを止めないため、最後の 1 回と最終レポートの「人が確認する項目」に載せる

次は **自分で直す** (タスクにしない。文書だけの不整合なので): DEC-STALE (覆した決定の旧い値が文書に残っている) と DEC-UNKNOWN は、
出力の行を新しい値・正しい DEC に直し、`devflow-commit.ps1 -Kind docs -Scope verification -Message '台帳の照合の修正'` でコミットして手順 2 をやり直す。
EXAMPLE-CHANGED は、覆し (`override` / `amend`) の後の `relock` 忘れなら `devflow-state.ps1 relock`、そうでなければ要件の例を lock の値に戻す。
REQ-NO-ACCEPTANCE (受け入れ例のある要件に `[AT][REQ-…]` のテストがない) は、下の追加タスクにする (担当ID はその要件、作るのは受け入れテスト)

それ以外の漏れがあれば:

1. 漏れを実装単位 (目安: 元の担当タスクごと) にまとめ、追加タスク `TASK-V<ラウンド>-<連番>` を `docs/04-detailed-design/tasks/` に作る
   (`templates/task.md` の形式)。
   - 担当ID: 漏れた ID
   - 参照すべき設計: 漏れた ID の定義行を含む節と、元の担当タスクのファイル (テストケースや作るファイルが書かれている)
   - テストケース: 漏れた ID ごとに 1 行書き、元の担当タスクのテストケースを指す (例: `- [REQ-TODO-004] TASK-015 のテストケース #1〜4`)。
     同じ内容は書き写さないが、行には必ず漏れた ID を書く (trace がテストケース節の ID を数えるため。ないと TASK-NO-TESTCASE になる)
   - 依存: 元の担当タスク (done 済みなので、すぐ実行できる)。タスクファイルと `tasks/index.md` の依存欄をそろえる
     (空にすると、元の担当タスクが作ったファイルを変更するときに trace が TASK-DEP-MISSING にする。依存にすると、読み物に元の担当タスクの実装メモも入る)
   - 漏れが設計の不備 (設計どおりでは実装できない) に起因する場合は、タスクにせず未解決として記録する
2. `tasks/index.md` に状態 `todo` で追記し、`devflow-state.ps1 add-verification-task <TASK-ID>` で記録する
3. `devflow-trace.ps1 -Mode design` が exit 0 であることを確かめる (追加タスクの書式の確認)
4. `.devflow/verification-log.md` の「## ラウンド <r>」節に、見つけた漏れと追加タスクを追記する (最終レポートの材料)
5. `devflow-commit.ps1 -Kind docs -Scope verification -Message "検証ラウンド <r>: 追加タスク <n> 件"`
6. `devflow-state.ps1 set-phase implementation -KeepVerification` で実装フェーズに戻し (このラウンドを閉じる。`-KeepVerification` を付けないと検証の記録が初期化される)、[05-implementation.md](05-implementation.md) の手順 4 から続けて、
   実装担当に追加タスクを実装させる。実装フェーズが終わると再びこの検証フェーズに戻る

漏れが 0 件 (追加タスクにするものがない) なら次へ。

### 4. 最後の 1 回 (debrief)

全タスクと漏れの処理が終わったら、聞かずに決めたことと確認事項を、**1 回の AskUserQuestion** でまとめて聞く。

```bash
pwsh -NoProfile -File scripts/devflow-state.ps1 debrief
```

- exit 3 (回答済み): 聞き直さない。手順 5 へ
- 出力 (`.devflow/debrief.md` にも残る) の 4 つの節を、専門用語 (DEC・ID・trace) を使わずに言い換えて、1 回の AskUserQuestion にまとめる
  (各問に推奨と 1 行の理由。「すべて推奨どおり」で答えられるようにする。4 問を超える分は、同じメッセージの文章で一覧にして聞く):
  1. **要回答** (推奨つき): 1 件ずつ問にする。お金・外部への送信・個人情報に関わるものは、推奨があっても必ずここで聞く
  1b. **止まったタスク** (blocked と、それを待って進めなかったタスク): blocked.md の「必要な判断」を、何ができていないか (例:「CSV の書き出しとコマンドの入口がまだない」) と
     推奨の直し方で 1 問にする。答えが設計の値なら `override`、形なら `amend`、そのまま試し直すなら `task <ID> todo` で戻し、手順の反映に進む
  2. **覆せる一覧** (聞かずに決めたこと。影響の大きい順): 「このままでよいか / 変えたいものはどれか」を 1 問にする
  3. **繰延べ** (外部環境がなくテストダブルで進めたもの): 「このまま (本番前に人が用意する) / 今は作らない」を 1 問にする
  4. **人が確認する項目** (受け入れ例と受け入れテストの照合の警告): 見てほしい点として示す (答えは要らない)
- AskUserQuestion が使えない、またはユーザーが席を外していて答えが返らないときは、質問を文章で示し、`devflow-state.ps1 run stop` を実行してから応答を終える
  (答えが来たら `/dev-flow` で再開し、この手順の反映から続ける)
- 答えを反映する: 値を変えるものは `override <DEC> … -Answered`、形を変えるものは `amend` (SKILL.md の「6. 承認の後の気変わり」の手順 2。確認の 1 問はもう済んでいる)。
  そのままでよい `要回答` は `override <DEC> -Value '<推奨>' -Match '<照合>' -Answered` で確定にし、止めたタスクを `devflow-state.ps1 task <ID> todo` で戻す。
  そのままでよい繰延べ (B) は `devflow-state.ps1 ledger resolve <DEC> -Reason '<答え>'` で解決にする
- 答えと、反映した DEC・足したタスクを `.devflow/debrief.md` の「回答と反映」に書き、`devflow-state.ps1 debrief -Done` → `devflow-commit.ps1 -Kind docs -Scope verification -Message '最後の 1 回の反映'`
- 反映でタスクが増えた・todo に戻ったときは、`devflow-state.ps1 set-phase implementation -KeepVerification` で実装フェーズに戻し、
  [05-implementation.md](05-implementation.md) の手順 4 から続ける (該当タスクだけが回し直される。検証に戻っても、最後の 1 回は聞き直さない)

### 5. 最終レポート

`docs/verification-report.md` を `templates/verification-report.md` の形で書く。
冒頭の判定は、未解決の漏れがなければ `判定: 漏れなし`、あれば `判定: 未解決あり` と書く (デプロイフェーズの `devflow-deploy.ps1` がこの文字列を読み、
「漏れなし」でなければデプロイしない。blocked のタスクの有無は別に確かめる):

- 全 ID の網羅状況 (`docs/traceability.md` の集計を転記)
- blocked のまま残ったタスクとその理由 (対象は `impl-status` で今も blocked のタスクだけ。理由は `.devflow/blocked.md` のそのタスクの最後の記録から。「解除」の記録があるものは載せない)
- 人が確認する項目: `manual` 種別と `review` 種別の ID (`docs/traceability.md` の一覧から。review は `.devflow/review-log.md` の自己確認の記録を添える)
- 検証で見つかって修正した漏れの一覧 (`.devflow/verification-log.md` から)
- 未解決の漏れ (最大ラウンド超過、設計の不備) があればその一覧
- 実装中に足した依存 (`.devflow/dep-changes.md` があれば、その見出しの一覧。設計の依存の漏れとして人が見る)
- 最後の 1 回の内容と答え (`.devflow/debrief.md`)。台帳 (`.devflow/decisions/ledger.md`) の件数 (確定 / 仮 / 処置-C / 処置-B / 要回答、open の件数)
- 人が確認する項目に、受け入れ例と受け入れテストの照合の警告 (`docs/traceability.md` の「受け入れ例と受け入れテストの照合」) を加える
- 実装担当が設計にない判断をしたもの (台帳の `処置-C` の行と、`.devflow/review-log.md` の `[判断]` の行)。モジュールごとにまとめ、
  利用者から見える振る舞いが変わるもの (表示・文言・エラー・お金・権限) を先に並べる。人が設計に取り込むか直すかを決める

そして:

```bash
pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase verification
pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind docs -Scope verification -Message "検証レポート"
```

phase が `deployment` になる。`run stop` はせず (オーケストレーターのまま)、ユーザーへの報告もまだしないで、
続けて [07-deployment.md](07-deployment.md) を読み、このセッションでデプロイフェーズを実行する (検証レポートの要点は、デプロイの結果と一緒に最後に伝える)。

## 完了条件

- [ ] `devflow-trace.ps1 -Mode full` の漏れが、blocked 起因・manual のものだけ (または 0 件)。あるいは最大ラウンドに達した
- [ ] 最後の 1 回を聞き、答えを反映した (`devflow-state.ps1 debrief` が exit 3)
- [ ] `docs/verification-report.md` に上の項目がすべてある
- [ ] phase が `deployment` になり、コミット済み

## コンテキストが圧縮されたとき

会話の記憶に頼らず、`.devflow/verification-log.md`、`.devflow/debrief.md` (最後の 1 回の状態) と `devflow-state.ps1 show` (検証ラウンド数) から、
どの手順まで終えたかを確かめて続ける。
