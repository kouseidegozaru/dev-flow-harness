# dev-flow-harness

Claude Code 上で **企画・構想 → 要件定義 → 基本設計 → 詳細設計 → 実装 → 検証 → デプロイ** の 7 フェーズで開発を進めるハーネス
(スキル + サブエージェント + フック + スクリプト + ドキュメント規約)。

- 前半 3 フェーズ (企画・構想・要件定義・基本設計) で仕様を対話で詰め、基本設計の承認から先 (詳細設計・実装・検証・デプロイ) は 1 つのセッションで質問なしに自動で進める。
  自動区間で聞かずに決めたことは **決定台帳** に溜め、全タスク処理後の **最後の 1 回** でまとめて確認する
- 対話フェーズはコンテキストをクリアして始め、前フェーズまでの成果物ファイル (`docs/`) だけを入力にする
- 要件の受け入れ例の値 (Then の `` `値` ``) を承認時に凍結し、受け入れテストの期待値と機械で照合する。承認後の気変わりは、やり直しではなく影響の範囲だけを直す
- 実装はテスト駆動 (Red → Green → Refactor) で、タスクごとに細かくコミットする
- 設計の決定事項すべてに ID を振り、`scripts/devflow-trace.ps1` で実装漏れがないことを機械的に検証する

## 必要なもの

| もの | バージョン | 用途 |
|------|------------|------|
| Claude Code | 2.1.x (2.1.282 で確認) | スキル、サブエージェント、フック |
| PowerShell | 7 以降 (`pwsh`) | フック・スクリプト本体 (Windows / macOS / Linux) |
| git | | コミット、進捗の判定 |

フックとスクリプトはすべて PowerShell 7 で書かれている (python / node / jq は不要)。`scripts/devflow-trace.sh` は pwsh を呼ぶだけのラッパー。
pwsh がない環境のために、bash で書いた SessionStart フック (`.claude/hooks/ensure-pwsh.sh`) が 1 つだけある (下の「クラウドで使う」)。

## 導入

```bash
pwsh -NoProfile -File scripts/devflow-install.ps1 -Target <対象プロジェクトのパス> [-Force]
```

- 導入の後、導入したファイルをコミットする (クラウドで使うなら push もする。導入の最後に手順が出る)
- 対象プロジェクト (git リポジトリ) に `.claude/skills/dev-flow`、`.claude/agents/` の 5 エージェント、`.claude/hooks/`、`scripts/devflow-*` をコピーする
- `.claude/settings.json` に dev-flow のフックを追加する (既存の設定は残す。dev-flow のフックが導入済みなら最新の定義に置き換える)。
  ステータスラインは未設定のときだけ設定する
- `.gitignore` に dev-flow の一時ファイルを、`.gitattributes` に `*.sh text eol=lf` を追加する
- `.devflow/config.json` に `implementer.tools` があれば、導入した `tdd-implementer.md` の `tools:` をその値で上書きする (MCP のツールを足したいときなど)
- `-Force`: 導入済みのプロジェクトを更新する。ハーネスのファイルをすべて置き換え、以前の版で使っていた不要なファイルを消す。
  導入済みのプロジェクトに `-Force` なしで実行するとエラーになる (一部だけ置き換わって古いファイルと混在するのを防ぐ)。git リポジトリでない場所にも導入しない

## クラウドで使う (claude.ai/code)

クラウドのセッションのコンテナには pwsh が入っておらず、コンテナが作り直されるたびに消える。

- **推奨:** 環境の設定のセットアップスクリプトに `bash scripts/devflow-setup-cloud.sh` を書く。セッションの開始前に pwsh が入る
- 書かなくても、SessionStart フック (`ensure-pwsh.sh`) が、クラウド (環境変数 `CLAUDE_CODE_REMOTE=true`) で pwsh がないときに同じスクリプトで入れてから
  dev-flow の SessionStart フックを実行する (初回は pwsh のフックが「見つからない」で失敗した表示が出ることがあるが、続けてよい)。
  ネットワークの設定で github.com からのダウンロードが許されていること

クラウドでは、セッションごとに別のブランチで作業する。dev-flow は **全フェーズを 1 つのブランチで進め、PR は最後 (デプロイの後) に 1 つだけ作る**:

- 企画・構想と要件定義の後は、同じセッションで `/clear` して一言送る (PR の取り込みは要らない)
- 基本設計の後 (自動区間の入口) は、権限モードを「自動」(auto) にして `/clear` し、一言送る。環境の設定に値を入れた場合だけ新しいセッションを開き、
  「ほかのブランチで進んでいる」と聞かれたら「取り込んでからここで続ける」を選ぶ
- **同じプロジェクトで 2 つのセッションを同時に進めない。** `/dev-flow` は最初に `devflow-state.ps1 check-branches` で、
  ほかのブランチで dev-flow が進んでいないかを確かめ、進んでいれば始める前に確認する
- 利用上限で止まったら、上限が戻ってから同じセッションで「続けて」と送る
- 権限モードは「自動」(auto) にする (起動し直して `bypassPermissions` にすることはできない)

## 使い方

### 開始する

対象プロジェクトで `claude` を起動し、次を実行する。

```
/dev-flow
```

`.devflow/state.json` がなければ作り、企画・構想から始める。

### フェーズの進み方

