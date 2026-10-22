# フェーズ 5: 実装 (完全自動)

詳細設計に続けて、同じセッションを **オーケストレーター** として実行する (自動区間の途中から再開したときも同じ)。
**ユーザーには一切質問しない。** 設計にない判断は実装担当が決定台帳に `処置-C` として記録して続け、外部環境がなくテストダブルで進めたものは `処置-B`、
お金・権限・個人情報などに当たる判断は `要回答` としてそのタスクだけ blocked にする。どれも全タスク処理後の **最後の 1 回** でまとめて見せる。

## 役割分担

- **このセッション (オーケストレーター)**: `tdd-implementer` サブエージェントを起動して、実装フェーズを任せるだけ。
  タスクの中身・設計ファイル・ソースコードは読まない。タスクの完了確認もしない (`devflow-state.ps1 task <ID> done` が機械的に確認する)。
  読むのは `impl-status` の出力と、実装担当の短い報告だけ
- **tdd-implementer サブエージェント (実装担当)**: **1 体で 1 タスク** (`implementer.tasksPerAgent`、既定 1) を TDD で実装・コミットし、done か blocked にして終える。
  次のタスクは新しい 1 体が行う (前のタスクの読み物を抱えないため。補償タスク・再試行も新しい 1 体)。担当分を処理する前に終えようとしたら SubagentStop フックが止める。
  1 タスクが 1 体のコンテキストに収まらないとき (使用率が `contextThresholdPercent`、既定 70% を超えた) だけ、`.devflow/handoff.md` を書いて交代する (非常口)

## 進め方

1. 詳細設計から続けて来たときは、出発前の確認 (`preflight -Departure`) が済んでいるので手順 2 へ。途中から再開したときは
   `pwsh -NoProfile -File scripts/devflow-state.ps1 preflight` (テストコマンドが実行できる環境かを確かめる)。
   exit 1 なら実装担当を起動せず、出力をそのままユーザーに報告して止まる (環境の不備のまま進めると、全タスクが blocked になるため)
2. `pwsh -NoProfile -File scripts/devflow-state.ps1 start-phase`
3. `pwsh -NoProfile -File scripts/devflow-state.ps1 run start`
   (このセッションをオーケストレーターとして登録する。Stop フックが、作業を残したままこのセッションが応答を終えるのを防ぐ)
4. `pwsh -NoProfile -File scripts/devflow-state.ps1 impl-status` を実行する
   - `status` が `ready`: 手順 5 へ
   - `complete` または `stuck` (残りが blocked とそれに依存するタスクだけ): 「全タスク処理後」へ。
     blocked の理由に設計の直し方が書かれていても、ここで設計を直したり、直してよいかをユーザーに確認したりしない (最終レポートで報告する)
   - `no-tasks` (tasks/index.md が無いか、ID と状態の列を持つ表が読めない): 実装担当を起動しない。`devflow-state.ps1 run stop` を実行し、
     「タスク一覧を読めない (docs/04-detailed-design/tasks/index.md を確認し、直したら `/dev-flow` で再開)」とユーザーに報告して止まる
5. `tdd-implementer` サブエージェントを **前面で** 起動し、終わるまで待つ (Agent ツールに `run_in_background: false` を必ず渡す。
   既定がバックグラウンドの環境があるため)。バックグラウンドで起動して Monitor やコミットの監視で見張らない
   (このセッションの応答が途中で終わり、監視の失効・終了時のフックのたびにターンを使い、実装担当の作業中のファイルを巻き込みやすくなる)。
   依頼文は次の 1 行だけ (タスクの中身を書き足さない):

   > 実装フェーズのタスクを 1 件進めよ (タスク: <impl-status の nextTask>)。

6. 実装担当の報告 (`STATUS: done | blocked | handoff | no-ready-task` と、タスク ID) を受け取ったら、手順 4 に戻る。
   報告の中身を検証したり、タスクファイルやコードを読んだりしない。ユーザーが途中で仕様の変更を言っていたら、ここで SKILL.md の「6. 承認の後の気変わり」を行ってから手順 4 に戻る

同じ状態 (impl-status の done と blocked の件数の合計が増えない) のまま実装担当が 2 回続けて終わった場合は、それ以上起動せず、
`devflow-state.ps1 run stop` を実行してユーザーに状況 (impl-status と .devflow/handoff.md の要点) を報告して止まる。
**「作業は進んでいる」「残りが少ない」などの自分の判断で、この規則を飛ばさない。** 1 タスクが 1 体の実装担当で終わらないのは、
タスクが大きすぎるか、読み物が大きすぎる (詳細設計の直し方の問題) ことが多く、続けても費用が増えるだけになりやすい。

### 実装担当の作業中にしてはいけないこと

- 作業ツリーのファイル (設計・タスクファイル・`.devflow/`) を編集・コミットしない。実装担当のコミット (`git add -A` を含む) に巻き込まれ、
  記録が混ざる。設計を直す必要があるとき (人が判断を返してきたときなど) は、実装担当が終わって報告を返してから直し、
  `devflow-commit.ps1 -Kind docs` でコミットしてから次の実装担当を起動する
