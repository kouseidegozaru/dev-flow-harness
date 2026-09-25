# フェーズ 3: 基本設計

## 入力

- `docs/01-vision.md`
- `docs/02-requirements/` — まず `index.md` を読み、必要なファイルだけを読む

## 最初に読むもの

- [../references/interview-rules.md](../references/interview-rules.md)
- [../references/doc-structure.md](../references/doc-structure.md)
- [../references/traceability.md](../references/traceability.md)
- テンプレート (`../references/templates/`): `basic-design-index.md`、`architecture.md`、`screens-index.md`、`screen.md`、
  `design-spec.md`、`data-model.md`、`api-index.md`、`api-resource-basic.md`、`error-policy.md`、`decisions.md`

## 進め方

1. `pwsh -NoProfile -File scripts/devflow-state.ps1 start-phase`
2. `.devflow/decisions/basic-design.md` があれば読んで再開する。なければ作り、下の論点を登録する
3. interview-rules.md に従い、1 問ずつ詰める。順序の目安:

   | 順 | 論点 | 成果物 | ID |
   |----|------|--------|----|
   | 1 | システム構成 (レイヤ、プロセス、配置、主要ライブラリの役割) | architecture.md | ARC |
   | 2 | 画面一覧と画面遷移 (CLI なら「コマンドごとの出力画面」を画面とみなす) | screens/index.md | SCR, TRN |
   | 3 | 各画面の目的・表示要素・状態 (通常/空/エラー/ローディング)・操作・トーン | screens/<SCR-ID>.md | SCR-xxx-E/S/A |
   | 4 | 画面デザイン (screen-designer、下の「画面デザインの手順」) | designs/、design-spec.md | — |
   | 5 | データモデル (エンティティ、属性、関連、ライフサイクル) | data-model.md | DM |
   | 6 | API / 公開インターフェース一覧 (HTTP、CLI コマンド、ライブラリ関数) | api/index.md、api/<resource>.md | API |
   | 7 | 外部インターフェース | architecture.md または api/ | EXT |
   | 8 | エラー方針 (分類、利用者への見せ方、ログ、リトライ、整合性) | error-policy.md | ERR |

4. すべての ID に検証方法と、対応する要件 ID (`上流` 列) を付ける。要件 ID ごとに「どの設計 ID で実現するか」を
   `index.md` の対応表に書く。どの設計にも対応しない要件があれば、設計の漏れか要件の誤りかをユーザーに確認する
5. 5 問ごとに「決定済み / 未決定」の一覧を提示する
6. 成果物を書き、次を実行して exit 0 にする (REQ-NOT-COVERED の警告は、詳細設計で扱う非機能要件などに限って残してよい。
   その場合は index.md の対応表に「詳細設計で対応」と書く):

   ```bash
   pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode docs -UpdateIndexes
   ```

7. `index.md` と各ファイルの要約を提示し、明示的な承認を得る

## 画面デザインの手順 (screen-designer サブエージェント)

画面デザインは、**`screen-designer` サブエージェントがローカルに書き出す HTML** (と必要な CSS・JavaScript・画像など) で作る。外部サービスは使わない。
生成・修正はサブエージェントに任せ、このセッションには生成したファイルの中身を読み込まない (メインのコンテキストを節約するため)。

成果物はすべて `docs/03-basic-design/designs/` に置く。**ファイルの構成は自由** (共通ファイル、部品、画像、サブディレクトリ、
1 ページに複数状態を並べる形、クリックで遷移できる試作など、デザインに合った形でよい)。守るのは次の 4 点だけ:

| 決まり | 目的 |
|--------|------|
| オフラインで開ける (`designs/` の外を読み込まない) | どの環境でもそのままプレビューできる |
| 各状態を表す要素に `data-state-id="<状態ID>"` と `id="<状態ID>"` を付け、`<ファイル>#<状態ID>` で開ける | 画面 ID ↔ デザイン対応表と監査で、状態を特定する |
| 画面仕様の各要素に `data-id="<ID>"` を付ける | 仕様への反映と監査で、要素を特定する |
| `designs/index.html` を入口のページにし、人が見るページと各状態へのリンクをすべて載せる | どこから見ればよいか迷わない (ユーザーは個々のファイルを直接開いてもよい) |

ファイル名・ディレクトリ名には、定義されていない ID の形の文字列を使わない (例 `SCR-010-normal.html` は trace が未定義参照として検出する)。

### D1. デザインの指示書を作る

手順 3 で決めた画面一覧・画面遷移・各画面の目的/表示要素/状態/トーンから、`design-spec.md` の「作成指示」節を書く。
画面ごとに、描く状態 (状態 ID) を列挙する。トーン (配色・書体・密度・言葉遣い) もここで決める (必要なら 1 問ずつ質問する)。

### D2. デザインを作る

`screen-designer` サブエージェントを起動し、ファイルの **パスだけ** を渡す:

> モード: create。画面仕様: docs/03-basic-design/screens/<SCR-ID>.md (全画面ぶん列挙)。
> デザイン指示書: docs/03-basic-design/design-spec.md の「作成指示」節。出力先: docs/03-basic-design/designs/

