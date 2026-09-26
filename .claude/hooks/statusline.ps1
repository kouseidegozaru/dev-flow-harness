# ステータスライン
#
# Claude Code から渡される JSON の context_window.used_percentage を使い、フェーズとコンテキスト使用率を 1 行で表示する。
# (対話セッションの表示用。実装担当 (サブエージェント) の使用率は PostToolUse / SubagentStop フックが transcript から計算する)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
Import-Module (Join-Path $PSScriptRoot '../../scripts/devflow-lib.psm1') -Force

$in = Read-StdinJson
$root = if ($in -and $in.workspace -and $in.workspace.project_dir) { [string]$in.workspace.project_dir } else { Get-DevflowRoot }

$cw = if ($in) { $in.context_window } else { $null }
$pct = $null
if ($cw -and $cw.PSObject.Properties['used_percentage'] -and $null -ne $cw.used_percentage) { $pct = [double]$cw.used_percentage }

$state = Read-DevflowState $root

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
