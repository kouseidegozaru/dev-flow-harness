# Stop フック (自動ループ専用。対話セッションでは何もしない)
#
# 1. コンテキスト使用率が閾値以上 (かつセッション開始時から minSessionWorkTokens 以上進んだ。Test-ContextOver):
#    handoff.md が今回のセッションで更新済み かつ 作業ツリーがクリーンなら停止を許可。
#    そうでなければ停止をブロックし、handoff.md の記入とコミットを指示する。
# 2. 閾値未満で作業が残っている: 停止をブロックし、次にやることを指示する。
# 3. 同じ状態のまま繰り返しブロックしている (進捗なし) 場合は停止を許可する。
#    外部ループが「進捗なし」を検知して止める。

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/devflow-lib.psm1') -Force

if ($env:DEVFLOW_AUTOLOOP -ne '1') { exit 0 }

$in = Read-StdinJson
$root = Get-DevflowRoot
$state = Read-DevflowState $root
if (-not $state -or $state.phase -notin @('implementation', 'verification')) { exit 0 }
$config = Get-DevflowConfig $root

function Get-Fingerprint {
    $head = (& git -C $root rev-parse HEAD 2>$null)
    $parts = @($head)
    foreach ($rel in '.devflow/state.json', 'docs/04-detailed-design/tasks/index.md') {
        $p = Join-DevflowPath $root $rel
        if (Test-Path -LiteralPath $p) { $parts += (Get-FileHash -LiteralPath $p -Algorithm SHA1).Hash }
    }
    return ($parts -join ':')
}

$loopPath = Join-DevflowPath $root '.devflow/loop-session.json'
$loop = if (Test-Path -LiteralPath $loopPath) { Read-Utf8 $loopPath | ConvertFrom-Json -AsHashtable } else { @{ startedAt = (Get-Date).AddHours(-1).ToString('o'); blocks = 0; lastFingerprint = '' } }

function Block([string]$Reason) {
    $fp = Get-Fingerprint
    if ($loop.lastFingerprint -eq $fp) { $loop.blocks = [int]$loop.blocks + 1 } else { $loop.blocks = 1 }
    $loop.lastFingerprint = $fp
    Write-Utf8 $loopPath (($loop | ConvertTo-Json -Compress) + "`n")
    if ([int]$loop.blocks -gt 2) {
        # 同じ状態で 3 回目の停止 → 進捗がないので止める
        Write-HookJson @{ systemMessage = 'dev-flow: 進捗がないまま停止が繰り返されたため、このセッションを終了します' }
        exit 0
    }
    Write-HookJson @{ decision = 'block'; reason = $Reason }
    exit 0
}

$usage = Get-ContextUsage $root $config $in
$threshold = [double]$config.contextThresholdPercent
Update-LoopBaseTokens $root $usage
$over = Test-ContextOver $root $config $usage

if ($over) {
    $handoff = Join-DevflowPath $root '.devflow/handoff.md'
    $started = [datetime]::Parse([string]$loop.startedAt)
    $handoffFresh = (Test-Path -LiteralPath $handoff) -and ((Get-Item -LiteralPath $handoff).LastWriteTime -gt $started)
    $dirty = @(& git -C $root status --porcelain 2>$null | Where-Object { $_ })
    if ($handoffFresh -and $dirty.Count -eq 0) {
        Write-HookJson @{ systemMessage = ('dev-flow: コンテキスト使用率 {0:N0}% のためセッションを切り替えます' -f $usage.Percent) }
        exit 0
    }
    $todo = @()
    if (-not $handoffFresh) { $todo += '.devflow/handoff.md を更新する (完了タスク / 作業中タスクの状態と途中経過 / 次にやること)' }
    if ($dirty.Count -gt 0) { $todo += "未コミットの変更 ($($dirty.Count) 件) をコミットする (テストが落ちている作業途中なら ``chore(<task-id>): WIP 引き継ぎ`` で可。handoff.md にその旨を書く)" }
    Block (('コンテキスト使用率が {0:N0}% (閾値 {1}%) に達した。新しいタスクには着手せず、次を行ってから終了すること: ' -f $usage.Percent, $threshold) + ($todo -join ' / '))
}

if ($state.phase -eq 'implementation') {
    $tasks = @(Read-TaskIndex $root $config)
    $ready = Get-ReadyTask $tasks
    if ($ready) {
        Block "実装フェーズの作業が残っている。phases/05-implementation.md の手順で次のタスク $($ready.Id) ($($ready.Title)) に進むこと。ユーザーには質問しない。"
    }
    Block '実行可能なタスクが残っていない。phases/05-implementation.md の「全タスク処理後」に従い、`devflow-state.ps1 complete-phase implementation` で検証フェーズへ進み、phases/06-verification.md を実行すること。'
}

# verification
Block '検証フェーズが完了していない。phases/06-verification.md の手順を最後まで実行すること (漏れがあれば追加タスクを作って実装フェーズに戻す / 漏れゼロなら最終レポートを書いて complete-phase verification)。'
