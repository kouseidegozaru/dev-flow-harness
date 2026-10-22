<#
.SYNOPSIS
  .devflow/state.json と tasks/index.md の状態を操作する。
  エージェントが JSON や表を手で書き換えずに済むよう、状態変更はすべてこのスクリプトで行う。

.EXAMPLE
  pwsh -NoProfile -File scripts/devflow-state.ps1 show
  pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase requirements
  pwsh -NoProfile -File scripts/devflow-state.ps1 next-task
  pwsh -NoProfile -File scripts/devflow-state.ps1 task TASK-003 done        # 完了の条件を確かめてから done にする
  pwsh -NoProfile -File scripts/devflow-state.ps1 task TASK-003 blocked -Reason "..."
  pwsh -NoProfile -File scripts/devflow-state.ps1 task-context TASK-003         # タスクの読み物を .devflow/context/TASK-003.md に書き出す (all で全タスク)
  pwsh -NoProfile -File scripts/devflow-state.ps1 check-branches               # ほかのブランチで dev-flow が進んでいないかを確かめる (exit 5 なら進んでいる)
  pwsh -NoProfile -File scripts/devflow-state.ps1 add-dep TASK-033 TASK-039 -Reason "..."   # 依存の漏れを直して後回しにする
  pwsh -NoProfile -File scripts/devflow-state.ps1 run start                # オーケストレーターの開始 (Stop フックが作業の途中で止まらないようにする)
  pwsh -NoProfile -File scripts/devflow-state.ps1 preflight -Departure     # 自動区間の出発前の確認 (テスト・受け入れテスト・準備のコマンド・秘密の値・git 利用者名)

  決定台帳 (.devflow/decisions/ledger.md) と覆し:
  pwsh -NoProfile -File scripts/devflow-state.ps1 ledger add -Kind 仮 -Topic 'CSV の文字コード' -Value 'UTF-8 BOM 付き' -Match 'BOM|efbbbf' -Basis 'REQ-EXP-003'
  pwsh -NoProfile -File scripts/devflow-state.ps1 ledger add -Kind C -Task TASK-007 -Topic '…' -Value '…' -Match '…'   # 実装担当の処置 (exit 4 = 要回答に格上げ)
  pwsh -NoProfile -File scripts/devflow-state.ps1 ledger check             # 台帳と docs/ の全行の照合 (DEC-UNCITED / DEC-STALE / 根拠)
  pwsh -NoProfile -File scripts/devflow-state.ps1 impact DEC-003           # 覆したときの影響 (引用行・照合当たり・担当タスク)。読み取りのみ
  pwsh -NoProfile -File scripts/devflow-state.ps1 override DEC-003 -Value 'UTF-8 (BOM なし)' -Match 'BOM なし' [-OldMatch '…'] [-Answered]
  pwsh -NoProfile -File scripts/devflow-state.ps1 amend -Topic '★評価の追加' -Value '…' -Match '★|評価' -Basis '「…」'   # 「形」の変更
  pwsh -NoProfile -File scripts/devflow-state.ps1 relock                   # 受け入れ例の lock を今の要件で書き直す (override / amend の後)
  pwsh -NoProfile -File scripts/devflow-state.ps1 debrief                  # 最後の 1 回に聞く一覧 (exit 3 = 回答済み)
#>
param(
    [Parameter(Position = 0)][string]$Command = 'show',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [string]$Reason = '',
    [switch]$Force,             # task <ID> done で完了の確認を飛ばす (人が手で状態を直すとき用)
    [switch]$KeepVerification,  # set-phase で検証ラウンドの記録を残す (検証フェーズから追加タスクの実装に戻るとき用)
    [switch]$Departure,         # preflight: 自動区間の出発前の確認 (詳細設計の後、実装の前に 1 回)
    [switch]$AllowMissingSecrets, # preflight -Departure: デプロイの秘密の値が足りなくても NG にしない (ユーザーが「デプロイなしで先に進める」を選んだとき)
    # 決定台帳 (ledger / override / amend)
    [string]$Kind = '',
    [string]$Topic = '',
    [string]$Value = '',
    [string]$Match = '',
    [string]$OldMatch = '',
    [string]$Basis = '',
    [string]$Task = '',
    [switch]$Answered,          # override: ユーザーが答えた (区分を確定にする。確定の決定を覆すときは必須)
    [switch]$Done               # debrief: 回答を反映し終えた
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'devflow-lib.psm1') -Force
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$root = Get-DevflowRoot
$config = Get-DevflowConfig $root

function Get-StateOrFail {
    $s = Read-DevflowState $root
    if (-not $s) { throw '.devflow/state.json がありません。`devflow-state.ps1 init` を実行してください。' }
    return $s
}

function Undo-TaskCommits([string]$TaskId, [string]$Base) {
    # blocked にするタスクの変更を取り消し、全テストが通る状態に戻す (失敗するテストが残ると、後続タスクが全部 Green にできなくなるため)。
    # タスク開始時点 ($Base) 以降の `<kind>(<TaskId>):` と `chore(handoff):` のコミットを新しい順に逆適用し、1 つのコミットにする
    # (作業途中の引き継ぎは chore(handoff) に入る。作業中のタスクは常に 1 件なので、その中身はこのタスクの変更だけ)。
    # .devflow/ と docs/ (状態・引き継ぎメモ・タスク一覧) は戻さない。戻り値: blocked.md に書く説明
    if (-not $Base) { return '作業の取り消し: タスク開始時点のコミットが記録されていないため、行っていない (失敗するテストが残っていれば人が戻すこと)' }
    $pat = '^((test|feat|refactor|fix|chore)\(' + [regex]::Escape($TaskId) + '\)|chore\(handoff\)):'
    $commits = @(& git -C $root log --format='%H %s' "$Base..HEAD" | Where-Object { $_ -and ($_.Substring(41) -match $pat) } | ForEach-Object { $_.Substring(0, 40) })
    if ($commits.Count -eq 0) { return '作業の取り消し: 取り消すコミットはなかった' }
    $patch = Join-DevflowPath $root '.devflow/logs/blocked-revert.patch'
    New-Item -ItemType Directory -Force -Path (Split-Path $patch) | Out-Null
    foreach ($h in $commits) {
        & git -C $root diff --binary "--output=$patch" "$h^" $h -- . ':(exclude).devflow' ':(exclude)docs'
        if ((Get-Item -LiteralPath $patch).Length -eq 0) { continue }
        & git -C $root apply -R --index $patch
        if ($LASTEXITCODE -ne 0) {
            & git -C $root reset -q --hard HEAD
            Remove-Item -LiteralPath $patch -Force
            return "作業の取り消し: コミット $($h.Substring(0, 7)) を逆適用できなかったため、行っていない (失敗するテストが残っていれば人が戻すこと)"
        }
    }
    Remove-Item -LiteralPath $patch -Force
    & git -C $root diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { return '作業の取り消し: 取り消す変更はなかった' }
    & git -C $root commit -q -m "revert(${TaskId}): blocked のため、このタスクの変更を取り消す"
    if ($LASTEXITCODE -ne 0) { throw '取り消しのコミットに失敗しました' }
    $rev = (& git -C $root rev-parse --short HEAD).Trim()
    $list = ($commits | ForEach-Object { $_.Substring(0, 7) }) -join ', '
    return "作業の取り消し: このタスクのコミット $($commits.Count) 件 ($list) を $rev で取り消した。作業を復元するには ``git revert $rev``"
}

