# フェーズ 4: 詳細設計 (ほぼ自律)

このフェーズの成果物だけで、実装フェーズがユーザーへの質問なしに完了できる状態を作る。
**ユーザーとの対話は「上流の決定が必要な指摘」をまとめて確認する 1 回だけ** (手順 9)。それ以外は自分で決める。

## 入力

- `docs/01-vision.md`、`docs/02-requirements/`、`docs/03-basic-design/` — いずれも `index.md` から必要なファイルだけを読む

## 最初に読むもの

- [../references/doc-structure.md](../references/doc-structure.md)
- [../references/traceability.md](../references/traceability.md)
- テンプレート (`../references/templates/`): `detailed-design-index.md`、`conventions.md`、`module.md`、`db-schema.md`、
  `db-migrations.md`、`api-resource-detailed.md`、`tasks-index.md`、`task.md`、`config.json`

## 進め方

1. `pwsh -NoProfile -File scripts/devflow-state.ps1 start-phase`
2. **規約を決める** (`conventions.md`): コーディング規約、命名、ディレクトリ構成、テスト方針 (単体/結合の範囲、テストダブルの方針、
   テストデータ)、**テストへの ID 埋め込み形式** (traceability.md §6 に従い、テスト名に `[ID]` を含める具体的な書き方)、
   コミット規約 (phases/05 の TDD コミット)、ビルド・テスト・実行のコマンド
3. **`.devflow/config.json` を書く** (`templates/config.json`): `test.command`、`test.resultGlobs`、`test.files`、`source.files`。
   プロジェクトの雛形 (ソリューション/パッケージ定義、テストプロジェクト、1 本のサンプルテスト) を作り、
   サンプルテストの名前に ID が入った状態で `test.command` を実行し、結果ファイルに ID 付きのテスト名が出ることを確かめる。
   確かめたらサンプルテストは消す (雛形の作成はタスク TASK-001 としてもよいが、その場合もこの確認は今行う)
4. **モジュール構成** (`modules/<module>.md`): 責務、依存方向、公開インターフェース。各インターフェースに ID (`IF-<module>-<連番>`) を振り、
   シグネチャ (引数・戻り値・例外の型)、事前条件、事後条件、処理手順、エラー時の振る舞いを書く
5. **データ** (`db/schema.md`、`db/migrations.md`): テーブル・列・型・制約 (各制約に `DBC-*`)、インデックス、初期データ、マイグレーション手順。
   ファイル保存などの場合も、保存形式と制約をここに書く
6. **API の入出力詳細** (`api/<resource>.md`): 入力スキーマ、各バリデーションルール (`VAL-*`)、出力スキーマ、各エラーコード (`EC-*`)、
   業務ルール・計算ロジック (`BR-*`)。基本設計の API ID を上流に書く
7. **タスク分解** (`tasks/index.md`、`tasks/<TASK-ID>.md`):
   - 粒度: 1 タスク = TDD の 1〜数サイクルで完了し、単独でコミット可能
   - 依存順に並べる。先頭は雛形・共通基盤。依存は `tasks/index.md` の `依存` 列とタスクファイルの `依存` 行の両方に同じものを書く
   - 各タスクファイルの必須項目は `templates/task.md` のとおり。特に:
     - 参照すべき設計ファイル: **実装者はここに挙げたファイルと conventions.md だけで実装できること**
     - テストケース一覧: 担当する `test` の ID ごとに 1 つ以上。入力と期待結果を具体的な値で書く
   - 状態はすべて `todo` で作る
8. **網羅性ゲート** — 次を exit 0 になるまで繰り返す:

   ```bash
   pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode design -UpdateIndexes
   ```

   未割り当て (NOT-ASSIGNED)、要件の未被覆 (REQ-NOT-COVERED)、テストケース不足 (TASK-NO-TESTCASE) などを、タスクや設計の追加・修正で解消する。
   (設計全体を読ませる ID 抜けの確認は行わない。トークン消費が大きいため。ID 抜けはタスクごとのレビューで見つける)