画面が多い場合 (目安 8 画面超) は、画面をいくつかに分けて複数回起動してよい (共通ファイルと `index.html` は最後の起動で整える)。
報告の `NOT-IN-SPEC` (仕様にない要素) は、画面仕様に ID を足すか、デザインから消すかをこの時点で決める。

### D3. ユーザーに見てもらい、文章の指示で修正する

1. 報告の `FILES` (作ったファイルと役割) を示し、入口の `docs/03-basic-design/designs/index.html` (または見たいファイル) をブラウザで開いてもらう。希望があれば開くコマンドを実行してよい
   (Windows: `Start-Process <path>`、macOS: `open <path>`、Linux: `xdg-open <path>`)
2. 修正は文章で受け取る。曖昧な指示は interview-rules.md に従って 1 点ずつ具体化する
   (「もう少しすっきり」→ どの画面のどの要素を、どうするか)
3. `screen-designer` を revise モードで起動し、修正指示 (具体化した文章) と対象ファイルのパスを渡す。
   文言 1 か所の差し替えのような小さな修正は、このセッションでファイルを直接編集してよい
4. 報告の `SPEC-DIFF` (仕様と食い違った点) は、画面仕様 (`screens/<SCR-ID>.md`) を修正して一致させる
5. 修正指示と判断理由を `design-spec.md` の「修正履歴」に 1 行ずつ追記する
6. ユーザーがデザインを明示的に承認するまで繰り返す

### D4. 画面 ID ↔ デザイン対応表

`screens/index.md` の「画面 ID ↔ デザイン対応表」に、画面 ID・状態・状態 ID・デザインの場所 (報告の `STATES` の `<ファイル>#<状態ID>`) を書く。
デザインのない画面状態、画面仕様にない状態のデザインがあってはならない。

### D5. デザインを画面仕様に反映する

サブエージェントの報告 (`STATES`・`ELEMENTS`・`NOT-IN-SPEC`・`SPEC-DIFF`) をもとに、`screens/<SCR-ID>.md` を更新して ID を付ける
(ファイルを読む必要があるときは `data-id` 属性で要素を Grep し、該当箇所だけを読む)。
**デザインにあって画面仕様にない要素、画面仕様にあってデザインにない要素をなくす。**

- 表示要素 (`SCR-xxx-Enn`): 見出し、一覧、各列/各項目、ボタン、入力欄、メッセージ、アイコン。表示条件・書式 (日付形式、桁区切り、切り詰め) を具体的に
- 状態 (`SCR-xxx-Snn`): 通常・空・エラー・ローディング・その他の状態。各状態の判定条件と表示内容
- 操作 (`SCR-xxx-Ann`): 各操作の契機 (クリック、キー、コマンド引数) と結果 (遷移先 TRN、呼ぶ API、表示の変化)
- 文言: 画面に出る文字列は一字一句そのまま書く (実装者が文言を決めずに済むように)
- 見た目 (色、余白、レイアウト) は原則 `review`。数値化できるもの (例:「期限切れは #B42318」) は具体的な値を書き、デザインの CSS の定義と一致させる

### D6. 判断理由の記録

`design-spec.md` に、作成指示・採用したトーンとその理由・検討して採用しなかった案・修正履歴を残す。

## 完了条件

- [ ] `.devflow/decisions/basic-design.md` に未決定ノードがない
- [ ] 全画面に、表示要素・状態 (通常/空/エラー/ローディングのうち該当するもの全部)・操作の ID がある
- [ ] 全画面状態にデザイン (`data-state-id` の付いた要素) があり、`screens/index.md` の対応表と `designs/index.html` から辿れる
- [ ] デザインから読み取れる文言・要素がすべて画面仕様に反映されている
- [ ] 全エンドポイント、全エラールールに ID がある
- [ ] すべての設計 ID に検証方法と上流の要件 ID がある
- [ ] 全要件 ID が、設計 ID から参照されているか、`index.md` の対応表で「詳細設計で対応」と明記されている
- [ ] `devflow-trace.ps1 -Mode docs -UpdateIndexes` が exit 0
- [ ] ユーザーが明示的に承認した (デザインと設計ドキュメントの両方)

## 終了

SKILL.md の「フェーズの終え方」に従う。phase 名は `basic-design`、コミットは `docs(basic-design): ...`。

## 出力テンプレート

| 出力 | テンプレート |
|------|--------------|
| `docs/03-basic-design/index.md` | `templates/basic-design-index.md` |
| `architecture.md` | `templates/architecture.md` |
| `screens/index.md` | `templates/screens-index.md` |
| `screens/<SCR-ID>.md` | `templates/screen.md` |
| `design-spec.md` | `templates/design-spec.md` |
| `data-model.md` | `templates/data-model.md` |
| `api/index.md` | `templates/api-index.md` |
| `api/<resource>.md` | `templates/api-resource-basic.md` |
| `error-policy.md` | `templates/error-policy.md` |
