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
     - **設計ファイルに書いたことをタスクファイルに写さない** (シグネチャ、処理手順、文言、書式、エラー表、README の本文など)。
       タスクファイルに書くのは、目的・担当ID・参照すべき設計 (節)・作成・変更するファイル・テストケース・完了条件だけ
     - 参照すべき設計: ファイルと節の見出しで指す。**実装者はここに挙げた節と conventions.md だけで実装できること**
     - テストケース一覧: 担当する `test` の ID ごとに 1 つ以上。入力と期待結果を具体的な値で書く (設計の文言そのものなら参照でよい)
   - 新しく作るタスクの状態は `todo`。やり直し (`redo`) で既存のタスクがあるときは、状態を次のように決める
     (全部を todo に戻すと実装済みの分まで作り直しになり、全部を残すと変更が実装されないため):
     - タスクファイルの内容 (担当ID・作成・変更するファイル・テストケース・完了条件) を変えたタスクと、
       「参照すべき設計」の節の中身を変えたタスクは、`devflow-state.ps1 task <ID> todo` で todo に戻す
     - どちらも変えていない done のタスクは done のまま残す。blocked のタスクは、原因を設計で解消したときだけ todo に戻す
     - 不要になったタスクは、タスクファイルと index の行を消す (実装済みのコードは、置き換えるタスクの中で消す)
8. **網羅性ゲート** — 次を exit 0 になるまで繰り返す:

   ```bash
   pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode design -UpdateIndexes
   ```

   未割り当て (NOT-ASSIGNED)、要件の未被覆 (REQ-NOT-COVERED)、テストケース不足 (TASK-NO-TESTCASE) などを、タスクや設計の追加・修正で解消する。
   (設計全体を読ませる ID 抜けの確認は行わない。ID 抜けはタスクのレビューで見つける)
9. **レビュー (必要最低限。1 回だけ)** — タスクを、主に参照する設計ファイル (モジュールなど) ごとのまとまりに分け、
   **まとまりごとに 1 体** の `design-reviewer` を起動する (互いに独立なので並列でよい)。共通の設計を読むのはまとまりごとに 1 回で済む。
   渡すのは、そのまとまりのタスクファイルと conventions.md の **パスだけ**。依頼文:

   > 次のタスクファイルを、各タスクの「参照すべき設計」に挙げられた節と conventions.md だけを読んでレビューせよ: <タスクファイルの列挙>。
   > 実装者が作業を止める、または設計と違う実装をしてしまう点だけを挙げよ。

   - **レビューは 1 回だけ。再レビューはしない。** 指摘は自分で設計・タスクファイルに反映する
     (実装上の詳細、上流の意図から一意に決まるものは自分で決めて書く)
   - 上流 (要件・基本設計) の決定が必要な指摘だけを溜めておき、最後に **まとめて** ユーザーに確認する。
     1 件ずつ推奨回答と理由を添え、回答を上流ドキュメントと詳細設計に反映する (反映後の再レビューはしない)
   - レビューを終えたまとまりは `.devflow/decisions/detailed-design.md` の「レビュー状況」表 (まとまり / タスク ID / 指摘件数 / 反映済みか) に記録する。
     中断から再開したときは、記録済みのまとまりを飛ばす
10. 最終確認として `devflow-trace.ps1 -Mode design -UpdateIndexes` が exit 0 であることを確かめる

## 完了条件

- [ ] `conventions.md` にテストへの ID 埋め込み形式があり、`.devflow/config.json` の `test.command` で ID 付きのテスト結果が出ることを確かめた
- [ ] 全インターフェース・バリデーション・エラーコード・DB 制約・業務ルールに ID、検証方法、上流 ID がある
- [ ] 全タスクファイルに必須項目がすべてあり、テストケースが担当 ID ごとに具体的な入力と期待結果を持つ
- [ ] `devflow-trace.ps1 -Mode design -UpdateIndexes` が exit 0
- [ ] 全タスクが design-reviewer のレビューを 1 回受け、指摘を設計に反映済み (上流の決定が必要なものはユーザー確認済み)
- [ ] 上流の決定が必要な指摘はユーザーに確認済みで、回答が反映されている

(このフェーズは原則ユーザーの承認を求めない。完了条件はすべて機械とレビューで確認する)

## 終了

SKILL.md の「フェーズの終え方」に従う。phase 名は `detailed-design`、コミットは `docs(detailed-design): ...`。
案内文は次のとおり (次フェーズは質問なしで最後まで自動で進むため、許可の確認で止まらない起動方法を案内する):

> 詳細設計が完了し、成果物をコミットしました (タスク N 件)。
> 実装と検証は、質問なしで最後まで自動で進みます (実装はサブエージェントが行い、このセッションは進行役になります)。
> テストの実行やコミットの許可確認で止まらないよう、Claude Code を `claude --permission-mode bypassPermissions` で起動し直し、
> 何か一言 (例:「続けて」) を送ってください。起動し直さない場合は `/clear` してから一言送っても始まります。

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
