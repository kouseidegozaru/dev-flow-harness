# トレーサビリティ規約 (ID・検証方法・テストへの埋め込み)

設計で決めたことが必ず実装されるよう、すべての検証可能な決定事項に ID を振り、
`scripts/devflow-trace.ps1` で機械的に網羅性を検証する。**エージェントの記憶や注意力に頼らない。**

## 1. ID の書式

`<接頭辞>-<区分>-<連番>` のように、接頭辞のあとを `-` 区切りの英数字で続ける。正規表現:
`(接頭辞)-[A-Za-z0-9]+(-[A-Za-z0-9]+)*`。接頭辞は `.devflow/config.json` の `idPrefixes` で変更できる。

| 接頭辞 | 層 | 対象 | 例 |
|--------|----|------|----|
| REQ | 要件 | 機能要件の受け入れ基準 (Given/When/Then 1つにつき1 ID)。データ要件・外部連携の要件も区分を変えて REQ で振る | REQ-TODO-001, REQ-DATA-003 |
| NFR | 要件 | 非機能要件の各項目 | NFR-PERF-001, NFR-SEC-002 |
| ARC | 基本設計 | システム構成上の決定 (レイヤ構成、プロセス構成、配置) | ARC-001 |
| SCR | 基本設計 | 画面、および画面の表示要素 (E)・状態 (S)・操作 (A) | SCR-010, SCR-010-E01, SCR-010-S02, SCR-010-A01 |
| TRN | 基本設計 | 画面遷移 | TRN-003 |
| API | 基本設計 | 外部に公開するインターフェースの各エンドポイント (HTTP API、CLI コマンド、公開ライブラリ関数など) | API-TASK-002 |
| DM | 基本設計 | データモデルのエンティティ・関連 | DM-TASK, DM-TASK-R01 |
| EXT | 基本設計 | 外部システムとのインターフェース | EXT-001 |
| ERR | 基本設計 | エラー方針の各ルール | ERR-004 |
| MOD | 詳細設計 | モジュール | MOD-store |
| IF | 詳細設計 | インターフェース (関数・メソッド・クラスの公開メンバ) | IF-store-003 |
| VAL | 詳細設計 | バリデーションルール | VAL-TASK-002 |
| EC | 詳細設計 | エラーコード | EC-E1001 |
| DBC | 詳細設計 | DB の制約 (NOT NULL、UNIQUE、FK、CHECK、既定値など) | DBC-TASK-03 |
| BR | 詳細設計 | 業務ルール・計算ロジック | BR-DUE-001 |
| TASK | タスク | 実装タスク。検証フェーズで追加したタスクは `TASK-V<ラウンド>-<連番>` | TASK-007, TASK-V1-02 |

- ID は一度振ったら変えない。削除する場合は行を消し、参照も消す (未定義参照は trace が検出する)
- 範囲をまとめて指す場合は `SCR-010-*` のように `-*` を付けて書ける (参照チェックの対象外になる。多用しない)
- 層はファイルの置き場所で決まる: `docs/02-requirements/` = 要件、`docs/03-basic-design/` = 基本設計、
  `docs/04-detailed-design/` (tasks/ を除く) = 詳細設計

## 2. ID の定義の書き方 (機械が読む形式)

ID は **見出し行に `ID` と `検証` の列を持つ Markdown の表** の1行として定義する。
`上流` 列には、この ID が実現する上位の ID をカンマ区切りで書く。その他の列は自由 (最初の自由列が要約として index に載る)。

```markdown
| ID | 内容 | 検証 | 上流 |
|----|------|------|------|
| SCR-010-S02 | タスクが0件のとき「タスクはありません」と表示する (空状態) | test | REQ-TODO-004 |
| SCR-010-E05 | 期限切れのタスクを赤字で表示する | review | REQ-TODO-009 |
```

