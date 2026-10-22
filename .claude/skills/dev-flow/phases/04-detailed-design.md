# フェーズ 4: 詳細設計 (自動区間の最初)

基本設計の承認の後、**ユーザーに質問せずに** 実装フェーズまで続けて進める。このフェーズの成果物だけで、実装フェーズがユーザーへの質問なしに完了できる状態を作る。
設計は `detailed-designer` サブエージェントが書き、このセッション (オーケストレーター) は起動して待ち、機械の判定 (`devflow-trace -Mode design` の exit 0) だけを見る。
上流 (要件・基本設計) の抜けは、推奨が上流から決まるものは補って決定台帳に `仮` で、聞くべきもの (承認済みの決定を覆す・お金や法令・セキュリティで根拠がない・
推奨を決められない) は `要回答` で記録し、全タスク処理後の **最後の 1 回** (検証フェーズの debrief) でまとめて聞く。

## 役割分担

| 担当 | すること | 読むもの |
|------|----------|----------|
| オーケストレーター (このセッション) | 下の「オーケストレーターの手順」。設計担当・レビュー担当の起動、trace、出発前の確認 | 報告と、スクリプトの出力だけ (設計ファイルを読まない) |
| `detailed-designer` | 下の「設計担当の手順」 (規約・config・モジュール・データ・API・タスク・台帳) | 01〜03 の成果物 (`index.md` から必要なものだけ) とテンプレート |
| `design-reviewer` | タスクのまとまりごとに 1 回だけ、実装者が止まる・誤る点を挙げる | `.devflow/context/<TASK-ID>.md` と conventions.md |

## オーケストレーターの手順

1. `pwsh -NoProfile -File scripts/devflow-state.ps1 start-phase`、続けて `devflow-state.ps1 run start`
   (このセッションを自動区間のオーケストレーターとして登録する。Stop フックが、途中で応答を終えるのを防ぐ)。
   `.devflow/decisions/detailed-design.md` の「レビュー状況」に記録があれば、終わった手順を飛ばして続きから始める
2. `detailed-designer` を **前面で** 起動する (Agent ツールに `run_in_background: false`)。依頼文は 1 行だけ:

   > mode: create。phases/04-detailed-design.md の「設計担当の手順」で詳細設計を書け。

3. 報告の `STATUS` が `ng` (trace が exit 0 にならない) なら、`mode: fix、trace の出力: <報告の TRACE>` でもう 1 回だけ起動する。
   それでも ng なら、`devflow-state.ps1 run stop` を実行し、報告の要点をユーザーに伝えて止まる (`/dev-flow` で再開できる)
4. **レビュー (1 回だけ)** — `pwsh -NoProfile -File scripts/devflow-state.ps1 task-context all` で全タスクの読み物を書き出し
   (レビュー担当は Bash を持たない)、報告の `REVIEW-GROUPS` のまとまりごとに 1 体の `design-reviewer` を **並列で前面で** 起動する。依頼文:

   > 次のタスクを、`.devflow/context/<TASK-ID>.md` (タスクの読み物) と conventions.md だけを読んでレビューせよ: <タスク ID の列挙>。
   > 実装者が作業を止める、または設計と違う実装をしてしまう点だけを挙げよ。

   全員の報告を、まとまりごとの見出しを付けて `.devflow/review/detailed-design.md` にそのまま書き、`.devflow/decisions/detailed-design.md` の
   「レビュー状況」表 (まとまり / タスク ID / 指摘件数 / 反映済みか) に記録する。**再レビューはしない**
5. 指摘があれば `detailed-designer` を `mode: reflect` で起動して反映させる (指摘が 0 件なら飛ばす)。「レビュー状況」を反映済みにする
6. `pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode design -UpdateIndexes` が exit 0 であることを自分で確かめる
   (exit 1 なら手順 3 と同じく `mode: fix` で 1 回だけ直させる)
7. 完了する:

   ```bash
   pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase detailed-design
   pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind docs -Scope detailed-design -Message '<タスク N 件、仮 n 件、要回答 m 件>'
   ```

   クラウドのセッションでは続けて `git push` する (PR はまだ作らない)