| フェーズ | 進め方 | 成果物 |
|----------|--------|--------|
| 1. 企画・構想 | 対話 (1 問ずつ、推奨回答付き。「それで」で推奨どおりに進む) | `docs/01-vision.md` |
| 2. 要件定義 | 対話。承認の前に `spec-reviewer` が 1 回だけレビューし、指摘が 1 問ずつ質問される | `docs/02-requirements/` |
| 3. 基本設計 | 対話。画面デザインは `screen-designer` がローカルの HTML などで作り、文章の指示で直す。承認の前に `spec-reviewer` が 1 回だけレビューし、指摘が 1 問ずつ質問される | `docs/03-basic-design/` |
| 4. 詳細設計 | 自動 (自動区間の最初)。`detailed-designer` が設計し、`design-reviewer` が 1 回レビュー。上流の抜けは台帳に `仮`、聞くべきものは `要回答` で記録して先へ進む。出発前の確認 (`preflight -Departure`) が NG のときだけ止まる | `docs/04-detailed-design/`、`.devflow/config.json` |
| 5. 実装 | 自動 (オーケストレーター + 実装担当サブエージェント。1 タスク 1 体) | コード、テスト、受け入れテスト、TDD のコミット |
| 6. 検証 | 自動。最後に 1 回だけ、聞かずに決めたことと確認事項をまとめて聞く (debrief) | `docs/traceability.md`、`docs/verification-report.md` |
| 7. デプロイ | 完全自動 (検証に続けて同じセッションで実行)。検証で漏れがなく blocked もないときだけ、`devflow-deploy.ps1` が環境を順にデプロイする | `docs/deployment-report.md` |

対話フェーズ (1〜3) の終わりに成果物のドラフトが提示され、承認すると `docs/` への保存・コミット・state の更新が行われ、
`/clear` するよう案内される (区切りは 3 回。基本設計の後は、権限モードを変えて起動し直す案内になる)。

```
/clear
続けて          ← 何か一言送ると次フェーズが始まる (内容は何でもよい)
```

`/clear` 後、SessionStart フックが state.json を読み、次フェーズの開始指示をコンテキストに注入する。
ユーザーの最初の一言を開始の合図として、次フェーズが始まる (スキル名を打ち直す必要はない)。

対話フェーズの決定事項は `.devflow/decisions/<phase>.md` に決定ツリーとして都度記録されるので、コンテキストが圧縮・クリアされても続きから再開できる。

### 決定台帳と最後の 1 回

- 聞く範囲は従来と同じ (企画・構想の全論点、要件の機能の中身、承認済みの決定の変更、お金・法令・セキュリティ・外部送信は必ず聞く)。
  慣習で決まる値・上流から一意に決まる値だけを聞かずに決め、**決定台帳** (`.devflow/decisions/ledger.md`) に `仮` の行として残す。聞いて決めた値も `確定` の行で残す
- 台帳の行は **照合パターン** (その値が文書に現れたときに当たる正規表現) を持つ。その値を書いた文書の行は DEC を引用する (`決定: DEC-003` / `(DEC-003)`)。
  `devflow-trace` が docs/ の全行を照合し、引用漏れ (DEC-UNCITED)・覆した後の旧い値の残り (DEC-STALE) を見つける
- 要件の受け入れ基準の Then で、プログラムが出す値を `` `値` `` で印す (`` `値` [DEC-003] ``・否定 `` `!値` ``・順序 `` `a` → `b` ``)。
  承認時に `.devflow/examples.lock.json` に凍結し、受け入れテスト (`tests/acceptance/`、テスト名 `[AT][REQ-…]`) のアサーションの **期待値側** にその値があるかを照合する
  (テスト名・コメント・前提の行に書いただけでは通らない。外れは警告で、最終レポートで人が確かめる)
- 自動区間で実装担当が設計にない判断をしたら `処置-C`、外部環境がなくテストダブルで進めたら `処置-B` を台帳に足して続ける。
  お金・権限・個人情報などに当たる判断は `要回答` に格上げされ、そのタスクだけ止めて他を進める
- 全タスク処理後に `devflow-state.ps1 debrief` が「要回答 (推奨つき)」「覆せる一覧 (影響の大きい順)」「繰延べ」「人が確認する項目」を出し、
  オーケストレーターが 1 回の質問でまとめて聞く。本番へのデプロイは、台帳に open の繰延べ・要回答がないときだけ

### 承認の後の気変わり

途中で「やっぱり〜したい」と言えば (`/dev-flow change <変えたいこと>` でも)、確認が 1 問だけ来て、**やり直しにならずに影響の範囲だけが直る**:

- 値の変更 (例: CSV を BOM なしに): `devflow-state.ps1 override <DEC>` が台帳の版を上げ、`impact` で直す行と回し直すタスクを出し、
  done のタスクをまとめた補償タスク `TASK-C-<DEC>-v<版>` を 1 つ足す
- 形の変更 (例: ★評価を足す): `amend` が台帳に変更の行を足し、要件と受け入れ例を足して、`detailed-designer` が基本設計・詳細設計の差分とタスクを足す
  (足した要件が基本設計から参照されていなければ trace が AMEND-NO-BASIC にする)

### 要件定義・基本設計の承認前レビュー

- 成果物を書き終えると、承認を求める前に `spec-reviewer` サブエージェント (読み取りのみ) が **1 回だけ** レビューする。
  次のフェーズの担当がユーザーに聞かないと決められない点 (曖昧・抜け・矛盾・検証できない基準・要件の未実現・設計間の不整合) だけを、推奨回答付きの質問の形で挙げる
