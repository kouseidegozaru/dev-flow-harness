---
name: dev-flow
description: 企画・構想 → 要件定義 → 基本設計 → 詳細設計 → 実装 → 検証 → デプロイ の7フェーズで開発を進めるハーネス。.devflow/state.json から現在フェーズを判定し、該当フェーズの手順書を読み込んで実行する。ユーザーが開発フローの開始・再開・状況確認・フェーズのやり直しを求めたとき、または SessionStart フックが dev-flow の再開を指示したときに使う。
argument-hint: "[status | change <変えたいこと> | redo <phase>]"
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
- `pwsh` が見つからないとき: クラウドのセッション (環境変数 `CLAUDE_CODE_REMOTE` が `true`) なら `bash scripts/devflow-setup-cloud.sh` で入れてから続ける。
  それ以外は、PowerShell 7 を入れるようユーザーに伝えて止まる
- 引数が `status` 以外なら、続けて **ほかのブランチで同じ開発フローが進んでいないか** を確かめる:

  ```bash
  pwsh -NoProfile -File scripts/devflow-state.ps1 check-branches
  ```

  exit 5 (ほかのブランチで進んでいる) なら、フェーズを始めない。出力をそのまま示し、ユーザーにどうするか (そのブランチのセッションで続ける /
  そのブランチを取り込んでからここで続ける / 無視してここで続ける) を聞く。実装・検証フェーズでも、これだけは聞いてよい。
  (クラウドのセッションは 1 セッション 1 ブランチで動くため、別のセッションで同じフェーズを始めると、同じ作業を 2 か所で進めてしまう)

## 2. 引数で分岐する

| 引数 | 動作 |
|------|------|
| なし | 現在フェーズを開始 (または途中から再開) する。下の表の手順書を読む |
| `status` | `devflow-state.ps1 show` と `devflow-state.ps1 impl-status` の結果を要約して表示するだけで終わる |
| `change <変えたいこと>` | 承認済みの仕様の変更 (気変わり)。下の「6. 承認の後の気変わり」に従う。自動区間の途中でユーザーが仕様の変更を言ったときも同じ |
| `redo <phase>` | 指定フェーズからやり直す。影響 (以降のフェーズの成果物が古くなること) を説明し、ユーザーの明示的な承認を得てから `devflow-state.ps1 set-phase <phase>` を実行する (検証ラウンド数と追加タスクの記録は初期化される。デプロイより前に戻すときは、デプロイの結果の記録も初期化される)。成果物は消さず、やり直すフェーズの手順で更新する。タスクの状態は、詳細設計の手順 (内容を変えたタスクだけ todo に戻す) で決める |

## 3. フェーズの手順書を読む

| phase | フェーズ | 手順書 | 対話 |
|-------|----------|--------|------|
| vision | 企画・構想 | [phases/01-vision.md](phases/01-vision.md) | あり |
| requirements | 要件定義 | [phases/02-requirements.md](phases/02-requirements.md) | あり |
| basic-design | 基本設計 | [phases/03-basic-design.md](phases/03-basic-design.md) | あり |
| detailed-design | 詳細設計 | [phases/04-detailed-design.md](phases/04-detailed-design.md) | なし (自動区間の最初。detailed-designer サブエージェントが設計し、続けて実装へ) |
| implementation | 実装 | [phases/05-implementation.md](phases/05-implementation.md) | なし (オーケストレーター + 実装担当サブエージェント。1 タスク 1 体) |
| verification | 検証 | [phases/06-verification.md](phases/06-verification.md) | なし (実装に続けて同じセッションで実行) |
| deployment | デプロイ | [phases/07-deployment.md](phases/07-deployment.md) | なし (検証に続けて同じセッションで実行。デプロイは `devflow-deploy.ps1` が行う) |
| done | 完了 | — | `docs/verification-report.md` の要点と `docs/deployment-report.md` の結果を伝える |

**対話は 01〜03 だけ。基本設計の承認が「自動区間」の入口** で、detailed-design / implementation / verification / deployment は、
1 つのセッションを **オーケストレーター** として続けて実行する (ユーザーに質問しない)。設計は `detailed-designer`、実装は `tdd-implementer`
サブエージェントが行い、このセッションはサブエージェントを起動して待つだけ (手順は 04〜07 の手順書)。
自動区間で止まるのは **出発前** (詳細設計の後の `preflight -Departure` が NG のとき) と **全タスク処理後の最後の 1 回** (`debrief`) だけ。
その間にユーザーに聞かずに決めたこと・処置したことは、決定台帳 (`.devflow/decisions/ledger.md`) に溜めて、最後の 1 回でまとめて見せる。
許可の確認で止まらないよう、ユーザーが `--permission-mode bypassPermissions` などで起動していない場合は、開始前にその旨を 1 回だけ伝えてから始める
(クラウドのセッションでは起動し直せないので、権限モードを「自動」(auto) などの確認の少ないものにするよう伝える)。

フェーズを始めるときは `devflow-state.ps1 start-phase` を実行する (SessionStart フックが「途中まで進んでいる」ことを判別するのに使う)。

## 4. 全フェーズ共通のルール

- **入力は前フェーズまでの成果物ファイルだけ。** 会話の記憶や推測で補わない。上流ドキュメントは `index.md` を読んでから、必要なファイルだけを読む
- 共通の参照資料 (必要なときに読む):
  - [references/interview-rules.md](references/interview-rules.md) — 対話フェーズの詰め方と、承認前のレビュー (02・03 は spec-reviewer で 1 回だけ) (01〜03 で必ず読む)
  - [references/doc-structure.md](references/doc-structure.md) — 設計ドキュメントの分割ルール (02〜04 で必ず読む)
  - [references/traceability.md](references/traceability.md) — ID の書式・粒度・検証方法・テストへの埋め込み (02〜06 で必ず読む)
  - [references/design-guidelines.md](references/design-guidelines.md) — 画面デザインの指針 (screen-designer が読む)
  - `references/templates/` — 各成果物のテンプレート
