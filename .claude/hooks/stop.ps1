# Stop フック (オーケストレーター専用)
#
# 自動区間 (詳細設計・実装・検証・デプロイ) のオーケストレーター (`devflow-state.ps1 run start` を実行したセッション) が、
# 作業を残したまま応答を終えないようにする。それ以外のセッションでは何もしない。
# - 実装フェーズで実行可能なタスクが残っている: 次の実装担当を起動させる
# - 実装フェーズで実行可能なタスクがない: 実装フェーズを完了して検証へ進ませる
# - 検証フェーズ・デプロイフェーズ: 手順を最後まで進めさせる
# - phase が done になったら止めない (残りが blocked だけでも検証へ進み、最終レポートで報告する)
# - タスク一覧が読めない (0 件): 止めずに終了を許可し、人に知らせる
# 同じ状態のまま 2 回止めても進捗がなければ、3 回目は終了を許可する。

$ErrorActionPreference = 'Stop'
# 例外で終わると見張りが黙って消えるため、理由を人に知らせてから終了を許可する
trap {
    [Console]::Out.Write((@{ systemMessage = "dev-flow: Stop フックでエラーが起きたため、今回は見張りを行いません: $($_.Exception.Message)" } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii))
    exit 0
}
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
if (-not $state -or $state.phase -notin @('detailed-design', 'implementation', 'verification', 'deployment')) {
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
        $orch.active = $false
        Write-Utf8 $orchPath (($orch | ConvertTo-Json -Compress) + "`n")
        Write-HookJson @{ systemMessage = 'dev-flow: 進捗がないまま停止が繰り返されたため、オーケストレーターを止めます (`/dev-flow` で再開できます)' }
        exit 0
    }
    Write-HookJson @{ decision = 'block'; reason = $Reason }
    exit 0
}

if ($state.phase -eq 'detailed-design') {
    Block '詳細設計が完了していない。phases/04-detailed-design.md の手順どおり、detailed-designer を起動して設計を終え、出発前の確認から実装へ進むこと。ユーザーには質問しない (出発前の確認が NG のときは run stop してから報告する)。'
}
if ($state.phase -eq 'implementation') {
    $tasks = @(Read-TaskIndex $root $config)
    if ($tasks.Count -eq 0) {
        # タスク一覧が読めない: 検証へ進ませると実装ゼロのまま「完了」になるので、止めて人に知らせる
        $orch.active = $false
        Write-Utf8 $orchPath (($orch | ConvertTo-Json -Compress) + "`n")
        Write-HookJson @{ systemMessage = 'dev-flow: tasks/index.md からタスクを読めないため、オーケストレーターを止めます (表を直したら `/dev-flow` で再開できます)' }
        exit 0
    }
    if (Get-ReadyTask $tasks) {
        Block '実装フェーズのタスクが残っている。phases/05-implementation.md の手順どおり、次の tdd-implementer を起動すること。ユーザーには質問しない。'
    }
    Block '実行可能なタスクが残っていない (残りがあっても blocked とそれに依存するものだけ)。phases/05-implementation.md の「全タスク処理後」に従い、実装フェーズを完了して検証フェーズへ進むこと。'
}
if ($state.phase -eq 'deployment') {
    Block 'デプロイフェーズが完了していない。phases/07-deployment.md の手順を最後まで実行すること (失敗しても、記録とレポートを書いてフェーズを完了する)。ユーザーには質問しない。'
}
Block '検証フェーズが完了していない。phases/06-verification.md の手順を最後まで実行すること。'