8. **出発前の確認** (ここを過ぎると全タスク処理後まで止まらないので、止まる原因になる環境の不備をここで全部出す):

   ```bash
   pwsh -NoProfile -File scripts/devflow-state.ps1 preflight -Departure
   ```

   テスト・受け入れテストのコマンド、`test.setupCommand` の実行、git の利用者名、デプロイの秘密の値を確かめる。
   - exit 0: 出力に `BLOCK:` の行 (台帳の `要回答` が止めるタスク) があれば、そのタスクごとに
     `devflow-state.ps1 task <ID> blocked -Reason '要回答 <DEC>: 最後の 1 回で聞く'` を実行してから、まとめて
     `devflow-commit.ps1 -Kind chore -Scope detailed-design -Message '要回答のタスクを止める'`。他のタスクはそのまま進める
   - exit 1 で、足りないのが **デプロイの秘密の値だけ** のとき: AskUserQuestion で 1 回だけ聞く
     (「値を入れてから続ける」/「デプロイなしで先に進める (推奨: 実装・検証は進め、デプロイだけ未実施で終わる)」)。
     先に進めるなら `preflight -Departure -AllowMissingSecrets` をもう一度実行して続ける
   - それ以外の exit 1: `devflow-state.ps1 run stop` を実行し、出力をそのままユーザーに伝えて止まる (直したら `/dev-flow` で再開)
9. 続けて [05-implementation.md](05-implementation.md) を読み、このセッションで実装フェーズを手順 2 から実行する
   (`preflight` は済んでいる。ユーザーへの報告はしない)

## 設計担当の手順 (detailed-designer)

最初に [../references/doc-structure.md](../references/doc-structure.md)、[../references/traceability.md](../references/traceability.md)、
[../references/interview-rules.md](../references/interview-rules.md) の §2 と §10、テンプレート (`../references/templates/`):
`detailed-design-index.md`、`conventions.md`、`module.md`、`db-schema.md`、`db-migrations.md`、`api-resource-detailed.md`、`tasks-index.md`、`task.md`、`config.json` を読む。
入力は `docs/01-vision.md`、`docs/02-requirements/`、`docs/03-basic-design/` (いずれも `index.md` から必要なファイルだけ) と、台帳 `.devflow/decisions/ledger.md`。
決定ツリー `.devflow/decisions/detailed-design.md` に進み具合を記録し、中断から再開できるようにする。

1. **規約を決める** (`conventions.md`): コーディング規約、命名、ディレクトリ構成、テスト方針 (単体/結合の範囲、テストダブルの方針、
   テストデータ)、**テストへの ID 埋め込み形式** (traceability.md §6 に従い、テスト名に `[ID]` を含める具体的な書き方)、
   コミット規約 (phases/05 の TDD コミット)、ビルド・テスト・実行のコマンド。
   **受け入れテスト** の書き方も決める: `tests/acceptance/` に、公開の入口 (CLI・HTTP・公開関数) から、テスト名を `[AT][REQ-…] …` にして書く。
   要件の受け入れ例の印の値は、アサーションの **期待値側** (`expect(x).toBe(値)`、`assert.strictEqual(実際, 値)`、`Assert.Equal(値, 実際)`、`assert 実際 == 値`) に、
   そのまま (または同じファイルの定数経由で) 書く。テスト名・コメント・Given の行に書いただけでは照合されない。否定印 (`!値`) は否定のアサーション
   (`.not.`、`assert.notStrictEqual`、`assertNot…`、`Assert.NotEqual`) に書く。
   conventions.md は全実装担当が最初に必ず読むので、**全タスクに共通することだけを 10KB 程度に収める**。
   一部のタスクだけに要る決まり (画面の部品の使い方、DB のテストの書き方など) は、モジュールの設計などの節に書いて、タスクの「参照すべき設計」から指す