9. **曖昧さゼロゲート** — 全タスクについて `design-reviewer` サブエージェントを起動する (互いに独立なので並列に起動してよい)。
   各起動に渡すのは「タスクファイル + そこに列挙された参照ファイル + conventions.md」の **パスだけ** で、次のように依頼する:

   > 次のファイルだけを読み、このタスクを実装できるかをレビューせよ: <パスの列挙>。
   > この情報だけで実装できるか。迷う点・判断が必要な点・参照漏れをすべて列挙せよ。

   - 指摘が出たら設計ファイルを修正し、修正したタスクを再レビューする。再レビューの依頼には、前回の指摘と直した内容を添える
     (「前回の指摘: … / 修正: … 。解消したかと、新たに実装者が止まる点があるかだけを確認せよ」)
   - **レビューは 1 タスク 2 回まで。** 2 回目でも指摘が残ったら、自分で決められるものは決めて設計に書き、
     上流の決定が必要なものはユーザーへの確認に回す。3 回目のレビューはしない
   - レビュー結果はタスクごとに `.devflow/decisions/detailed-design.md` の「レビュー状況」表 (タスク ID / 回数 / 結果 / 最終レビュー後に変更した参照ファイル) に
     その都度記録する。中断から再開したときは、この表で指摘ゼロになったタスクを飛ばす。
     ただし、指摘ゼロ後にそのタスクの参照ファイルを大きく変更した場合 (インターフェース・テストケースの変更) は再レビューする (回数の上限は同じ)
   - レビューは並列に 3〜5 件ずつ起動する (一度に全タスクを起動すると利用上限に達しやすい)
   - 自分で決められる指摘 (実装上の詳細、上流の意図から一意に決まるもの) は自分で決めて設計に書く
   - 上流 (要件・基本設計) の決定が必要な指摘だけを溜めておき、最後に **まとめて** ユーザーに確認する。
     1 件ずつ推奨回答と理由を添える。回答を上流ドキュメントと詳細設計に反映し、影響するタスクを再レビューする
10. 最終確認として `devflow-trace.ps1 -Mode design -UpdateIndexes` が exit 0 であることを確かめる

## 完了条件

- [ ] `conventions.md` にテストへの ID 埋め込み形式があり、`.devflow/config.json` の `test.command` で ID 付きのテスト結果が出ることを確かめた
- [ ] 全インターフェース・バリデーション・エラーコード・DB 制約・業務ルールに ID、検証方法、上流 ID がある
- [ ] 全タスクファイルに必須項目がすべてあり、テストケースが担当 ID ごとに具体的な入力と期待結果を持つ
- [ ] `devflow-trace.ps1 -Mode design -UpdateIndexes` が exit 0
- [ ] 全タスクが design-reviewer のレビューで指摘ゼロ、または 2 回のレビュー後に残りの指摘を設計に反映済み・ユーザー確認に回し済み
- [ ] 上流の決定が必要な指摘はユーザーに確認済みで、回答が反映されている

(このフェーズは原則ユーザーの承認を求めない。完了条件はすべて機械とレビューで確認する)

## 終了

SKILL.md の「フェーズの終え方」に従う。phase 名は `detailed-design`、コミットは `docs(detailed-design): ...`。
案内文は次のとおり (次フェーズは自動ループで実行するため):

> 詳細設計が完了し、成果物をコミットしました (タスク N 件)。
> 実装と検証は自動で進みます。別のターミナルでプロジェクト直下から `scripts/devflow-implement.sh`
> (または `pwsh -NoProfile -File scripts/devflow-implement.ps1`) を実行してください。
> このセッションは `/clear` してかまいません。

## 出力テンプレート

| 出力 | テンプレート |
|------|--------------|
| `docs/04-detailed-design/index.md` | `templates/detailed-design-index.md` |
| `conventions.md` | `templates/conventions.md` |
| `modules/<module>.md` | `templates/module.md` |
| `db/schema.md`、`db/migrations.md` | `templates/db-schema.md`、`templates/db-migrations.md` |
| `api/<resource>.md` | `templates/api-resource-detailed.md` |
| `tasks/index.md` | `templates/tasks-index.md` |
| `tasks/<TASK-ID>.md` | `templates/task.md` |
| `.devflow/config.json` | `templates/config.json` |