- 指摘は通常の対話と同じく 1 問ずつ質問され、回答が成果物と決定ツリーに反映される。ユーザーの判断が要らない指摘は質問せずに直される
- 指摘を反映した後は再レビューしない。そのまま成果物の要約 (指摘と対応を含む) が提示され、承認に進む

### 基本設計の画面デザイン

- `screen-designer` サブエージェント (メイン会話と同じモデル) が、画面仕様とデザイン指示書から `docs/03-basic-design/designs/` に HTML などを書き出す。
  外部サービスは使わず、ブラウザで開くだけでプレビューできる
- ファイル構成は自由 (共通 CSS、部品、画像、1 ページに複数状態を並べる形、クリックで遷移する試作など)。守る決まりは次のとおり:
  オフラインで開けること、各状態の要素に `data-state-id` と `id`、各要素に `data-id` を付けること、入口として `designs/index.html` を置くこと
- 見た目の質は [references/design-guidelines.md](.claude/skills/dev-flow/references/design-guidelines.md) (余白・文字・色・部品・状態・避けること・仕上げの確認) で揃える
- 修正は文章で指示する (例:「一覧の完了行をグレーにして」)。結果は `design-spec.md` の修正履歴に残り、画面仕様にも反映される

### 詳細設計のタスクとレビュー

- 詳細設計は自動区間の最初で、`detailed-designer` サブエージェントが書く (オーケストレーターは報告と trace の exit コードだけを見る)
- 受け入れ例のある機能領域ごとに、受け入れテストのタスク `TASK-AT-<区分>` を作る (実装のタスクに依存し、`devflow-commit.ps1 -Kind acceptance` でコミット)

- タスクファイルには、そのタスク固有の内容 (目的・担当ID・参照すべき設計の節・作るファイル・テストケース・完了条件) だけを書き、設計の内容は写さずに節を参照する。
  参照は「1 行 1 ファイル、節は「見出し」、ID はそのまま」の形で書き、`devflow-state.ps1 task-context <ID>` がそこから読み物
  (タスクファイル + 指した節 + ID の定義行) を機械的に切り出す。実装担当とレビュー担当は、この読み物と conventions.md だけを読む
- 読み物の大きさは `taskContextBudgetKB` (既定 40KB) 以内にする (超えたら参照を絞るかタスクを分ける)。conventions.md は全タスク共通のことだけにして小さく保つ
- レビューは必要最低限で、**1 回だけ**。同じ設計を参照するタスクのまとまりごとに `design-reviewer` を 1 体起動し、実装者が作業を止める、または設計と違う実装をしてしまう点だけを挙げさせる
- 指摘は再レビューせずに設計へ反映する。上流 (要件・基本設計) の抜けも、上流の方針から推奨が決まるものは推奨で補って決定ツリーの「上流を補った決定」に記録し、
  完了時に件数を報告する。ユーザーに聞くのは、承認済みの決定を覆す・お金や法令・セキュリティなどで上流に根拠がない・同等の案があり推奨を決められないものだけ
- ID の網羅性 (未割り当て・要件の未被覆・テストケース不足) と、実装で止まる原因 (依存の漏れ・参照先の見出しがない・読み物が大きすぎる) は
  `devflow-trace.ps1 -Mode design` で機械的に確かめる
- テストの実行方法 (`test.command` など) を `.devflow/config.json` に設定する

### 実装・検証・デプロイ (完全自動)

基本設計が終わると案内が出る。テストの実行やコミットの許可確認で止まらないよう、`claude --permission-mode bypassPermissions` で起動し直して、
何か一言 (「続けて」など) を送る。そのセッションが **オーケストレーター** になり、詳細設計から最後まで進む。止まるのは、出発前の確認 (詳細設計の直後。
テストのコマンド・準備のコマンド・git の利用者名・デプロイの秘密の値) が NG のときと、最後の 1 回だけ。

```
オーケストレーター (このセッション)            実装担当 (tdd-implementer サブエージェント)
  detailed-designer → design-reviewer → 出発前の確認
  impl-status を見て実装担当を起動する ───────▶  next-task → TDD で実装・コミット → task done (1 タスクだけ)
  (依頼文は「タスクを 1 件進めよ」の 1 行だけ)     設計にない判断は台帳に 処置-C を足して続ける
  短い報告を受け取る ◀──────────────────────────  done / blocked を報告して終える (1 タスクが収まらないときだけ handoff.md)
  タスクが残っていれば、新しい実装担当を起動する
  全タスクが終わったら検証フェーズ (trace で漏れを調べ、漏れがあれば追加タスクを作って実装担当に戻す)
  最後の 1 回 (debrief): 要回答・覆せる一覧・繰延べ・照合の警告をまとめて聞き、答えを override / amend で反映して該当タスクだけ回し直す
  検証が終わったらデプロイフェーズ (devflow-deploy.ps1 all で環境を順にデプロイし、結果をレポートにする)
```

