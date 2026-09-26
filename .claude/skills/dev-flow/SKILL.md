---
name: dev-flow
description: 企画・構想 → 要件定義 → 基本設計 → 詳細設計 → 実装 → 検証 の6フェーズで開発を進めるハーネス。.devflow/state.json から現在フェーズを判定し、該当フェーズの手順書を読み込んで実行する。ユーザーが開発フローの開始・再開・状況確認・フェーズのやり直しを求めたとき、または SessionStart フックが dev-flow の再開を指示したときに使う。
argument-hint: "[status | redo <phase>]"
---

# dev-flow ルーター

このスキルは「今どのフェーズか」を判定して、そのフェーズの手順書を読み込むだけの入口である。
フェーズの中身は `phases/*.md` に書かれている。**手順書を読まずにフェーズを進めてはならない。**

引数: `$ARGUMENTS`

## 1. 状態を読む

```bash
pwsh -NoProfile -File scripts/devflow-state.ps1 phase
```

- `none` と出たら (state.json がない): `pwsh -NoProfile -File scripts/devflow-state.ps1 init` を実行し、企画・構想から始める
- 以下、スクリプトはすべてプロジェクト直下から `pwsh -NoProfile -File scripts/<name>.ps1` で呼ぶ

## 2. 引数で分岐する

| 引数 | 動作 |
|------|------|
| なし | 現在フェーズを開始 (または途中から再開) する。下の表の手順書を読む |
| `status` | `devflow-state.ps1 show` と `devflow-state.ps1 impl-status` の結果を要約して表示するだけで終わる |
| `redo <phase>` | 指定フェーズからやり直す。影響 (以降のフェーズの成果物が古くなること) を説明し、ユーザーの明示的な承認を得てから `devflow-state.ps1 set-phase <phase>` を実行する (検証ラウンド数と追加タスクの記録は初期化される)。成果物は消さず、やり直すフェーズの手順で更新する。タスクの状態は、詳細設計の手順 (内容を変えたタスクだけ todo に戻す) で決める |

## 3. フェーズの手順書を読む

| phase | フェーズ | 手順書 | 対話 |
|-------|----------|--------|------|
| vision | 企画・構想 | [phases/01-vision.md](phases/01-vision.md) | あり |
| requirements | 要件定義 | [phases/02-requirements.md](phases/02-requirements.md) | あり |
| basic-design | 基本設計 | [phases/03-basic-design.md](phases/03-basic-design.md) | あり |
| detailed-design | 詳細設計 | [phases/04-detailed-design.md](phases/04-detailed-design.md) | ほぼなし |
| implementation | 実装 | [phases/05-implementation.md](phases/05-implementation.md) | なし (オーケストレーター + 実装担当サブエージェント) |
| verification | 検証 | [phases/06-verification.md](phases/06-verification.md) | なし (実装に続けて同じセッションで実行) |
| done | 完了 | — | `docs/verification-report.md` の要点を伝える |

implementation / verification は、このセッションを **オーケストレーター** として実行する (ユーザーに質問しない)。
実装そのものは `tdd-implementer` サブエージェントが行い、このセッションはサブエージェントを起動して待つだけ (手順は 05 の手順書)。
許可の確認で止まらないよう、ユーザーが `--permission-mode bypassPermissions` などで起動していない場合は、開始前にその旨を 1 回だけ伝えてから始める。

フェーズを始めるときは `devflow-state.ps1 start-phase` を実行する (SessionStart フックが「途中まで進んでいる」ことを判別するのに使う)。

## 4. 全フェーズ共通のルール

- **入力は前フェーズまでの成果物ファイルだけ。** 会話の記憶や推測で補わない。上流ドキュメントは `index.md` を読んでから、必要なファイルだけを読む
- 共通の参照資料 (必要なときに読む):
  - [references/interview-rules.md](references/interview-rules.md) — 対話フェーズの詰め方 (01〜03 で必ず読む)
  - [references/doc-structure.md](references/doc-structure.md) — 設計ドキュメントの分割ルール (02〜04 で必ず読む)
  - [references/traceability.md](references/traceability.md) — ID の書式・粒度・検証方法・テストへの埋め込み (02〜06 で必ず読む)
  - [references/design-guidelines.md](references/design-guidelines.md) — 画面デザインの指針 (screen-designer が読む)
  - `references/templates/` — 各成果物のテンプレート
- 状態の変更 (フェーズ・タスクの状態) は必ず `scripts/devflow-state.ps1` で行い、state.json や tasks/index.md の状態欄を手で書き換えない
- ID の網羅性は必ず `scripts/devflow-trace.ps1` で確かめる。目視の確認で代えない

## 5. フェーズの終え方 (対話フェーズ 01〜04 共通)

各手順書の「完了条件」をすべて満たしたら、次の順で終える。

1. 成果物を `docs/` に保存する (02 以降は `devflow-trace.ps1 -Mode docs -UpdateIndexes` が exit 0 になること。04 は `-Mode design`)
2. `pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase <phase>` で次フェーズに進める
3. 成果物と state をまとめてコミットする:
   `pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind docs -Scope <phase> -Message "<成果物の要約>"`
4. ユーザーに次のように案内して応答を終える (このセッションで次フェーズを始めない):

   > <フェーズ名> が完了し、成果物をコミットしました。
   > `/clear` を実行してください。クリア後に何か一言 (例:「続けて」) を送ると、<次フェーズ名> が自動で始まります。

   (Claude Code の仕様上、`/clear` 後にエージェントが自発的に話し始めることはできない。SessionStart フックが
   次フェーズの開始指示を注入しておき、ユーザーの最初の一言を開始の合図にする)