function Add-TaskIndexRow([string]$TaskId, [string]$Title, [string[]]$Deps) {
    # tasks/index.md のタスクの表の末尾に todo の行を足す
    $path = Get-TasksIndexPath $root
    $lines = [System.Collections.Generic.List[string]]((Read-Utf8 $path) -split "`r?`n")
    $tb = Get-MdTables $path | Where-Object { (Get-ColumnIndex $_.Headers @('ID')) -ge 0 -and (Get-ColumnIndex $_.Headers @('状態', 'Status')) -ge 0 } | Select-Object -Last 1
    if (-not $tb) { throw 'tasks/index.md にタスクの表がありません' }
    $cells = foreach ($h in $tb.Headers) {
        switch -Regex ($h) { '^ID$' { $TaskId } '^(タイトル|Title)$' { $Title } '^(依存|Deps)$' { if ($Deps.Count) { $Deps -join ', ' } else { '-' } } '^(状態|Status)$' { 'todo' } default { '-' } }
    }
    $after = if ($tb.Rows.Count -gt 0) { $tb.Rows[$tb.Rows.Count - 1].No } else { $tb.No + 1 }
    $lines.Insert($after, '| ' + (($cells | ForEach-Object { ([string]$_).Replace('|', '\|') }) -join ' | ') + ' |')
    Write-Utf8 $path (($lines -join "`n"))
}

function New-CompensationTask($Row, [string]$OldValue, $Impact, $DoneTasks) {
    # 覆しの補償タスク TASK-C-<DEC>-v<版>: done のタスクの成果 (コード・テスト) を新しい値に直す。1 回の覆しにつき 1 つ
    $tid = "TASK-C-$($Row.Dec)-v$($Row.Version)"
    $defIdx = Get-IdDefinitionIndex $root $config
    $doneIds = @($DoneTasks | ForEach-Object { $_.Id })
    $assignedOfDone = @($DoneTasks | ForEach-Object { Get-TaskAssignedIds $root $config $_.Id } | Select-Object -Unique)
    $ids = @($Impact.Ids | Where-Object { $assignedOfDone -contains $_ })
    if ($ids.Count -eq 0) { $ids = @($assignedOfDone | Where-Object { $defIdx.ById.ContainsKey($_) -and $defIdx.ById[$_].Verify -eq 'test' }) }
    $files = [ordered]@{}
    foreach ($t in $DoneTasks) {
        $tf = Join-DevflowPath $root "docs/04-detailed-design/tasks/$($t.Id).md"
        foreach ($e in Get-TaskFileEntries (Get-MdSection $tf '作成・変更するファイル')) { $files[$e.Path] = $t.Id }
    }
    $refs = [ordered]@{}
    foreach ($i in $ids) { if ($defIdx.ById.ContainsKey($i)) { $f = $defIdx.ById[$i].File; if (-not $refs.Contains($f)) { $refs[$f] = @() }; $refs[$f] += $i } }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# ${tid}: $($Row.Dec) の覆し ($($Row.Topic)) を実装に反映する").AppendLine()
    [void]$sb.AppendLine('| 項目 | 値 |').AppendLine('|------|----|')
    [void]$sb.AppendLine("| ID | $tid |").AppendLine("| 依存 | $($doneIds -join ', ') |").AppendLine("| 担当ID | $($ids -join ', ') |").AppendLine()
    [void]$sb.AppendLine('## 目的').AppendLine()
    # 旧い値はここに書かない (書くと、この行が DEC-STALE になる)。旧い値は台帳の旧照合と git の履歴にある
    [void]$sb.AppendLine("決定台帳の $($Row.Dec) が版 $($Row.Version) で「$($Row.Value)」に変わった (前の版の値は台帳の旧照合に当たるもの)。done のタスク ($($doneIds -join ', ')) のテストの期待値とコードを新しい値に直す")
    [void]$sb.AppendLine('(設計の変更に合わせた期待値の変更なので、「期待値を実装に合わせて書き換える」禁止には当たらない。先にテストの期待値を新しい値にして Red を確かめる)。').AppendLine()
    [void]$sb.AppendLine('## 参照すべき設計').AppendLine()
    foreach ($f in $refs.Keys) { [void]$sb.AppendLine("- ``$f`` $($refs[$f] -join ', ')") }
    foreach ($d in $doneIds) { [void]$sb.AppendLine("- ``docs/04-detailed-design/tasks/$d.md``") }
    [void]$sb.AppendLine().AppendLine('## 作成・変更するファイル').AppendLine()
    foreach ($f in $files.Keys) { [void]$sb.AppendLine("- ``$f`` (変更: $($files[$f]) の成果を新しい値に直す)") }
    [void]$sb.AppendLine().AppendLine('## テストケース').AppendLine()
    [void]$sb.AppendLine('| # | 検証する ID | 前提・入力 | 期待結果 |').AppendLine('|---|-------------|------------|----------|')
    $n = 0
    foreach ($i in $ids) {
        $n++
        $owner = @($DoneTasks | Where-Object { (Get-TaskAssignedIds $root $config $_.Id) -contains $i } | ForEach-Object { $_.Id }) -join ', '
        [void]$sb.AppendLine("| $n | $i | $owner のテストケースのうち $($Row.Dec) の値を使うもの | 期待値を「$($Row.Value)」にしたもの (前の版の値は出ない) |")
    }
    [void]$sb.AppendLine().AppendLine('## 完了条件').AppendLine()
    [void]$sb.AppendLine('- [ ] テストケースがすべてテスト (テスト名に ID 付き) として実装され、通っている').AppendLine('- [ ] 全テストが通っている')
    [void]$sb.AppendLine("- [ ] コードとテスト (受け入れテスト tests/acceptance/ を含む) に、台帳の $($Row.Dec) の旧照合に当たる値が残っていない")
    Write-Utf8 (Join-DevflowPath $root "docs/04-detailed-design/tasks/$tid.md") $sb.ToString()
    Add-TaskIndexRow $tid "$($Row.Dec) の覆しの反映 (版 $($Row.Version))" $doneIds
    return $tid
}

function Get-ImplStatus {
    $tasks = @(Read-TaskIndex $root $config)
    $ready = Get-ReadyTask $tasks
    $counts = [ordered]@{}
    foreach ($st in Get-TaskStatuses) { $counts[$st] = @($tasks | Where-Object { $_.Status -eq $st }).Count }
    $remaining = @($tasks | Where-Object { $_.Status -ne 'done' }).Count
    $status = if ($tasks.Count -eq 0) { 'no-tasks' }
              elseif ($ready) { 'ready' }
              elseif ($remaining -eq 0) { 'complete' }
              else { 'stuck' }   # 残りは blocked か、blocked に依存するタスクのみ
    return [pscustomobject]@{
        status    = $status
        total     = $tasks.Count
        counts    = $counts
        nextTask  = if ($ready) { $ready.Id } else { $null }
        remaining = $remaining
    }
}

foreach ($pp in @($Match, $OldMatch) | Where-Object { $_ }) {
    # 台帳の表では照合をバッククォートで囲むため、照合の中にバッククォートは書けない (印の `…` を区別したいときは (?<!!) などで書く)
    if ($pp.Contains('`')) { throw "照合にバッククォート (``) は使えません: $pp (否定印 ``!…`` と区別するなら (?<!!)値 のように書く)" }
}

