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
                      / 5 = MCP で行うデプロイ先の手順を出して止まった (下の kind が agent)
  run <name>        : command → smokeCommand (公開後の確認) を実行し、.devflow/deploy-log.md と state.json に記録する。
                      公開後の確認が失敗したら、deploy.rollbackOnFailure (既定 true) のとき rollbackCommand で切り戻す
                      終了コード: 0 = 成功 / 1 = デプロイ失敗・実行を拒否 / 2 = 公開後の確認が失敗
  rollback <name>   : rollbackCommand を実行し、記録する (人が手で戻すとき用)。終了コード: 0 = 成功 / 1 = 失敗 / 3 = 未設定
  status            : デプロイ先ごとの最後の結果

  kind が agent のデプロイ先 (MCP で行う。秘密の値を環境変数に用意しなくて済むため):
  all はそのデプロイ先の前提を確かめて agent-pending と記録し、手順 (steps) を出して exit 5 で止まる。
  オーケストレーターが steps どおりに MCP のツールで行い、結果を finish で記録してから、all をもう一度実行する
  finish <name> -Result success|failed [-Note ...]
                    : agent の結果を記録する。success なら smokeCommand を実行する。確認が失敗したら、rollbackCommand があれば実行し、
                      rollbackSteps しかなければ手順を出す (MCP で戻して rollback-done で記録する)
                      終了コード: 0 = 成功 / 1 = デプロイ失敗・拒否 / 2 = 公開後の確認が失敗
  rollback-done <name> -Result success|failed : MCP で行った切り戻しの結果を記録する

  秘密の値 (requiredEnv の環境変数) と vault (deploy.vault。Doppler・1Password・Infisical など):
  環境変数にない値は、vault の getCommand で取り出し、このスクリプトのプロセスの環境変数にだけ入れる (ファイルには書かない)。
  デプロイ・確認・切り戻しのコマンドは、その環境変数を引き継ぐ。vault の CLI がなければ installCommand で入れる
  secrets           : 必要な秘密の値が揃っているかと、足りないものの入手方法 (deploy.secrets の source) を一覧にする
                      終了コード: 0 = 揃っている / 1 = 足りない
  set-secret <NAME> -Value <値> : vault の setCommand で vault に保存する (値は標準入力で渡す)。以後のデプロイで使い回す

  前提 (all / run / plan が確かめる):
  - デプロイフェーズであること (plan を除く)
  - コードに未コミットの変更がないこと (.devflow/ と docs/ は数えない。記録を書くたびに変わるため)
  - 検証の結果: docs/verification-report.md の判定が「漏れなし」で、blocked のタスクがないこと
    (deploy.allowWithIssues が true なら飛ばす。-Force では飛ばさない。本番のデプロイ先では飛ばせない)
  - 本番のデプロイ先 (production: true、または名前が prod / production / 本番): 上に加えて、決定台帳に open の 処置-B (繰延べ) と
    要回答 が 0 件であること。allowWithIssues の代わりに、最後の 1 回 (debrief) でユーザーが答えて台帳を解決にする
  - 前のデプロイ先 (ステージングなど) が、今と同じコードで成功していること (-Force で飛ばす)
  コマンドの出力は .devflow/logs/deploy-<name>-<段階>.log に書き、標準出力には失敗したときの末尾だけを出す。

.EXAMPLE
  pwsh -NoProfile -File scripts/devflow-deploy.ps1 plan
  pwsh -NoProfile -File scripts/devflow-deploy.ps1 all
  pwsh -NoProfile -File scripts/devflow-deploy.ps1 rollback production
  pwsh -NoProfile -File scripts/devflow-deploy.ps1 finish preview -Result success -Note 'https://xxx.vercel.app'
