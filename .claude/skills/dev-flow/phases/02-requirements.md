# フェーズ 2: 要件定義

## 入力

- `docs/01-vision.md` **のみ**。前フェーズの会話内容は参照しない

## 最初に読むもの

- [../references/interview-rules.md](../references/interview-rules.md)
- [../references/doc-structure.md](../references/doc-structure.md)
- [../references/traceability.md](../references/traceability.md)
- テンプレート (`../references/templates/`): `requirements-index.md`、`functional-area.md`、`non-functional.md`、`data.md`、`external-integrations.md`、`tech-stack.md`、`decisions.md`

## 進め方

1. `pwsh -NoProfile -File scripts/devflow-state.ps1 start-phase`
2. `.devflow/decisions/requirements.md` があれば読んで再開する。なければ作り、vision の主要機能ごとに「機能領域」ノード、
   および非機能・データ・外部連携・技術スタックのノードを登録する
3. **今回の開発範囲を決める** — vision に段階リリースがあるなら、このフローで要件・設計・実装まで進める範囲を最初の 1 問で確かめる。
   推奨は「最初の段階だけ」(残りの段階は、この範囲が完成してから `/dev-flow redo requirements` で足す)。
   全段階を一度に進めると、要件が数百件・タスクが百件を超え、承認で全部を確かめられず、実装も長くなって途中で止まりやすい。
   ユーザーが全段階を選んだらそれに従う。範囲外の段階の機能は、index.md の「段階リリース」に機能名だけを残す
4. **機能領域の分割単位を決める** (例: 「タスク管理」「認証」)。1 領域 = `functional/<area>.md` の 1 ファイル。
   領域の区分 (ID の 2 段目, 例 `TODO`) もここで決める
5. 機能領域ごとに、ユースケース / ユーザーストーリーを洗い出し、各ストーリーの受け入れ基準を詰める
   - 受け入れ基準は **テストケースに直接変換できる具体性** で Given/When/Then で書く。1 組 = 1 ID (`REQ-<区分>-<連番>`)
   - 正常系だけでなく、境界値・0 件・上限超過・不正入力・権限なし・同時操作・失敗時の振る舞いを必ず聞く
   - 各 ID に検証方法 (`test` / `review` / `manual`) を付ける。`test` にできないか先に検討する
6. 非機能要件を詰める。項目ごとに 1 ID (`NFR-<区分>-<連番>`) と、測定可能な基準値・測定条件を決める
   - 性能 (応答時間、件数、同時利用)、セキュリティ (認証、権限、秘匿情報、入力検証)、可用性 (稼働時間、バックアップ、障害時)、
     対応環境 (OS、ブラウザ、端末、画面サイズ、言語)、運用・保守 (ログ、監視、更新手順、公開先・配布方法)
7. データ要件 (扱うデータ、件数見込み、保持期間、整合性、移行) と外部連携 (相手、方向、形式、頻度、失敗時) を詰める。
   検証可能な要件は `REQ-DATA-*`、`REQ-EXT-*` として ID を振る
8. 横断的な観点を詰める — interview-rules.md §9 のチェックリストの各観点を決定ツリーに登録し、決定・スコープ外・該当なしのどれかにする
   (機能ごとの質問では聞かれないまま抜けるため)
9. 技術スタックを選定する。言語・ランタイム・フレームワーク・DB・テストフレームワーク・ビルド/実行環境について、
   候補・選定結果・理由を記録する。**テストフレームワークは JUnit XML または TRX を出力できるものを選ぶ** (trace が結果を読むため)
10. 5 問ごとに「決定済み / 未決定」の一覧を提示する
11. 成果物を書き、次を実行して exit 0 にする。ユーザーがはっきり選んだ決定は、要件の備考に `決定: Q<番号> (理由)` を書く
    (interview-rules.md「決定の理由を成果物に残す」):

    ```bash
    pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode docs -UpdateIndexes
    ```

12. **レビュー (1 回だけ)** — interview-rules.md §7 に従い、`spec-reviewer` に対象フェーズ `requirements` と
    `docs/02-requirements/` の成果物 (index.md、functional/*.md、non-functional.md、data.md、external-integrations.md、tech-stack.md) の
    パスを渡してレビューさせる。指摘を 1 つずつユーザーに質問して反映し、trace を exit 0 に戻す。**反映後の再レビューはしない**
13. `index.md` と各ファイルの要約 (ID 件数、主な決定、レビュー指摘と対応) を提示し、明示的な承認を得る

## 完了条件

- [ ] `.devflow/decisions/requirements.md` に未決定ノードがない
- [ ] 今回の開発範囲 (段階) が決まっていて、範囲内の vision の主要機能 (必須) がすべて、いずれかの機能領域の要件として受け入れ基準を持つ
- [ ] すべての受け入れ基準が Given/When/Then で書かれ、1 組 1 ID、検証方法付き
- [ ] 曖昧語 (「適切に」「速く」「など」「等」) が受け入れ基準・非機能要件に残っていない
- [ ] 非機能要件が数値基準と測定条件を持つ
- [ ] interview-rules.md §9 の横断的な観点が、決定・スコープ外・該当なしのどれかになっている
- [ ] 技術スタックが理由付きで決まり、テスト結果を JUnit XML / TRX で出せる
- [ ] `devflow-trace.ps1 -Mode docs -UpdateIndexes` が exit 0
- [ ] spec-reviewer のレビューを 1 回受け、指摘をすべてユーザーに確認して反映した (決定ツリーの「レビュー状況」が反映済み)
- [ ] ユーザーが明示的に承認した

## 終了

SKILL.md の「フェーズの終え方」に従う。phase 名は `requirements`、コミットは `docs(requirements): ...`。

## 出力テンプレート

| 出力 | テンプレート |
|------|--------------|
| `docs/02-requirements/index.md` | `templates/requirements-index.md` |
| `docs/02-requirements/functional/<area>.md` | `templates/functional-area.md` |
| `docs/02-requirements/non-functional.md` | `templates/non-functional.md` |
| `docs/02-requirements/data.md` | `templates/data.md` |
| `docs/02-requirements/external-integrations.md` | `templates/external-integrations.md` |
| `docs/02-requirements/tech-stack.md` | `templates/tech-stack.md` |
