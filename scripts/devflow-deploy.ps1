<#
.SYNOPSIS
  デプロイフェーズで、.devflow/config.json の deploy.targets のコマンドを実行し、結果を記録する。
  デプロイは質問なしで自動で進めるため、順序・前提の確認・失敗時の切り戻し・記録をすべてこのスクリプトが機械的に行う
  (エージェントがデプロイのコマンドを直接打たない)。

.DESCRIPTION
  plan              : デプロイ先を順に一覧し、実行できるか (前提・コマンドの有無・必要な環境変数) を確かめる。コマンドは実行しない
                      終了コード: 0 = 実行できる / 1 = 実行できない / 3 = デプロイ先が設定されていない / 4 = 検証の結果が前提を満たさない
  all               : plan の確認のあと、全デプロイ先を上から順に run する。失敗したらそこで止める (後のデプロイ先は実行しない)
                      終了コード: 0 = 全部成功 / 1 = 失敗 (または実行できない) / 3 = デプロイ先なし / 4 = 検証の結果が前提を満たさない
  run <name>        : command → smokeCommand (公開後の確認) を実行し、.devflow/deploy-log.md と state.json に記録する。
                      公開後の確認が失敗したら、deploy.rollbackOnFailure (既定 true) のとき rollbackCommand で切り戻す
                      終了コード: 0 = 成功 / 1 = デプロイ失敗・実行を拒否 / 2 = 公開後の確認が失敗
  rollback <name>   : rollbackCommand を実行し、記録する (人が手で戻すとき用)。終了コード: 0 = 成功 / 1 = 失敗 / 3 = 未設定
  status            : デプロイ先ごとの最後の結果

  前提 (all / run / plan が確かめる):
  - デプロイフェーズであること (plan を除く)
  - コードに未コミットの変更がないこと (.devflow/ と docs/ は数えない。記録を書くたびに変わるため)
  - 検証の結果: docs/verification-report.md の判定が「漏れなし」で、blocked のタスクがないこと
    (deploy.allowWithIssues が true なら飛ばす。-Force では飛ばさない)
  - 前のデプロイ先 (ステージングなど) が、今と同じコードで成功していること (-Force で飛ばす)
  コマンドの出力は .devflow/logs/deploy-<name>-<段階>.log に書き、標準出力には失敗したときの末尾だけを出す。

.EXAMPLE
  pwsh -NoProfile -File scripts/devflow-deploy.ps1 plan
  pwsh -NoProfile -File scripts/devflow-deploy.ps1 all
  pwsh -NoProfile -File scripts/devflow-deploy.ps1 rollback production
#>
param(
    [Parameter(Position = 0)][string]$Command = 'plan',
    [Parameter(Position = 1)][string]$Name,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'devflow-lib.psm1') -Force
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$root = Get-DevflowRoot
$config = Get-DevflowConfig $root
$targets = @($config.deploy.targets | Where-Object { $_ })
# デプロイするコードの範囲 (記録のコミットで HEAD が進んでも、コードが同じなら同じものとみなす)
$codeSpec = @('.', ':(exclude).devflow', ':(exclude)docs')

function Get-Field($Target, [string]$Key) {
    if ($Target -is [System.Collections.IDictionary]) { if ($Target.Contains($Key)) { return $Target[$Key] } else { return $null } }
    if ($Target.PSObject.Properties[$Key]) { return $Target.$Key }
    return $null
}

function Get-ConfigFlag([string]$Key, [bool]$Default) {
    if ($config.deploy.Contains($Key) -and $null -ne $config.deploy[$Key]) { return [bool]$config.deploy[$Key] }
    return $Default
}

function Get-Results($State) {
    if (-not $State.Contains('deployment') -or $null -eq $State.deployment) { $State.deployment = [ordered]@{} }
    if (-not $State.deployment.Contains('results') -or $null -eq $State.deployment.results) { $State.deployment.results = [ordered]@{} }
    return $State.deployment.results
}

function Get-Target([string]$TargetName) {
    if (-not $TargetName) { throw "$Command <デプロイ先の名前> の形式で指定してください" }
    $t = $targets | Where-Object { [string](Get-Field $_ 'name') -eq $TargetName } | Select-Object -First 1
    if (-not $t) { throw "deploy.targets に $TargetName がありません (有効値: $(($targets | ForEach-Object { Get-Field $_ 'name' }) -join ', '))" }
    return $t
}

