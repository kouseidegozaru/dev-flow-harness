# フェーズ 5: 実装 (完全自動)

`scripts/devflow-implement` が起動する無人セッション (`claude -p "/dev-flow auto"`) で実行する。
**ユーザーには一切質問しない。** 判断に迷ったら設計ファイルに従い、設計で決まらないことは blocked として記録して次へ進む。

## 役割分担

- **このセッション (オーケストレーター)**: タスクの割り振り・完了判定・状態更新・引き継ぎだけを行う。
  設計ファイルやソースコードを自分で読み込まない (コンテキストを節約するため)。読むのは tasks/index.md、handoff.md、スクリプトの出力だけ
- **tdd-implementer サブエージェント**: 1 タスクを TDD で実装してコミットする

## 入力

- `.devflow/handoff.md` (前セッションからの引き継ぎ。SessionStart フックが内容を注入している)
- `pwsh -NoProfile -File scripts/devflow-state.ps1 impl-status` の出力
- `docs/04-detailed-design/tasks/index.md`

## 進め方

1. `devflow-state.ps1 impl-status` で状況を確認する。handoff.md に作業中のタスクがあれば、その記述を次の委任に添える
2. 次のタスクを取る: `pwsh -NoProfile -File scripts/devflow-state.ps1 next-task`
   - 出力が `NONE (...)` (exit 3) なら「全タスク処理後」へ
   - 作業中 (in_progress) のタスクがあればそれが返る
3. `devflow-state.ps1 task <TASK-ID> in_progress`
4. `tdd-implementer` サブエージェントを **前面で** 起動し、完了を待つ。渡すのは次の情報だけ:

   > タスク <TASK-ID> を実装せよ。
   > - タスクファイル: docs/04-detailed-design/tasks/<TASK-ID>.md
   > - 参照ファイル: タスクファイルの「参照すべき設計ファイル」に列挙されたもの
   > - 規約: docs/04-detailed-design/conventions.md
   > - 同じテストで失敗が続く上限: <config.maxAttemptsPerTest> 回
   > - 前回までの経過: <handoff.md に記述があればその要約、なければ「なし」>

5. サブエージェントの報告 (`STATUS: done` / `STATUS: blocked`) を受けて完了判定をする:
   - `done` の場合、機械判定を実行する:

     ```bash
     pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode task -Task <TASK-ID>
     git log --oneline --grep "(<TASK-ID>)"
     ```

     trace が exit 0 で、`test(<TASK-ID>)` と `feat(<TASK-ID>)` のコミットがあれば完了とする。
     満たさない場合は、trace の出力を添えて同じサブエージェントに差し戻す (SendMessage で続けるか、新たに起動する)。差し戻しは 2 回まで。
     それでも満たさなければ blocked とする
   - 完了: `devflow-state.ps1 task <TASK-ID> done` → `devflow-commit.ps1 -Kind chore -Scope <TASK-ID> -Message "タスク完了"`
   - blocked: `devflow-state.ps1 task <TASK-ID> blocked -Reason "<試したこと / 行き詰まった理由 / 必要な判断>"` →
     `devflow-commit.ps1 -Kind chore -Scope <TASK-ID> -Message "blocked として記録"`
6. `.devflow/handoff.md` の「進捗」に 1 行追記する (例: `- TASK-004 done (feat 2 件, refactor 1 件)`)
7. 手順 2 に戻る。PostToolUse フックが「コンテキスト使用率が閾値を超えた」と知らせてきたら、新しいタスクを取らずに「セッションの終え方」へ

## タスクの完了判定 (すべて満たさない限り done にしない)

- タスクファイルのテストケース一覧がすべてテストとして実装され、通っている
- 担当する全 ID がテスト名に埋め込まれている (trace -Mode task が確認する)
- タスクの完了条件をすべて満たしている (サブエージェントが項目ごとに報告する)
- 全テストが通っている (trace -Mode task が test.command を実行して確認する)
- 担当範囲に TODO・FIXME・スタブ・未実装例外が残っていない (trace -Mode task が確認する)

## 禁止事項 (サブエージェントにも守らせる)

- テストの削除・スキップ・期待値を実装に合わせて書き換えること
- 設計にない仕様で代替すること、設計を勝手に変更すること (docs/ を実装フェーズで編集しない。状態欄は devflow-state.ps1 が更新する)
- テストが落ちている状態での `feat` / `refactor` コミット (`devflow-commit.ps1` が拒否する)
- ユーザーへの質問

## 行き詰まったとき

次のいずれかに当たったら、そのタスクを blocked にして、依存しない次のタスクへ進む (next-task は blocked に依存するタスクを返さない)。

- 同じテストで maxAttemptsPerTest 回続けて失敗した
- 設計と異なる実装が必要になった (設計どおりでは完了条件やテストを満たせない)
- 設計に書かれていない判断が必要になった
- 参照ファイルに書かれた前提 (他タスクの成果物、外部環境) が存在しない

## 全タスク処理後

`next-task` が `NONE (complete)` または `NONE (stuck)` を返したら:

1. `pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase implementation`
2. `devflow-commit.ps1 -Kind chore -Scope implementation -Message "実装フェーズ完了"`
3. 続けて [06-verification.md](06-verification.md) を読んで検証フェーズを実行する (コンテキストに余裕がなければ「セッションの終え方」で終える。次のセッションが検証から始める)

## セッションの終え方

コンテキスト使用率が閾値を超えたとき (PostToolUse / Stop フックが知らせる) は、新しいタスクに着手せずに次を行う。

1. `.devflow/handoff.md` を `templates/handoff.md` の形で更新する:
   このセッションで完了したタスク、作業中タスクとその状態 (どのコミットまで進んだか、残っているテストケース)、次にやること、注意点
2. `pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind chore -Scope handoff -Message "セッション引き継ぎ"`
   (作業途中で未コミットの変更があれば、それも含める。テストが落ちていても chore なら拒否されない。handoff.md にその旨を書く)
3. 1〜2 行の要約を書いて応答を終える。外部ループが新しいセッションを起動し、handoff.md から再開する