#>
param(
    [Parameter(Position = 0)][string]$Command = 'plan',
    [Parameter(Position = 1)][string]$Name,
    [ValidateSet('', 'success', 'failed')][string]$Result = '',
    [string]$Note = '',
    [string]$Value = '',
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

function Get-Vault {
    if ($config.deploy.Contains('vault') -and $config.deploy.vault) { return $config.deploy.vault }
    return $null
}

function Expand-VaultCommand([string]$Template, [string]$EnvName) {
    if ($EnvName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "環境変数名として使えません: $EnvName" }
    return $Template.Replace('{name}', $EnvName)
}

function Invoke-Capture([string]$Cmd, [string]$InputText = $null) {
    # コマンドを実行し、標準出力をメモリに受け取る (秘密の値を扱うので、ログのファイルには書かない)
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("`$PSStyle.OutputRendering = 'PlainText'`n" + $Cmd))
    Push-Location $root
    try {
        if ($null -ne $InputText) { $out = $InputText | & pwsh -NoProfile -NonInteractive -EncodedCommand $enc 2>$null }
        else { $out = & pwsh -NoProfile -NonInteractive -EncodedCommand $enc 2>$null }
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    return [pscustomobject]@{ ExitCode = $code; Output = (@($out) -join "`n").Trim() }
}

function Test-CommandExists([string]$Cmd) {
    $cmdName = Get-TestCommandName $Cmd
    if (-not $cmdName) { return $true }
    Push-Location $root
    try { return [bool](Get-Command $cmdName -ErrorAction SilentlyContinue) } finally { Pop-Location }
}

function Get-VaultIssues {
    # vault を使えない理由の一覧 (vault がなければ空)。CLI がなければ installCommand で入れる
    $v = Get-Vault
    if (-not $v) { return @() }
    $ng = @()
    $get = [string](Get-Field $v 'getCommand')
    if (-not $get) { return @('deploy.vault.getCommand が未設定です') }
    if (-not (Test-CommandExists $get)) {
        $inst = [string](Get-Field $v 'installCommand')
        if ($inst) {
            Write-Host "vault の CLI がないため、installCommand で入れています..."
            $r = Invoke-LoggedCommand $root $inst '.devflow/logs/deploy-vault-install.log' ([int]$config.deploy.timeoutSeconds) 'deploy.timeoutSeconds'
            if ($r.ExitCode -ne 0) { $ng += "vault の CLI を入れられませんでした (ログ: $($r.Log))" }
        }
        if (-not (Test-CommandExists $get)) { $ng += "vault の CLI ``$(Get-TestCommandName $get)`` が見つかりません (deploy.vault.installCommand を設定するか、入れておく)" }
    }
    foreach ($e in @(Get-Field $v 'requiredEnv' | Where-Object { $_ })) {
        if (-not [Environment]::GetEnvironmentVariable([string]$e)) { $ng += "vault の認証に使う環境変数 $e が設定されていません (ユーザーが一度だけ環境の設定に入れる)" }
    }
    return $ng
}

function Get-RequiredSecretNames {
    return @($targets | ForEach-Object { @(Get-Field $_ 'requiredEnv' | Where-Object { $_ }) } | Select-Object -Unique)
}

$script:vaultIssues = @()
$script:notInVault = @()
function Resolve-Secrets {
    # 環境変数にない秘密の値を vault から取り出して、このプロセスの環境変数に入れる
    $missing = @(Get-RequiredSecretNames | Where-Object { -not [Environment]::GetEnvironmentVariable([string]$_) })
    $v = Get-Vault
    if ($missing.Count -eq 0 -or -not $v) { return }
    $script:vaultIssues = @(Get-VaultIssues)
    if ($script:vaultIssues.Count -gt 0) { return }
    foreach ($n in $missing) {
        $r = Invoke-Capture (Expand-VaultCommand ([string](Get-Field $v 'getCommand')) $n)
        if ($r.ExitCode -eq 0 -and $r.Output) { [Environment]::SetEnvironmentVariable($n, $r.Output) }
        else { $script:notInVault += $n }
    }
}

function Get-SecretSource([string]$EnvName) {
    # deploy.secrets に書いた入手方法 (MCP・CLI で読み出す手順)
    foreach ($e in @($config.deploy.secrets | Where-Object { $_ })) {
        if ([string](Get-Field $e 'name') -eq $EnvName) { return [string](Get-Field $e 'source') }
    }
    return ''
}

function Get-Kind($Target) {
    $k = [string](Get-Field $Target 'kind')
    if ($k -eq 'agent') { return 'agent' }
    return 'command'
}

function Get-Steps($Target, [string]$Key) {
    # steps / rollbackSteps (文字列か文字列の配列) を番号付きの行にする
    $list = @(Get-Field $Target $Key | Where-Object { $_ })
    if ($list.Count -eq 0) { return '' }
    $i = 0
    return (($list | ForEach-Object { $i++; "  $i. $_" }) -join "`n")
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
    $agent = (Get-Kind $Target) -eq 'agent'
    if ($agent -and -not (Get-Steps $Target 'steps')) { $ng += 'kind が agent なのに steps (MCP で行う手順) が未設定です' }
    foreach ($key in 'command', 'smokeCommand', 'rollbackCommand') {
        $c = [string](Get-Field $Target $key)
        if (-not $c) {
            if ($key -eq 'command' -and -not $agent) { $ng += 'command が未設定です' }
            continue
        }
        $cmdName = Get-TestCommandName $c
        if (-not $cmdName) { continue }   # コマンド名のない文 (exit など) は確かめられない
        Push-Location $root
        try { $found = Get-Command $cmdName -ErrorAction SilentlyContinue } finally { Pop-Location }
        if (-not $found) { $ng += "$key のコマンド ``$cmdName`` が見つかりません (インストールと PATH を確かめる)" }
    }
    foreach ($e in @(Get-Field $Target 'requiredEnv' | Where-Object { $_ })) {
        if (-not [Environment]::GetEnvironmentVariable([string]$e)) {
            $where = if ($script:notInVault -contains $e) { 'vault にもない' } elseif (Get-Vault) { 'vault から取り出せなかった' } else { 'vault は未設定' }
            $ng += "秘密の値 $e がありません ($where。``devflow-deploy.ps1 secrets`` で入手方法を確かめ、``set-secret`` で vault に保存する)"
        }
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

function Test-ProductionTarget($Target) {
    $p = Get-Field $Target 'production'
    if ($null -ne $p -and [string]$p -ne '') { return [bool]$p }
    return ([string](Get-Field $Target 'name') -match '^(prod|production|本番)$')
}

function Get-ProductionGateIssues {
    # 本番の前提 (allowWithIssues では飛ばせない): 検証の結果 + 台帳の open の 処置-B・要回答 が 0 件
    $ng = @()
    $rp = Join-DevflowPath $root 'docs/verification-report.md'
    if (-not (Test-Path -LiteralPath $rp)) { $ng += 'docs/verification-report.md がありません (検証フェーズが終わっていない)' }
    elseif ((Read-Utf8 $rp) -notmatch '判定:\s*漏れなし') { $ng += 'docs/verification-report.md の判定が「漏れなし」ではありません' }
    $blocked = @(Read-TaskIndex $root $config | Where-Object { $_.Status -eq 'blocked' } | ForEach-Object { $_.Id })
    if ($blocked.Count -gt 0) { $ng += "blocked のタスクがあります: $($blocked -join ', ')" }
    $open = @(Read-Ledger $root | Where-Object { $_ -and $_.Kind -in @('処置-B', '要回答') -and $_.Status -eq 'open' } | ForEach-Object { "$($_.Dec) ($($_.Kind): $($_.Topic))" })
    if ($open.Count -gt 0) { $ng += "決定台帳に未解決の繰延べ・要回答があります: $($open -join ', ') (最後の 1 回で答えて解決にする)" }
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

function Get-RunIssues($State, $Target) {
    # そのデプロイ先へデプロイしてはいけない理由の一覧
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
    return $ng
}

function Invoke-Smoke($State, $Target, [string]$DeployLog) {
    # 公開後の確認と、失敗したときの切り戻し。戻り値: 終了コード (0 / 2)
    $n = [string](Get-Field $Target 'name')
    if (-not (Get-Field $Target 'smokeCommand')) {
        Save-Result $State $n 'success' $head $DeployLog '公開後の確認: なし (smokeCommand 未設定)'
        Write-Host "OK: $n へデプロイしました (公開後の確認は未設定。ログ: $DeployLog)"
        return 0
    }
    $sm = Invoke-Step $Target 'smokeCommand' 'smoke'
    if ($sm.ExitCode -ne 0) {
        $why = if ($sm.TimedOut) { '公開後の確認がタイムアウト' } else { "公開後の確認が失敗 (終了コード $($sm.ExitCode))" }
        Save-Result $State $n 'smoke-failed' $head $sm.Log "$why。デプロイの記録: $DeployLog"
        Write-Host "NG: $n へのデプロイは終わったが、$why"
        Write-LogTail $sm.Log
        if (-not (Get-ConfigFlag 'rollbackOnFailure' $true)) { Write-Host '切り戻し: deploy.rollbackOnFailure が false のため行っていない' }
        elseif (Get-Field $Target 'rollbackCommand') { Write-Host (Invoke-Rollback $State $Target $why) }
        elseif (Get-Steps $Target 'rollbackSteps') {
            Write-Host "ROLLBACK-BY-AGENT: 次の手順で $n を切り戻し、結果を ``devflow-deploy.ps1 rollback-done $n -Result success|failed`` で記録すること:"
            Write-Host (Get-Steps $Target 'rollbackSteps')
        }
        else { Write-Host '切り戻し: rollbackCommand / rollbackSteps が未設定のため行っていない (人が手で戻すこと)' }
        return 2
    }
    Save-Result $State $n 'success' $head $DeployLog "公開後の確認: 成功 ($($sm.Log))"
    Write-Host "OK: $n へデプロイし、公開後の確認も成功しました (記録: $DeployLog、$($sm.Log))"
    return 0
}

function Invoke-Run($State, $Target) {
    # 1 つのデプロイ先へのデプロイ。戻り値: 終了コード (0 / 1 / 2 / 5 = agent の手順を出して止まった)
    $n = [string](Get-Field $Target 'name')
    $ng = @(Get-RunIssues $State $Target)
    if ($ng.Count -gt 0) {
        Write-Host "$n へのデプロイを拒否:"
        $ng | ForEach-Object { Write-Host "- $_" }
        return 1
    }
    if ((Get-Kind $Target) -eq 'agent') {
        Save-Result $State $n 'agent-pending' $head '' 'MCP で行う手順を出した'
        Write-Host "AGENT: $n へのデプロイは MCP で行う (コミット $head)。次の手順どおりに行い、ほかの操作はしないこと:"
        Write-Host (Get-Steps $Target 'steps')
        $mcp = @(Get-Field $Target 'requiredMcp' | Where-Object { $_ })
        if ($mcp.Count -gt 0) { Write-Host "使うツール: $($mcp -join ', ') (ツール一覧にないなら、何もせず ``finish $n -Result failed -Note 'MCP 未接続: <ツール>'``)" }
        Write-Host "終わったら ``devflow-deploy.ps1 finish $n -Result success|failed -Note '<公開した URL・失敗の理由>'`` で記録し、all をもう一度実行すること"
        return 5
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
    return (Invoke-Smoke $State $Target $r.Log)
}

$head = (& git -C $root rev-parse --short HEAD 2>$null)
if ($Command -in @('plan', 'all', 'run', 'finish', 'rollback', 'secrets')) {
    Resolve-Secrets
    foreach ($i in $script:vaultIssues) { Write-Host "注意: $i" }
}

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
            if ((Get-Kind $t) -eq 'agent') {
                Write-Output "$i. $n (MCP で行う)"
                Write-Output "   手順:`n$((Get-Steps $t 'steps') -replace '(?m)^', '   ')"
                $mcp = @(Get-Field $t 'requiredMcp' | Where-Object { $_ })
                if ($mcp.Count -gt 0) { Write-Output "   使うツール: $($mcp -join ', ') (要確認: このスクリプトでは確かめられない。オーケストレーターがツール一覧で確かめる)" }
            } else {
                Write-Output "$i. $n"
                Write-Output "   デプロイ: $(Get-Field $t 'command')"
            }
            Write-Output "   公開後の確認: $(if (Get-Field $t 'smokeCommand') { Get-Field $t 'smokeCommand' } else { 'なし' })"
            $rb = if (Get-Field $t 'rollbackCommand') { Get-Field $t 'rollbackCommand' } elseif (Get-Steps $t 'rollbackSteps') { 'MCP で行う (rollbackSteps)' } else { 'なし' }
            Write-Output "   切り戻し: $rb"
            if ($results.Contains($n)) {
                $r = $results[$n]
                $same = if (Test-SameCode $r.commit) { '今と同じコード' } else { '今と違うコード' }
                Write-Output "   前回: $($r.status) ($($r.commit)、$same、$($r.at))"
            }
            $ng += @(Test-Target $t | ForEach-Object { "${n}: $_" })
            if (Test-ProductionTarget $t) { $gateProd = @(Get-ProductionGateIssues) }
        }
        $dirty = @(Get-CodeDirty)
        if ($dirty.Count -gt 0) { $ng += "コードに未コミットの変更が $($dirty.Count) 件あります (コミットしたものだけをデプロイする)" }
        $gate = @(Get-GateIssues) + @(if (Get-Variable gateProd -ErrorAction SilentlyContinue) { $gateProd })
        $gate = @($gate | Where-Object { $_ } | Select-Object -Unique)
        if ($gate.Count -gt 0) {
            Write-Output '検証の結果・決定台帳がデプロイの前提を満たしません:'
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
            if (Test-ProductionTarget $t) {
                $pg = @(Get-ProductionGateIssues)
                if ($pg.Count -gt 0) {
                    Write-Output "デプロイしません: 本番のデプロイ先 $n の前提を満たしません:"
                    $pg | ForEach-Object { Write-Output "- $_" }
                    exit 4
                }
            }
            $code = Invoke-Run $s $t
            if ($code -eq 5) { exit 5 }
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
    'finish' {
        $s = Assert-DeploymentPhase
        $t = Get-Target $Name
        if ((Get-Kind $t) -ne 'agent') { throw "$Name は kind が agent ではありません (run を使う)" }
        if (-not $Result) { throw 'finish <name> -Result success|failed の形式で指定してください' }
        $results = Get-Results $s
        $r = if ($results.Contains($Name)) { $results[$Name] } else { $null }
        if (-not $r -or $r.status -ne 'agent-pending' -or -not (Test-SameCode $r.commit)) {
            Write-Output "finish を拒否: $Name は今のコードで手順を出していません (先に all を実行する)"
            exit 1
        }
        $rec = if ($Note) { "MCP で実施: $Note" } else { 'MCP で実施' }
        if ($Result -eq 'failed') {
            Save-Result $s $Name 'deploy-failed' $head '' $rec
            Write-Output "${Name}: deploy-failed と記録しました"
            exit 1
        }
        exit (Invoke-Smoke $s $t $rec)
    }
    'rollback-done' {
        $s = Assert-DeploymentPhase
        $null = Get-Target $Name
        if (-not $Result) { throw 'rollback-done <name> -Result success|failed の形式で指定してください' }
        $status = if ($Result -eq 'success') { 'rolled-back' } else { 'rollback-failed' }
        Save-Result $s $Name $status $head '' "MCP で切り戻し$(if ($Note) { ": $Note" })"
        Write-Output "${Name}: $status と記録しました"
        if ($Result -ne 'success') { exit 1 }
    }
    'secrets' {
        $names = @(Get-RequiredSecretNames)
        if ($names.Count -eq 0) { Write-Output '必要な秘密の値はありません (requiredEnv なし)'; exit 0 }
        $vaultName = if (Get-Vault) { [string](Get-Field (Get-Vault) 'name') } else { '' }
        $missing = @($names | Where-Object { -not [Environment]::GetEnvironmentVariable([string]$_) })
        foreach ($n in $names) {
            if ($missing -contains $n) {
                $src = Get-SecretSource $n
                $how = if ($src) { "入手方法: $src" } else { '入手方法: 未設定 (ユーザーが vault に入れる)' }
                Write-Output "$n : 足りない / $how"
            } else { Write-Output "$n : あり" }
        }
        if ($missing.Count -gt 0) {
            if ($vaultName) { Write-Output "入手したら ``devflow-deploy.ps1 set-secret <NAME> -Value '<値>'`` で $vaultName に保存する" }
            else { Write-Output 'deploy.vault が未設定のため、保存先がない (環境変数に入れるか、基本設計で vault を決める)' }
            exit 1
        }
    }
    'set-secret' {
        $v = Get-Vault
        if (-not $v -or -not (Get-Field $v 'setCommand')) { Write-Output 'deploy.vault.setCommand が未設定のため保存できません'; exit 1 }
        if (-not $Value) { throw 'set-secret <NAME> -Value <値> の形式で指定してください' }
        $ng = @(Get-VaultIssues)
        if ($ng.Count -gt 0) { $ng | ForEach-Object { Write-Output "- $_" }; exit 1 }
        $r = Invoke-Capture (Expand-VaultCommand ([string](Get-Field $v 'setCommand')) $Name) $Value
        if ($r.ExitCode -ne 0) { Write-Output "$Name を vault に保存できませんでした (終了コード $($r.ExitCode))"; exit 1 }
        Write-Output "$Name を $(Get-Field $v 'name') に保存しました"
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
        throw "未知のコマンド: $Command (plan|all|run|rollback|finish|rollback-done|secrets|set-secret|status)"
    }
}