function Test-SameCode([string]$Commit) {
    # $Commit と HEAD でコード (.devflow/ と docs/ 以外) が同じか
    if (-not $Commit) { return $false }
    & git -C $root diff --quiet $Commit HEAD -- @codeSpec 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-Target($Target) {
    # 実行できない理由の一覧 (空なら実行できる)。環境変数は有無だけを確かめ、値は出さない
    $ng = @()
    $n = [string](Get-Field $Target 'name')
    if ($n -notmatch '^[A-Za-z0-9_-]+$') { $ng += "名前 ``$n`` は英数字・-・_ だけにする (ログのファイル名に使うため)" }
    foreach ($key in 'command', 'smokeCommand', 'rollbackCommand') {
        $c = [string](Get-Field $Target $key)
        if (-not $c) {
            if ($key -eq 'command') { $ng += 'command が未設定です' }
            continue
        }
        $cmdName = Get-TestCommandName $c
        if (-not $cmdName) { continue }   # コマンド名のない文 (exit など) は確かめられない
        Push-Location $root
        try { $found = Get-Command $cmdName -ErrorAction SilentlyContinue } finally { Pop-Location }
        if (-not $found) { $ng += "$key のコマンド ``$cmdName`` が見つかりません (インストールと PATH を確かめる)" }
    }
    foreach ($e in @(Get-Field $Target 'requiredEnv' | Where-Object { $_ })) {
        if (-not [Environment]::GetEnvironmentVariable([string]$e)) { $ng += "環境変数 $e が設定されていません" }
    }
    return $ng
}

function Get-GateIssues {
    # 検証の結果がデプロイの前提を満たさない理由の一覧 (deploy.allowWithIssues で飛ばせる)
    if (Get-ConfigFlag 'allowWithIssues' $false) { return @() }
    $ng = @()
    $rp = Join-DevflowPath $root 'docs/verification-report.md'
    if (-not (Test-Path -LiteralPath $rp)) { $ng += 'docs/verification-report.md がありません (検証フェーズが終わっていない)' }
    elseif ((Read-Utf8 $rp) -notmatch '判定:\s*漏れなし') { $ng += 'docs/verification-report.md の判定が「漏れなし」ではありません' }
    $blocked = @(Read-TaskIndex $root $config | Where-Object { $_.Status -eq 'blocked' } | ForEach-Object { $_.Id })
    if ($blocked.Count -gt 0) { $ng += "blocked のタスクがあります: $($blocked -join ', ')" }
    return $ng
}

function Get-CodeDirty { return @(Get-UncommittedChanges $root $config $codeSpec) }

function Add-DeployLog([string]$Text) {
    $p = Join-DevflowPath $root '.devflow/deploy-log.md'
    $old = if (Test-Path -LiteralPath $p) { Read-Utf8 $p } else { "# デプロイの記録`n" }
    Write-Utf8 $p ($old + $Text)
}

function Write-LogTail([string]$LogRel) {
    Write-Host "ログの末尾 ($LogRel):"
    Get-Content -LiteralPath (Join-DevflowPath $root $LogRel) -Tail 20 | ForEach-Object { Write-Host "  $_" }
}

function Invoke-Step($Target, [string]$Key, [string]$Step) {
    $n = [string](Get-Field $Target 'name')
    return Invoke-LoggedCommand $root ([string](Get-Field $Target $Key)) ".devflow/logs/deploy-$n-$Step.log" ([int]$config.deploy.timeoutSeconds) 'deploy.timeoutSeconds'
}

function Save-Result($State, [string]$TargetName, [string]$Status, [string]$Commit, [string]$Log, [string]$Note) {
    $at = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    (Get-Results $State)[$TargetName] = [ordered]@{ status = $Status; commit = $Commit; at = $at; log = $Log }
    Write-DevflowState $root $State
    Add-DeployLog "`n## $TargetName $Status ($at)`n`n- コミット: $Commit`n- ログ: $Log`n$(if ($Note) { "- $Note`n" })"
}

function Assert-DeploymentPhase {
    $s = Read-DevflowState $root
    if (-not $s) { throw '.devflow/state.json がありません' }
    if ($s.phase -ne 'deployment') {
        Write-Host "$Command を拒否: 現在のフェーズは $($s.phase) です (デプロイフェーズでだけ実行できる)"
        exit 1
    }
    return $s
}

function Invoke-Rollback($State, $Target, [string]$Why) {
    # 切り戻し。戻り値: 結果の説明
    $n = [string](Get-Field $Target 'name')
    if (-not (Get-Field $Target 'rollbackCommand')) { return '切り戻し: rollbackCommand が未設定のため行っていない (人が手で戻すこと)' }
    Write-Host "$n を切り戻しています ($Why)..."
    $r = Invoke-Step $Target 'rollbackCommand' 'rollback'
    if ($r.ExitCode -ne 0) {
        Save-Result $State $n 'rollback-failed' $head $r.Log "$Why。切り戻しも失敗 (終了コード $($r.ExitCode))"
        Write-LogTail $r.Log
        return "切り戻し: 失敗した (人が手で戻すこと。ログ: $($r.Log))"
    }
    Save-Result $State $n 'rolled-back' $head $r.Log $Why
    return "切り戻し: 成功した (ログ: $($r.Log))"
}

function Invoke-Run($State, $Target) {
    # 1 つのデプロイ先へのデプロイ。戻り値: 終了コード (0 / 1 / 2)
    $n = [string](Get-Field $Target 'name')
    $ng = @(Test-Target $Target)
    if ((Get-CodeDirty).Count -gt 0) { $ng += 'コードに未コミットの変更があります (コミットしたものだけをデプロイする)' }
    $ng += @(Get-GateIssues)
    if (-not $Force) {
        $results = Get-Results $State
        foreach ($prev in $targets) {
            $pn = [string](Get-Field $prev 'name')
            if ($pn -eq $n) { break }
            $r = if ($results.Contains($pn)) { $results[$pn] } else { $null }
            if (-not $r -or $r.status -ne 'success' -or -not (Test-SameCode $r.commit)) {
                $ng += "前のデプロイ先 $pn が今のコードで成功していません (先に run $pn)"
            }
        }
    }
    if ($ng.Count -gt 0) {
        Write-Host "$n へのデプロイを拒否:"
        $ng | ForEach-Object { Write-Host "- $_" }
        return 1
    }
    Write-Host "$n へデプロイしています (コミット $head)..."
    $r = Invoke-Step $Target 'command' 'deploy'
    if ($r.ExitCode -ne 0) {
        $why = if ($r.TimedOut) { "deploy.timeoutSeconds ($($config.deploy.timeoutSeconds) 秒) を超えた" } else { "終了コード $($r.ExitCode)" }
        Save-Result $State $n 'deploy-failed' $head $r.Log $why
        Write-Host "NG: $n へのデプロイが失敗しました ($why)"
        Write-LogTail $r.Log
        return 1
    }
    if (-not (Get-Field $Target 'smokeCommand')) {
        Save-Result $State $n 'success' $head $r.Log '公開後の確認: なし (smokeCommand 未設定)'
        Write-Host "OK: $n へデプロイしました (公開後の確認は未設定。ログ: $($r.Log))"
        return 0
    }
    $sm = Invoke-Step $Target 'smokeCommand' 'smoke'
    if ($sm.ExitCode -ne 0) {
        $why = if ($sm.TimedOut) { '公開後の確認がタイムアウト' } else { "公開後の確認が失敗 (終了コード $($sm.ExitCode))" }
        Save-Result $State $n 'smoke-failed' $head $sm.Log "$why。デプロイのログ: $($r.Log)"
        Write-Host "NG: $n へのデプロイは終わったが、$why"
        Write-LogTail $sm.Log
        if (Get-ConfigFlag 'rollbackOnFailure' $true) { Write-Host (Invoke-Rollback $State $Target $why) }
        else { Write-Host '切り戻し: deploy.rollbackOnFailure が false のため行っていない' }
        return 2
    }
    Save-Result $State $n 'success' $head $r.Log "公開後の確認: 成功 ($($sm.Log))"
    Write-Host "OK: $n へデプロイし、公開後の確認も成功しました (ログ: $($r.Log)、$($sm.Log))"
    return 0
}

$head = (& git -C $root rev-parse --short HEAD 2>$null)

switch ($Command) {
    'plan' {
        if ($targets.Count -eq 0) { Write-Output 'デプロイ先が設定されていません (.devflow/config.json の deploy.targets)'; exit 3 }
        $s = Read-DevflowState $root
        $results = if ($s) { Get-Results $s } else { @{} }
        $branch = (& git -C $root rev-parse --abbrev-ref HEAD 2>$null)
        Write-Output "デプロイ先 $($targets.Count) 件 (コミット $head、ブランチ $branch、上から順に実行する):"
        $ng = @()
        $i = 0
        foreach ($t in $targets) {
            $i++
            $n = [string](Get-Field $t 'name')
            Write-Output "$i. $n"
            Write-Output "   デプロイ: $(Get-Field $t 'command')"
            Write-Output "   公開後の確認: $(if (Get-Field $t 'smokeCommand') { Get-Field $t 'smokeCommand' } else { 'なし' })"
            Write-Output "   切り戻し: $(if (Get-Field $t 'rollbackCommand') { Get-Field $t 'rollbackCommand' } else { 'なし' })"
            if ($results.Contains($n)) {
                $r = $results[$n]
                $same = if (Test-SameCode $r.commit) { '今と同じコード' } else { '今と違うコード' }
                Write-Output "   前回: $($r.status) ($($r.commit)、$same、$($r.at))"
            }
            $ng += @(Test-Target $t | ForEach-Object { "${n}: $_" })
        }
        $dirty = @(Get-CodeDirty)
        if ($dirty.Count -gt 0) { $ng += "コードに未コミットの変更が $($dirty.Count) 件あります (コミットしたものだけをデプロイする)" }
        $gate = @(Get-GateIssues)
        if ($gate.Count -gt 0) {
            Write-Output '検証の結果がデプロイの前提を満たしません (deploy.allowWithIssues が false):'
            $gate | ForEach-Object { Write-Output "- $_" }
            exit 4
        }
        if ($ng.Count -gt 0) {
            Write-Output '実行できません:'
            $ng | ForEach-Object { Write-Output "- $_" }
            exit 1
        }
        Write-Output 'OK (実行できる)'
    }
    'all' {
        if ($targets.Count -eq 0) { Write-Output 'デプロイ先が設定されていません (.devflow/config.json の deploy.targets)'; exit 3 }
        $s = Assert-DeploymentPhase
        $gate = @(Get-GateIssues)
        if ($gate.Count -gt 0) {
            Write-Output 'デプロイしません: 検証の結果がデプロイの前提を満たしません (deploy.allowWithIssues が false):'
            $gate | ForEach-Object { Write-Output "- $_" }
            exit 4
        }
        $results = Get-Results $s
        foreach ($t in $targets) {
            $n = [string](Get-Field $t 'name')
            $r = if ($results.Contains($n)) { $results[$n] } else { $null }
            if ($r -and $r.status -eq 'success' -and (Test-SameCode $r.commit)) {
                Write-Output "skip: $n は今と同じコードでデプロイ済み ($($r.commit)、$($r.at))"
                continue
            }
            $code = Invoke-Run $s $t
            if ($code -ne 0) {
                $rest = @($targets | Select-Object -Skip ([Array]::IndexOf($targets, $t) + 1) | ForEach-Object { Get-Field $_ 'name' })
                if ($rest.Count -gt 0) { Write-Output "後のデプロイ先は実行していません: $($rest -join ', ')" }
                exit 1
            }
        }
        Write-Output 'OK: 全デプロイ先へのデプロイが成功しました'
    }
    'run' {
        $s = Assert-DeploymentPhase
        $t = Get-Target $Name
        exit (Invoke-Run $s $t)
    }
    'rollback' {
        $s = Assert-DeploymentPhase
        $t = Get-Target $Name
        if (-not (Get-Field $t 'rollbackCommand')) { Write-Output "$Name には rollbackCommand が設定されていません (人が手で戻す)"; exit 3 }
        $msg = Invoke-Rollback $s $t '人の指示'
        Write-Output $msg
        if ($msg -notmatch '成功') { exit 1 }
    }
    'status' {
        $s = Read-DevflowState $root
        $results = if ($s) { Get-Results $s } else { @{} }
        if ($targets.Count -eq 0) { Write-Output 'デプロイ先が設定されていません'; exit 0 }
        foreach ($t in $targets) {
            $n = [string](Get-Field $t 'name')
            if ($results.Contains($n)) {
                $r = $results[$n]
                $same = if (Test-SameCode $r.commit) { '今と同じコード' } else { '今と違うコード' }
                Write-Output "$n : $($r.status) ($($r.commit)、$same、$($r.at))"
            } else { Write-Output "$n : 未実行" }
        }
    }
    default {
        throw "未知のコマンド: $Command (plan|all|run|rollback|status)"
    }
}