2. **`.devflow/config.json` を書く** (`templates/config.json`): `test.command`、`test.resultGlobs`、`test.files`、`source.files`、
   `acceptance.files` (受け入れテストの場所。`test.command` がこれも実行すること)、`test.setupCommand` (依存の取得など、出発前に 1 回だけ実行する準備。なければ空)。
   プロジェクトの雛形 (ソリューション/パッケージ定義、テストプロジェクト、1 本のサンプルテスト) を作り、
   サンプルテストの名前に ID が入った状態で `test.command` を実行し、結果ファイルに ID 付きのテスト名が出ることを確かめる。
   確かめたらサンプルテストは消す (雛形の作成はタスク TASK-001 としてもよいが、その場合もこの確認は今行う)。
   続けて、基本設計の `architecture.md`「デプロイ」節に従い `deploy.targets` を書く (「なし」なら空のまま)。
   デプロイは検証の後に **確認なしで自動で** 実行されるので、次を守る:
   - 1 行 = 1 環境。上から順に実行され、前の環境が成功したときだけ次へ進む (ステージングを本番より前に置く)
   - 操作手段が MCP・Git 連携の環境は `kind: "agent"` にし、`steps` に、デプロイフェーズのオーケストレーターが行う手順を 1 行 1 操作で書く
     (使う MCP のツール名、待つ状態、公開した URL の取り出し方。サービス間で受け渡す設定値があれば、その読み出しと書き込みも先頭に入れる)。
     `requiredMcp` に使うツールの接頭辞 (例: `mcp__Vercel__`) を、`rollbackSteps` に切り戻しの手順を書く。
     オーケストレーターは `steps` に書いた操作しかしないので、判断の要らない具体的な手順にする
   - 操作手段が CLI の環境は `kind` を省き (`command`)、`command` はデプロイだけを行って終わったら終了する (対話の入力待ちにしない)。
     `rollbackCommand` は直前の状態に戻す。秘密の値 (トークンなど) は書かず、`requiredEnv` に環境変数名だけを書く
     (値は環境変数になければ、デプロイフェーズで `devflow-deploy.ps1` が vault から取り出してコマンドに渡す)
   - 基本設計の「秘密の値の置き場所」に従い `deploy.vault` を書く: `name`、`getCommand` (値を標準出力に出す。`{name}` が秘密の値の名前になる)、
     `setCommand` (標準入力の値を保存する)、`requiredEnv` (vault の認証に使う環境変数)、`installCommand` (CLI がないときに入れる)。
     `deploy.secrets` には、秘密の値ごとに `name` と `source` (エージェントが MCP・CLI で読み出す手順。読み出せないなら「ユーザーが vault に入れる」) を書く
   - `smokeCommand` は公開した環境が動いていることを確かめ、失敗なら 0 以外で終了する。秘密の値が要らない形 (公開 URL への HTTP など) にする。
     どのコマンド・手順もここでは **実行しない** (本番が変わるため)
   - デプロイ・確認・切り戻しに使うスクリプトや設定ファイル (Dockerfile、デプロイ先の設定など) を作る必要があれば、タスクにする
   - そのサービスの MCP が自分のツールにあれば (設計担当はメイン会話の MCP を引き継ぐ)、ユーザーの手間を減らすために使う: 準備 (プロジェクトの作成、Git 連携、ドメインの設定など) のうち、
     `architecture.md` の「ユーザーが一度だけする作業」に入っていないものをここで済ませ、決定ツリーに記録する。
     読み出した秘密の値は、vault (`devflow-deploy.ps1 set-secret`) か設定先のサービスにだけ書き、リポジトリ (コード・`docs/`・コミット) には書かない
3. **モジュール構成** (`modules/<module>.md`): 責務、依存方向、公開インターフェース。各インターフェースに ID (`IF-<module>-<連番>`) を振り、
   シグネチャ (引数・戻り値・例外の型)、事前条件、事後条件、処理手順、エラー時の振る舞いを書く
4. **データ** (`db/schema.md`、`db/migrations.md`): テーブル・列・型・制約 (各制約に `DBC-*`)、インデックス、初期データ、マイグレーション手順。
   ファイル保存などの場合も、保存形式と制約をここに書く
5. **API の入出力詳細** (`api/<resource>.md`): 入力スキーマ、各バリデーションルール (`VAL-*`)、出力スキーマ、各エラーコード (`EC-*`)、
   業務ルール・計算ロジック (`BR-*`)。基本設計の API ID を上流に書く
