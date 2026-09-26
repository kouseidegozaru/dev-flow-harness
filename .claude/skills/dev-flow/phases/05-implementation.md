# フェーズ 5: 実装 (完全自動)

`/clear` 後の対話セッションで、そのセッションを **オーケストレーター** として実行する。
**ユーザーには一切質問しない。** 判断に迷うことは実装担当が blocked として記録し、最終レポートで報告する。

## 役割分担

- **このセッション (オーケストレーター)**: `tdd-implementer` サブエージェントを起動して、実装フェーズを任せるだけ。
  タスクの中身・設計ファイル・ソースコードは読まない。タスクの完了確認もしない (`devflow-state.ps1 task <ID> done` が機械的に確認する)。
  読むのは `impl-status` の出力と、実装担当の短い報告だけ
- **tdd-implementer サブエージェント (実装担当)**: タスクを依存順に 1 件ずつ TDD で実装・コミットし、次々にこなす。
  自分のコンテキスト使用率が閾値 (`contextThresholdPercent`、既定 50%) を超えたら、きりの良いところで `.devflow/handoff.md` を書いて終える
  (使用率はフックが実装担当自身の transcript から測り、実装担当に知らせる。閾値前に終えようとしたら SubagentStop フックが止めて次のタスクへ進ませる)

## 進め方

1. `pwsh -NoProfile -File scripts/devflow-state.ps1 start-phase`
2. `pwsh -NoProfile -File scripts/devflow-state.ps1 run start`
   (このセッションをオーケストレーターとして登録する。Stop フックが、作業を残したままこのセッションが応答を終えるのを防ぐ)
3. `pwsh -NoProfile -File scripts/devflow-state.ps1 impl-status` を実行する
   - `status` が `ready`: 手順 4 へ
   - `complete` または `stuck` (残りが blocked とそれに依存するタスクだけ): 「全タスク処理後」へ
   - `no-tasks` (tasks/index.md が無いか、ID と状態の列を持つ表が読めない): 実装担当を起動しない。`devflow-state.ps1 run stop` を実行し、
     「タスク一覧を読めない (docs/04-detailed-design/tasks/index.md を確認し、直したら `/dev-flow` で再開)」とユーザーに報告して止まる
4. `tdd-implementer` サブエージェントを **前面で** 起動し、終わるまで待つ。依頼文は次の 1 行だけ (タスクの中身を書き足さない):

   > 実装フェーズのタスクを進めよ (次のタスク: <impl-status の nextTask>)。

5. 実装担当の報告 (`STATUS: handoff | no-ready-task` と、done / blocked にしたタスク ID) を受け取ったら、手順 3 に戻る。
   報告の中身を検証したり、タスクファイルやコードを読んだりしない

同じ状態 (impl-status の done 件数が増えない) のまま実装担当が 2 回続けて終わった場合は、それ以上起動せず、
`devflow-state.ps1 run stop` を実行してユーザーに状況 (impl-status と .devflow/handoff.md の要点) を報告して止まる。

## 全タスク処理後

1. `pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase implementation`
2. `devflow-commit.ps1 -Kind chore -Scope implementation -Message "実装フェーズ完了"`
3. 続けて [06-verification.md](06-verification.md) を読んで、このセッションで検証フェーズを実行する

## 実装担当に守らせていること (参考)

詳細は `.claude/agents/tdd-implementer.md`。

- テストの削除・スキップ・期待値を実装に合わせて書き換えることの禁止。設計にない仕様で代替しない。`docs/` を編集しない
- テストが落ちている状態での `feat` / `refactor` コミットの禁止 (`devflow-commit.ps1` が拒否する)
- タスクの完了は `devflow-state.ps1 task <ID> done` が確かめる: `test(<ID>)`・`feat(<ID>)` のコミットがあり、
  `devflow-trace -Mode task` (全テスト実行・担当 ID のテスト名・スタブ検索) が exit 0
- 同じテストで `maxAttemptsPerTest` 回失敗した、設計どおりでは実装できない、設計にない判断が必要、のいずれかなら blocked にして次のタスクへ

## ユーザーの権限設定について

実装担当はテストの実行・ファイルの編集・コミットを繰り返す。許可の確認で止まらないよう、このフェーズは
`claude --permission-mode bypassPermissions` (または必要なコマンドを許可リストに入れた `acceptEdits`) で起動したセッションで実行する。
