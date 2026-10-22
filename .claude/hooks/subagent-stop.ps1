# SubagentStop フック (matcher: tdd-implementer)
#
# 1 体の実装担当に、担当分のタスク (implementer.tasksPerAgent、既定 1) を処理し終えるまで続けさせる。
# 0. 担当分の処理: 開始後に done か blocked のタスクが tasksPerAgent 件以上増え、作業ツリーがクリーンなら終了を許可する
#    (補償タスク・再試行も新しい 1 体で行い、前のタスクの読み物を抱えないため)。tasksPerAgent が 0 なら従来どおり閾値まで続ける。
# 1. 閾値超え (1 タスクが 1 体に収まらないときの非常口): handoff.md がこの実装担当の開始後に更新済み かつ 作業ツリーがクリーンなら終了を許可。
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

$per = 0
if ($config.Contains('implementer') -and $config.implementer -and $config.implementer.Contains('tasksPerAgent')) { $per = [int]$config.implementer.tasksPerAgent }
if ($per -gt 0) {
    $startCount = if ($run.Contains('processedAtStart') -and $null -ne $run.processedAtStart) { [int]$run.processedAtStart } else { 0 }
    $processed = (Get-ProcessedTaskCount $root) - $startCount
    if ($processed -ge $per) {
        $dirty = @(Get-UncommittedChanges $root $config)
        if ($dirty.Count -eq 0) { exit 0 }
        Block "担当のタスクは処理済み。未コミットの変更 ($($dirty.Count) 件) を ``devflow-commit.ps1 -Kind chore`` でコミットしてから、報告して終了すること。"
    }
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
if ($ready -and $per -gt 0) {
    Block "まだ終了しないこと。tdd-implementer の手順に従い、タスク $($ready.Id) ($($ready.Title)) を done にするか、行き詰まったら blocked にしてから報告して終えること。"
}
if ($ready) {
    Block "まだ終了しないこと。コンテキストに余裕があるので、tdd-implementer の手順に従い次のタスク $($ready.Id) ($($ready.Title)) に進むこと。"
}
exit 0