6. **タスク分解** (`tasks/index.md`、`tasks/<TASK-ID>.md`):
   - 粒度: 1 タスク = TDD の 1〜数サイクルで完了し、単独でコミット可能
   - 依存順に並べる。先頭は雛形・共通基盤。依存は `tasks/index.md` の `依存` 列とタスクファイルの `依存` 行の両方に同じものを書く
   - 各タスクファイルの必須項目は `templates/task.md` のとおり。特に:
     - **設計ファイルに書いたことをタスクファイルに写さない** (シグネチャ、処理手順、文言、書式、エラー表、README の本文など)。
       タスクファイルに書くのは、目的・担当ID・参照すべき設計 (節)・作成・変更するファイル・テストケース・完了条件だけ
     - 参照すべき設計: `templates/task.md` の書き方 (1 行 1 ファイル、節は「見出し」、ID はそのまま) で指す。
       実装者とレビュー担当は、`devflow-state.ps1 task-context <TASK-ID>` がここから機械的に切り出して `.devflow/context/<TASK-ID>.md` に書き出した読み物だけを読む。
       **実装者はその読み物と conventions.md だけで実装できること**。読み物は `taskContextBudgetKB` (既定 40KB) 以内
       (超えたら参照を節・ID に絞るか、タスクを分ける。画面デザインの HTML は大きいので、そのタスクで作る状態の ID を書いて、その状態だけを切り出させる)
     - 作成・変更するファイル: パスだけをバッククォートで囲み、新しく作るファイルには「新規」と書く。
       他のタスクが新規に作るファイルを変更・利用するタスクは、そのタスクを依存に入れる。
       説明の中で関数名・ディレクトリ・他のタスクのファイルに触れるときは、括弧の中に書く (括弧の外のバッククォートは、
       完了時に存在を確かめる「作るファイル」として読まれる。説明のつもりの `src/server/data` で全タスクが止まったことがある)
     - テストケース一覧: 担当する `test` の ID ごとに 1 つ以上。入力と期待結果を具体的な値で書く (設計の文言そのものなら参照でよい)
     - 台帳の DEC の値をテストケースや説明に書いた行には `(DEC-…)` を書く (覆したとき、直す行として機械で見つかるように)
   - **受け入れテストのタスク** を機能領域ごとに 1 つ作る (`TASK-AT-<領域の区分>`。要件ごとではない)。担当ID はその領域の、受け入れ例 (Then の印) のある `test` の要件 ID。
     依存はその領域の要件を実装するタスク全部 (実装済みの機能に公開の入口からテストを書くので、Red は求めない。`devflow-commit.ps1 -Kind acceptance` でコミットする)。
     作成するファイルは `tests/acceptance/<領域>.test.<拡張子>` など。テストケースは要件ごとに 1 行で、期待結果は「受け入れ例の印の値」と書けばよい
     (`task-context` が、担当の要件の定義行と印の一覧を読み物に添える)
   - 新しく作るタスクの状態は `todo`。`amend` (仕様の変更) では done のタスクを開き直さず、差分を実装する新しいタスクを足す。
     やり直し (`redo`) で既存のタスクがあるときは、状態を次のように決める
     (全部を todo に戻すと実装済みの分まで作り直しになり、全部を残すと変更が実装されないため):
     - タスクファイルの内容 (担当ID・作成・変更するファイル・テストケース・完了条件) を変えたタスクと、
       「参照すべき設計」の節の中身を変えたタスクは、`devflow-state.ps1 task <ID> todo` で todo に戻す
     - どちらも変えていない done のタスクは done のまま残す。blocked のタスクは、原因を設計で解消したときだけ todo に戻す
     - 不要になったタスクは、タスクファイルと index の行を消す (実装済みのコードは、置き換えるタスクの中で消す)
7. **網羅性ゲート** — 次を exit 0 になるまで繰り返す:

   ```bash
   pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode design -UpdateIndexes
   ```

   未割り当て (NOT-ASSIGNED)、要件の未被覆 (REQ-NOT-COVERED)、テストケース不足 (TASK-NO-TESTCASE) などを、タスクや設計の追加・修正で解消する。
   実装フェーズで止まらないための検査もここで通す:
   - TASK-DEP-MISSING (他のタスクが新規に作るファイルを使うのに依存にない) → 依存を足す
   - TASK-REF-NOT-FOUND (参照先の見出し・ファイルがない) → 参照を実在する見出しに直す
   - TASK-CONTEXT-LARGE (読み物が上限超え) → 参照を絞るか、タスクを分ける
   - 警告 TASK-DEP-SUSPECT (参照する ID を依存にないタスクが実装する) → 1 件ずつ見て、前提として使うなら依存を足す。
     後のタスクの仕様を参考に読むだけなら、その参照を外す (実装者が「まだないもの」を使おうとして止まる原因になる)
   - DEC-UNCITED (台帳の照合に当たるのに DEC を書いていない行) → その行に `(DEC-…)` を書く。別の意味なら `DEC 対象外: DEC-…`
   - EXAMPLE-CHANGED (承認した受け入れ例の値が変わった) → 要件の例を元に戻す (変える必要があるなら `要回答` にする)
   (設計全体を読ませる ID 抜けの確認は行わない。ID 抜けはタスクのレビューで見つける)