- 「Stop hook feedback: ... uncommitted changes」(クラウドの終了時のチェック) が出ても、実装担当の作業中ならコミットしない。
  前面で起動していれば、実装担当の作業中にこのセッションの応答が終わることはない

## 自動区間の途中でユーザーが仕様の変更を言ったとき

実装担当の作業中にユーザーの発言が届いたら、実装担当の報告を待ってから、SKILL.md の「6. 承認の後の気変わり」に従う
(確認の 1 問だけを聞き、値なら `override`、形なら `amend`。**最初からやり直さない・黙って実装だけ足さない**)。
反映で足したタスク (補償タスク `TASK-C-…`、amend のタスク) は、手順 4 からの通常の流れで 1 タスク 1 体の実装担当が進める。

## 全タスク処理後

1. `pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase implementation`
2. `devflow-commit.ps1 -Kind chore -Scope implementation -Message "実装フェーズ完了"`
3. 続けて [06-verification.md](06-verification.md) を読んで、このセッションで検証フェーズを実行する

## 止まったあとの再開 (人が行う)

オーケストレーターが止まった理由ごとに、原因を直してから `/dev-flow` で再開する (手順 1 からやり直してよい。完了済みのタスクは飛ばされる)。
原因を直さずに再開すると、同じところで止まる。

| 止まった理由 | 見るもの | 直し方 |
|--------------|----------|--------|
| preflight が NG | 出力 | テストのツールを入れる、または `.devflow/config.json` の `test.command` / `test.resultGlobs` を直す |
| no-tasks | `docs/04-detailed-design/tasks/index.md` | ID と状態の列を持つ表に直す (`devflow-trace -Mode design` が exit 0 になること) |
| 進捗がないまま実装担当が終わり続けた | `impl-status`、`.devflow/handoff.md`、`.devflow/logs/` のテストのログ | テストの環境 (DB・外部サービス・ポート) を用意する。設計が原因なら `/dev-flow redo detailed-design` |
| 残りが blocked だけ (検証まで進み、最後の 1 回で聞かれる) | `.devflow/blocked.md` の理由、`.devflow/debrief.md` | 最後の 1 回で答えれば、オーケストレーターが override / amend で反映して該当タスクだけ回し直す。手で直すなら設計を直し、`devflow-state.ps1 task <ID> todo` で戻す。途中の作業を生かすなら、blocked.md の `git revert <取り消しコミット>` で先に復元する |

## 実装担当に守らせていること (参考)

詳細は `.claude/agents/tdd-implementer.md`。

- テストの削除・スキップ・期待値を実装に合わせて書き換えることの禁止。設計にない仕様で代替しない。`docs/` を編集しない
- テストが落ちている状態での `feat` / `refactor` コミットの禁止 (`devflow-commit.ps1` が拒否する)
- タスクの完了は `devflow-state.ps1 task <ID> done` が確かめる: `test(<ID>)`・`feat(<ID>)` のコミットがあり、
  `devflow-trace -Mode task` (全テスト実行・担当 ID のテスト名・スタブ検索) が exit 0
- タスクごとに読むのは `devflow-state.ps1 task-context <ID>` が書き出す `.devflow/context/<ID>.md` (タスクファイル + 参照した設計の節 + 依存タスクの実装メモ) だけ。
  done の前に、後続のタスク向けの実装メモ `.devflow/notes/<ID>.md` を書く (`task <ID> done` が有無を確かめる)。`handoff.md` は引き継ぐときだけ、全体を書き直す
- 前提のタスクが依存に入っていなかったときは、blocked にせず `devflow-state.ps1 add-dep <ID> <作るタスク>` で依存を足して後回しにする (人の判断を待たない)
- 設計にない細部の判断は、決めて台帳に `処置-C` を足して続ける (`devflow-state.ps1 ledger add -Kind C -Task <ID> …`)。お金・権限・個人情報などの語に当たると
  `要回答` に格上げされ (exit 4)、そのタスクを blocked にする。外部環境がなくテストダブルで進めたら `処置-B`
- 受け入れテストのタスク (`TASK-AT-*`) は `devflow-commit.ps1 -Kind acceptance` でコミットする (全テスト成功を求める。Red は求めない)。
  受け入れ例の値が期待値側にないと警告が 1 回出る (拒否はしない。最終レポートで人が確認する)
- 同じテストで `maxAttemptsPerTest` 回失敗した、設計どおりでは実装できない、のいずれかなら blocked にして終える (次のタスクは新しい 1 体が行う)

## ユーザーの権限設定について

実装担当はテストの実行・ファイルの編集・コミットを繰り返す。許可の確認で止まらないよう、このフェーズは
`claude --permission-mode bypassPermissions` (または必要なコマンドを許可リストに入れた `acceptEdits`) で起動したセッションで実行する。
クラウドのセッションでは、権限モードを「自動」(auto) にする。

## 利用上限に達したとき

利用上限 (session limit) で応答が止まったら、上限が戻ってから **同じセッションで**「続けて」と送ってもらう。
別のセッションを開いて実装フェーズを始めると、同じタスクを 2 か所で進めてしまう (手順の最初の `check-branches` が止めるが、
ブランチを分けずに続けるのが確実)。
