<#
.SYNOPSIS
  .devflow/state.json と tasks/index.md の状態を操作する。
  エージェントが JSON や表を手で書き換えずに済むよう、状態変更はすべてこのスクリプトで行う。

.EXAMPLE
  pwsh -NoProfile -File scripts/devflow-state.ps1 show
  pwsh -NoProfile -File scripts/devflow-state.ps1 complete-phase requirements
  pwsh -NoProfile -File scripts/devflow-state.ps1 next-task
  pwsh -NoProfile -File scripts/devflow-state.ps1 task TASK-003 blocked -Reason "..."
#>
param(
    [Parameter(Position = 0)][string]$Command = 'show',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [string]$Reason = ''
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
                $title = if ($f -eq 'handoff.md') { '# セッション引き継ぎメモ' } else { '# 行き詰まったタスクの記録' }
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
        $s = Get-StateOrFail
        Set-TaskIndexStatus $root $config $Arg1 $Arg2
        if ($Arg2 -eq 'in_progress') { $s.implementation.currentTask = $Arg1 }
        elseif ($s.implementation.currentTask -eq $Arg1) { $s.implementation.currentTask = $null }
        if ($Arg2 -eq 'blocked') {
            $p = Join-DevflowPath $root '.devflow/blocked.md'
            $text = if (Test-Path -LiteralPath $p) { Read-Utf8 $p } else { "# 行き詰まったタスクの記録`n" }
            $text += "`n## $Arg1 ($((Get-Date).ToString('yyyy-MM-dd HH:mm')))`n`n$Reason`n"
            Write-Utf8 $p $text
        }
        Write-DevflowState $root $s
        Write-Output "$Arg1 → $Arg2"
    }
    'session' {
        $s = Get-StateOrFail
        $s.implementation.sessions = [int]$s.implementation.sessions + 1
        Write-DevflowState $root $s
        Write-Output $s.implementation.sessions
    }
    'verification-round' {
        # 検証ラウンドを 1 進め、上限を超えたら exit 4
        $s = Get-StateOrFail
        $s.verification.round = [int]$s.verification.round + 1
        Write-DevflowState $root $s
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
    default {
        throw "未知のコマンド: $Command (init|show|phase|start-phase|complete-phase|set-phase|impl-status|next-task|task|session|verification-round|add-verification-task|config)"
    }
}