- **オーケストレーター** はタスクの中身・設計・コードを読まず、実装担当を起動して待つだけ。コンテキストがほとんど増えない
- **実装担当** は 1 体で 1 タスク (`implementer.tasksPerAgent`、既定 1。0 なら従来どおり閾値まで続ける)。タスクごとに `task-context` の出力だけを読み、`test` → `feat` (→ `refactor`) をコミットし、
  後続のタスク向けの実装メモ (`.devflow/notes/<ID>.md`) を書いて `task done` → `chore(<ID>): タスク完了` で区切る。
  後続のタスクの `task-context` には依存タスクの実装メモが入るので、既存のコードを探し回らずに済む。`handoff.md` は引き継ぐときだけ全体を書き直す (追記で大きくしない)
- SubagentStop フックが、開始後に done か blocked のタスクが 1 件増えて作業ツリーがクリーンなら終了を許し、そうでなければ止めて続けさせる。
  実装担当のコンテキスト使用率 (フックが実装担当自身の transcript から測る) が閾値 (`contextThresholdPercent`、既定 70%) を超えたときだけ、
  コミットできる区切りで `handoff.md` を書いて交代する (1 タスクが 1 体に収まらないときの非常口)
- タスクの完了は `devflow-state.ps1 task <ID> done` が機械的に確かめる (`test(<ID>)`・`feat(<ID>)` のコミットがあり、`devflow-trace -Mode task` が通ること)
- 前提のタスクが依存に入っていなかったときは、blocked にせず `devflow-state.ps1 add-dep` で依存を足して todo に戻し、次のタスクへ進む。依存先が終わると自動で再開する
  (記録は `.devflow/dep-changes.md` と最終レポート)
- 同じテストで `maxAttemptsPerTest` 回失敗した、設計どおりでは実装できない、設計にない判断が必要、のいずれかに当たったタスクは blocked として記録し、依存しない次のタスクへ進む。
  blocked にするとき、そのタスクの変更は `revert(<TASK-ID>)` コミットで取り消され、全テストが通る状態に戻る (失敗するテストが残って後続のタスクまで Green にできなくなるのを防ぐ。取り消したコミットと復元方法は `.devflow/blocked.md` に残る)
- **検証** は `devflow-trace.ps1 -Mode full` (全テスト実行・スタブ検索・ID の網羅性) で行う。漏れがあれば追加タスク `TASK-V<ラウンド>-<連番>` を作って実装に戻し、
  漏れがなくなる (または残りが blocked だけになる) か `maxVerificationRounds` に達したら、最終レポートを書いてデプロイフェーズへ進む
- **デプロイ** は `scripts/devflow-deploy.ps1 all` が行う (オーケストレーターはデプロイのコマンドを直接打たない)。確認なしで進むので、次を機械的に守る:
  - 検証レポートの判定が「漏れなし」で、blocked のタスクがないときだけデプロイする (`deploy.allowWithIssues` で外せるのは本番でないデプロイ先だけ)。
    本番のデプロイ先 (`production: true`、または名前が prod / production / 本番) は、加えて台帳に open の繰延べ (処置-B)・要回答がないこと
  - コードに未コミットの変更があればデプロイしない。`deploy.targets` を上から順に実行し、前の環境 (ステージングなど) が同じコードで成功していなければ次 (本番) へ進まない
  - 各環境で、デプロイ (`command`) → 公開後の確認 (`smokeCommand`)。確認が失敗したら `rollbackCommand` で自動で切り戻し、後の環境は実行しない
  - MCP で行う環境 (`kind: "agent"`) は、`all` が手順 (`steps`) を出して止まり (exit 5)、オーケストレーターがその手順どおりに MCP のツールで行って
    `finish` で記録する。公開後の確認と、失敗時の切り戻し (`rollbackSteps`) の記録はスクリプトが行う。秘密の値を環境変数に用意しなくて済む
  - 失敗しても直して再実行はしない。結果を `docs/deployment-report.md` に書いて phase を `done` にする。直したら `/dev-flow redo deployment` で再開する
    (同じコードで成功済みの環境は飛ばされる)
  - デプロイ先は基本設計で、**秘密の値をユーザーにコピーさせない** ものを推奨にして決める。操作手段は、MCP (claude.ai のコネクタなら OAuth で接続するだけ) か
    Git 連携の自動デプロイ → トークン 1 つで済む CLI → サービスごとにキーが要るもの、の順に選ぶ。
    アプリが使う設定値を別のサービスから受け渡すとき (DB の URL・公開キーなど) も、両方の MCP があればエージェントが読み出して設定する。
    ユーザーがする作業は `architecture.md` の「ユーザーが一度だけする作業」にまとまり、詳細設計の終わりに案内される
  - 必要な秘密 (トークンなど) は `requiredEnv` に名前だけを書き、値は **vault** (Doppler・1Password・Infisical など。`deploy.vault`) に置く。
    環境変数になければ `devflow-deploy.ps1` が vault から取り出して、デプロイのコマンドにだけ渡す (ファイルには書かない)。
    エージェントが MCP・CLI で読み出せる値は、エージェントが vault に保存する (`set-secret`)。ユーザーが環境の設定に入れるのは vault の認証の値 1 つだけ。
    ログ (`.devflow/logs/deploy-*.log`) は git の管理外

**注意:** `bypassPermissions` は git・テスト・ファイル編集・デプロイを確認なしで行う。信頼できるリポジトリで、できればコンテナや専用の作業環境で実行すること。
許可リストを細かく設定する場合は `acceptEdits` + `permissions.allow` (テストコマンド、`git`、`pwsh -NoProfile -File scripts/devflow-*`) でもよい。

### 途中から再開する

