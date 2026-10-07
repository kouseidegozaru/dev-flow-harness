# SubagentStart フック (matcher: tdd-implementer)
#
# 実装担当が起動したら、その実行記録 .devflow/implementer.json を作り直す
# (開始時刻は SubagentStop フックが handoff.md の更新有無を判定するのに、開始時の使用量は Test-ContextOver が使う)。

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/devflow-lib.psm1') -Force

$in = Read-StdinJson
if (-not $in -or -not $in.PSObject.Properties['agent_id']) { exit 0 }
$root = Get-DevflowRoot
$state = Read-DevflowState $root
if (-not $state -or $state.phase -ne 'implementation') { exit 0 }
New-ImplementerRun $root ([string]$in.agent_id) | Out-Null
exit 0
