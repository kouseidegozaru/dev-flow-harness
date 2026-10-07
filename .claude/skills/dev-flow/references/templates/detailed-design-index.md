# 詳細設計 目次

> 入力: [../03-basic-design/index.md](../03-basic-design/index.md)

## 目次

| ファイル | 要約 |
|----------|------|
| [conventions.md](conventions.md) | コーディング規約、命名、ディレクトリ、テスト方針、テストへの ID 埋め込み形式 |
| [modules/<module>.md](modules/<module>.md) | <モジュールの責務 1 行> (MOD-*, IF-*, BR-*) |
| [db/schema.md](db/schema.md) | テーブル・制約 (DBC-*) |
| [db/migrations.md](db/migrations.md) | マイグレーション手順 |
| [api/<res>.md](api/<res>.md) | 入出力スキーマ、バリデーション (VAL-*)、エラーコード (EC-*) |
| [tasks/index.md](tasks/index.md) | 実装タスク一覧 |

## モジュール一覧

| ID | モジュール | 責務 | 依存してよいモジュール | 検証 | 上流 |
|----|------------|------|------------------------|------|------|
| MOD-<name> | | | | review | ARC-001 |

## 基本設計 ID → 詳細設計 ID 対応表

| 基本設計 ID | 詳細設計 ID | タスク |
|-------------|-------------|--------|
| API-<RES>-001 | IF-<mod>-001, VAL-<RES>-001 | TASK-003 |