- 状態の変更 (フェーズ・タスクの状態) は必ず `scripts/devflow-state.ps1` で行い、state.json や tasks/index.md の状態欄を手で書き換えない
- **ユーザーに聞かずに決めたことと、聞いて決めた値は、決定台帳に 1 行ずつ載せる** (`devflow-state.ps1 ledger add`。interview-rules.md §2)。
  その値を書いた成果物の行には `決定: DEC-…` か `(DEC-…)` を書く (trace が DEC-UNCITED で確かめる)。覆すときは `override` / `amend` だけを通す (§6)
- ID の網羅性は必ず `scripts/devflow-trace.ps1` で確かめる。目視の確認で代えない
- ユーザーへの報告・質問、PR の本文・コメントは、すべて **日本語** で書く (GitHub の通知への応答も同じ)
- `pwsh` の `-Message` / `-Reason` に渡す文は **シングルクォート** で囲む (`-Message '顧客の統合 (案 1)'`)。
  ダブルクォートや括弧をそのまま書くと、bash が括弧を解釈して構文エラーになる。文中のシングルクォートは `''` と 2 つ重ねる

## 5. フェーズの終え方 (対話フェーズ 01〜03 共通)

各手順書の「完了条件」をすべて満たしたら、次の順で終える。

1. 成果物を `docs/` に保存する (02 以降は `devflow-trace.ps1 -Mode docs -UpdateIndexes` が exit 0 になること)
2. `pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase <phase>` で次フェーズに進める
   (02・03 では、承認した受け入れ例が `.devflow/examples.lock.json` に凍結される)
3. 成果物と state をまとめてコミットする:
   `pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind docs -Scope <phase> -Message "<成果物の要約>"`。
   クラウドのセッション (環境変数 `CLAUDE_CODE_REMOTE` が `true`) では、続けて今のブランチに `git push` する
   (**クラウドでも全フェーズを 1 つのブランチで進め、PR は最後に 1 つだけ作る**。フェーズごとに PR を取り込む必要はない)
4. ユーザーに次のように案内して応答を終える (このセッションで次フェーズを始めない)。01・02 の後は、ローカルでもクラウドでも同じ:

   > <フェーズ名> が完了し、成果物をコミットしました。
   > `/clear` を実行してください。クリア後に何か一言 (例:「続けて」) を送ると、<次フェーズ名> が自動で始まります。

   03 (基本設計) の後は、自動区間の入口なので、03 の手順書の「終了」の案内文を使う (権限モード・一度だけする作業・新しいセッション)。

   (Claude Code の仕様上、`/clear` 後にエージェントが自発的に話し始めることはできない。SessionStart フックが
   次フェーズの開始指示を注入しておき、ユーザーの最初の一言を開始の合図にする)

## 6. 承認の後の気変わり (値の覆しと形の変更)

承認済みの決定を変えたいとユーザーが言ったとき (`/dev-flow change …`、または自動区間の途中の発言)。**redo はしない。** 影響の範囲だけを前向きに直す。
実装担当の作業中なら、その実装担当が終わって報告を返してから行う (作業ツリーを巻き込まないため)。

1. **確認を 1 問だけ** (AskUserQuestion。承認済みの決定を覆すので、自動区間でも聞いてよい): 何をどう変えるかを 1 文で言い直し、
   「値の変更」か「形の変更」かと影響 (`devflow-state.ps1 impact <DEC>` の件数) を添えて、推奨 (そのとおり変える) を先頭にする
2. 分ける:
   - **値の変更** (台帳の既存の DEC の値を別の値にする。例: CSV の文字コード、上限の数): 
     `devflow-state.ps1 override <DEC> -Value '<新しい値>' -Match '<新しい値の照合>' -Answered`。
     拒否されたら (新しい値が旧照合に当たる)、旧い値だけに当たる `-OldMatch` を足して同じ呼び出しでやり直す。
     出力の「次にすること」(引用行・照合当たり・todo のタスクのテストケースを直す → `relock` → `trace -Mode design` → docs のコミット) を行い、
     補償タスク `TASK-C-<DEC>-v<版>` があれば実装担当に回す
   - **形の変更** (機能・項目・画面・コマンドを足す・消す。例: ★評価を付けたい): 
     `devflow-state.ps1 amend -Topic '<何を変えるか>' -Value '<決定>' -Match '<新しい語の照合>' -Basis '「<ユーザーの発言の逐語>」'`。
     `-Basis` には、ユーザーの発言をそのまま「」で囲んで渡す (スクリプトが `.devflow/decisions/changes.md` の質問ログに逐語で残す)。
     出力の「次にすること」に従い、02 に要件と受け入れ例を足し (interview-rules.md §10 の印の書き方)、ユーザーが言っていない中身 (範囲外の文言・列の位置・表示の形など) は
     推奨で決めて値ごとに `仮` の行で台帳に載せ (最後の 1 回の「覆せる一覧」に出る)、`detailed-designer` を `mode: amend` で起動して
     03・04 の差分とタスクを足させ、`relock` → `trace -Mode design` exit 0 → docs のコミット。足したタスクは実装フェーズの手順 4 から回す
   - 値か形か迷うもの (値に見えて画面やデータの形が変わる) は形として扱う
3. 自動区間の途中なら、元の手順 (実装フェーズの手順 4 など) に戻る。対話フェーズの途中なら、その手順書の続きから
