<#
.SYNOPSIS
  dev-flow ハーネスを対象プロジェクトに導入する。

.DESCRIPTION
  コピーするもの: .claude/skills/dev-flow、.claude/agents の 3 エージェント、.claude/hooks、scripts/devflow-*
  .claude/settings.json は、既存のものがあればフックを追記し、statusLine は未設定のときだけ設定する。
  .gitignore に dev-flow の一時ファイルを追記する。

.EXAMPLE
  pwsh -NoProfile -File scripts/devflow-install.ps1 -Target C:\work\my-app
#>
param(
    [Parameter(Mandatory)][string]$Target,
    [switch]$Force   # 既存のハーネスファイルを上書きする
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
$src =(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Force -Path $Target | Out-Null }
$dst = (Resolve-Path -LiteralPath $Target).Path
if (-not (Test-Path -LiteralPath (Join-Path $dst '.git'))) { Write-Warning "$dst は git リポジトリではありません。dev-flow はコミットを前提にしています (git init を実行してください)" }

function Copy-Item2([string]$Rel) {
    $from = Join-Path $src $Rel
    $to = Join-Path $dst $Rel
    if ((Test-Path -LiteralPath $to) -and -not $Force) { Write-Output "skip (既存): $Rel"; return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
    Write-Output "copy: $Rel"
}

Copy-Item2 '.claude/skills/dev-flow'
if (-not (Test-Path -LiteralPath (Join-Path $dst '.gitattributes'))) { Copy-Item2 '.gitattributes' } elseif (-not (Select-String -LiteralPath (Join-Path $dst '.gitattributes') -Pattern '*.sh' -SimpleMatch -Quiet)) { Add-Content -LiteralPath (Join-Path $dst '.gitattributes') -Value '*.sh text eol=lf'; Write-Output 'update: .gitattributes' }
foreach ($a in 'design-reviewer', 'screen-designer', 'tdd-implementer', 'implementation-auditor') { Copy-Item2 ".claude/agents/$a.md" }
foreach ($h in Get-ChildItem -LiteralPath (Join-Path $src '.claude/hooks') -File) { Copy-Item2 ".claude/hooks/$($h.Name)" }
foreach ($s in Get-ChildItem -LiteralPath (Join-Path $src 'scripts') -File -Filter 'devflow-*') {
    if ($s.Name -like 'devflow-install*') { continue }
    Copy-Item2 "scripts/$($s.Name)"
}

# settings.json のマージ
$ours = Get-Content -LiteralPath (Join-Path $src '.claude/settings.json') -Raw | ConvertFrom-Json -AsHashtable
$settingsPath = Join-Path $dst '.claude/settings.json'
if (Test-Path -LiteralPath $settingsPath) {
    $theirs = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $theirs.Contains('hooks')) { $theirs['hooks'] = [ordered]@{} }
    foreach ($ev in $ours.hooks.Keys) {
        $existing = if ($theirs.hooks.Contains($ev)) { @($theirs.hooks[$ev]) } else { @() }
        $json = ($existing | ConvertTo-Json -Depth 10)
        foreach ($entry in $ours.hooks[$ev]) {
            $script = [string]$entry.hooks[0].args[-1]
            if ($json -and $json.Contains([System.IO.Path]::GetFileName($script))) { continue }   # 導入済み
            $existing += $entry
        }
        $theirs.hooks[$ev] = $existing
    }
    if (-not $theirs.Contains('statusLine')) { $theirs['statusLine'] = $ours.statusLine }
    else { Write-Output 'statusLine は既存の設定を残しました (dev-flow のステータスラインは任意。README 参照)' }
    ($theirs | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $settingsPath -Encoding utf8NoBOM
    Write-Output 'merge: .claude/settings.json'
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsPath) | Out-Null
    Copy-Item -LiteralPath (Join-Path $src '.claude/settings.json') -Destination $settingsPath
    Write-Output 'copy: .claude/settings.json'
}

# .gitignore
$ignore = @(
    '# dev-flow の一時ファイル',
    '.devflow/context-usage',
    '.devflow/loop-session.json',
    '.devflow/logs/',
    '.devflow/trace-*.json',
    '.devflow/audit-plan.json'
)
$gi = Join-Path $dst '.gitignore'
$cur = if (Test-Path -LiteralPath $gi) { Get-Content -LiteralPath $gi } else { @() }
$add = @($ignore | Where-Object { $cur -notcontains $_ })
if ($add.Count -gt 0) { Add-Content -LiteralPath $gi -Value (@('') + $add) -Encoding utf8; Write-Output 'update: .gitignore' }

Write-Output ''
Write-Output "導入しました: $dst"
Write-Output '次の手順: 対象プロジェクトで claude を起動し、/dev-flow を実行してください'
