<#
.SYNOPSIS
  検証フェーズの監査を進めるための一覧と依頼文を出す。
  オーケストレーターが .devflow/audit-plan.json (大きい) を直接読まずに済むようにする。

.DESCRIPTION
  list          : 監査の単位を 1 行ずつ出す (今のラウンドで監査が必要か、監査済みか、機械チェックの漏れ)
  prompt <unit> : その単位を implementation-auditor に渡す依頼文をそのまま出す

  監査済みかどうかは .devflow/verification-log.md の「## ラウンド <r>」節にある「### UNIT: <unit>」見出しで判定する。
  事前に `devflow-trace.ps1 -Mode full -AuditPlan` を実行しておくこと。

.EXAMPLE
  pwsh -NoProfile -File scripts/devflow-audit.ps1 list
  pwsh -NoProfile -File scripts/devflow-audit.ps1 prompt api/index.md
#>
param(
    [Parameter(Position = 0)][string]$Command = 'list',
    [Parameter(Position = 1)][string]$Unit
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'devflow-lib.psm1') -Force
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$root = Get-DevflowRoot
$planPath = Join-DevflowPath $root '.devflow/audit-plan.json'
if (-not (Test-Path -LiteralPath $planPath)) { throw '.devflow/audit-plan.json がありません。`devflow-trace.ps1 -Mode full -AuditPlan` を先に実行してください。' }
$plan = Read-Utf8 $planPath | ConvertFrom-Json
$state = Read-DevflowState $root
$round = if ($state -and $state.verification) { [int]$state.verification.round } else { 0 }

$issues = @()
$tracePath = Join-DevflowPath $root '.devflow/trace-result.json'
if (Test-Path -LiteralPath $tracePath) {
    $tr = Read-Utf8 $tracePath | ConvertFrom-Json
    if ($tr.PSObject.Properties['issues'] -and $tr.issues) { $issues = @($tr.issues) }
}

function Get-LogUnits([int]$R) {
    # verification-log.md のラウンド R 節にある UNIT 見出しと、その RESULT を返す
    $res = @{}
    $p = Join-DevflowPath $root '.devflow/verification-log.md'
    if ($R -le 0 -or -not (Test-Path -LiteralPath $p)) { return $res }
    $inRound = $false; $cur = $null
    foreach ($line in (Read-Utf8 $p) -split "`r?`n") {
        if ($line -match '^##\s*ラウンド\s*(\d+)') { $inRound = ([int]$Matches[1] -eq $R); $cur = $null; continue }
        if (-not $inRound) { continue }
        if ($line -match '^###\s*UNIT:\s*(.+?)\s*$') { $cur = $Matches[1]; $res[$cur] = ''; continue }
        if ($cur -and $line -match '^RESULT:\s*(\S+)') { $res[$cur] = $Matches[1] }
    }
    return $res
}

function Get-UnitIssues($U) {
    $ids = @($U.ids | ForEach-Object { $_.id }) + @($U.upstreamIds)
    return @($issues | Where-Object { $ids -contains $_.id })
}

function Test-NeedsAudit($U, $Prev) {
    if ($round -le 1) { return $true }
    # ラウンド 2 以降: 前ラウンドで追加したタスクを含む単位、前ラウンドで NG だった単位、機械チェックの漏れがある単位
    $prefix = "TASK-V$($round - 1)-"
    if (@($U.tasks | Where-Object { $_ -like "$prefix*" }).Count -gt 0) { return $true }
    if ($Prev.ContainsKey($U.unit) -and $Prev[$U.unit] -notmatch '^OK') { return $true }
    if ((Get-UnitIssues $U).Count -gt 0) { return $true }
    return $false
}

switch ($Command) {
    'list' {
        $done = Get-LogUnits $round
        $prev = Get-LogUnits ($round - 1)
        $rows = foreach ($u in $plan.units) {
            $need = Test-NeedsAudit $u $prev
            $audited = $done.ContainsKey($u.unit)
            $ng = @(Get-UnitIssues $u | ForEach-Object { "$($_.code):$($_.id)" }) -join ','
            [pscustomobject]@{ unit = $u.unit; need = $need; audited = $audited; ids = @($u.ids).Count; ng = $ng }
        }
        $todo = @($rows | Where-Object { $_.need -and -not $_.audited })
        Write-Output "ラウンド $round / 単位 $(@($rows).Count) / 要監査 $(@($rows | Where-Object need).Count) / 未監査 $($todo.Count)"
        foreach ($r in $rows) {
            $mark = if (-not $r.need) { '対象外' } elseif ($r.audited) { '監査済' } else { '未監査' }
            $line = "$mark`t$($r.unit)`tids=$($r.ids)"
            if ($r.ng) { $line += "`t機械チェック=$($r.ng)" }
            Write-Output $line
        }
    }
    'prompt' {
        if (-not $Unit) { throw 'prompt <unit> の形式で単位名を指定してください (list の 2 列目)' }
        $u = @($plan.units | Where-Object { $_.unit -eq $Unit }) | Select-Object -First 1
        if (-not $u) { throw "単位が見つかりません: $Unit" }
        $ids = @($u.ids | ForEach-Object { "$($_.id) ($($_.verify))" }) -join ', '
        $ng = @(Get-UnitIssues $u | ForEach-Object { "- $($_.code) $($_.id) ($($_.where))" })
        $text = @(
            "UNIT: $($u.unit)"
            '次の設計ファイルとコードだけを読み、設計がコードに漏れなく正しく反映されているか監査せよ。'
            "設計: $(@($u.designFiles) -join ', ')"
            "上流: $(@($u.upstreamFiles) -join ', ')"
            "コード: $(@($u.codeFiles) -join ', ')"
            "テスト: $(@($u.testFiles) -join ', ')"
            "対象 ID: $ids"
            "担当タスク: $(@($u.tasks) -join ', ')"
            '確認すること: (1) 設計に書かれた内容がすべてコードに反映されているか (ID がテスト名にあっても中身が不十分なケースを含む)'
            '(2) review 種別の ID が実装されているか (3) 設計と異なる実装がないか。'
            '一覧にあるファイルが存在しない場合は、それ自体を漏れとして報告する。'
        )
        if ($ng.Count -gt 0) {
            $text += '機械チェック (devflow-trace) がこの単位で次の漏れを検出している。原因 (テストがない / ID の書き漏れ / 実装がない) を特定して報告に含めること:'
            $text += $ng
        }
        Write-Output ($text -join "`n")
    }
    default { throw "未知のコマンド: $Command (list|prompt)" }
}
