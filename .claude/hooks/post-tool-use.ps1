# PostToolUse フック (自動ループ専用)
#
# ツール実行のたびにコンテキスト使用率を計算して .devflow/context-usage に書き出す。
# 閾値を超えていたら、セッションを締める指示を Claude に渡す。
# (-p 実行ではステータスラインが動かないため、使用率の監視はこのフックが主となる)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/devflow-lib.psm1') -Force

if ($env:DEVFLOW_AUTOLOOP -ne '1') { exit 0 }

$in = Read-StdinJson
$root = Get-DevflowRoot
$state = Read-DevflowState $root
if (-not $state -or $state.phase -notin @('implementation', 'verification')) { exit 0 }
$config = Get-DevflowConfig $root

$usage = Get-ContextUsage $root $config $in
if (-not $usage) { exit 0 }
Update-LoopBaseTokens $root $usage
$threshold = [double]$config.contextThresholdPercent
if (-not (Test-ContextOver $root $config $usage)) { exit 0 }

$msg = ('[dev-flow] コンテキスト使用率 {0:N0}% (閾値 {1}%)。新しいタスクには着手しないこと。' -f $usage.Percent, $threshold) +
    '今のタスクがコミット可能な区切りに達したら (または今すぐ中断して)、手順書の「セッションの終え方」に従い、' +
    '.devflow/handoff.md を更新し、変更をコミットしてから応答を終えること。次のセッションが handoff.md から再開する。'
Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $msg } }
exit 0
