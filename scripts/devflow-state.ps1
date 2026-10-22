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
#>
param(
    [Parameter(Position = 0)][string]$Command = 'show',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [string]$Reason = '',
    [switch]$Force,             # task <ID> done で完了の確認を飛ばす (人が手で状態を直すとき用)
    [switch]$KeepVerification   # set-phase で検証ラウンドの記録を残す (検証フェーズから追加タスクの実装に戻るとき用)
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
            foreach ($k in 'test', 'feat') {
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
        if ($ng.Count -gt 0) {
            Write-Output 'テストを実行できる環境ではありません:'
            $ng | ForEach-Object { Write-Output "- $_" }
            exit 1
        }
        Write-Output "OK (test.command: $($config.test.command))"
    }
    default {
        throw "未知のコマンド: $Command (init|show|phase|start-phase|complete-phase|set-phase|impl-status|next-task|task|task-context|add-dep|check-branches|run|verification-round|add-verification-task|config|preflight)"
    }
}
