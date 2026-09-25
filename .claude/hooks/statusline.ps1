# ステータスライン
#
# Claude Code から渡される JSON の context_window.used_percentage を .devflow/context-usage に
# 書き出し、フェーズとコンテキスト使用率を 1 行で表示する。
# (対話セッション用。-p の自動ループでは PostToolUse / Stop フックが transcript から計算する)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
Import-Module (Join-Path $PSScriptRoot '../../scripts/devflow-lib.psm1') -Force

$in = Read-StdinJson
$root = if ($in -and $in.workspace -and $in.workspace.project_dir) { [string]$in.workspace.project_dir } else { Get-DevflowRoot }

$cw = if ($in) { $in.context_window } else { $null }
$pct = $null
$window = 200000
$tokens = 0
if ($cw) {
    if ($cw.PSObject.Properties['context_window_size'] -and $cw.context_window_size) { $window = [double]$cw.context_window_size }
    if ($cw.PSObject.Properties['used_percentage'] -and $null -ne $cw.used_percentage) { $pct = [double]$cw.used_percentage }
    if ($cw.PSObject.Properties['total_input_tokens'] -and $cw.total_input_tokens) { $tokens = [double]$cw.total_input_tokens }
}

$state = Read-DevflowState $root
if ($null -ne $pct -and (Test-Path -LiteralPath (Join-DevflowPath $root '.devflow'))) {
    $sid = if ($in -and $in.PSObject.Properties['session_id']) { [string]$in.session_id } else { '' }
    try { Write-ContextUsage $root $pct $tokens $window 'statusline' $sid } catch {}
}

$esc = [char]27
$model = if ($in -and $in.model -and $in.model.display_name) { $in.model.display_name } else { 'Claude' }
$parts = @("$esc[1m$model$esc[0m")
if ($state) { $parts += "dev-flow: $(Get-PhaseLabel ([string]$state.phase))" }
if ($null -ne $pct) {
    $color = if ($pct -ge 50) { "$esc[31m" } elseif ($pct -ge 35) { "$esc[33m" } else { "$esc[32m" }
    $parts += ("{0}ctx {1:N0}%{2}" -f $color, $pct, "$esc[0m")
} else {
    $parts += 'ctx --%'
}
Write-Host ($parts -join ' | ')