switch ($Command) {
    'init' {
        $existing = Read-DevflowState $root
        if ($existing) { Write-Output "state.json は既にあります (phase: $($existing.phase))"; break }
        Write-DevflowState $root (New-DevflowState)
        foreach ($f in 'handoff.md', 'blocked.md') {
            $p = Join-DevflowPath $root ".devflow/$f"
            if (-not (Test-Path -LiteralPath $p)) {
                $title = if ($f -eq 'handoff.md') { '# 実装担当の引き継ぎメモ' } else { '# 行き詰まったタスクの記録' }
                Write-Utf8 $p "$title`n"
            }
        }
        Write-Output 'state.json を作成しました (phase: vision)'
    }
    'show' {
        $s = Get-StateOrFail
        $s | ConvertTo-Json -Depth 10
    }
    'phase' {
        $s = Read-DevflowState $root
        if (-not $s) { Write-Output 'none' } else { Write-Output $s.phase }
    }
    'start-phase' {
        $s = Get-StateOrFail
        $s.phaseStarted = $true
        Write-DevflowState $root $s
        Write-Output "phase $($s.phase) を開始済みにしました"
    }
    'complete-phase' {
        $s = Get-StateOrFail
        if (-not $Arg1) { throw 'complete-phase <phase> の形式で、完了するフェーズ名を指定してください' }
        if ($s.phase -ne $Arg1) { throw "現在のフェーズは $($s.phase) です ($Arg1 ではありません)" }
        $s.completedPhases = @(@($s.completedPhases) + $Arg1 | Select-Object -Unique)
        $s.phase = Get-NextPhase $Arg1
        $s.phaseStarted = $false
        Write-DevflowState $root $s
        Write-Output "phase: $Arg1 → $($s.phase)"
        if ($Arg1 -in @('requirements', 'basic-design') -and (Test-Path -LiteralPath (Join-DevflowPath $root 'docs/02-requirements'))) {
            # 承認した受け入れ例を凍結する (以後、例の変更は override / amend を通して relock する)
            $n = Write-ExampleLock $root $config
            Write-Output "受け入れ例を凍結しました: .devflow/examples.lock.json (要件 $n 件)"
        }
    }
    'set-phase' {
        # フェーズのやり直し。指定フェーズ以降の完了記録を消す
        $s = Get-StateOrFail
        $order = Get-PhaseOrder
        if ($order -notcontains $Arg1) { throw "未知のフェーズ: $Arg1 (有効値: $($order -join ', '))" }
        $idx = [Array]::IndexOf($order, $Arg1)
        $s.completedPhases = @(@($s.completedPhases) | Where-Object { [Array]::IndexOf($order, $_) -lt $idx })
        $s.phase = $Arg1
        $s.phaseStarted = $false
        if ($KeepVerification) {
            # 検証ラウンドを閉じる (次の verification-round で新しいラウンドになる)
            $s.verification.roundOpen = $false
        } else {
            # 人によるやり直し: 検証の記録を初期化する (前回のラウンド数を持ち越すと、上限で即座に打ち切られるため)
            $s.verification = [ordered]@{ round = 0; roundOpen = $false; addedTasks = @() }
            $s.implementation.taskBase = [ordered]@{}
        }
        if ($idx -lt [Array]::IndexOf($order, 'deployment')) {
            # デプロイより前からのやり直し: デプロイの結果を消す (redo deployment では残し、成功済みのデプロイ先を飛ばさせる)
            $s.deployment = [ordered]@{ results = [ordered]@{} }
        }
        Write-DevflowState $root $s
        Write-Output "phase を $Arg1 に設定しました"
    }
    'impl-status' {
        Get-ImplStatus | ConvertTo-Json -Depth 5
    }
    'next-task' {
        $st = Get-ImplStatus
        if ($st.nextTask) { Write-Output $st.nextTask; exit 0 }
        Write-Output "NONE ($($st.status))"
        exit 3
    }
    'task' {
        # task <TASK-ID> <todo|in_progress|done|blocked> [-Reason ...]
        if (-not $Arg1 -or -not $Arg2) { throw 'task <TASK-ID> <status> の形式で指定してください' }
        if ((Get-TaskStatuses) -notcontains $Arg2) { throw "未知の状態: $Arg2" }
        if ($Arg2 -eq 'done' -and -not $Force) {
            # 完了の確認 (オーケストレーターは確認しないので、ここで機械的に保証する):
            # test(<ID>) と feat(<ID>) のコミットがあり、trace -Mode task (全テスト実行・ID のテスト名・スタブ検索) が exit 0
            $ng = @()
            # 受け入れテストのタスク (TASK-AT-*) は、実装済みの機能に公開の入口からテストを書くので Red がない。acceptance のコミットだけを求める
            $kinds = if ($Arg1 -like 'TASK-AT-*') { @('acceptance') } else { @('test', 'feat') }
            foreach ($k in $kinds) {
                $hit = @(& git -C $root log --oneline --fixed-strings --grep "$k($Arg1)" 2>$null | Where-Object { $_ })
                if ($hit.Count -eq 0) { $ng += "``$k($Arg1)`` のコミットがありません" }
            }
            # 後続のタスクの実装担当が、コードを探し回らずに済むよう、作ったものの要点を残させる
            $note = Join-DevflowPath $root ".devflow/notes/$Arg1.md"
            if (-not (Test-Path -LiteralPath $note) -or -not (Read-Utf8 $note).Trim()) {
                $ng += "実装メモ .devflow/notes/$Arg1.md がありません (templates/task-note.md の形で、後続のタスクが使う公開の名前・ファイル・注意点を書く)"
            }
            $traceOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'devflow-trace.ps1') -Mode task -Task $Arg1 2>&1
            if ($LASTEXITCODE -ne 0) { $ng += "devflow-trace -Mode task -Task $Arg1 が NG です:`n$(($traceOut | Select-Object -Last 30) -join "`n")" }
            if ($ng.Count -gt 0) {
                Write-Output "$Arg1 を done にできません:"
                $ng | ForEach-Object { Write-Output "- $_" }
                exit 1
            }
        }
        $s = Get-StateOrFail
        # タスク開始時点のコミット (blocked にしたとき、ここまで戻す)
        if (-not $s.implementation.Contains('taskBase') -or $null -eq $s.implementation.taskBase) { $s.implementation.taskBase = [ordered]@{} }
        $undoNote = ''
        if ($Arg2 -eq 'blocked') {
            $dirty = @(Get-UncommittedChanges $root $config)
            if ($dirty.Count -gt 0) {
                Write-Output "$Arg1 を blocked にできません: 未コミットの変更があります。先に ``devflow-commit.ps1 -Kind chore -Scope $Arg1 -Message ""WIP (blocked)""`` でコミットすること"
                exit 1
            }
            $undoNote = Undo-TaskCommits $Arg1 ([string]$s.implementation.taskBase[$Arg1])
        }
        $prev = @(Read-TaskIndex $root $config | Where-Object { $_.Id -eq $Arg1 } | ForEach-Object { $_.Status }) | Select-Object -First 1
        Set-TaskIndexStatus $root $config $Arg1 $Arg2
        if ($prev -eq 'blocked' -and $Arg2 -ne 'blocked') {
            # blocked の記録は追記のみなので、解除したことも残す (最終レポートに解消済みの blocked を載せないため)
            $p = Join-DevflowPath $root '.devflow/blocked.md'
            if (Test-Path -LiteralPath $p) {
                Write-Utf8 $p ((Read-Utf8 $p) + "`n## $Arg1 解除 ($((Get-Date).ToString('yyyy-MM-dd HH:mm'))) → $Arg2`n")
            }
        }
        if ($Arg2 -eq 'in_progress') {
            $s.implementation.currentTask = $Arg1
            if (-not $s.implementation.taskBase[$Arg1]) { $s.implementation.taskBase[$Arg1] = (& git -C $root rev-parse HEAD).Trim() }
        } else {
            if ($s.implementation.currentTask -eq $Arg1) { $s.implementation.currentTask = $null }
            if ($s.implementation.taskBase.Contains($Arg1)) { $s.implementation.taskBase.Remove($Arg1) }
        }
        if ($Arg2 -eq 'blocked') {
            $p = Join-DevflowPath $root '.devflow/blocked.md'
            $text = if (Test-Path -LiteralPath $p) { Read-Utf8 $p } else { "# 行き詰まったタスクの記録`n" }
            $text += "`n## $Arg1 ($((Get-Date).ToString('yyyy-MM-dd HH:mm')))`n`n$Reason`n`n$undoNote`n"
            Write-Utf8 $p $text
            Write-Output $undoNote
        }
        Write-DevflowState $root $s
        Write-Output "$Arg1 → $Arg2"
    }
    'task-context' {
        # task-context <TASK-ID> | all: 実装担当・レビュー担当がそのタスクで読むもの (タスクファイル + 参照すべき設計で指した節・ID の定義行
        # + 依存タスクの実装メモ) を 1 つにまとめ、.devflow/context/<TASK-ID>.md に書き出す。設計ファイルを探し回って読む量を抑えるため。
        # 標準出力には書き出し先と大きさだけを出す (Bash の出力の上限で読み物の後半が切れるのを避け、Read で読ませるため)。
        # all: tasks/index.md の全タスク分を書き出す (詳細設計のレビュー担当に Bash を持たせずに済むよう、レビューの前に実行する)
        if (-not $Arg1) { throw 'task-context <TASK-ID> | all の形式で指定してください' }
        $ids = if ($Arg1 -eq 'all') { @(Read-TaskIndex $root $config | ForEach-Object { $_.Id }) } else { @($Arg1) }
        foreach ($tid in $ids) {
            $ctx = Get-TaskContext $root $config $tid -WithNotes
            $text = $ctx.Text
            if ($ctx.Missing.Count -gt 0) {
                $text += "<!-- 見つからなかった参照 (必要なら index.md から探して読む) -->`n" + (($ctx.Missing | ForEach-Object { "<!-- - $_ -->" }) -join "`n") + "`n"
            }
            $rel = ".devflow/context/$tid.md"
            Write-Utf8 (Join-DevflowPath $root $rel) $text
            $kb = [math]::Round([System.Text.Encoding]::UTF8.GetByteCount($text) / 1024, 1)
            Write-Output "$rel ($kb KB$(if ($ctx.Missing.Count -gt 0) { "、見つからなかった参照 $($ctx.Missing.Count) 件" }))"
        }
        if ($Arg1 -ne 'all') { Write-Output 'このファイルを Read で読むこと (大きいときは offset / limit で分けて全部読む)' }
    }
    'add-dep' {
        # add-dep <TASK-ID> <DEP-ID> -Reason ...: 実装中に依存の漏れ (前提の成果物を作るタスクが依存にない) を見つけたとき、
        # 依存を足して todo に戻す (blocked にして人の判断を待たずに、依存先の完了後に自動で再開させる)。
        # 作業中なら、このタスクのコミットを blocked と同じく取り消す
        if (-not $Arg1 -or -not $Arg2) { throw 'add-dep <TASK-ID> <DEP-ID> の形式で指定してください' }
        $tasks = @(Read-TaskIndex $root $config)
        $t = $tasks | Where-Object { $_.Id -eq $Arg1 } | Select-Object -First 1
        $d = $tasks | Where-Object { $_.Id -eq $Arg2 } | Select-Object -First 1
        if (-not $t) { throw "tasks/index.md に $Arg1 がありません" }
        if (-not $d) { throw "tasks/index.md に $Arg2 がありません" }
        if ($t.Status -eq 'done') { throw "$Arg1 は done です" }
        if ($d.Status -eq 'done') { Write-Output "$Arg2 は done なので、依存を足す必要はありません (前提の成果物が無い原因は別にある)"; exit 1 }
        if ($d.Status -eq 'blocked') { Write-Output "$Arg2 は blocked です。足しても再開されないため、$Arg1 も blocked にすること (理由に「$Arg2 (blocked) の成果物が必要」と書く)"; exit 1 }
        if (Test-TaskDependsOn $tasks $Arg2 $Arg1) { Write-Output "$Arg2 は $Arg1 に (間接に) 依存しているため、足すと循環します。blocked にすること"; exit 1 }
        $dirty = @(Get-UncommittedChanges $root $config)
        if ($dirty.Count -gt 0) {
            Write-Output "依存を足せません: 未コミットの変更があります。先に ``devflow-commit.ps1 -Kind chore -Scope $Arg1 -Message ""WIP (依存の追加)""`` でコミットすること"
            exit 1
        }
        $s = Get-StateOrFail
        if (-not $s.implementation.Contains('taskBase') -or $null -eq $s.implementation.taskBase) { $s.implementation.taskBase = [ordered]@{} }
        $undoNote = Undo-TaskCommits $Arg1 ([string]$s.implementation.taskBase[$Arg1])
        Add-TaskDependency $root $config $Arg1 $Arg2
        Set-TaskIndexStatus $root $config $Arg1 'todo'
        if ($t.Status -eq 'blocked') {
            # blocked の解除として残す (最終レポートに解消済みの blocked を載せないため)
            $bp = Join-DevflowPath $root '.devflow/blocked.md'
            if (Test-Path -LiteralPath $bp) { Write-Utf8 $bp ((Read-Utf8 $bp) + "`n## $Arg1 解除 ($((Get-Date).ToString('yyyy-MM-dd HH:mm'))) → todo (依存に $Arg2 を追加)`n") }
        }
        if ($s.implementation.currentTask -eq $Arg1) { $s.implementation.currentTask = $null }
        if ($s.implementation.taskBase.Contains($Arg1)) { $s.implementation.taskBase.Remove($Arg1) }
        Write-DevflowState $root $s
        $p = Join-DevflowPath $root '.devflow/dep-changes.md'
        $text = if (Test-Path -LiteralPath $p) { Read-Utf8 $p } else { "# 実装中に足した依存`n" }
        $text += "`n## $Arg1 → $Arg2 ($((Get-Date).ToString('yyyy-MM-dd HH:mm')))`n`n$Reason`n`n$undoNote`n"
        Write-Utf8 $p $text
        Write-Output $undoNote
        Write-Output "$Arg1 の依存に $Arg2 を足し、todo に戻しました ($Arg2 の完了後に next-task が返す)"
    }
    'check-branches' {
        # ほかのブランチ (リモート) で dev-flow が並行して進んでいないかを確かめる。
        # クラウドのセッションは 1 セッション 1 ブランチで動き、state.json はブランチごとにあるため、別のセッションで
        # 同じフェーズを始めると、同じ作業を 2 か所で進めてしまう (互いの進捗も見えない)。
        # 次の条件をすべて満たすブランチを報告して exit 5: 今のブランチに取り込まれていないコミットがある /
        # .devflow/state.json がある / .devflow・docs が今のブランチと違う / .devflow の最後の変更が concurrentRunHours 以内
        $hours = [double]$config.concurrentRunHours
        & git -C $root fetch -q --prune origin 2>$null
        $fetched = ($LASTEXITCODE -eq 0)
        $cur = (& git -C $root rev-parse --abbrev-ref HEAD 2>$null)
        $refs = @(& git -C $root for-each-ref --format='%(refname:short)' refs/remotes 2>$null | Where-Object { $_ -and $_ -notmatch '/HEAD$' -and $_ -notmatch '^[^/]+$' })
        $found = @()
        foreach ($r in $refs) {
            if ($r -eq "origin/$cur") { continue }
            & git -C $root merge-base --is-ancestor $r HEAD 2>$null
            if ($LASTEXITCODE -eq 0) { continue }   # 取り込み済み
            $st = (& git -C $root show "${r}:.devflow/state.json" 2>$null) -join "`n"
            if (-not $st) { continue }
            & git -C $root diff --quiet HEAD $r -- .devflow docs 2>$null
            if ($LASTEXITCODE -eq 0) { continue }   # dev-flow の成果物は同じ (squash で取り込み済みなど)
            $ct = [string](& git -C $root log -1 --format=%ct $r -- .devflow 2>$null)
            if (-not $ct) { continue }
            $age = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$ct) / 3600
            if ($hours -gt 0 -and $age -gt $hours) { continue }
            try { $o = $st | ConvertFrom-Json } catch { continue }
            $done = ''
            $ix = (& git -C $root show "${r}:docs/04-detailed-design/tasks/index.md" 2>$null) -join "`n"
            if ($ix) { $done = "、done のタスク $(([regex]::Matches($ix, '\|\s*done\s*\|')).Count) 件" }
            $found += "- $r (phase: $($o.phase)$done、.devflow の最終更新: $([math]::Round($age, 1)) 時間前)"
        }
        if (-not $fetched) { Write-Output '注意: git fetch に失敗したため、手元にあるリモートの情報だけで確かめた' }
        if ($found.Count -eq 0) { Write-Output 'OK (ほかのブランチで進んでいる dev-flow はない)'; exit 0 }
        Write-Output "ほかのブランチで dev-flow が進んでいます (今のブランチ: $cur、現在フェーズ: $((Read-DevflowState $root).phase)):"
        $found | ForEach-Object { Write-Output $_ }
        Write-Output 'そのブランチのセッションがまだ動いているなら、こちらでは始めない。続きをこちらで進めるなら、そのブランチを取り込んでから (git merge <ブランチ>) 始める'
        exit 5
    }
    'run' {
        # run start: このセッションを実装・検証フェーズのオーケストレーターとして登録する (Stop フックが途中で止まらないようにする)
        # run stop : 登録を外す
        $p = Join-DevflowPath $root '.devflow/orchestrator.json'
        switch ($Arg1) {
            'start' {
                $o = [ordered]@{ active = $true; sessionId = ''; startedAt = (Get-Date).ToString('o'); blocks = 0; lastFingerprint = '' }
                Write-Utf8 $p (($o | ConvertTo-Json -Compress) + "`n")
                Write-Output 'オーケストレーターを開始しました'
            }
            'stop' {
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
                Write-Output 'オーケストレーターを終了しました'
            }
            default { throw 'run start | run stop の形式で指定してください' }
        }
    }
    'verification-round' {
        # 検証ラウンドを 1 進め、上限を超えたら exit 4。
        # ラウンドの途中 (set-phase -KeepVerification で閉じる前) に再実行しても進めない (再開時に数え直さないため)
        $s = Get-StateOrFail
        if (-not $s.verification.roundOpen) {
            $s.verification.round = [int]$s.verification.round + 1
            $s.verification.roundOpen = $true
            Write-DevflowState $root $s
        }
        Write-Output $s.verification.round
        if ($s.verification.round -gt [int]$config.maxVerificationRounds) { exit 4 }
    }
    'add-verification-task' {
        $s = Get-StateOrFail
        $s.verification.addedTasks = @(@($s.verification.addedTasks) + $Arg1 | Select-Object -Unique)
        Write-DevflowState $root $s
        Write-Output "追加タスクとして記録: $Arg1"
    }
    'config' {
        $config | ConvertTo-Json -Depth 5
    }
    'preflight' {
        # 実装フェーズの開始前に、テストを実行できる環境かを確かめる (環境の不備で全タスクが blocked になるのを防ぐ)
        $ng = @()
        if (-not $config.test.command) { $ng += 'test.command が未設定です (.devflow/config.json)' }
        else {
            $name = Get-TestCommandName ([string]$config.test.command)
            Push-Location $root
            try { $found = if ($name) { Get-Command $name -ErrorAction SilentlyContinue } else { $null } } finally { Pop-Location }
            if (-not $found) { $ng += "test.command のコマンド ``$name`` が見つかりません (インストールと PATH を確かめる)" }
        }
        if (@($config.test.resultGlobs | Where-Object { $_ }).Count -eq 0) { $ng += 'test.resultGlobs が空です' }
        if ([int]$config.test.timeoutSeconds -le 0) { Write-Output '注意: test.timeoutSeconds が 0 以下のため、テストが終わらなくても止めません' }
        $blockList = @()
        if ($Departure -and $ng.Count -eq 0) {
            # 自動区間の出発前: ここを過ぎると全タスク処理後まで止まらないので、止まる原因になる環境の不備をここで全部出す
            $setup = [string]$config.test.setupCommand
            if ($setup) {
                $r = Invoke-LoggedCommand $root $setup '.devflow/logs/setup.log' ([int]$config.test.timeoutSeconds) 'test.timeoutSeconds'
                if ($r.ExitCode -ne 0) { $ng += "test.setupCommand が失敗しました (exit $($r.ExitCode)、ログ: $($r.Log))" } else { Write-Output "test.setupCommand: OK ($setup)" }
            }
            foreach ($k in 'user.name', 'user.email') {
                $v = (& git -C $root config --get $k 2>$null)
                if (-not $v) { $ng += "git の $k が未設定です (``git config $k '<値>'``。コミットが全部失敗するため)" }
            }
            $ex = Get-RequirementExamples $root $config
            $withMarks = @($ex.Values | Where-Object { $_.Verify -eq 'test' -and $_.Marks.Count -gt 0 })
            if ($withMarks.Count -gt 0) {
                if (@($config.acceptance.files | Where-Object { $_ }).Count -eq 0) { $ng += 'acceptance.files が空です (受け入れ例のある要件が ' + $withMarks.Count + ' 件ある)' }
                elseif (@(Select-ByGlobs @($config.acceptance.files | ForEach-Object { ($_ -replace '\*\*.*$', '') + 'x.test.js' }) $config.test.files).Count -eq 0 -and @($config.test.files).Count -gt 0) {
                    Write-Output "注意: acceptance.files ($(@($config.acceptance.files) -join ', ')) が test.files に含まれていない可能性があります (test.command が受け入れテストも実行することを確かめる)"
                }
                $atTasks = @(Read-TaskIndex $root $config | Where-Object { $_.Id -like 'TASK-AT-*' })
                if ($atTasks.Count -eq 0) { $ng += "受け入れ例のある要件が $($withMarks.Count) 件あるのに、受け入れテストのタスク (TASK-AT-<領域>) がありません" }
            }
            if (@($config.deploy.targets).Count -gt 0) {
                $out = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'devflow-deploy.ps1') secrets 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $msg = "デプロイの秘密の値が足りません:`n$(($out | Select-Object -Last 15) -join "`n")"
                    if ($AllowMissingSecrets) { Write-Output "注意: $msg`n(デプロイだけが未実施で終わる)" } else { $ng += $msg }
                }
            }
            $rows = Read-Ledger $root
            foreach ($r in @($rows | Where-Object { $_.Kind -eq '要回答' -and $_.Status -eq 'open' })) {
                foreach ($tid in @(Get-IdsInText $r.Basis (Get-IdRegex $config) | Where-Object { $_ -like 'TASK-*' })) { $blockList += "$tid ($($r.Dec): $($r.Topic))" }
            }
        }
        if ($ng.Count -gt 0) {
            Write-Output 'テストを実行できる環境ではありません:'
            $ng | ForEach-Object { Write-Output "- $_" }
            exit 1
        }
        Write-Output "OK (test.command: $($config.test.command))"
        if ($blockList.Count -gt 0) {
            Write-Output '出発前に blocked にするタスク (要回答の決定を待つ。最後の 1 回で聞く):'
            $blockList | ForEach-Object { Write-Output "- BLOCK: $_" }
        }
    }
    'ledger' {
        switch ($Arg1) {
            'add' {
                $k = switch ($Kind) { 'C' { '処置-C' } 'B' { '処置-B' } default { $Kind } }
                if ((Get-LedgerKinds) -notcontains $k) { throw "-Kind は 確定 / 仮 / C / B / 要回答 のいずれか: '$Kind'" }
                if (-not $Topic -or -not $Value) { throw 'ledger add には -Topic (論点) と -Value (決定) が要ります' }
                if ($k -eq '仮' -and -not $Match) { throw '仮の決定には -Match (照合の正規表現) が要ります。照合が書けない「形」の論点は、仮にせずユーザーに聞く' }
                if ($Match -and -not (Test-RegexValid $Match)) { throw "-Match が正規表現として読めません: $Match" }
                if ($k -in @('処置-C', '処置-B') -and -not $Task) { throw '処置の行には -Task <TASK-ID> が要ります' }
                $basisText = if ($Basis) { $Basis } elseif ($Task) { $Task } else { throw '-Basis (上流の ID か、発言の逐語引用「…」) が要ります' }
                if ($Task -and $basisText -notmatch [regex]::Escape($Task)) { $basisText = "$Task $basisText" }
                $escalated = @()
                if ($k -eq '処置-C') {
                    $escalated = @(Test-SensitiveDecision $root $config "$Topic $Value" $Task)
                    if ($escalated.Count -gt 0) { $k = '要回答' }
                }
                $rows = @(Read-Ledger $root | Where-Object { $_ })
                $dec = Get-NextDecId $rows
                $status = if ($k -in @('処置-B', '要回答')) { 'open' } else { '有効' }
                $rows += [pscustomobject]@{ Dec = $dec; Topic = $Topic; Value = $Value; Match = $Match; Kind = $k; Basis = $basisText; Status = $status; Version = 1; OldMatches = @(); Line = 0 }
                Write-Ledger $root $rows
                Write-Output "$dec ($k) を台帳に足しました: $Topic → $Value"
                if ($escalated.Count -gt 0) {
                    Write-Output "要回答に格上げしました ($($escalated -join '、') に当たる)。このタスクは決めずに blocked にすること:"
                    Write-Output "  devflow-state.ps1 task $Task blocked -Reason '要回答 ${dec}: <推奨と理由>' (他のタスクは続ける。最後の 1 回でユーザーに聞く)"
                    exit 4
                }
            }
            'check' {
                $rows = Read-Ledger $root
                if ($null -eq $rows) { Write-Output '台帳 (.devflow/decisions/ledger.md) はまだありません'; exit 0 }
                $iss = @(Get-LedgerIssues $root $config $rows)
                if ($iss.Count -eq 0) { Write-Output "台帳: OK ($(@($rows).Count) 行)"; exit 0 }
                Write-Output "台帳: NG — $($iss.Count) 件"
                foreach ($g in ($iss | Group-Object code | Sort-Object Name)) {
                    Write-Output "[$($g.Name)] $($g.Count) 件"
                    $g.Group | Select-Object -First 30 | ForEach-Object { Write-Output "  - $($_.id) $($_.message) ($($_.where))" }
                }
                exit 1
            }
            'resolve' {
                # ledger resolve <DEC> -Reason <答え>: 最後の 1 回で「このままでよい」と答えた繰延べ (処置-B) を解決にする (値は変えない)
                $rows = @(Read-Ledger $root | Where-Object { $_ })
                $row = $rows | Where-Object { $_.Dec -eq $Arg2 } | Select-Object -First 1
                if (-not $row) { throw "台帳に $Arg2 がありません" }
                if ($row.Kind -eq '要回答') { throw '要回答は override -Answered で値を確定にする (推奨のままなら推奨の値で)' }
                $row.Status = '解決'
                if ($Reason) { $row.Basis = "$($row.Basis) (答え: $Reason)".Trim() }
                Write-Ledger $root $rows
                Write-Output "$Arg2 を解決にしました"
            }
            default { throw 'ledger add | ledger check | ledger resolve <DEC> の形式で指定してください' }
        }
    }
    'impact' {
        # impact <DEC>: 覆したときに直す行と回し直すタスク (読み取りのみ)
        $rows = @(Read-Ledger $root | Where-Object { $_ })
        $row = $rows | Where-Object { $_.Dec -eq $Arg1 } | Select-Object -First 1
        if (-not $row) { throw "台帳に $Arg1 がありません" }
        $imp = Get-DecImpact $root $config $row
        Write-Output "$($row.Dec) ($($row.Kind)、版 $($row.Version)、$($row.Status)): $($row.Topic) → $($row.Value)"
        Write-Output "照合: $(if ($row.Match) { '`' + $row.Match + '`' } else { 'なし' })$(if (@($row.OldMatches).Count -gt 0) { "  旧照合: $((@($row.OldMatches) | ForEach-Object { '`' + $_ + '`' }) -join ' ')" })"
        Write-Output "引用している行: $($imp.Cites.Count) 件"
        $imp.Cites | ForEach-Object { Write-Output "  - $($_.File):$($_.No)  $($_.Text.Trim())" }
        Write-Output "照合に当たる行 (DEC を引用していない): $($imp.Hits.Count) 件"
        $imp.Hits | ForEach-Object { Write-Output "  - $($_.File):$($_.No)  $($_.Text.Trim())" }
        Write-Output "関わる ID: $(if ($imp.Ids.Count) { $imp.Ids -join ', ' } else { 'なし' })"
        foreach ($st in 'done', 'in_progress', 'todo', 'blocked') {
            $ts = @($imp.Tasks | Where-Object { $_.Status -eq $st } | ForEach-Object { $_.Id })
            if ($ts.Count -gt 0) { Write-Output "担当タスク ($st): $($ts -join ', ')" }
        }
        if ($imp.Tasks.Count -eq 0) { Write-Output '担当タスク: なし' }
    }
    'override' {
        # override <DEC> -Value <新しい値> -Match <新しい照合> [-OldMatch <狭めた旧照合>] [-Answered]
        # 値の覆し (仮・処置の取り替え、または確定の決定のユーザーによる変更)。版を上げ、旧照合を残し、done のタスクの補償タスクを 1 つ足す
        $rows = @(Read-Ledger $root | Where-Object { $_ })
        $row = $rows | Where-Object { $_.Dec -eq $Arg1 } | Select-Object -First 1
        if (-not $row) { throw "台帳に $Arg1 がありません" }
        if (-not $Value -or -not $Match) { throw 'override には -Value (新しい値) と -Match (新しい値の照合) が要ります' }
        if (-not (Test-RegexValid $Match)) { throw "-Match が正規表現として読めません: $Match" }
        if ($row.Kind -eq '確定' -and -not $Answered) {
            Write-Output "$($row.Dec) はユーザーが決めた (確定) 決定です。ユーザーの指示があるときだけ覆す (指示を受けたなら -Answered を付ける)"
            exit 1
        }
        $old = if ($OldMatch) { $OldMatch } else { $row.Match }
        if ($old -and -not (Test-RegexValid $old)) { throw "-OldMatch が正規表現として読めません: $old" }
        if ($old -and [regex]::IsMatch($Value, $old)) {
            Write-Output "覆しを拒否: 新しい値「$Value」が旧照合 ``$old`` に当たります (このままでは直した行まで DEC-STALE になる)。"
            Write-Output "-OldMatch に、旧い値だけに当たる狭い照合を渡して、同じ呼び出しでやり直すこと (例: 旧い値に固有の語だけ)"
            exit 1
        }
        if (-not [regex]::IsMatch($Value, $Match)) { Write-Output "注意: 新しい照合 ``$Match`` が新しい値「$Value」に当たりません (派生値だけを書いたのでなければ見直す)" }
        $imp = Get-DecImpact $root $config $row
        $oldValue = $row.Value
        if ($old) { $row.OldMatches = @(@($row.OldMatches) + $old | Select-Object -Unique) }
        $row.Value = $Value; $row.Match = $Match; $row.Version = [int]$row.Version + 1
        if ($Answered) { $row.Kind = '確定'; $row.Status = '有効' }
        elseif ($row.Status -eq 'open') { $row.Status = '解決' }
        Write-Ledger $root $rows
        Write-Output "$($row.Dec) を版 $($row.Version) にしました: $oldValue → $Value (旧照合: ``$old``)"
        $doneList = @($imp.Tasks | Where-Object { $_.Status -eq 'done' })
        $comp = ''
        if ($doneList.Count -gt 0) {
            $comp = New-CompensationTask $row $oldValue $imp $doneList
            Write-Output "補償タスク $comp を足しました (done のタスク $(($doneList | ForEach-Object { $_.Id }) -join ', ') の成果を新しい値に直す。todo)"
        } else { Write-Output 'done のタスクはないので、補償タスクは要りません' }
        Write-Output ''
        Write-Output '次にすること (オーケストレーター。実装担当の作業中でないときに):'
        Write-Output "1. 引用している行・照合に当たる行 ($($imp.Cites.Count + $imp.Hits.Count) 件。地の文と todo のタスクのテストケースを含む) の値を新しい値に直す:"
        @($imp.Cites) + @($imp.Hits) | ForEach-Object { Write-Output "   - $($_.File):$($_.No)" }
        $todo = @($imp.Tasks | Where-Object { $_.Status -in @('todo', 'blocked') } | ForEach-Object { $_.Id })
        if ($todo.Count -gt 0) { Write-Output "   (todo / blocked のタスク $($todo -join ', ') は、テストケースの値を直せば新しい値で実装される)" }
        Write-Output '2. pwsh -NoProfile -File scripts/devflow-state.ps1 relock   (要件の例の値を変えたとき)'
        Write-Output "3. pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode design が exit 0 (DEC-STALE が出たら、その行も直す)"
        Write-Output "4. devflow-commit.ps1 -Kind docs -Scope $($row.Dec) -Message '覆し: $($row.Topic)'"
        if ($comp) { Write-Output "5. 実装担当を 1 体起動して $comp を進めさせる (実装フェーズの手順 4 から)" }
    }
    'amend' {
        # amend -Topic <何を変えるか> -Value <決定> -Basis <ユーザーの発言の逐語引用> [-Match <新しい語の照合>]
        # 「形」の変更 (機能・項目の追加など)。台帳に確定の行を足し、手順を出す (要件・設計・タスクの差分はオーケストレーターと detailed-designer が書く)
        if (-not $Topic -or -not $Value -or -not $Basis) { throw 'amend には -Topic・-Value・-Basis (ユーザーの発言の逐語引用「…」) が要ります' }
        if ($Match -and -not (Test-RegexValid $Match)) { throw "-Match が正規表現として読めません: $Match" }
        $rows = @(Read-Ledger $root | Where-Object { $_ })
        $dec = Get-NextDecId $rows
        $rows += [pscustomobject]@{ Dec = $dec; Topic = "変更: $Topic"; Value = $Value; Match = $Match; Kind = '確定'; Basis = $Basis; Status = '有効'; Version = 1; OldMatches = @(); Line = 0 }
        Write-Ledger $root $rows
        # 自動区間の途中の発言は、どのフェーズの質問ログにも書かれないので、変更の質問ログ (.devflow/decisions/changes.md) に逐語で残す (根拠の引用の照合先)
        $cp = Join-DevflowPath $root '.devflow/decisions/changes.md'
        $ct = if (Test-Path -LiteralPath $cp) { Read-Utf8 $cp } else { "# 決定ツリー: 承認の後の変更`n`n## 質問ログ`n`n回答欄にはユーザーの言葉をそのまま書く。`n`n| 変更 | 確認したこと | ユーザーの発言 (逐語) |`n|------|--------------|------------------------|`n" }
        foreach ($q in @([regex]::Matches($Basis, '「([^」]+)」') | ForEach-Object { $_.Groups[1].Value })) {
            $ct = $ct.TrimEnd() + "`n| $dec | $($Topic.Replace('|', '\|')) | $($q.Replace('|', '\|')) |`n"
        }
        Write-Utf8 $cp $ct
        Write-Output "$dec (確定、変更) を台帳に足しました: $Topic → $Value"
        Write-Output ''
        Write-Output '次にすること (オーケストレーター。実装担当の作業中でないときに。redo はしない):'
        Write-Output "   (発言の逐語引用を .devflow/decisions/changes.md の質問ログに残しました)"
        Write-Output "1. docs/02-requirements/ に要件 (REQ) と受け入れ例を足す。ユーザーが言っていない中身 (範囲外の文言・列の位置・表示の形など) は推奨で決め、値ごとに ``ledger add -Kind 仮 -Basis <足した REQ>`` で台帳に載せる (最後の 1 回の覆せる一覧に出す)。足した REQ の行の備考に ``決定: $dec`` を書き、Then の印の値には [$dec] を付ける"
        Write-Output "2. detailed-designer を mode: amend、DEC: $dec で起動し、基本設計 (03) と詳細設計 (04) の差分とタスクを足させる (03 の変更行に $dec を書く。done のタスクは開き直さず、差分を実装する新しいタスクを足す)"
        Write-Output '3. pwsh -NoProfile -File scripts/devflow-state.ps1 relock'
        Write-Output "4. pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode design が exit 0 (足した REQ が 03 の ID から参照されていなければ AMEND-NO-BASIC)"
        Write-Output "5. devflow-commit.ps1 -Kind docs -Scope $dec -Message '変更: $Topic'。実装フェーズの手順 4 から続ける"
    }
    'relock' {
        $n = Write-ExampleLock $root $config
        Write-Output "受け入れ例の lock を書き直しました: .devflow/examples.lock.json (要件 $n 件)"
    }
    'debrief' {
        # 全タスク処理後の最後の 1 回: 台帳から、聞くこと・覆せること・繰延べ・人が確認する項目を出し、.devflow/debrief.md に残す
        $p = Join-DevflowPath $root '.devflow/debrief.md'
        if ($Done) {
            if (-not (Test-Path -LiteralPath $p)) { throw '.devflow/debrief.md がありません (先に debrief を実行する)' }
            Write-Utf8 $p ((Read-Utf8 $p) -replace '(?m)^> 状態: .*$', "> 状態: 回答済み ($((Get-Date).ToString('yyyy-MM-dd HH:mm')))")
            Write-Output '最後の 1 回を回答済みにしました'
            exit 0
        }
        if ((Test-Path -LiteralPath $p) -and ((Read-Utf8 $p) -match '(?m)^> 状態: 回答済み')) { Write-Output '最後の 1 回は回答済みです (聞き直さない)'; exit 3 }
        $rows = @(Read-Ledger $root | Where-Object { $_ })
        $docLines = @(Get-DocScanLines $root)
        $defIdx = Get-IdDefinitionIndex $root $config
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('# 最後の 1 回 (debrief)').AppendLine().AppendLine('> 状態: 質問前').AppendLine()
        $ask = @($rows | Where-Object { $_.Kind -eq '要回答' -and $_.Status -eq 'open' })
        [void]$sb.AppendLine("## 1. 要回答 ($($ask.Count) 件。推奨つき)").AppendLine()
        if ($ask.Count -eq 0) { [void]$sb.AppendLine('なし') }
        foreach ($r in $ask) { [void]$sb.AppendLine("- $($r.Dec) $($r.Topic): 推奨「$($r.Value)」 (止めたタスク: $((@(Get-IdsInText $r.Basis (Get-IdRegex $config)) | Where-Object { $_ -like 'TASK-*' }) -join ', '))") }
        [void]$sb.AppendLine()
        # blocked のタスク (要回答で止めたものを除く) と、それを待って進めなかったタスク。設計の判断が要るので、ここで聞く
        $allTasks = @(Read-TaskIndex $root $config)
        $askDecTasks = @($ask | ForEach-Object { Get-IdsInText $_.Basis (Get-IdRegex $config) } | Where-Object { $_ -like 'TASK-*' })
        $blk = @($allTasks | Where-Object { $_.Status -eq 'blocked' -and $askDecTasks -notcontains $_.Id })
        $bp = Join-DevflowPath $root '.devflow/blocked.md'
        $btext = if (Test-Path -LiteralPath $bp) { Read-Utf8 $bp } else { '' }
        [void]$sb.AppendLine("## 1b. 止まったタスク ($($blk.Count) 件。設計の判断が要る)").AppendLine()
        if ($blk.Count -eq 0) { [void]$sb.AppendLine('なし') }
        foreach ($t in $blk) {
            $secs = @([regex]::Matches($btext, '(?ms)^## ' + [regex]::Escape($t.Id) + ' \(.*?(?=^## |\z)'))
            $reason = if ($secs.Count -gt 0) { (($secs[-1].Value -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() -and $_ -notmatch '^作業の取り消し' }) -join ' ').Trim() } else { '(理由の記録なし)' }
            $waiting = @($allTasks | Where-Object { $_.Status -ne 'done' -and $_.Id -ne $t.Id -and (Test-TaskDependsOn $allTasks $_.Id $t.Id) } | ForEach-Object { $_.Id })
            [void]$sb.AppendLine("- $($t.Id) ($($t.Title)): $reason$(if ($waiting.Count) { " (これを待って進めなかったタスク: $($waiting -join ', '))" })")
        }
        [void]$sb.AppendLine()
        $rev = @(foreach ($r in @($rows | Where-Object { $_.Kind -in @('仮', '処置-C') -and $_.Status -eq '有効' })) {
            $imp = Get-DecImpact $root $config $r $docLines $defIdx
            [pscustomobject]@{ Row = $r; Lines = ($imp.Cites.Count + $imp.Hits.Count); Tasks = $imp.Tasks.Count; Done = @($imp.Tasks | Where-Object { $_.Status -eq 'done' }).Count }
        })
        $rev = @($rev | Sort-Object @{ Expression = 'Done'; Descending = $true }, @{ Expression = 'Lines'; Descending = $true })
        [void]$sb.AppendLine("## 2. 覆せる一覧 (聞かずに決めたこと $($rev.Count) 件。影響の大きい順)").AppendLine()
        if ($rev.Count -eq 0) { [void]$sb.AppendLine('なし') }
        foreach ($x in @($rev | Select-Object -First 10)) { [void]$sb.AppendLine("- $($x.Row.Dec) [$($x.Row.Kind)] $($x.Row.Topic): 「$($x.Row.Value)」 (覆すと: 直す行 $($x.Lines)、回し直す done のタスク $($x.Done))") }
        if ($rev.Count -gt 10) { [void]$sb.AppendLine("- ほか $($rev.Count - 10) 件 (.devflow/decisions/ledger.md)") }
        [void]$sb.AppendLine()
        $defer = @($rows | Where-Object { $_.Kind -eq '処置-B' -and $_.Status -eq 'open' })
        [void]$sb.AppendLine("## 3. 繰延べ (外部環境がなくテストダブルで進めたもの $($defer.Count) 件)").AppendLine()
        if ($defer.Count -eq 0) { [void]$sb.AppendLine('なし') }
        foreach ($r in $defer) { [void]$sb.AppendLine("- $($r.Dec) $($r.Topic): $($r.Value) ($($r.Basis))") }
        [void]$sb.AppendLine()
        $warn = @()
        $tp = Join-DevflowPath $root '.devflow/trace-result.json'
        if (Test-Path -LiteralPath $tp) {
            $tr = Read-Utf8 $tp | ConvertFrom-Json
            $warn = @(@($tr.warnings) + @($tr.issues) | Where-Object { $_ -and $_.code -in @('EXAMPLE-NOT-IN-AT', 'EXAMPLE-ORDER', 'REQ-NO-ACCEPTANCE', 'DEC-UNCITED') })
        }
        [void]$sb.AppendLine("## 4. 人が確認する項目 (受け入れ例と受け入れテストの照合の警告 $($warn.Count) 件)").AppendLine()
        if ($warn.Count -eq 0) { [void]$sb.AppendLine('なし') }
        foreach ($w in $warn) { [void]$sb.AppendLine("- [$($w.code)] $($w.id) $($w.message) ($($w.where))") }
        [void]$sb.AppendLine().AppendLine('## 回答と反映').AppendLine().AppendLine('(オーケストレーターが、回答と、override / amend で反映した DEC・回し直したタスクを書く)')
        Write-Utf8 $p $sb.ToString()
        Write-Output $sb.ToString()
        if ($ask.Count + $blk.Count + $rev.Count + $defer.Count + $warn.Count -eq 0) { Write-Output '聞くことはありません (debrief -Done で回答済みにして先へ進む)' }
    }
    default {
        throw "未知のコマンド: $Command (init|show|phase|start-phase|complete-phase|set-phase|impl-status|next-task|task|task-context|add-dep|check-branches|run|verification-round|add-verification-task|config|preflight|ledger|impact|override|amend|relock|debrief)"
    }
}