- **対話フェーズ**: `claude` を起動して `/dev-flow` (または何か一言。SessionStart フックが進行中のフェーズを知らせる)。`.devflow/decisions/<phase>.md` から続ける
- **実装・検証・デプロイ**: `claude --permission-mode bypassPermissions` を起動して `/dev-flow` (または何か一言)。in_progress のタスクと `handoff.md` から続ける。
  途中の作業はタスクごと・引き継ぎごとにコミットされている
- **自動フェーズが止まったとき** (テスト環境の不備、タスク一覧が読めない、進捗がない、残りが blocked だけ): 原因を直してから再開する。
  理由ごとの見る場所と直し方は [phases/05-implementation.md](.claude/skills/dev-flow/phases/05-implementation.md) の「止まったあとの再開」。
  blocked を todo に戻すと、`.devflow/blocked.md` に解除の記録が付き、最終レポートには載らなくなる
- 状況の確認: `/dev-flow status`、または `pwsh -NoProfile -File scripts/devflow-state.ps1 impl-status`

### フェーズをやり直す

```
/dev-flow redo requirements
```

影響の説明と確認のあと、`devflow-state.ps1 set-phase <phase>` で指定フェーズに戻る (検証ラウンド数と追加タスクの記録は初期化される。デプロイより前に戻すときは、デプロイの結果の記録も初期化される)。成果物は消さず、そのフェーズの手順で更新する。
やり直したフェーズより後の成果物は古くなるので、以降のフェーズも順に通し直す (`devflow-trace` が不整合を検出する)。
詳細設計を通し直すとき、内容や参照する設計の節を変えたタスクだけを todo に戻し、変えていない done のタスクは done のまま残す
(実装済みの分を作り直さないため)。

特定のタスクだけやり直す場合: `pwsh -NoProfile -File scripts/devflow-state.ps1 task TASK-007 todo`

### 検証レポートを読む

`docs/verification-report.md`:

| 節 | 見るべきこと |
|----|--------------|
| 1. 網羅状況 | `devflow-trace -Mode full` の漏れ件数が 0 か。詳細は `docs/traceability.md` (要件 → 設計 → タスク → テストの対応表) |
| 2. blocked のまま残ったタスク | 理由と「必要な判断」。判断して設計を直したら、タスクを `todo` に戻して `/dev-flow redo implementation` で実装を再開する。途中までの作業を生かすなら、blocked.md にある `git revert <取り消しコミット>` で先に復元する |
| 3. 人が確認する項目 | `manual` 種別と `review` 種別の ID (review には、実装担当が実装時に `.devflow/review-log.md` に残した自己確認の記録が付く) |
| 4. 検証で見つかって修正した漏れ | 機械チェックが見つけ、追加タスクで実装した内容 |
| 5. 未解決の漏れ | 最大ラウンド超過や設計の不備で残ったもの |

### デプロイレポートを読む

`docs/deployment-report.md`: 冒頭の判定 (成功 / 失敗 / 未実施 / デプロイなし)、環境ごとの結果、切り戻したもの、人がすること、
公開後に人が確認すること。直し方は [phases/07-deployment.md](.claude/skills/dev-flow/phases/07-deployment.md) の「止まったあとの再開」。

## コミット規約

| 種類 | 形式 | 条件 (`devflow-commit.ps1` が確かめる) |
|------|------|----------------------------------------|
| Red | `test(<TASK-ID>): <メッセージ>` | テストを実行し、失敗すること。結果ファイルに、そのタスクの担当 ID を名前に含む失敗したテストが必要 (ビルドエラーや無関係なテストの失敗は Red とみなさない) |
| Green | `feat(<TASK-ID>): <メッセージ>` | 全テストが成功すること |
| Refactor | `refactor(<TASK-ID>): <メッセージ>` | 全テストが成功すること |
| 受け入れテスト | `acceptance(<TASK-AT-…>): <メッセージ>` | 全テストが成功すること (Red は求めない)。コミット後に、担当の要件の受け入れ例が期待値側にあるかを照合し、外れを警告で示す |
| 修正 | `fix(<scope>): <メッセージ>` | 全テストが成功すること |
| フェーズの成果物 | `docs(<phase>): <メッセージ>` | テストは実行しない |
| 状態・引き継ぎ | `chore(<scope>): <メッセージ>` | テストは実行しない |

```bash
pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind test -Scope TASK-003 -Message "期限切れ判定のテストを追加" [-Paths <パス>...]
```

## 構成

