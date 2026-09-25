<#
.SYNOPSIS
  TDD のコミット規約を機械的に守らせるコミット用スクリプト。

.DESCRIPTION
  -Kind test     : Red。テストが「失敗する」ことを確認してからコミットする (成功したら拒否)
  -Kind feat     : Green。全テストが成功することを確認してからコミットする
  -Kind refactor : Refactor。全テストが成功することを確認してからコミットする
  -Kind fix      : 検証フェーズなどでの修正。全テスト成功が必要
  -Kind docs / chore : テストを実行しない

  メッセージは "<kind>(<scope>): <message>" になる。
  終了コード: 0 = コミット済み / 1 = 条件を満たさず拒否 / 2 = エラー

.EXAMPLE
  pwsh -NoProfile -File scripts/devflow-commit.ps1 -Kind test -Scope TASK-003 -Message "期限切れ判定のテストを追加"
#>
param(
    [Parameter(Mandatory)][ValidateSet('test', 'feat', 'refactor', 'fix', 'docs', 'chore')][string]$Kind,
    [Parameter(Mandatory)][string]$Scope,
    [Parameter(Mandatory)][string]$Message,
    [string[]]$Paths = @()   # 省略時は git add -A
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'devflow-lib.psm1') -Force
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$root = Get-DevflowRoot
$config = Get-DevflowConfig $root
Set-Location $root

function Invoke-Tests {
    if (-not $config.test.command) { Write-Output 'test.command が未設定です (.devflow/config.json)'; exit 2 }
    $log = Join-DevflowPath $root '.devflow/logs/commit-test-run.log'
    New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
    & pwsh -NoProfile -Command $config.test.command *> $log
    $code = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $code; Log = $log }
}

$pending = @(& git status --porcelain -- @Paths | Where-Object { $_ })
if ($pending.Count -eq 0) { Write-Output 'コミットする変更がありません'; exit 1 }

# テストを先に実行し、条件を満たしたときだけステージする (テスト実行の生成物を巻き込まないため)
switch ($Kind) {
    'test' {
        $r = Invoke-Tests
        if ($r.ExitCode -eq 0) {
            Write-Output "Red コミットを拒否: テストが成功しています。先に失敗するテストを書くこと (ログ: $($r.Log))"
            exit 1
        }
        Write-Output "Red 確認: テストは失敗しています (exit $($r.ExitCode))"
    }
    { $_ -in @('feat', 'refactor', 'fix') } {
        $r = Invoke-Tests
        if ($r.ExitCode -ne 0) {
            Write-Output "$Kind コミットを拒否: テストが失敗しています (exit $($r.ExitCode))。ログ末尾:"
            Get-Content -LiteralPath $r.Log -Tail 30 | ForEach-Object { Write-Output "  $_" }
            exit 1
        }
        Write-Output '全テスト成功を確認'
    }
}

if ($Paths.Count -gt 0) { & git add -- @Paths } else { & git add -A }
if ($LASTEXITCODE -ne 0) { exit 2 }
& git diff --cached --quiet
if ($LASTEXITCODE -eq 0) { Write-Output 'コミットする変更がありません'; exit 1 }

& git commit -q -m "${Kind}(${Scope}): $Message"
if ($LASTEXITCODE -ne 0) { exit 2 }
Write-Output ("コミットしました: " + (& git log -1 --format='%h %s'))
exit 0
