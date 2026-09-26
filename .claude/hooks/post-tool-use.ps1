# PostToolUse フック (実装担当 tdd-implementer の中だけで動く)
#
# 実装担当のツール実行のたびに、そのサブエージェント自身のコンテキスト使用率を transcript から計算する。
# 閾値を超えていたら、きりの良いところで引き継ぐよう指示を渡す (additionalContext はサブエージェントに届く)。

$ErrorActionPreference = 'Stop'
$raw = [Console]::In.ReadToEnd()
# 実装担当以外 (メイン会話・他のサブエージェント) では何もしない。モジュール読み込みの前に軽く判定する
if ($raw -notmatch '"agent_type"\s*:\s*"tdd-implementer"') { exit 0 }

Import-Module (Join-Path $PSScriptRoot '../../scripts/devflow-lib.psm1') -Force
$in = $raw | ConvertFrom-Json
$root = Get-DevflowRoot
$state = Read-DevflowState $root
if (-not $state -or $state.phase -ne 'implementation') { exit 0 }
$config = Get-DevflowConfig $root

$usage = Get-AgentContextUsage $config $in
if (-not $usage) { exit 0 }
$run = Get-ImplementerRun $root ([string]$in.agent_id)
if (-not $run.baseTokens) { $run.baseTokens = $usage.Tokens; Write-ImplementerRun $root $run }
if (-not (Test-ContextOver $config $usage $run.baseTokens)) { exit 0 }

$msg = ('[dev-flow] 実装担当のコンテキスト使用率 {0:N0}% (閾値 {1}%)。新しいタスクには着手しないこと。' -f $usage.Percent, $config.contextThresholdPercent) +
    '今のタスクを完了させるか、コミットできる区切り (Red / Green / Refactor のどれかのコミット) まで進めたら、' +
    'tdd-implementer の手順「引き継いで終える」に従い、.devflow/handoff.md を更新してコミットし、報告して終了すること。次の実装担当が handoff.md から再開する。'
Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $msg } }
exit 0
