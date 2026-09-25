# dev-flow-harness

Claude Code 上で **企画・構想 → 要件定義 → 基本設計 → 詳細設計 → 実装 → 検証** の 6 フェーズで開発を進めるハーネス
(スキル + フック + スクリプト + ドキュメント規約)。

- 前半 4 フェーズで仕様を徹底的に詰め、実装・検証はユーザーとの対話なしに自動で進める
- 各フェーズはコンテキストをクリアして始め、前フェーズまでの成果物ファイル (`docs/`) だけを入力にする
- 実装はテスト駆動 (Red → Green → Refactor) で、タスクごとに細かくコミットする
- 設計の決定事項すべてに ID を振り、`scripts/devflow-trace.ps1` で実装漏れがないことを機械的に検証する

## 必要なもの

| もの | バージョン | 用途 |
|------|------------|------|
| Claude Code | 2.1.x (2.1.282 で確認) | スキル、フック、サブエージェント、`claude -p` |
| PowerShell | 7 以降 (`pwsh`) | フック・スクリプト本体 (Windows / macOS / Linux) |
| git | | コミット、進捗判定 |

スクリプトを PowerShell 7 で書いたのは、JSON を標準で扱え、Windows / macOS / Linux のどこでも同じように動くため
(python / node / jq に依存しない)。`scripts/*.sh` は pwsh を呼ぶだけの薄いラッパー。

## 導入

```bash
pwsh -NoProfile -File scripts/devflow-install.ps1 -Target <対象プロジェクトのパス>
```

`.claude/skills/dev-flow`、`.claude/agents/` の 4 エージェント、`.claude/hooks/`、`scripts/devflow-*` をコピーし、
`.claude/settings.json` にフックを追記し、`.gitignore` と `.gitattributes` を更新する。対象は git リポジトリであること。

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
| 1. 企画・構想 | 対話 (1 問ずつ、推奨回答付き。「それで」で進めてよい) | `docs/01-vision.md` |
| 2. 要件定義 | 対話 | `docs/02-requirements/` |
| 3. 基本設計 | 対話。画面デザインは screen-designer サブエージェントがローカルの HTML で作成し、文章の指示で修正 | `docs/03-basic-design/` |
| 4. 詳細設計 | ほぼ自律。上流の決定が必要な指摘だけをまとめて確認される | `docs/04-detailed-design/` |
| 5. 実装 | 完全自動 (外部ループ) | コード、テスト、TDD のコミット |
| 6. 検証 | 完全自動 (外部ループ) | `docs/traceability.md`、`docs/verification-report.md` |

各対話フェーズの終わりに成果物のドラフトが提示されるので、承認すると `docs/` への保存・コミット・state の更新が行われ、
**「`/clear` を実行してください」** と案内される。

```
/clear
続けて          ← 何か一言送ると次フェーズが始まる (内容は何でもよい)
```

`/clear` 後、SessionStart フック (source=clear) が state.json を読み、次フェーズの開始指示をコンテキストに注入する。
スキル名を打ち直す必要はないが、**何か 1 メッセージ送る必要がある** (Claude Code の仕様上、対話モードでは
エージェントが自分から話し始められないため。下の「既知の制約」参照)。

途中の決定事項は `.devflow/decisions/<phase>.md` に決定ツリーとして記録されるので、コンテキストが圧縮・クリアされても続きから再開できる。

### 実装ループを起動する

詳細設計が終わると案内が出るので、別のターミナルでプロジェクト直下から実行する。

```bash
scripts/devflow-implement.sh
# または
pwsh -NoProfile -File scripts/devflow-implement.ps1 [-MaxIterations 40] [-ContextThreshold 50] [-Model <model>]
```

- `claude -p "/dev-flow auto"` を繰り返し起動する。各セッションは state.json と `.devflow/handoff.md` を読んで続きから再開する
- 各タスクは `tdd-implementer` サブエージェントが TDD で実装し、`scripts/devflow-commit.ps1` でコミットする
  (Red はテストが失敗すること、Green / Refactor は全テストが成功することを、スクリプトが実際にテストを実行して確認する)
- コンテキスト使用率が閾値 (既定 50%) を超えると、handoff.md を書いてコミットし、セッションを切り替える
- 全タスクが終わると検証フェーズに進み、漏れがあれば追加タスクを作って実装に戻る。漏れゼロ (または残りが blocked のみ) で終了する
- 終了コード: 0 = 完了 / 2 = フェーズが実装・検証でない / 3 = 進捗なしで停止 / 4 = 最大反復回数に到達
- ログ: `.devflow/logs/loop.log`、各セッションの JSON 出力 `.devflow/logs/session-NNN.json`

