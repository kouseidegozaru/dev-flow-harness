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
3. **最初に機能領域の分割単位を決める** (例: 「タスク管理」「認証」)。1 領域 = `functional/<area>.md` の 1 ファイル。
   領域の区分 (ID の 2 段目, 例 `TODO`) もここで決める
4. 機能領域ごとに、ユースケース / ユーザーストーリーを洗い出し、各ストーリーの受け入れ基準を詰める
   - 受け入れ基準は **テストケースに直接変換できる具体性** で Given/When/Then で書く。1 組 = 1 ID (`REQ-<区分>-<連番>`)
   - 正常系だけでなく、境界値・0 件・上限超過・不正入力・権限なし・同時操作・失敗時の振る舞いを必ず聞く
   - 各 ID に検証方法 (`test` / `review` / `manual`) を付ける。`test` にできないか先に検討する
5. 非機能要件を詰める。項目ごとに 1 ID (`NFR-<区分>-<連番>`) と、測定可能な基準値・測定条件を決める
   - 性能 (応答時間、件数、同時利用)、セキュリティ (認証、権限、秘匿情報、入力検証)、可用性 (稼働時間、バックアップ、障害時)、
     対応環境 (OS、ブラウザ、端末、画面サイズ、言語)、運用・保守 (ログ、監視、更新手順)
6. データ要件 (扱うデータ、件数見込み、保持期間、整合性、移行) と外部連携 (相手、方向、形式、頻度、失敗時) を詰める。
   検証可能な要件は `REQ-DATA-*`、`REQ-EXT-*` として ID を振る
7. 技術スタックを選定する。言語・ランタイム・フレームワーク・DB・テストフレームワーク・ビルド/実行環境について、
   候補・選定結果・理由を記録する。**テストフレームワークは JUnit XML または TRX を出力できるものを選ぶ** (trace が結果を読むため)
8. 5 問ごとに「決定済み / 未決定」の一覧を提示する
9. 成果物を書き、次を実行して exit 0 にする (警告は基本設計以降で解消するので可):

   ```bash
   pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode docs -UpdateIndexes
   ```

10. `index.md` と各ファイルの要約 (ID 件数、主な決定) を提示し、明示的な承認を得る

## 完了条件

- [ ] `.devflow/decisions/requirements.md` に未決定ノードがない
- [ ] vision の主要機能 (必須) がすべて、いずれかの機能領域の要件として受け入れ基準を持つ
- [ ] すべての受け入れ基準が Given/When/Then で書かれ、1 組 1 ID、検証方法付き
- [ ] 曖昧語 (「適切に」「速く」「など」「等」) が受け入れ基準・非機能要件に残っていない
- [ ] 非機能要件が数値基準と測定条件を持つ
- [ ] 技術スタックが理由付きで決まり、テスト結果を JUnit XML / TRX で出せる
- [ ] `devflow-trace.ps1 -Mode docs -UpdateIndexes` が exit 0
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