```
.claude/
  skills/dev-flow/
    SKILL.md                  # ルーター: state を読んで各フェーズの手順書を読み込む
    phases/01〜07-*.md        # 各フェーズの 入力 / 進め方 / 完了条件 / 出力テンプレート
    references/
      interview-rules.md      # 対話フェーズ共通の詰め方
      doc-structure.md        # 設計ドキュメントの分割ルール
      traceability.md         # ID の書式・粒度・検証方法・テストへの埋め込み・trace の検査項目
      design-guidelines.md    # 画面デザインの指針
      templates/              # 各成果物のテンプレート
  agents/
    spec-reviewer.md          # 要件定義・基本設計を承認前に 1 回だけレビュー (次フェーズがユーザーに聞かないと決められない点を質問の形で)
    detailed-designer.md      # 詳細設計担当: 自動区間の最初に詳細設計を書く (create / reflect / amend / fix)。ユーザーに質問しない
    design-reviewer.md        # 詳細設計のタスクのまとまりを実装者目線で 1 回だけレビュー (実装者が止まる・誤る点だけ)
    screen-designer.md        # 画面デザインを HTML などで作成・修正 (文章の指示で修正)
    tdd-implementer.md        # 実装担当: 1 タスクを TDD で実装して終える (毎回の手順 / 詰まったとき)。設計にない判断は台帳へ
  hooks/
    session-start.ps1         # /clear 後の次フェーズ開始 (実装・検証はオーケストレーターとして開始)、compact 後の再読指示
    stop.ps1                  # オーケストレーター: 作業 (実装・検証・デプロイ) が残っていれば応答を終えさせない
    post-tool-use.ps1         # 実装担当: 自分のコンテキスト使用率を測り、閾値超えを知らせる
    subagent-start.ps1        # 実装担当: 開始時刻・開始時の使用量の記録を作る
    subagent-stop.ps1         # 実装担当: 担当のタスクを done / blocked にするまで終えさせない。閾値超えなら引き継ぎが済むまで終えさせない
    statusline.ps1            # ステータスライン: 現在フェーズとコンテキスト使用率を表示
  settings.json
scripts/
  devflow-lib.psm1            # 共通ライブラリ
  devflow-state.ps1           # state.json / tasks/index.md の状態操作 (エージェントに手で書き換えさせない)
  devflow-trace.ps1 (.sh)     # ID の網羅性検証、traceability.md・各層の ID 一覧 (ids.md) の生成
  devflow-commit.ps1          # コミット規約の機械的な強制
  devflow-deploy.ps1          # デプロイの実行 (前提の確認、環境の順序、公開後の確認、失敗時の切り戻し、記録)
  devflow-install.ps1         # 対象プロジェクトへの導入
  devflow-setup-cloud.sh      # pwsh がなければ入れる (クラウドのセッション用)
.devflow/                     # (対象プロジェクトに作られる)
  state.json                  # 現在フェーズ、完了フェーズ、検証ラウンド、追加タスク
  config.json                 # テストコマンド、閾値など (詳細設計で設定)
  decisions/<phase>.md        # 対話フェーズの決定ツリー
  decisions/ledger.md         # 決定台帳 (確定・仮・処置-C・処置-B・要回答。照合パターンと版を持つ)
  examples.lock.json          # 承認時に凍結した受け入れ例 (要件 → 印の値の列)
  debrief.md                  # 最後の 1 回の一覧と答え
  review/detailed-design.md   # 詳細設計のレビュー担当の指摘 (detailed-designer が反映する)
  handoff.md                  # 実装担当の間の引き継ぎ (作業中のタスクと注意点だけ。毎回書き直す)
  notes/<TASK-ID>.md          # タスクの実装メモ (後続のタスクが使う公開の名前・ファイル・注意点。task-context が依存タスクの分を出す)
  dep-changes.md              # 実装中に足した依存の記録
  blocked.md                  # 行き詰まったタスクの記録
  review-log.md               # review 種別の ID の自己確認の記録 (trace が有無を検査する) と、実装担当が設計にない細部を決めた記録 ([判断] の行)
  verification-log.md         # 検証ラウンドごとの漏れと追加タスク
  deploy-log.md               # デプロイ・公開後の確認・切り戻しの記録
  implementer.json            # 実行中の実装担当の記録 (git 管理外)
  orchestrator.json           # オーケストレーターの登録 (git 管理外)
  context/<TASK-ID>.md        # task-context が書き出すタスクの読み物 (git 管理外)
```

## スクリプト

| スクリプト | 主なコマンド |
|------------|--------------|
| `devflow-state.ps1` | `ledger add -Kind 確定\|仮\|C\|B\|要回答 -Topic -Value -Match -Basis [-Task]` (exit 4 = 要回答に格上げ) / `ledger check` / `ledger resolve <DEC>` / `impact <DEC>` (覆したときの影響。読み取りのみ) / `override <DEC> -Value -Match [-OldMatch] [-Answered]` (版を上げ、補償タスクを足す) / `amend -Topic -Value -Basis [-Match]` (形の変更) / `relock` / `debrief [-Done]` (exit 3 = 回答済み) / `preflight -Departure [-AllowMissingSecrets]` (出発前の確認) / `show` / `phase` / `init` / `start-phase` / `complete-phase <phase>` (02・03 では受け入れ例を凍結) / `set-phase <phase> [-KeepVerification]` / `impl-status` / `next-task` / `task <ID> <todo\|in_progress\|done\|blocked> [-Reason] [-Force]` / `task-context <ID>\|all` (タスクの読み物を `.devflow/context/<ID>.md` に書き出す) / `check-branches` (ほかのブランチで dev-flow が進んでいないか。exit 5 なら進んでいる) / `add-dep <ID> <依存 ID> [-Reason]` (依存を足して todo に戻す) / `run start\|stop` / `verification-round` / `add-verification-task <ID>` / `config` / `preflight` (テストを実行できる環境かを確かめる) |
| `devflow-trace.ps1` | `-Mode docs \| design \| full \| task [-Task <ID>]`、`-UpdateIndexes` (各層の ids.md を生成)、`-NoRun` (テストを実行しない)、`-NoReport`。終了コード 0 = 漏れなし、1 = 漏れあり、2 = エラー |
| `devflow-deploy.ps1` | `plan` (実行できるかを確かめる。exit 3 = デプロイ先なし、4 = 検証の結果が前提を満たさない) / `all` (全環境を順にデプロイ。exit 5 = MCP で行う環境の手順を出して止まった) / `run <name> [-Force]` / `rollback <name>` / `finish <name> -Result success\|failed [-Note]` / `rollback-done <name> -Result success\|failed` / `secrets` (秘密の値がそろっているか) / `set-secret <NAME> -Value <値>` (vault に保存) / `status` |
| `devflow-commit.ps1` | `-Kind test\|feat\|refactor\|fix\|acceptance\|docs\|chore -Scope <scope> -Message <msg> [-Paths ...]`。test は結果ファイルに担当 ID 付きの失敗したテストがあること、feat / refactor / fix は全テストの成功を確かめる |