**注意:** 既定では `--permission-mode bypassPermissions` で起動する (無人で git・テスト・ファイル編集を行うため)。
信頼できるリポジトリで、できればコンテナや専用の作業環境で実行すること。変える場合は `.devflow/config.json` の `claudeArgs` を編集する。

### 途中から再開する

- **対話フェーズ**: `claude` を起動して `/dev-flow` (または何か一言。SessionStart フックが進行中のフェーズを知らせる)。
  `.devflow/decisions/<phase>.md` から再開する
- **実装・検証**: `scripts/devflow-implement.sh` をもう一度実行するだけ。in_progress のタスクと handoff.md から続ける
- 状況の確認: `/dev-flow status`、または `pwsh -NoProfile -File scripts/devflow-state.ps1 impl-status`

### フェーズをやり直す

```
/dev-flow redo requirements
```

影響の説明と確認のあと、`devflow-state.ps1 set-phase <phase>` で指定フェーズに戻る。成果物は消さず、そのフェーズの手順で更新する。
やり直したフェーズより後の成果物は古くなるので、以降のフェーズも順に通し直す (`devflow-trace` が不整合を検出する)。

特定のタスクだけやり直す場合: `pwsh -NoProfile -File scripts/devflow-state.ps1 task TASK-007 todo`

### 検証レポートを読む

`docs/verification-report.md`:

| 節 | 見るべきこと |
|----|--------------|
| 1. 網羅状況 | `devflow-trace -Mode full` の漏れ件数が 0 か。詳細は `docs/traceability.md` (要件 → 設計 → タスク → テストの対応表) |
| 2. blocked のまま残ったタスク | 理由と「必要な判断」。判断して設計を直したら、タスクを `todo` に戻してループを再実行する |
| 3. 手動確認が必要な項目 | `manual` 種別の ID。人が確認する |
| 4. 監査で見つかって修正した漏れ | 監査 (implementation-auditor) が見つけ、追加タスクで実装した内容 |
| 5. 未解決の漏れ | 最大ラウンド超過や設計の不備で残ったもの |

## 構成

```
.claude/
  skills/dev-flow/
    SKILL.md                  # ルーター: state を読んで各フェーズの手順書を読み込む
    phases/01〜06-*.md        # 各フェーズの 入力 / 進め方 / 完了条件 / 出力テンプレート
    references/
      interview-rules.md      # 対話フェーズ共通の詰め方
      doc-structure.md        # 設計ドキュメントの分割ルール
      traceability.md         # ID の書式・粒度・検証方法・テストへの埋め込み・trace の検査項目
      design-guidelines.md    # 画面デザインの指針 (余白・文字・色・部品・状態・避けること・仕上げの確認)
      templates/              # 各成果物のテンプレート (28 種)
  agents/
    design-reviewer.md        # 詳細設計を実装者目線でレビュー
    screen-designer.md        # 画面デザインを HTML などで作成・修正 (文章の指示で修正)
    tdd-implementer.md        # 1 タスクを TDD で実装
    implementation-auditor.md # 設計とコードを突き合わせて漏れを検出
  hooks/
    session-start.ps1         # /clear 後の自動再開、自動ループの再開、compact 後の再読指示
    stop.ps1                  # 自動ループ: 作業が残っていれば継続、閾値超えなら引き継ぎを強制
    post-tool-use.ps1         # 自動ループ: コンテキスト使用率の監視と警告
    statusline.ps1            # 対話セッション: 使用率を .devflow/context-usage に書き出して表示
  settings.json
scripts/
  devflow-lib.psm1            # 共通ライブラリ
  devflow-state.ps1           # state.json / tasks/index.md の状態操作 (エージェントに手で書き換えさせない)
  devflow-trace.ps1 (.sh)     # ID の網羅性検証、traceability.md・index.md の ID 一覧・監査計画の生成
  devflow-commit.ps1          # TDD コミット規約の機械的な強制
  devflow-implement.ps1 (.sh) # 実装・検証の自動ループ
  devflow-install.ps1         # 対象プロジェクトへの導入
.devflow/                     # (対象プロジェクトに作られる)
  state.json                  # 現在フェーズ、完了フェーズ、実装・検証の進捗
  config.json                 # テストコマンド、閾値など (詳細設計で設定)
  decisions/<phase>.md        # 対話フェーズの決定ツリー
  handoff.md                  # セッション間の引き継ぎ
  blocked.md                  # 行き詰まったタスクの記録
  verification-log.md         # 検証ラウンドごとの漏れと追加タスク
  context-usage               # コンテキスト使用率 (git 管理外)
  logs/                       # ループのログ (git 管理外)
```

