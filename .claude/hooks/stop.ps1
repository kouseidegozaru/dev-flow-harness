# Stop フック (オーケストレーター専用)
#
# 実装・検証フェーズのオーケストレーター (`devflow-state.ps1 run start` を実行したセッション) が、
# 作業を残したまま応答を終えないようにする。それ以外のセッションでは何もしない。
# - 実装フェーズで実行可能なタスクが残っている: 次の実装担当を起動させる
# - 実装フェーズで実行可能なタスクがない: 実装フェーズを完了して検証へ進ませる
# - 検証フェーズ: 手順を最後まで進めさせる
# - phase が done になったら止めない (残りが blocked だけでも検証へ進み、最終レポートで報告する)
# 同じ状態のまま 3 回止めた場合 (進捗なし) は終了を許可する。

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/devflow-lib.psm1') -Force

$in = Read-StdinJson
$root = Get-DevflowRoot
$orchPath = Join-DevflowPath $root '.devflow/orchestrator.json'
if (-not (Test-Path -LiteralPath $orchPath)) { exit 0 }
try { $orch = Read-Utf8 $orchPath | ConvertFrom-Json -AsHashtable } catch { exit 0 }
if (-not $orch.active) { exit 0 }
$sid = if ($in -and $in.PSObject.Properties['session_id']) { [string]$in.session_id } else { '' }
# run start の後で最初に止まったセッションをオーケストレーターとして結び付ける
if (-not $orch.sessionId) { $orch.sessionId = $sid }
if ($orch.sessionId -ne $sid) { exit 0 }

$state = Read-DevflowState $root
if (-not $state -or $state.phase -notin @('implementation', 'verification')) {
    $orch.active = $false
    Write-Utf8 $orchPath (($orch | ConvertTo-Json -Compress) + "`n")
    exit 0
}
$config = Get-DevflowConfig $root

function Block([string]$Reason) {
    $fp = Get-ProgressFingerprint $root
    if ($orch.lastFingerprint -eq $fp) { $orch.blocks = [int]$orch.blocks + 1 } else { $orch.blocks = 1 }
    $orch.lastFingerprint = $fp
    Write-Utf8 $orchPath (($orch | ConvertTo-Json -Compress) + "`n")
    if ([int]$orch.blocks -gt 2) {
        Write-HookJson @{ systemMessage = 'dev-flow: 進捗がないまま停止が繰り返されたため、オーケストレーターを止めます (`/dev-flow` で再開できます)' }
        exit 0
    }
    Write-HookJson @{ decision = 'block'; reason = $Reason }
    exit 0
}

if ($state.phase -eq 'implementation') {
    $tasks = @(Read-TaskIndex $root $config)
    if (Get-ReadyTask $tasks) {
        Block '実装フェーズのタスクが残っている。phases/05-implementation.md の手順どおり、次の tdd-implementer を起動すること。ユーザーには質問しない。'
    }
    Block '実行可能なタスクが残っていない (残りがあっても blocked とそれに依存するものだけ)。phases/05-implementation.md の「全タスク処理後」に従い、実装フェーズを完了して検証フェーズへ進むこと。'
}
Block '検証フェーズが完了していない。phases/06-verification.md の手順を最後まで実行すること。'
