# SubagentStop フック (matcher: tdd-implementer)
#
# 1 体の実装担当に、コンテキストが閾値を超えるまでタスクを続けてこなさせる。
# 1. 閾値超え: handoff.md がこの実装担当の開始後に更新済み かつ 作業ツリーがクリーンなら終了を許可。
#    そうでなければ終了を止めて、引き継ぎ (handoff.md の更新とコミット) を指示する。
# 2. 閾値未満で実行可能なタスクが残っている: 終了を止めて、次のタスクに進ませる。
# 3. 実行可能なタスクがない (全部完了、または残りが blocked とそれに依存するものだけ): 終了を許可する。
# 同じ状態のまま 2 回止めても進捗がなければ、3 回目は終了を許可し、オーケストレーターに判断を任せる。

$ErrorActionPreference = 'Stop'
# 例外で終わると見張りが黙って消えるため、理由を人に知らせてから終了を許可する
trap {
    [Console]::Out.Write((@{ systemMessage = "dev-flow: SubagentStop フックでエラーが起きたため、今回は見張りを行いません: $($_.Exception.Message)" } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii))
    exit 0
}
Import-Module (Join-Path $PSScriptRoot '../../scripts/devflow-lib.psm1') -Force

$in = Read-StdinJson
if (-not $in -or -not $in.PSObject.Properties['agent_id']) { exit 0 }
$root = Get-DevflowRoot
$state = Read-DevflowState $root
if (-not $state -or $state.phase -ne 'implementation') { exit 0 }
$config = Get-DevflowConfig $root
$run = Get-ImplementerRun $root ([string]$in.agent_id)

function Block([string]$Reason) {
    $fp = Get-ProgressFingerprint $root
    if ($run.lastFingerprint -eq $fp) { $run.blocks = [int]$run.blocks + 1 } else { $run.blocks = 1 }
    $run.lastFingerprint = $fp
    Write-ImplementerRun $root $run
    if ([int]$run.blocks -gt 2) {
        Write-HookJson @{ systemMessage = 'dev-flow: 実装担当が進捗のないまま終了を繰り返したため、終了を許可します' }
        exit 0
    }
    Write-HookJson @{ decision = 'block'; reason = $Reason }
    exit 0
}

$usage = Get-AgentContextUsage $config $in
if ($usage -and -not $run.baseTokens) { $run.baseTokens = $usage.Tokens; Write-ImplementerRun $root $run }
$over = Test-ContextOver $config $usage $run.baseTokens

if ($over) {
    $handoff = Join-DevflowPath $root '.devflow/handoff.md'
    $started = [datetime]::Parse([string]$run.startedAt)
    $handoffFresh = (Test-Path -LiteralPath $handoff) -and ((Get-Item -LiteralPath $handoff).LastWriteTime -gt $started)
    $dirty = @(Get-UncommittedChanges $root $config)
    if ($handoffFresh -and $dirty.Count -eq 0) { exit 0 }
    $todo = @()
    if (-not $handoffFresh) { $todo += '.devflow/handoff.md を更新する (完了したタスク / 作業中タスクの状態と途中経過 / 次にやること)' }
    if ($dirty.Count -gt 0) { $todo += "未コミットの変更 ($($dirty.Count) 件) をコミットする (テストが落ちている作業途中なら ``devflow-commit.ps1 -Kind chore -Scope <TASK-ID> -Message `"WIP 引き継ぎ`"`` で可。handoff.md にその旨を書く)" }
    Block (('コンテキスト使用率が {0:N0}% (閾値 {1}%) に達した。新しいタスクには着手せず、次を行ってから報告して終了すること: ' -f $usage.Percent, $config.contextThresholdPercent) + ($todo -join ' / '))
}

$ready = Get-ReadyTask @(Read-TaskIndex $root $config)
if ($ready) {
    Block "まだ終了しないこと。コンテキストに余裕があるので、tdd-implementer の手順に従い次のタスク $($ready.Id) ($($ready.Title)) に進むこと。"
}
exit 0