依頼時の案からの変更点:

- `.devflow/decisions/`: 対話フェーズの決定ツリーを都度保存する (compact・中断からの再開用)
- `.devflow/config.json`: テストコマンドと結果ファイルの場所 (trace がテスト結果から ID ごとの成否を読むため)
- `scripts/devflow-state.ps1`・`devflow-commit.ps1`: 状態更新と TDD コミットを、エージェントの注意力ではなくスクリプトで保証する
- `screen-designer` サブエージェント: 画面デザインを `docs/03-basic-design/designs/` に HTML などで書き出す (外部サービスを使わず、ブラウザで開くだけでプレビューできる。ファイル構成は自由で、入口は `index.html`)

## ID とトレーサビリティ

詳細は [.claude/skills/dev-flow/references/traceability.md](.claude/skills/dev-flow/references/traceability.md)。要点:

- ID は、見出しに `ID` と `検証` の列を持つ Markdown 表の 1 行として定義する。`上流` 列に上位の ID を書く
- 検証方法は `test` (原則) / `review` (監査がコードを読んで確認) / `manual` (最終レポートに列挙)
- テスト名に `[REQ-TODO-001]` の形で ID を入れる。trace は JUnit XML / TRX のテスト名から ID ごとの成否を判定する
- `devflow-trace.ps1 -Mode docs | design | full | task`。終了コード 0 = 漏れなし、1 = 漏れあり、2 = エラー

## 設定 (.devflow/config.json)

| キー | 既定値 | 意味 |
|------|--------|------|
| `contextWindowTokens` | 200000 | 使用率の分母。1M コンテキストのモデルでも、品質のため 200000 のままを推奨 |
| `contextThresholdPercent` | 50 | この使用率を超えたらセッションを切り替える |
| `minSessionWorkTokens` | 40000 | セッション開始時の使用量からこのトークン数以上進むまでは、閾値を超えても切り替えない (起動直後の固定分が閾値に近い環境で、何も進めずに引き継ぎだけを繰り返すのを防ぐ)。`autoCompactPercent` - 5 に達したら作業量にかかわらず切り替える |
| `maxNoProgress` | 2 | 進捗のないセッションがこの回数続いたら停止 (引き継ぎメモ・セッション数だけの変更は進捗とみなさない) |
| `maxIterations` | 40 | 自動ループの最大セッション数 |
| `maxVerificationRounds` | 3 | 検証ラウンドの上限 |
| `maxAttemptsPerTest` | 3 | 同じテストでこの回数失敗したら blocked |
| `autoCompactPercent` | 70 | `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` に渡す値 (閾値より前に自動 compact が走る場合の安全網) |
| `claudeArgs` | `["--permission-mode","bypassPermissions"]` | `claude -p` に渡す引数 |
| `test.command` | (詳細設計で設定) | 全テストを実行し結果ファイルを出すコマンド |
| `test.resultGlobs` | TRX / JUnit の典型パス | テスト結果ファイルの場所 |
| `test.files` / `source.files` | | テストコード / 本番コードの場所 |
| `idPrefixes` | REQ, NFR, ARC, SCR, TRN, API, ERR, EXT, DM, MOD, IF, VAL, EC, DBC, BR, TASK | ID として認識する接頭辞 |

一時的な上書き: 環境変数 `DEVFLOW_CONTEXT_THRESHOLD`、`DEVFLOW_CONTEXT_WINDOW`。

## Claude Code の仕様確認の結果と、それに合わせた設計

2026-09-25 時点の公式ドキュメント (code.claude.com/docs) と、Claude Code 2.1.282 の実機で確認した。

