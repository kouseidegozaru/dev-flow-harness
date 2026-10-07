# 設計ドキュメントの分割ルール (要件定義・基本設計・詳細設計で共通)

エージェントが「必要なファイルだけ」を読めるように分割する。1 ファイルを丸ごと読まないと判断できない構成にしない。

## 1. 分割

- **1 ファイル 1 関心事。** 目安として 1 ファイル 300 行を超えそうなら分割する
- 分割の単位 (機能領域、画面、リソース、モジュール) はフェーズ内の対話や作業で決め、その単位と理由を `index.md` に記録する
- ファイル名は分割単位の ID またはその小文字名にする (例: `screens/SCR-010.md`、`api/task.md`、`modules/store.md`)

## 2. index.md

各ディレクトリ (`docs/02-requirements/`、`docs/03-basic-design/`、その下の `screens/`・`api/`、`docs/04-detailed-design/` など) に `index.md` を置く。

index.md に書くもの:

1. **目次**: 各ファイルへのリンクと 1 行要約 (そのファイルを読むべきかを判断できる要約)
2. **分割の単位と理由**
3. **対応表**: 上流 ID → このディレクトリの ID (例: 要件 ID → 画面 ID)。上流のどの ID をどのファイルが扱うかを一目で分かるようにする
ID 一覧は index.md に書かない。`devflow-trace.ps1 -UpdateIndexes` が同じディレクトリの `ids.md` に自動生成し、index.md にはそこへのリンクだけを置く
(index.md は各フェーズで最初に読まれるので、小さく保つ)。

エージェントはまず index.md を読み、必要なファイルだけを読む。ID の定義場所を探すときは `ids.md` 全体を読まず、Grep で ID を検索する。

## 3. 重複の禁止

- 同じ内容を複数ファイルに書かない。参照はファイルパスと ID へのリンクで行う (`[SCR-010](screens/SCR-010.md)`)
- 上流の内容を下流で言い換えて書き直さない。「REQ-TODO-003 を満たすため〜」のように ID で参照し、下流で新たに決めたことだけを書く
- ID の定義は 1 か所だけ (traceability.md 参照)

## 4. 相対リンク

- 他ファイルへのリンクは、そのファイルからの相対パスで書く
- 上流ドキュメントへのリンクも相対パス (例: `../../02-requirements/functional/todo.md`)

## 5. 成果物の置き場所

```
docs/
  01-vision.md
  02-requirements/
    index.md                   # 目次、分割単位、要件ID一覧 (自動)、ファイル対応表
    functional/<area>.md       # 機能領域ごと
    non-functional.md
    data.md
    external-integrations.md
    tech-stack.md
  03-basic-design/
    index.md                   # 目次、要件ID → 設計ID の対応表、設計ID一覧 (自動)
    architecture.md
    screens/index.md           # 画面一覧、画面遷移図、画面ID ↔ デザインの対応表
    screens/<SCR-ID>.md
    designs/                   # 画面デザイン (HTML など。構成は自由、入口は index.html)。ブラウザで開いて確認
    design-spec.md             # デザイン作成時の指示と判断理由
    data-model.md
    api/index.md
    api/<resource>.md
    error-policy.md
  04-detailed-design/
    index.md                   # 目次、モジュール一覧、基本設計ID → 詳細設計ID の対応表
    conventions.md
    modules/<module>.md
    db/schema.md
    db/migrations.md
    api/<resource>.md
    tasks/index.md             # タスク一覧 (ID、タイトル、依存、状態)
    tasks/<TASK-ID>.md
  traceability.md              # 自動生成
  verification-report.md       # 検証フェーズの最終レポート
```

対象のシステムに不要なファイル (例: DB のない CLI の `db/`) は作らず、index.md に「不要 (理由)」と書く。