## ID とトレーサビリティ

詳細は [references/traceability.md](.claude/skills/dev-flow/references/traceability.md)。要点:

- ID は、見出しに `ID` と `検証` の列を持つ Markdown 表の 1 行として定義する。`上流` 列に上位の ID を書く。層はファイルの場所で決まる
  (`docs/02-*` = 要件、`docs/03-*` = 基本設計、`docs/04-*` = 詳細設計、`docs/04-*/tasks/` = タスク)
- 検証方法は `test` (原則。自動テストで確かめる) / `review` (実装担当が実装時に自己確認し、最終レポートで人が確認する) / `manual` (最終レポートに列挙し、人が確認する)
- テスト名に `[REQ-TODO-001]` の形で ID を入れる。trace は JUnit XML / TRX のテスト結果から ID ごとの成否を判定する
- `docs/traceability.md` に、要件 → 設計 → タスク → テストの対応表、検出された漏れ、人が確認する項目 (review / manual) が生成される
- 各層の `index.md` と同じ場所に、その層の ID 一覧 `ids.md` が自動生成される (`index.md` は目次と対応表だけにして小さく保つ)

## 設定 (.devflow/config.json)

| キー | 既定値 | 意味 |
|------|--------|------|
| `contextWindowTokens` | 200000 | 使用率の分母 |
| `contextThresholdPercent` | 70 | 実装担当のコンテキスト使用率がこれを超えたら、次の実装担当に引き継ぐ |
| `minSessionWorkTokens` | 40000 | 実装担当の開始時の使用量からこのトークン数以上進むまでは、閾値を超えても引き継がない (何も進めずに引き継ぎだけを繰り返すのを防ぐ) |
| `hardLimitPercent` | 85 | この使用率に達したら、作業量にかかわらず引き継ぐ |
| `maxVerificationRounds` | 3 | 検証ラウンドの上限 |
| `maxAttemptsPerTest` | 3 | 同じテストでこの回数失敗したら blocked |
| `concurrentRunHours` | 72 | `check-branches` が、ほかのブランチの dev-flow を「並行して進んでいる」とみなす、`.devflow` の最終更新からの時間 (0 で無制限) |
| `taskContextBudgetKB` | 40 | 1 タスクの読み物 (`task-context` の設計部分) の上限。超えたタスクは詳細設計の trace で TASK-CONTEXT-LARGE になる |
| `implementer.tasksPerAgent` | 1 | 実装担当 1 体が処理する (done か blocked にする) タスク数。0 で従来どおり閾値まで続ける |
| `implementer.tools` | [] | 空でなければ、導入時に `tdd-implementer.md` の `tools:` をこの値で上書きする |
| `acceptance.files` | `tests/acceptance/**` | 受け入れテストの場所 (受け入れ例の照合の対象)。`test.command` がこれも実行すること |
| `ledger.sensitiveWords` | 料金・決済・権限・個人情報・外部送信など | 実装担当の処置 C がこれらの語に当たると `要回答` に格上げする |
| `test.setupCommand` | (空) | 出発前の確認で 1 回だけ実行する準備のコマンド (依存の取得など) |
| `test.command` | (詳細設計で設定) | 全テストを実行し結果ファイルを出すコマンド。ウォッチモードにしないこと |
| `test.timeoutSeconds` | 900 | テストの実行がこの秒数を超えたら止め、失敗として扱う (0 で無制限) |
| `test.resultGlobs` | TRX / JUnit の典型パス | テスト結果ファイルの場所 |
| `test.files` / `source.files` | | テストコード / 本番コードの場所 |
| `deploy.targets` | (詳細設計で設定) | デプロイ先の一覧 (上から順に実行)。各要素は `name`、`command`、`smokeCommand` (公開後の確認)、`rollbackCommand`、`requiredEnv` (必要な環境変数名)。MCP で行う環境は `kind: "agent"` と `steps` (手順)、`rollbackSteps`、`requiredMcp` (使うツールの接頭辞) |
| `deploy.timeoutSeconds` | 1800 | デプロイ・確認・切り戻しの各コマンドがこの秒数を超えたら止め、失敗として扱う (0 で無制限) |
| `deploy.rollbackOnFailure` | true | 公開後の確認が失敗したら、自動で切り戻す |
| `deploy.allowWithIssues` | false | true なら、検証に未解決の漏れや blocked のタスクがあってもデプロイする (本番のデプロイ先には効かない) |
| `deploy.targets[].production` | (名前で判定) | true のデプロイ先は本番として扱い、台帳に open の繰延べ・要回答があればデプロイしない |
| `deploy.vault` | (詳細設計で設定) | 秘密の値の置き場所。`name`、`getCommand` (`{name}` の値を標準出力に出す)、`setCommand` (標準入力の値を `{name}` に保存する)、`requiredEnv` (vault の認証)、`installCommand` (CLI がないときに入れる) |
| `deploy.secrets` | | 秘密の値ごとの `name` と `source` (エージェントが MCP・CLI で読み出す手順、または「ユーザーが vault に入れる」) |
| `stubPatterns` | TODO/FIXME/XXX のコメント、未実装例外など | スタブとして検出するパターン (正規表現) |
| `idPrefixes` | REQ, NFR, ARC, SCR, TRN, API, ERR, EXT, DM, MOD, IF, VAL, EC, DBC, BR, TASK | ID として認識する接頭辞 |