| 仕組み | 確認した仕様 | 採った設計 |
|--------|--------------|------------|
| スキル | `.claude/skills/<name>/SKILL.md`。frontmatter は `name`・`description`・`argument-hint` など。サブディレクトリの補助ファイルを相対リンクで参照できる。`/name` で呼べ、`-p` のプロンプトに `/name` を書いても展開される | SKILL.md はルーターだけにし、フェーズごとの手順書を `phases/` に分けて、必要なものだけ読み込む |
| SessionStart | `source` は `startup` / `resume` / `clear` / `compact` / `fork`。`hookSpecificOutput.additionalContext` で文脈を注入できる。`initialUserMessage` (最初の発言を自動で送る) は **`-p` 専用** | clear: 次フェーズの開始指示を注入する。compact: 手順書と決定ツリーの再読を指示する。自動ループ: handoff.md を注入する |
| Stop | `{"decision":"block","reason":...}` で停止をやめさせ、reason を Claude に渡せる。`{"continue":false}` で完全に停止。入力に `stop_hook_active`。**8 回連続でブロックすると強制的に終わる** | 自動ループでだけ動かす。作業が残っていれば続けさせ、閾値超えなら引き継ぎを強制する。同じ状態のまま 3 回止まったら停止を許す (進捗なし) |
| PostToolUse | `additionalContext` を返せる | 自動ループで、ツール実行のたびに使用率を計算し、閾値超えを知らせる |
| ステータスライン | stdin の JSON に `context_window.used_percentage`・`context_window_size`・`total_input_tokens`・`current_usage`。`-p` で動くかは記載がない | 対話セッション用。自動ループでの監視はフックで行う (下記) |
| コンテキスト使用量 | フック入力の `transcript_path` (JSONL) の各 assistant 行に `message.usage` (`input_tokens`・`cache_creation_input_tokens`・`cache_read_input_tokens`) がある。サブエージェントの会話は別ファイル (`subagents/`) | 最新の assistant 行の 3 つの値の合計 ÷ `contextWindowTokens` を使用率とする |
| 自動 compact | `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1〜100、下げる方向のみ)、`DISABLE_AUTO_COMPACT` | 自動ループで安全網として 70 を設定する。切り替えは compact ではなくセッションの作り直しで行う (クリーンな状態から handoff で再開するため) |
| ヘッドレス | `claude -p`、`--output-format json` (結果に `session_id`・`total_cost_usd`・`num_turns`・`is_error`・`result`)、`--permission-mode` (`default`/`acceptEdits`/`plan`/`auto`/`dontAsk`/`bypassPermissions`)、`--resume`。`--bare` でなければ、プロジェクトのフック・スキル・エージェントを読み込む | `devflow-implement` が `claude -p "/dev-flow auto" --output-format json` を繰り返し起動する |
| サブエージェント | `.claude/agents/<name>.md` (frontmatter: `name`・`description`・`tools`・`model` など)。Agent ツールで起動する。`-p` では fork モードが無効。`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` で常に前面実行になる | 自動ループではこの環境変数を設定し、実装担当の完了を待ってから次に進むようにする |
| 画面デザイン | (当初は Claude Design を Artifact ツールの Design 型で操作する方式で作り、動作も確認した。トークン消費が大きく、成果物が claude.ai 上に置かれるため取りやめた) | `screen-designer` サブエージェント (メイン会話と同じモデル) がローカルに HTML などを書き出す (構成は自由)。デザインの質は `references/design-guidelines.md` (デザイン指針と仕上げの確認項目) で担保する。修正は文章で指示し、ブラウザで入口の `designs/index.html` や各ファイルを開いて確認する |
| フックの実行シェル | Windows の既定は Git Bash。`args` を指定すると exec 形式 (シェルを介さない) になり、`${CLAUDE_PROJECT_DIR}` が引数ごとに展開される | `"command": "pwsh", "args": ["-NoProfile","-File","${CLAUDE_PROJECT_DIR}/.claude/hooks/x.ps1"]` の形にして、OS やシェルに依存しないようにした |

### 実現できなかった点と代替案

| 依頼内容 | 制約 | 代替案 (実装済み) |
|----------|------|-------------------|
| `/clear` 後、スキル名を打たなくても次フェーズが **自動で** 始まる | 対話モードでは SessionStart フックから最初の発言を送れない (`initialUserMessage` は `-p` 専用) | 次フェーズの開始指示を注入しておき、ユーザーが送る **任意の一言** (「続けて」など) を開始の合図にする |
| ステータスラインの使用率で 50% 超を検知する | ステータスラインは端末の画面表示用で、`-p` で動く保証がない | PostToolUse / Stop フックが transcript の usage から使用率を計算し、`.devflow/context-usage` にも書き出す。ステータスラインも対話セッションでは同じファイルに書く |
| Stop フックでセッションを終了させる | Stop フックは「止まるのを止める」ことはできるが、止まっていない (作業中の) 会話を途中で切ることはできない | PostToolUse フックがツール実行ごとに閾値超えを知らせ、区切りのよいところで handoff を書いて止まらせる。Stop フックは「引き継ぎが済むまで止まらせない」ことを保証する |
| 1 セッション内で全タスクを連続処理 | Stop フックのブロックは 8 回連続で強制解除される | 8 タスク程度でセッションが区切られても、外部ループが次のセッションを起動するので問題にならない |
