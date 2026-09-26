<#
.SYNOPSIS
  TDD のコミット規約を機械的に守らせるコミット用スクリプト。

.DESCRIPTION
  -Kind test     : Red。テストが「失敗する」ことを確認してからコミットする (成功したら拒否)。
                   結果ファイルに ID を名前に含む失敗したテストがなければ、環境の不備とみなして拒否する
  テストは test.timeoutSeconds を超えると止め、コミットを拒否する
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
    $r = Invoke-TestCommand $root $config '.devflow/logs/commit-test-run.log'
    if ($r.TimedOut) {
        Write-Output "コミットを拒否: テストが test.timeoutSeconds ($($config.test.timeoutSeconds) 秒) 以内に終わりませんでした (ログ: $($r.Log))。"
        Write-Output 'ウォッチモードで起動していないか、無限ループや入力待ちになっていないかを確かめること'
        exit 1
    }
    return $r
}

function Write-LogTail($r) {
    Get-Content -LiteralPath (Join-DevflowPath $root $r.Log) -Tail 30 | ForEach-Object { Write-Output "  $_" }
}

$pending = @(Get-UncommittedChanges $root $config $Paths)
if ($pending.Count -eq 0) { Write-Output 'コミットする変更がありません'; exit 1 }

# テストを先に実行し、条件を満たしたときだけステージする
switch ($Kind) {
    'test' {
        $r = Invoke-Tests
        if ($r.ExitCode -eq 0) {
            Write-Output "Red コミットを拒否: テストが成功しています。先に失敗するテストを書くこと (ログ: $($r.Log))"
            exit 1
        }
        # 環境の不備 (テストランナーがない、ビルドが通らない) は Red とみなさない:
        # 結果ファイルに「ID を名前に含む、失敗したテスト」が 1 件以上あることを確かめる
        $idre = Get-IdRegex $config
        $failed = @(Read-TestResultFiles $root $config | Where-Object {
            $_.outcome -notin @('passed', 'skipped', 'notexecuted') -and @(Get-IdsInText $_.name $idre).Count -gt 0 })
        if ($failed.Count -eq 0) {
            Write-Output "Red コミットを拒否: テストコマンドは失敗しましたが (exit $($r.ExitCode))、結果ファイルに ID を名前に含む失敗したテストがありません。"
            Write-Output 'ビルドエラー (コンパイルエラーは Red ではない)、テストランナーの不在、結果ファイルの出力先 (test.resultGlobs) の誤りのどれか。ログ末尾:'
            Write-LogTail $r
            exit 1
        }
        # タスクの Red なら、失敗したテストの中にそのタスクの担当 ID を含むものがあることを確かめる
        # (新しく書いたテストが実際に失敗していることの確認。無関係なテストの失敗や、テスト名への ID の書き漏れで通さない)
        $assigned = Get-TaskAssignedIds $root $config $Scope
        if ($null -ne $assigned -and $assigned.Count -gt 0) {
            $mine = @($failed | Where-Object { @(Get-IdsInText $_.name $idre | Where-Object { $assigned -contains $_ }).Count -gt 0 })
            if ($mine.Count -eq 0) {
                Write-Output "Red コミットを拒否: 失敗したテストに、$Scope の担当 ID ($($assigned -join ', ')) を名前に含むものがありません。"
                Write-Output "失敗したテスト: $(($failed | Select-Object -First 5 | ForEach-Object { $_.name }) -join '; ')"
                Write-Output '新しく書いたテストの名前に担当 ID が入っているか、そのテストが実際に失敗しているかを確かめること'
                exit 1
            }
            $failed = $mine
        }
        Write-Output "Red 確認: テストは失敗しています (exit $($r.ExitCode)、失敗: $(($failed | Select-Object -First 5 | ForEach-Object { $_.name }) -join '; '))"
    }
    { $_ -in @('feat', 'refactor', 'fix') } {
        $r = Invoke-Tests
        if ($r.ExitCode -ne 0) {
            Write-Output "$Kind コミットを拒否: テストが失敗しています (exit $($r.ExitCode))。ログ末尾:"
            Write-LogTail $r
            exit 1
        }
        Write-Output '全テスト成功を確認'
    }
}

# テスト結果ファイル (test.resultGlobs) はテストを実行するたびに作り直される生成物なので、.gitignore になくてもコミットしない
# (除外の pathspec を git add に渡すと、結果ファイルの場所が .gitignore 済みのとき git add がエラーになるため、ステージ後に外す)
if ($Paths.Count -gt 0) { & git add -- @Paths } else { & git add -A }
if ($LASTEXITCODE -ne 0) { exit 2 }
$staged = @(& git diff --cached --name-only | Where-Object { $_ })
$results = @(Select-ByGlobs $staged $config.test.resultGlobs)
if ($results.Count -gt 0) {
    & git reset -q -- @results
    if ($LASTEXITCODE -ne 0) { exit 2 }
}
& git diff --cached --quiet
if ($LASTEXITCODE -eq 0) { Write-Output 'コミットする変更がありません'; exit 1 }

& git commit -q -m "${Kind}(${Scope}): $Message"
if ($LASTEXITCODE -ne 0) { exit 2 }
Write-Output ("コミットしました: " + (& git log -1 --format='%h %s'))
exit 0