一時的な上書き: 環境変数 `DEVFLOW_CONTEXT_THRESHOLD`、`DEVFLOW_CONTEXT_WINDOW`。

## 仕組み

| 仕組み | 使い方 |
|--------|--------|
| スキル | `.claude/skills/dev-flow/SKILL.md` はルーターだけを持ち、現在フェーズの手順書 (`phases/`) と必要な参照資料だけを読み込ませる |
| SessionStart フック | `/clear` 後 (source=clear): 次フェーズの開始指示を注入する。実装・検証・デプロイフェーズでは、そのセッションをオーケストレーターとして開始させる。compact 後: 手順書と決定ツリー (実装・検証なら状態と handoff、デプロイなら `devflow-deploy.ps1 status` と deploy-log) を読み直させる。起動時: 進行中のフェーズを知らせる (クラウドで、前のフェーズが終わって次が未開始なら、最初の短い一言で開始させる)。`ensure-pwsh.sh`: クラウドで pwsh がなければ入れてから上を実行する |
| Stop フック | `devflow-state.ps1 run start` で登録したオーケストレーターのセッションでだけ動く。作業が残っていれば `decision: block` で応答を終えさせず、次の実装担当の起動や検証・デプロイの続きを指示する。同じ状態のまま 2 回止めても進捗がなければ、3 回目は終了を許す。タスク一覧が読めない (0 件) ときは止めずに終了を許し、人に知らせる |
| PostToolUse フック | 入力の `agent_type` が `tdd-implementer` のときだけ動く。実装担当の transcript (`<セッションの transcript と同じ場所>/<session_id>/subagents/agent-<agent_id>.jsonl`) の最新の応答の `message.usage` (`input_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`) を `contextWindowTokens` で割って使用率とし、閾値超えなら `additionalContext` で引き継ぎを指示する |
| SubagentStart フック | `tdd-implementer` の起動時に `.devflow/implementer.json` (開始時刻・開始時の使用量) を作る |
| SubagentStop フック | `tdd-implementer` が終えようとしたとき、開始後に done / blocked のタスクが `implementer.tasksPerAgent` 件増えて作業ツリーがクリーンなら終了を許す。まだなら `decision: block` で担当のタスクを続けさせる。閾値超えなら、`handoff.md` が開始後に更新され、作業ツリーがクリーンになるまで終えさせない。同じ状態のまま 2 回止めても進捗がなければ、3 回目は終了を許す |
| サブエージェント | `spec-reviewer` (読み取りのみ)、`design-reviewer` (読み取りのみ)、`screen-designer`、`detailed-designer`、`tdd-implementer` (tools を明示)。いずれもメイン会話と同じモデル (`model: inherit`) |
| フックの起動方法 | `"command": "pwsh", "args": ["-NoProfile", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/<名前>.ps1"]` の exec 形式で、OS やシェルに依存しない (`ensure-pwsh.sh` だけは `bash`。pwsh があれば何もしない) |

## 以前の版からの更新

`pwsh -NoProfile -File scripts/devflow-install.ps1 -Target <プロジェクト> -Force` で入れ直し、更新したファイルをコミットする
(`git add -A && git commit -m 'chore: dev-flow を更新'`。しないと次のフェーズのコミットに混ざる)。`state.json` の形と既存のサブコマンドは変わらないので、
そのまま `/dev-flow` (または何か一言) で続きから再開できる。詳細設計から先は自動区間になったので、詳細設計以降で止まっていたプロジェクトは、
再開の前に権限モードを確認の少ないもの (ローカルは `--permission-mode bypassPermissions`、クラウドは「自動」) にする。

- 詳細設計の途中だったプロジェクトは、詳細設計が自動区間に入ったので、再開すると `detailed-designer` が `.devflow/decisions/detailed-design.md` の続きから設計を進める
  (書きかけの 04 はそのまま使う。追加の質問は来ない。聞くべきものは最後の 1 回にまとめられる)
- 決定台帳 (`ledger.md`) と受け入れ例の lock (`examples.lock.json`) がないプロジェクトでは、台帳の照合は行わず、受け入れテストの有無 (REQ-NO-ACCEPTANCE) は警告になる。
  台帳に最初の行を足すと、その行の照合が始まる (その値を書いた行に DEC を書く)
- 実装担当は 1 タスク 1 体になる (`implementer.tasksPerAgent`。従来どおりにするなら 0)
- 本番のデプロイ先は `deploy.allowWithIssues` では前提を飛ばせなくなった (台帳に open の繰延べ・要回答がないことも求める)