- ID 列の値は ID だけにする (装飾の `` ` `` や `**` は無視される)
- 1 つの ID は 1 か所でだけ定義する。重複は trace がエラーにする
- 要件 ID には `上流` は不要。基本設計 ID は要件 ID を、詳細設計 ID は基本設計 ID (または要件 ID) を 1 つ以上書く
- 表以外の本文や対応表での言及は「参照」として扱われ、存在しない ID ならエラーになる
- `ids.md` (ID 一覧) は trace が生成するので手で編集しない

## 3. 検証方法

| 値 | 意味 | 使う場面 |
|----|------|----------|
| `test` | 自動テストで検証する (**原則こちら**) | 入力と期待結果を書けるものすべて |
| `review` | 実装時に `tdd-implementer` が完了条件として自分のコードを読んで確認し、`.devflow/review-log.md` に記録する。最終レポートで記録とともに人が確認する項目として列挙される | 自動テストが困難なもの (見た目、配色、レイアウト、文言の体裁など) |
| `manual` | 人が確認する。最終レポートに「手動確認が必要な項目」として必ず列挙される | 本番環境での性能、実機でしか分からない操作感など |

`review` / `manual` を選ぶ前に、テスト可能な形に具体化できないかを必ず検討する。
例:「高速に表示する」(manual) → 「1,000 件のとき一覧表示が 200ms 以内」(test)。
`review` / `manual` にした場合は、その理由を内容欄に一言書く。

## 4. 粒度 (検証可能な最小単位まで振る)

- 要件: 受け入れ基準 1 つ (Given/When/Then 1 組) につき 1 ID。非機能要件は項目ごとに 1 ID
- 基本設計: 画面の各表示要素・各状態 (通常/空/エラー/ローディング)・各操作、各画面遷移、API の各エンドポイント、エラー方針の各ルール
- 詳細設計: 各インターフェース (関数・メソッド)、各バリデーションルール、各エラーコード、各 DB 制約、各業務ルール・計算ロジック

「1 つの ID に 2 つ以上の検証観点が入っていないか」を常に確認する。「〜し、かつ〜する」は 2 つに分ける。

## 5. タスクへの割り当て

- タスクファイル (`docs/04-detailed-design/tasks/<TASK-ID>.md`) の先頭の表の `担当ID` 行に、担当する ID をカンマ区切りで書く
- `test` / `review` の ID は、要件・基本設計・詳細設計のどの層でも、1 つ以上のタスクに割り当てる
- `test` の ID は、担当タスクの「テストケース」節に、その ID を検証するテストケースが 1 つ以上なければならない

## 6. テストへの ID の埋め込み

**テスト名 (テストランナーが結果ファイルに出力する名前) に、検証する ID を `[ID]` の形で含める。**
結果ファイル (JUnit XML または TRX) のテスト名から ID を抽出して成否を判定するため、コメントやタグだけでは不可。

```text
[REQ-TODO-001][IF-store-002] 空のストアに追加すると件数が1になる
```

言語ごとの書き方は `docs/04-detailed-design/conventions.md` で決める。例:
xUnit は `[Fact(DisplayName = "[REQ-TODO-001] ...")]`、Jest/Vitest は `test("[REQ-TODO-001] ...")`、
pytest は関数名に `-` を使えないので `@pytest.mark.parametrize(..., ids=["REQ-TODO-001"])` で結果の name に ID を含める。
書き方を決めたら、結果ファイルに ID が出ることを詳細設計フェーズで実際に確かめる。
1 つのテストが複数の ID を検証してよい。`test` 種別の ID でテストのないものがあってはならない。

## 7. devflow-trace の検査項目

`pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode <mode>` 。終了コード 0 = 漏れなし、1 = 漏れあり、2 = エラー。
結果は `.devflow/trace-result.json` (task モードは `.devflow/trace-<TASK-ID>.json`) と `docs/traceability.md` に出る。

| コード | 内容 | docs | design | full | task |
|--------|------|:----:|:------:|:----:|:----:|
| DUPLICATE-ID | 同じ ID が複数か所で定義されている | ● | ● | ● | |
| INVALID-VERIFY | 検証方法が test/review/manual でない | ● | ● | ● | |
| UNKNOWN-REF | 存在しない ID への参照 (ドキュメント・テストコード・テスト名・デザインの data-id) | ● | ● | ● | ● |
| NO-UPSTREAM | 基本設計・詳細設計の ID に上流 ID がない | ● | ● | ● | |
| REQ-NOT-COVERED | 要件 ID がどの設計 ID からも参照されていない | 警告 (基本設計がまだなければ件数だけ) | ● | ● | |
| NOT-ASSIGNED | test/review の ID がどのタスクにも割り当てられていない | 件数だけ | ● | ● | |
| TASK-* / UNKNOWN-DEP / DEP-CYCLE | タスクファイルと index の不整合、依存の誤り・循環、テストケース不足 | 警告 | ● | ● | ● |
| TASK-NOT-DONE | 完了していないタスク (blocked も漏れ扱い) | | | ● | |
| NO-TEST / TEST-NOT-PASSING | test の ID を名前に含むテストがない / 成功していない | | | ● | ● (担当分) |
| TESTS-FAILING | テストコマンドが失敗した | | | ● | ● |
| STUB-LEFT | TODO・FIXME・スタブ・未実装例外が残っている | | | ● (source.files) | ● (タスクのファイル) |
| DESIGN-NO-STATE | 画面の状態 ID (`SCR-*-S*`) に対応するデザイン (`data-state-id`) がない (デザインがあるときだけ) | ● | ● | ● | |
| DESIGN-NO-ELEMENT | 画面の要素・操作 ID (`SCR-*-E*` / `SCR-*-A*`) に対応するデザインの要素 (`data-id`) がない | 警告 | 警告 | 警告 | |
| REVIEW-NOT-RECORDED | review の ID の自己確認が `.devflow/review-log.md` に記録されていない | | | ● (done のタスク) | ● (担当分) |
| FILE-MISSING | タスクの「作成・変更するファイル」が存在しない (括弧の外でバッククォートで囲んだ、拡張子のあるパスだけを数える。シグネチャ・ディレクトリ・コード中の名前・括弧の中の説明は数えない。ディレクトリのない名前は既知の拡張子のときだけ) | | | | ● |
| TASK-DEP-MISSING | 他のタスクが「新規」で作るファイルを変更・利用するのに、そのタスクが依存 (祖先) にない (作るのが後続のタスクなら、ファイルの一覧から外すよう案内する) | | ● (done のタスクは警告) | | |
| TASK-DEP-SUSPECT | 「参照すべき設計」で指した ID を他のタスクだけが担当していて、そのタスクが依存 (祖先) にない (担当が後続のタスクだけなら数えない) | | 警告 | | |
| TASK-REF-NOT-FOUND | 「参照すべき設計」の参照先 (ファイル・「」の見出し・ID の定義行) が見つからない | | ● (done のタスクは警告) | | |
| TASK-CONTEXT-LARGE | タスクの読み物 (`devflow-state.ps1 task-context` の出力) が `taskContextBudgetKB` を超える | | ● (done のタスクは警告) | | |

| LEDGER-INVALID / LEDGER-BASIS | 決定台帳の行の誤り (区分・状態・照合・DEC の重複) / 根拠の ID・逐語引用が実在しない | ● | ● | ● (BASIS は警告) | |
| DEC-UNKNOWN | 台帳にない DEC の引用 | ● | ● | ● | |
| DEC-UNCITED | 台帳の確定・仮の行の照合に当たるのに、その DEC を書いていない行 (docs/ の全行。`DEC 対象外: DEC-…` の行は除く) | ● | ● | 警告 | |
| DEC-STALE | 覆した決定の旧照合に当たる行が残っている (docs/ の全行: 表の行・地の文・タスクファイル) | ● | ● | ● | |
| DEC-NOT-IN-EXAMPLE | DEC を引用する test の要件の Then に、その DEC の印 (`` `値` [DEC-…] ``) がない | ● | ● | ● | |
| EXAMPLE-CHANGED | 承認時に凍結した受け入れ例 (`.devflow/examples.lock.json`) と今の要件の例が違う (lock がなければ検査しない) | 警告 | ● | ● | |
| EXAMPLE-UNLOCKED | 承認後に足された受け入れ例 (amend の後は `relock`) | 警告 | 警告 | 警告 | |
| AMEND-NO-BASIC | amend (台帳の論点が「変更:」) で足した要件が、基本設計のどの ID からも参照されていない | ● | ● | ● | |
| REQ-NO-ACCEPTANCE | 受け入れ例のある test の要件に `[AT][REQ-…]` の受け入れテストがない (lock がなければ警告) | | | ● | |
| EXAMPLE-NOT-IN-AT / EXAMPLE-ORDER | 受け入れ例の値が、受け入れテストのアサーションの期待値側にない / 並び順を確かめていない | | | 警告 (最終レポートの人が確認する項目) | |

`-UpdateIndexes` を付けると、各 `index.md` と同じディレクトリに ID 一覧 `ids.md` を生成し、index.md に ids.md へのリンクを置く。
`-NoRun` を付けるとテストを実行せず、既存の結果ファイルで判定する。

## 8. 設定 (.devflow/config.json)

詳細設計フェーズで、技術スタックに合わせて次を設定する (既定値は `scripts/devflow-lib.psm1` の `Get-DefaultConfig`)。

```json
{
  "test": {
    "command": "dotnet test --logger trx",
    "resultGlobs": ["**/TestResults/*.trx"],
    "files": ["tests/**"]
  },
  "source": { "files": ["src/**"] }
}
```

- `test.command`: 全テストを実行し、結果ファイルを出力するコマンド (PowerShell で実行される)。失敗時に非 0 で終わること
- `test.timeoutSeconds`: テスト実行の上限秒数 (既定 900、0 で無制限)。超えたらプロセスごと止めて失敗扱いにする。ウォッチモードのコマンドにしないこと
- `test.resultGlobs`: 結果ファイル (JUnit XML または TRX) の場所。trace は実行前にこれらを削除する
- `test.files`: テストコードの場所 (未定義 ID の検出に使う)
- `source.files`: 本番コードの場所 (スタブ残りの検出に使う)
- `taskContextBudgetKB`: 1 タスクの読み物 (タスクファイル + 参照すべき設計で指した節・ID の定義行) の上限 KB (既定 40)。
  実装担当がタスクごとに読む量を抑えるため、詳細設計の網羅性ゲートで超えたタスクを TASK-CONTEXT-LARGE にする

## 9. 決定台帳と受け入れ例の照合

ID の網羅 (上の検査) とは別に、「承認した値」がそのまま実装まで届いているかを機械で追う。

- **決定台帳** (`.devflow/decisions/ledger.md`): `| DEC | 論点 | 決定 | 照合 | 区分 | 根拠 | 状態 | 版 | 旧照合 |`。
  区分は `確定` (ユーザーが答えた) / `仮` (聞かずに決めた) / `処置-C` (実装担当が設計にない細部を決めた) / `処置-B` (外部環境がなくテストダブルで進めた) /
  `要回答` (お金・権限・個人情報などに当たり、決めずに止めた)。行は `devflow-state.ps1 ledger add` で足し、`override` / `amend` で変える
- **照合**: その値が docs/ に現れたときに当たる正規表現。DEC-UNCITED・DEC-STALE は docs/ の **全行** (表の行・地の文・タスクファイルのテストケース) を見る
  (表の行だけを見ると、地の文や todo のタスクに残った旧い値を見逃すため)
- **受け入れ例**: 要件の Then の `` `値` `` の印 (interview-rules.md §10)。`complete-phase requirements` / `basic-design` と `relock` が `.devflow/examples.lock.json` に凍結する
- **受け入れテストとの照合** (devflow-lib の `Test-AcceptanceExamples`): `acceptance.files` の中で、`[AT]` と `[REQ-…]` を含む行から次の `[AT]` の行までをそのテストとし、
  アサーションの **期待値側の引数** と、そこから名前で参照される同じファイルの定数だけを取り出す。テスト名・コメント・Given の行は見ない

  | 書き方 | 期待値側として見るところ |
  |--------|--------------------------|
  | `expect(x)[.not].toBe/toEqual/toStrictEqual/toContain/toMatch/…(期待値)` (Jest・Vitest) | matcher の引数 (`.not` なら否定) |
  | `assert.<fn>(実際, 期待値[, メッセージ])` (node:assert・chai) | 第 2 引数 (引数が 1 つならそれ)。`notStrictEqual`・`doesNotMatch` などは否定 |
  | `Assert.<Fn>(期待値, 実際)` (xUnit・MSTest)、`Assert.That(実際, 制約)` (NUnit) | 第 1 引数 (That は第 2)。`NotEqual`・`DoesNotContain`・`False` は否定 |
  | `self.assert<Fn>(a, b)`・`assert<Fn>(a, b)` (unittest・JUnit) | 第 1・第 2 引数。`assertNot…`・`assertFalse` は否定 |
  | `assert 実際 == 期待値` / `assert 値 in 実際` (pytest) | `==` の右辺 / `in` の左辺。`!=`・`not in` は否定 |

  否定印の値は否定のアサーションに、他は肯定のアサーションにあることを求める。順序の宣言は、1 つのアサーションの中の並び、または各値の最後の出現の順で確かめる。
  ここにない書き方 (Go の `if got != want`、別ファイルの fixture、文字列のエスケープ表記) は外れとして警告に出る (止めない。人が確かめる)
