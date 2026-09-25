<#
.SYNOPSIS
  実装・検証フェーズの自動ループ。`claude -p` を繰り返し起動し、各セッションは
  state.json と handoff.md から続きを再開する。

.DESCRIPTION
  終了条件:
    - state.json の phase が done になった (検証で漏れゼロ、または残りが blocked のみ)  → exit 0
    - 進捗のないセッションが maxNoProgress 回続いた                                   → exit 3
    - maxIterations 回に達した                                                        → exit 4
    - phase が implementation / verification 以外                                     → exit 2

  進捗の判定: git HEAD、state.json、tasks/index.md のいずれかが変化したか。

.EXAMPLE
  pwsh -NoProfile -File scripts/devflow-implement.ps1
  pwsh -NoProfile -File scripts/devflow-implement.ps1 -MaxIterations 5 -ContextThreshold 20
#>
param(
    [int]$MaxIterations = 0,
    [double]$ContextThreshold = 0,   # 省略時は config.contextThresholdPercent
    [string]$Model = '',
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'devflow-lib.psm1') -Force
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$root = Get-DevflowRoot
Set-Location $root
$config = Get-DevflowConfig $root
if ($MaxIterations -le 0) { $MaxIterations = [int]$config.maxIterations }
if ($ContextThreshold -gt 0) { $env:DEVFLOW_CONTEXT_THRESHOLD = [string]$ContextThreshold }

$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) { Write-Error 'claude コマンドが見つかりません'; exit 2 }

$logDir = Join-DevflowPath $root '.devflow/logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Get-Fingerprint {
    $parts = @((& git rev-parse HEAD 2>$null))
    foreach ($rel in '.devflow/state.json', 'docs/04-detailed-design/tasks/index.md') {
        $p = Join-DevflowPath $root $rel
        if (Test-Path -LiteralPath $p) { $parts += (Get-FileHash -LiteralPath $p -Algorithm SHA1).Hash }
    }
    return ($parts -join ':')
}

function Write-Log([string]$Text) {
    $line = "[$((Get-Date).ToString('HH:mm:ss'))] $Text"
    Write-Host $line
    Add-Content -LiteralPath (Join-Path $logDir 'loop.log') -Value $line -Encoding utf8
}

$env:DEVFLOW_AUTOLOOP = '1'
# サブエージェントを前面で実行させ、結果を待ってから次に進ませる
$env:CLAUDE_CODE_DISABLE_BACKGROUND_TASKS = '1'
# 閾値前に自動 compact が走った場合の安全網 (下げることしかできない)
if ($config.autoCompactPercent) { $env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = [string]$config.autoCompactPercent }

$noProgress = 0
for ($i = 1; $i -le $MaxIterations; $i++) {
    $state = Read-DevflowState $root
    if (-not $state) { Write-Log 'state.json がありません'; exit 2 }
    if ($state.phase -eq 'done') { Write-Log '全フェーズ完了。docs/verification-report.md を確認してください'; exit 0 }
    if ($state.phase -notin @('implementation', 'verification')) {
        Write-Log "現在フェーズは $($state.phase) です。実装ループは implementation / verification でのみ動きます"
        exit 2
    }

    $before = Get-Fingerprint
    $n = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'devflow-state.ps1') session
    $impl = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'devflow-state.ps1') impl-status | ConvertFrom-Json
    Write-Log "セッション $n 開始 (反復 $i/$MaxIterations, phase=$($state.phase), タスク done=$($impl.counts.done) blocked=$($impl.counts.blocked) 全体=$($impl.total))"

    $prompt = "/dev-flow auto"
    $cargs = @('-p', $prompt, '--output-format', 'json') + @($config.claudeArgs) + $ExtraArgs
    if ($Model) { $cargs += @('--model', $Model) }
    $out = Join-Path $logDir ("session-{0:D3}.json" -f [int]$n)
    $err = Join-Path $logDir ("session-{0:D3}.stderr.log" -f [int]$n)
    # stdin を空で閉じる (claude -p が stdin を 3 秒待つのを避ける)
    $null | & $claude.Source @cargs 2> $err | Out-File -LiteralPath $out -Encoding utf8
    $code = $LASTEXITCODE

    $summary = ''
    try {
        $res = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        $cost = if ($res.PSObject.Properties['total_cost_usd']) { '{0:N2}' -f [double]$res.total_cost_usd } else { '?' }
        $turns = if ($res.PSObject.Properties['num_turns']) { $res.num_turns } else { '?' }
        $text = [string]$res.result
        if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '…' }
        $summary = "exit=$code turns=$turns cost=`$$cost :: $($text -replace '\s+', ' ')"
    } catch { $summary = "exit=$code (JSON 出力を解析できません: $out)" }
    Write-Log "セッション $n 終了 $summary"

    $after = Get-Fingerprint
    if ($after -eq $before) {
        $noProgress++
        Write-Log "進捗なし ($noProgress/$($config.maxNoProgress))"
        if ($noProgress -ge [int]$config.maxNoProgress) {
            Write-Log '進捗のないセッションが続いたため停止します。.devflow/blocked.md と .devflow/logs/ を確認してください'
            exit 3
        }
    } else {
        $noProgress = 0
    }
}
Write-Log "最大反復回数 ($MaxIterations) に達したため停止します"
exit 4