8. **上流の抜けと判断の記録** — 設計中に見つけた上流 (要件・基本設計) の抜けは、次の 2 つに分ける (ユーザーには聞かない):
   - **自分で補う**: 承認済みの要件・決定・類似の画面や API の扱いから推奨が決まるもの (画面の状態・文言・エラー表示・0 件や境界の表示、
     API のエラーコードの割り当て、上流どうしの言葉の食い違いの統一など)。推奨どおりに上流ドキュメントと詳細設計を直し、
     台帳に `仮` の行を足す (`ledger add -Kind 仮 -Basis <上流の ID>`)。値を書いた行に `(DEC-…)` を書く。照合の書けない「形」の補いは、
     決定ツリーの「上流を補った決定」表 (指摘 / 決めたこと / 根拠 / 直したファイル) に書く
   - **要回答**: 承認済みの要件・決定を覆す / 料金・お金の計算・法令・セキュリティ・個人情報・外部サービスの契約に関わり、上流に根拠がない /
     同等の案が複数あって推奨を決める根拠がない。推奨を設計とタスクに入れたうえで、`ledger add -Kind 要回答 -Basis '<関わるタスク ID>'` で記録する
     (オーケストレーターが出発前にそのタスクだけを blocked にし、最後の 1 回でユーザーに聞く)
9. `devflow-trace.ps1 -Mode design -UpdateIndexes` を exit 0 にして、報告する (`.claude/agents/detailed-designer.md` の「報告の形式」)。
   `REVIEW-GROUPS` には、タスクを主に参照する設計ファイル (モジュールなど) ごとのまとまりに分けて書く (まとまりごとに 1 体のレビュー担当が起動される)

### mode: reflect (レビューの指摘の反映)

`.devflow/review/detailed-design.md` の指摘を、1 つずつ設計・タスクファイルに反映する (実装上の詳細、上流の意図から一意に決まるものは自分で決めて書く)。
上流に関わる指摘は手順 8 と同じく 2 つに分ける (補うなら `仮`、聞くべきなら `要回答`)。反映後に trace を exit 0 にして報告する。再レビューはない。

### mode: amend (仕様の変更の差分)

依頼の DEC (台帳の論点が `変更:` の行) と、オーケストレーターが 02 に足した要件・受け入れ例を読み、次を足す
(設計で新たに決めた値は、通常どおり `仮` の行で台帳に載せる):
- 基本設計 (03) の差分 (画面・API・データモデルの行)。足した・変えた行に DEC を書き、`上流` に足した要件 ID を書く (書かないと trace が AMEND-NO-BASIC)
- 詳細設計 (04) の差分と、差分を実装する新しいタスク (done のタスクは開き直さない。新しいタスクの依存に、変更するファイルを作った done のタスクを入れる)。
  受け入れ例のある要件を足したら、その領域の受け入れテストのタスクも足す (`TASK-AT-<区分>2` など)
- trace を exit 0 にして報告する

## 完了条件

- [ ] `conventions.md` にテストへの ID 埋め込み形式と受け入れテストの書き方があり、`.devflow/config.json` の `test.command` で ID 付きのテスト結果が出ることを確かめた
- [ ] 受け入れ例のある機能領域ごとに受け入れテストのタスク (`TASK-AT-<区分>`) がある
- [ ] `architecture.md` の「デプロイ」節が「なし」でなければ、`deploy.targets` に全環境があり、使うスクリプト・設定ファイルを作るタスクがある
- [ ] 全インターフェース・バリデーション・エラーコード・DB 制約・業務ルールに ID、検証方法、上流 ID がある
- [ ] 全タスクファイルに必須項目がすべてあり、テストケースが担当 ID ごとに具体的な入力と期待結果を持つ
- [ ] `devflow-trace.ps1 -Mode design -UpdateIndexes` が exit 0 (台帳の照合・受け入れ例の lock を含む)
- [ ] 全タスクが design-reviewer のレビューを 1 回受け、指摘を設計に反映済み
- [ ] 上流を補った決定は台帳 (`仮`) か決定ツリーに、聞くべきものは台帳 (`要回答`) に記録済み
- [ ] `preflight -Departure` が exit 0 で、`要回答` のタスクを blocked にした

(このフェーズはユーザーの承認を求めない。完了条件はすべて機械とレビューで確認する)

## 出力テンプレート

| 出力 | テンプレート |
|------|--------------|
| `docs/04-detailed-design/index.md` | `templates/detailed-design-index.md` |
| `conventions.md` | `templates/conventions.md` |
| `modules/<module>.md` | `templates/module.md` |
| `db/schema.md`、`db/migrations.md` | `templates/db-schema.md`、`templates/db-migrations.md` |
| `api/<resource>.md` | `templates/api-resource-detailed.md` |
| `tasks/index.md` | `templates/tasks-index.md` |
| `tasks/<TASK-ID>.md` | `templates/task.md` (読み物は `devflow-state.ps1 task-context <TASK-ID>` で確かめる) |
| `.devflow/config.json` | `templates/config.json` |
