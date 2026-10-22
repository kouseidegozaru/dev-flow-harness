# devflow 共通ライブラリ (PowerShell 7+)
#
# state.json / config.json の読み書き、Markdown 表の解析、ID の抽出、
# ファイル列挙、コンテキスト使用率の計算をまとめる。
# hooks と scripts の両方から Import-Module で読み込む。

Set-StrictMode -Version 3.0

$script:PhaseOrder = @(
    'vision', 'requirements', 'basic-design', 'detailed-design',
    'implementation', 'verification', 'deployment', 'done'
)
$script:PhaseFiles = @{
    'vision'          = '01-vision.md'
    'requirements'    = '02-requirements.md'
    'basic-design'    = '03-basic-design.md'
    'detailed-design' = '04-detailed-design.md'
    'implementation'  = '05-implementation.md'
    'verification'    = '06-verification.md'
    'deployment'      = '07-deployment.md'
}
$script:PhaseLabels = @{
    'vision'          = '企画・構想'
    'requirements'    = '要件定義'
    'basic-design'    = '基本設計'
    'detailed-design' = '詳細設計'
    'implementation'  = '実装'
    'verification'    = '検証'
    'deployment'      = 'デプロイ'
    'done'            = '完了'
}
$script:TaskStatuses = @('todo', 'in_progress', 'done', 'blocked')

# ---------------------------------------------------------------------------
# パス・入出力
# ---------------------------------------------------------------------------

function Get-DevflowRoot {
    if ($env:CLAUDE_PROJECT_DIR -and (Test-Path -LiteralPath $env:CLAUDE_PROJECT_DIR)) {
        return (Resolve-Path -LiteralPath $env:CLAUDE_PROJECT_DIR).Path
    }
    $top = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { return (Resolve-Path -LiteralPath $top).Path }
    return (Get-Location).Path
}

function Join-DevflowPath([string]$Root, [string]$Rel) {
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Rel))
}

function Get-RelativePath([string]$Root, [string]$Path) {
    return [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Read-Utf8([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Read-StdinJson {
    # フックの stdin を UTF-8 として読む (コンソールのコードページに依存しない)
    $raw = ''
    try {
        $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
        $raw = $reader.ReadToEnd()
    } catch {}
    if (-not $raw.Trim()) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

function Write-HookJson($Object) {
    # 非 ASCII を \uXXXX にして出力し、出力エンコーディングの差異を避ける
    $json = $Object | ConvertTo-Json -Depth 10 -Compress -EscapeHandling EscapeNonAscii
    [Console]::Out.Write($json)
}

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------

function Get-DefaultConfig {
    return [ordered]@{
        contextWindowTokens     = 200000
        contextThresholdPercent = 70
        minSessionWorkTokens    = 40000
        hardLimitPercent        = 85
        maxVerificationRounds   = 3
        # check-branches: ほかのブランチの dev-flow を「並行して進んでいる」とみなす、.devflow の最終更新からの時間 (0 で無制限)
        concurrentRunHours      = 72
        maxAttemptsPerTest      = 3
        # 1 タスクの読み物 (タスクファイル + 参照すべき設計で指した節) の上限 (KB)。超えたタスクは詳細設計で分けるか参照を絞る
        taskContextBudgetKB     = 40
        # 実装担当 1 体が処理するタスク数 (done か blocked にした数)。0 で従来どおり閾値まで続ける。tools は導入時に tdd-implementer の tools: を上書きする
        implementer             = [ordered]@{
            tasksPerAgent = 1
            tools         = @()
        }
        # 受け入れテストの場所 (受け入れ例の照合の対象)
        acceptance              = [ordered]@{
            files = @('tests/acceptance/**')
        }
        # 決定台帳: 実装担当の処置 C をこれらの語に当たるとき 要回答 に格上げする
        ledger                  = [ordered]@{
            sensitiveWords = @('料金', '課金', '決済', '支払', '金額', '価格', 'お金', '有料', '無料', '権限', '認証', 'パスワード', 'トークン',
                               '個人情報', '氏名', '住所', '電話番号', 'メールアドレス', '法令', '規約', '同意', '外部送信', '外部サービス', '外部 API', 'API キー', 'セキュリティ', '暗号')
        }
        idPrefixes              = @('REQ', 'NFR', 'ARC', 'SCR', 'TRN', 'API', 'ERR', 'EXT', 'DM',
                                    'MOD', 'IF', 'VAL', 'EC', 'DBC', 'BR', 'TASK')
        test                    = [ordered]@{
            command        = ''
            # 出発前 (preflight -Departure) に 1 回だけ実行する準備のコマンド (依存の取得など)。空なら実行しない
            setupCommand   = ''
            timeoutSeconds = 900
            resultGlobs    = @('**/TestResults/*.trx', '**/junit*.xml', '**/test-results/**/*.xml')
            files       = @('tests/**', 'test/**', '**/*.test.*', '**/*_test.*', '**/*Tests.cs', '**/test_*.py')
        }
        source                  = [ordered]@{
            files = @('src/**')
        }
        # デプロイ先 (詳細設計で設定)。targets の順に実行する。秘密の値は書かず、requiredEnv に環境変数名だけを書く
        deploy                  = [ordered]@{
            timeoutSeconds = 1800
            targets        = @()   # @{ name; command; smokeCommand; rollbackCommand; requiredEnv = @(); confirm }
        }
        # コメント中の TODO/FIXME/XXX だけを大文字小文字を区別して拾う (識別子の Todo などに反応しないため)
        stubPatterns            = @(
            '(?-i)(//|#|/\*|--|<!--|\*)\s*(TODO|FIXME|XXX)\b', 'NotImplementedException', 'NotImplementedError',
            'raise NotImplemented', 'unimplemented!\(', '(?-i)\btodo!\(',
            # 文字列リテラル全体が「not implemented」のものだけ ("501 Not Implemented" のような正当な文言には反応しない)
            '["''`]not implemented( yet)?[.!]?["''`]'
        )
    }
}

function Merge-Hashtable($Base, $Over) {
    if ($null -eq $Over) { return $Base }
    foreach ($p in $Over.PSObject.Properties) {
        $name = $p.Name
        $val = $p.Value
        if ($Base.Contains($name) -and $Base[$name] -is [System.Collections.IDictionary] -and $val -is [pscustomobject]) {
            $Base[$name] = Merge-Hashtable $Base[$name] $val
        } else {
            $Base[$name] = $val
        }
    }
    return $Base
}

function Get-DevflowConfig([string]$Root) {
    $cfg = Get-DefaultConfig
    $path = Join-DevflowPath $Root '.devflow/config.json'
    if (Test-Path -LiteralPath $path) {
        $over = Read-Utf8 $path | ConvertFrom-Json
        $cfg = Merge-Hashtable $cfg $over
    }
    # 環境変数による一時上書き (ドライランや試験用)
    if ($env:DEVFLOW_CONTEXT_THRESHOLD) { $cfg.contextThresholdPercent = [double]$env:DEVFLOW_CONTEXT_THRESHOLD }
    if ($env:DEVFLOW_CONTEXT_WINDOW) { $cfg.contextWindowTokens = [double]$env:DEVFLOW_CONTEXT_WINDOW }
    return $cfg
}

# ---------------------------------------------------------------------------
# state.json
# ---------------------------------------------------------------------------

function New-DevflowState {
    return [ordered]@{
        version         = 1
        phase           = 'vision'
        completedPhases = @()
        phaseStarted    = $false
        implementation  = [ordered]@{
            currentTask = $null
            taskBase    = [ordered]@{}   # タスク ID → 開始時点のコミット (blocked にしたとき、ここまで戻す)
        }
        verification    = [ordered]@{
            round       = 0
            roundOpen   = $false
            addedTasks  = @()
        }
        deployment      = [ordered]@{
            results     = [ordered]@{}   # デプロイ先の名前 → 最後の結果 (status, commit, at, log)
        }
        updatedAt       = (Get-Date).ToString('o')
    }
}

function Get-StatePath([string]$Root) { return Join-DevflowPath $Root '.devflow/state.json' }

function Read-DevflowState([string]$Root) {
    $path = Get-StatePath $Root
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $obj = Read-Utf8 $path | ConvertFrom-Json -AsHashtable
    return $obj
}

function Write-DevflowState([string]$Root, $State) {
    $State.updatedAt = (Get-Date).ToString('o')
    $json = $State | ConvertTo-Json -Depth 10
    Write-Utf8 (Get-StatePath $Root) ($json + "`n")
}

function Get-NextPhase([string]$Phase) {
    $i = [Array]::IndexOf($script:PhaseOrder, $Phase)
    if ($i -lt 0 -or $i -ge $script:PhaseOrder.Count - 1) { return 'done' }
    return $script:PhaseOrder[$i + 1]
}

function Get-PhaseOrder { return $script:PhaseOrder }
function Get-PhaseFile([string]$Phase) { return $script:PhaseFiles[$Phase] }
function Get-PhaseLabel([string]$Phase) { return $script:PhaseLabels[$Phase] }
function Get-TaskStatuses { return $script:TaskStatuses }

# ---------------------------------------------------------------------------
# ファイル列挙と glob
# ---------------------------------------------------------------------------

function ConvertTo-GlobRegex([string]$Glob) {
    $g = $Glob.Replace('\', '/')
    $sb = [System.Text.StringBuilder]::new('^')
    $i = 0
    while ($i -lt $g.Length) {
        $c = $g[$i]
        if ($c -eq '*') {
            if ($i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
                # '**/' はゼロ個以上のディレクトリ、末尾の '**' は何でも
                if ($i + 2 -lt $g.Length -and $g[$i + 2] -eq '/') {
                    [void]$sb.Append('(?:.*/)?'); $i += 3; continue
                }
                [void]$sb.Append('.*'); $i += 2; continue
            }
            [void]$sb.Append('[^/]*')
        } elseif ($c -eq '?') {
            [void]$sb.Append('[^/]')
        } else {
            [void]$sb.Append([regex]::Escape([string]$c))
        }
        $i++
    }
    [void]$sb.Append('$')
    return [regex]::new($sb.ToString(), 'IgnoreCase')
}

function Get-TrackedFiles([string]$Root) {
    # git 管理下 + 未追跡 (gitignore 除外) のファイル。git がなければ全走査
    Push-Location $Root
    try {
        $list = & git ls-files -co --exclude-standard 2>$null
        if ($LASTEXITCODE -eq 0) { return @($list | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') }) }
    } finally { Pop-Location }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } |
        ForEach-Object { Get-RelativePath $Root $_.FullName })
}

function Select-ByGlobs([string[]]$Files, [object[]]$Globs) {
    $regs = @($Globs | Where-Object { $_ } | ForEach-Object { ConvertTo-GlobRegex ([string]$_) })
    if ($regs.Count -eq 0) { return @() }
    return @($Files | Where-Object { $f = $_; @($regs | Where-Object { $_.IsMatch($f) }).Count -gt 0 })
}

function Find-FilesOnDisk([string]$Root, [object[]]$Globs) {
    # gitignore されたファイル (テスト結果など) を探す用。.git / node_modules は除外
    $regs = @($Globs | Where-Object { $_ } | ForEach-Object { ConvertTo-GlobRegex ([string]$_) })
    if ($regs.Count -eq 0) { return @() }
    $out = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($d in [System.IO.Directory]::GetDirectories($dir)) {
            $name = [System.IO.Path]::GetFileName($d)
            if ($name -in @('.git', 'node_modules')) { continue }
            $stack.Push($d)
        }
        foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
            $rel = Get-RelativePath $Root $f
            if (@($regs | Where-Object { $_.IsMatch($rel) }).Count -gt 0) { $out.Add($rel) }
        }
    }
    return @($out)
}

# ---------------------------------------------------------------------------
# テストの実行と結果ファイル
# ---------------------------------------------------------------------------

function Get-TestCommandName([string]$Command) {
    # test.command の最初のコマンド名 (dotnet / npx / ./gradlew など)。解析できなければ $null
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$null, [ref]$errs)
    $c = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    if ($c) { return $c.GetCommandName() }
    return $null
}

function Invoke-LoggedCommand([string]$Root, [string]$Command, [string]$LogRel, [int]$TimeoutSeconds, [string]$TimeoutName) {
    # コマンドを pwsh で実行し、標準出力と標準エラーを $LogRel に書く。$TimeoutSeconds を超えたらプロセスツリーごと止める (0 以下で無制限)。
    # 戻り値: @{ ExitCode; TimedOut; Log (ルートからの相対パス) }
    $log = Join-DevflowPath $Root $LogRel
    New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
    $err = "$log.stderr"
    $cmd = "`$PSStyle.OutputRendering = 'PlainText'`n" + $Command
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $p = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', $enc) `
        -WorkingDirectory $Root -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $p.Handle   # ExitCode を確実に取れるようにする
    $timedOut = $false
    if ($TimeoutSeconds -gt 0) {
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $p.Kill($true) } catch {}
            $p.WaitForExit()
        }
    } else { $p.WaitForExit() }
    if (Test-Path -LiteralPath $err) {
        $e = Read-Utf8 $err
        if ($e) { Add-Content -LiteralPath $log -Value $e -Encoding utf8 }
        Remove-Item -LiteralPath $err -Force
    }
    if ($timedOut) { Add-Content -LiteralPath $log -Value "dev-flow: $TimeoutName ($TimeoutSeconds 秒) を超えたため停止しました" -Encoding utf8 }
    $code = if ($timedOut) { 124 } else { $p.ExitCode }
    return [pscustomobject]@{ ExitCode = $code; TimedOut = $timedOut; Log = $LogRel }
}

function Invoke-TestCommand([string]$Root, $Config, [string]$LogRel) {
    # 結果ファイルを消してから test.command を実行する。test.timeoutSeconds を超えたらプロセスツリーごと止める。
    # 戻り値: @{ ExitCode; TimedOut; Log (ルートからの相対パス) }
    foreach ($rel in Find-FilesOnDisk $Root $Config.test.resultGlobs) { Remove-Item -LiteralPath (Join-DevflowPath $Root $rel) -Force }
    return Invoke-LoggedCommand $Root ([string]$Config.test.command) $LogRel ([int]$Config.test.timeoutSeconds) 'test.timeoutSeconds'
}

function Get-ResultExcludePathspecs($Config) {
    # テスト結果ファイル (テストのたびに作り直される生成物) を git の対象から外す pathspec
    return @($Config.test.resultGlobs | Where-Object { $_ } | ForEach-Object { ":(exclude,glob)$_" })
}

function Get-UncommittedChanges([string]$Root, $Config, [string[]]$Paths = @()) {
    # 未コミットの変更 (git status --porcelain の行)。テスト結果ファイルは数えない
    $spec = @(if ($Paths.Count -gt 0) { $Paths } else { '.' })
    return @(& git -C $Root status --porcelain -- @spec @(Get-ResultExcludePathspecs $Config) 2>$null | Where-Object { $_ })
}

function Read-TestResultFiles([string]$Root, $Config) {
    # test.resultGlobs の TRX / JUnit XML を読み、@{ name; outcome (passed|failed|skipped|...); file } の一覧を返す
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in Find-FilesOnDisk $Root $Config.test.resultGlobs) {
        $full = Join-DevflowPath $Root $rel
        try { [xml]$x = Read-Utf8 $full } catch { continue }
        if ($x.DocumentElement.LocalName -eq 'TestRun') {
            # Visual Studio TRX
            foreach ($r in $x.GetElementsByTagName('UnitTestResult')) {
                $out.Add([pscustomobject]@{ name = $r.GetAttribute('testName'); outcome = $r.GetAttribute('outcome').ToLowerInvariant(); file = $rel })
            }
        } else {
            # JUnit XML
            foreach ($tc in $x.GetElementsByTagName('testcase')) {
                $outcome = 'passed'
                foreach ($c in $tc.ChildNodes) {
                    if ($c.LocalName -in @('failure', 'error')) { $outcome = 'failed' }
                    elseif ($c.LocalName -eq 'skipped' -and $outcome -eq 'passed') { $outcome = 'skipped' }
                }
                $name = "$($tc.GetAttribute('classname')) $($tc.GetAttribute('name'))".Trim()
                $out.Add([pscustomobject]@{ name = $name; outcome = $outcome; file = $rel })
            }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Markdown 解析
# ---------------------------------------------------------------------------

function Split-MdRow([string]$Line) {
    $t = $Line.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|') -and -not $t.EndsWith('\|')) { $t = $t.Substring(0, $t.Length - 1) }
    $cells = [regex]::Split($t, '(?<!\\)\|')
    return @($cells | ForEach-Object { $_.Trim().Replace('\|', '|') })
}

function ConvertTo-PlainCell([string]$Cell) {
    $c = $Cell
    $c = [regex]::Replace($c, '\[([^\]]*)\]\([^)]*\)', '$1')   # [text](url) → text
    $c = $c.Replace('`', '').Replace('**', '').Replace('__', '')
    $c = [regex]::Replace($c, '<br\s*/?>', ' ')
    return $c.Trim()
}

function Get-MdLines([string]$Path) {
    # フェンスコードブロック内の行を除いた (行番号, 本文) の列を返す
    $lines = (Read-Utf8 $Path) -split "`r?`n"
    $out = [System.Collections.Generic.List[object]]::new()
    $inFence = $false
    $inGen = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        # 自動生成ブロック (index.md の ID 一覧) は定義にも参照にも数えない
        if ($l -match '<!-- devflow:ids:begin -->') { $inGen = $true; continue }
        if ($l -match '<!-- devflow:ids:end -->') { $inGen = $false; continue }
        if ($inGen) { continue }
        $out.Add([pscustomobject]@{ No = $i + 1; Text = $l })
    }
    return $out
}

function Get-MdTables([string]$Path) {
    # 表を @{ Headers; Rows(各行 = @{ No; Cells }) } の列で返す
    $tables = [System.Collections.Generic.List[object]]::new()
    $lines = @(Get-MdLines $Path)
    $i = 0
    while ($i -lt $lines.Count) {
        $t = $lines[$i].Text.Trim()
        $isHeader = $t.StartsWith('|') -and ($i + 1 -lt $lines.Count) -and
            ($lines[$i + 1].Text.Trim() -match '^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$')
        if (-not $isHeader) { $i++; continue }
        $headers = @(Split-MdRow $t | ForEach-Object { ConvertTo-PlainCell $_ })
        $rows = [System.Collections.Generic.List[object]]::new()
        $j = $i + 2
        while ($j -lt $lines.Count -and $lines[$j].Text.Trim().StartsWith('|')) {
            $rows.Add([pscustomobject]@{ No = $lines[$j].No; Cells = @(Split-MdRow $lines[$j].Text) })
            $j++
        }
        $tables.Add([pscustomobject]@{ Headers = $headers; Rows = $rows; No = $lines[$i].No })
        $i = $j
    }
    return $tables
}

function Get-ColumnIndex([string[]]$Headers, [string[]]$Names) {
    for ($k = 0; $k -lt $Headers.Count; $k++) {
        if ($Names -contains $Headers[$k]) { return $k }
    }
    return -1
}

function Get-MdSection([string]$Path, [string]$HeadingPattern) {
    # 見出しが HeadingPattern に一致する節の本文 (同レベル以上の次の見出しまで)
    $lines = (Read-Utf8 $Path) -split "`r?`n"
    $out = [System.Collections.Generic.List[string]]::new()
    $level = 0
    $inFence = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*(```|~~~)') { $inFence = -not $inFence }
        if (-not $inFence -and $l -match '^(#{1,6})\s+(.*)$') {
            $lv = $Matches[1].Length
            if ($level -gt 0 -and $lv -le $level) { break }
            if ($level -eq 0 -and $Matches[2] -match $HeadingPattern) { $level = $lv; continue }
        }
        if ($level -gt 0) { $out.Add($l) }
    }
    return ($out -join "`n")
}

function Get-MdHeadingSections([string]$Path, [string]$Heading) {
    # 見出しの文字列が Heading と一致する節 (見出しの行を含む。同レベル以上の次の見出しまで) をすべて返す。
    # 完全一致がなければ前方一致、それもなければ部分一致で探す
    $lines = (Read-Utf8 $Path) -split "`r?`n"
    $heads = [System.Collections.Generic.List[object]]::new()
    $inFence = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if (-not $inFence -and $lines[$i] -match '^(#{1,6})\s+(.*?)\s*#*\s*$') {
            $heads.Add([pscustomobject]@{ Index = $i; Level = $Matches[1].Length; Text = $Matches[2].Trim() })
        }
    }
    $h = $Heading.Trim()
    $hit = @($heads | Where-Object { $_.Text -eq $h })
    if ($hit.Count -eq 0) { $hit = @($heads | Where-Object { $_.Text.StartsWith($h) }) }
    if ($hit.Count -eq 0) { $hit = @($heads | Where-Object { $_.Text.Contains($h) }) }
    $out = @()
    foreach ($s in $hit) {
        $next = $heads | Where-Object { $_.Index -gt $s.Index -and $_.Level -le $s.Level } | Select-Object -First 1
        $end = if ($next) { $next.Index } else { $lines.Count }
        $out += (($lines[$s.Index..($end - 1)]) -join "`n").TrimEnd()
    }
    return $out
}

# ---------------------------------------------------------------------------
# タスクファイルの解析 (作成・変更するファイル、参照すべき設計)
# ---------------------------------------------------------------------------

function Test-PathLikeToken([string]$Token) {
    # バッククォートの中身がファイルのパスとして書かれているか。
    # 説明文中のシグネチャ (`migrate(url, dir = "x/y")`)・ディレクトリ (`src/server/data`、末尾が /)・glob はファイルとみなさない
    # コード中の名前 (`router.refresh()`・`error.fieldErrors`・`app.merging`) や URL のパス (`/a/b.json`) もファイルとみなさない
    if ($Token -notmatch '^[\w@.+\-\[\]()/]+$' -or $Token.StartsWith('/') -or $Token.EndsWith('/')) { return $false }
    $leaf = ($Token -split '/')[-1]
    if ($leaf -in @('Dockerfile', 'Makefile', 'Procfile', 'Gemfile', 'Rakefile', 'Jenkinsfile', 'LICENSE')) { return $true }
    if ($leaf -notmatch '^[\w@.+\-\[\]]*\.([A-Za-z0-9]{1,10})$') { return $false }
    # ディレクトリのない名前 (`a.b`) は、ファイルの拡張子として知られたものだけをファイルとみなす (`obj.prop` を作るファイルと誤読しないため)
    if ($Token -notmatch '/') { return ($script:KnownFileExtensions -contains $Matches[1].ToLowerInvariant()) }
    return $true
}

$script:KnownFileExtensions = @(
    'ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'mts', 'cts', 'json', 'jsonc', 'json5', 'md', 'mdx', 'sql', 'css', 'scss', 'sass', 'less',
    'html', 'htm', 'vue', 'svelte', 'astro', 'py', 'pyi', 'ipynb', 'cs', 'csproj', 'sln', 'fs', 'vb', 'go', 'mod', 'sum', 'rs', 'java', 'kt', 'kts',
    'scala', 'groovy', 'gradle', 'rb', 'erb', 'php', 'swift', 'm', 'mm', 'h', 'hpp', 'c', 'cc', 'cpp', 'dart', 'ex', 'exs', 'erl', 'clj',
    'lua', 'r', 'jl', 'pl', 'sh', 'bash', 'zsh', 'ps1', 'psm1', 'psd1', 'bat', 'cmd', 'yml', 'yaml', 'toml', 'ini', 'cfg', 'conf', 'env',
    'xml', 'xsd', 'plist', 'properties', 'lock', 'txt', 'csv', 'tsv', 'svg', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'pdf',
    'proto', 'graphql', 'gql', 'prisma', 'tf', 'hcl', 'dockerfile', 'editorconfig', 'gitignore', 'npmrc', 'nvmrc', 'config', 'resx', 'razor', 'cshtml'
)

function Get-OutsideParenMask([string]$Line) {
    # 行の各位置が括弧 (半角・全角) の外かどうか。バッククォートの中の括弧は数えない
    $mask = [bool[]]::new($Line.Length)
    $depth = 0; $inCode = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq '`') { $inCode = -not $inCode; $mask[$i] = ($depth -eq 0); continue }
        if (-not $inCode) {
            if ($c -eq '(' -or $c -eq '（') { $depth++ }
            elseif (($c -eq ')' -or $c -eq '）') -and $depth -gt 0) { $depth--; $mask[$i] = ($depth -eq 0); continue }
        }
        $mask[$i] = ($depth -eq 0)
    }
    return $mask
}

function Get-TaskFileEntries([string]$Section) {
    # 「作成・変更するファイル」節のパス。戻り値: @{ Path; New } の列
    # - 括弧の中で触れたパス・名前 (`a.ts` (変更: `b.ts` の関数を使う)) は、説明とみなしてファイルにしない
    # - New: パスの後ろから次のパスまでの説明に「新規」があり、「変更」がない (`a.ts` (新規)、`a.ts` 新規)。
    #   「(変更: 新規の関数を足す)」のように変更の説明の中で使った「新規」は New にしない
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($Section -split "`r?`n")) {
        if ($line -notmatch '^\s*[-*+]\s') { continue }
        $mask = Get-OutsideParenMask $line
        $ms = @([regex]::Matches($line, '`([^`]+)`') | Where-Object { $mask[$_.Index] -and (Test-PathLikeToken $_.Groups[1].Value.Trim()) })
        for ($k = 0; $k -lt $ms.Count; $k++) {
            $p = $ms[$k].Groups[1].Value.Trim()
            if (@($out | Where-Object { $_.Path -eq $p }).Count -gt 0) { continue }
            $from = $ms[$k].Index + $ms[$k].Length
            $to = if ($k + 1 -lt $ms.Count) { $ms[$k + 1].Index } else { $line.Length }
            $spec = $line.Substring($from, $to - $from)
            $out.Add([pscustomobject]@{ Path = $p; New = ($spec.Contains('新規') -and -not $spec.Contains('変更')) })
        }
    }
    return $out
}

function Expand-IdShorthand([string]$Text, [regex]$IdRegex) {
    # 略記を展開する: IF-set-003・004 → IF-set-003 IF-set-004、BR-SLOT-001〜003 → BR-SLOT-001 BR-SLOT-002 BR-SLOT-003
    return [regex]::Replace($Text, '(' + $IdRegex.ToString() + ')((?:\s*[・、,〜~]\s*\d+)+)', {
        param($m)
        $id = $m.Groups[1].Value
        if ($id -notmatch '^(.*-)(\d+)$') { return $m.Value }
        $prefix = $Matches[1]; $width = $Matches[2].Length; $last = [int]$Matches[2]
        $out = @($id)
        foreach ($p in [regex]::Matches($m.Groups[2].Value, '([・、,〜~])\s*(\d+)')) {
            $n = [int]$p.Groups[2].Value
            if ($p.Groups[1].Value -in @('〜', '~') -and $n -gt $last -and $n - $last -le 50) { ($last + 1)..$n | ForEach-Object { $out += $prefix + $_.ToString().PadLeft($width, '0') } }
            else { $out += $prefix + $p.Groups[2].Value.PadLeft($width, '0') }
            $last = $n
        }
        return ($out -join ' ')
    })
}

function Get-TaskReferences([string]$Section, [regex]$IdRegex, [string]$RootForResolve = '') {
    # 「参照すべき設計」節の各行を、参照先ファイルごとに分ける。
    # 書き方: - `docs/.../x.md` の「見出し」「見出し」 (ID, ID)  ← 見出しは「」で、ID はそのまま書く
    # 1 行に複数のファイルがあるときは、ファイルの後ろから次のファイルまでの文をそのファイルの指定とみなす。
    # `y.md` のようにディレクトリのないファイル名は、同じ行の直前のファイルと同じディレクトリとみなす。
    # 戻り値: @{ Path; Headings; Ids; Line } の列。Headings も Ids もなければファイル全体
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($Section -split "`r?`n")) {
        if ($line -notmatch '^\s*[-*+]\s') { continue }
        # 参照先は設計ドキュメント (.md) と画面デザイン (.html) だけ。コードのファイル名は実装担当が自分で読む
        $ms = @([regex]::Matches($line, '`([^`]+)`') | Where-Object { $v = $_.Groups[1].Value.Trim(); (Test-PathLikeToken $v) -and $v -match '\.(md|html?)$' })
        $prevDir = ''
        for ($k = 0; $k -lt $ms.Count; $k++) {
            $p = $ms[$k].Groups[1].Value.Trim()
            if (-not $p.StartsWith('docs/') -and $prevDir) {
                # 直前のファイルからの相対 (`SCR-790.md`・`designs/SCR-790.html`): 直前のディレクトリから上にたどって最初に当たる場所
                $cand = "$prevDir/$p"
                $d = if ($RootForResolve) { $prevDir } else { '' }
                while ($d) {
                    if (Test-Path -LiteralPath (Join-DevflowPath $RootForResolve "$d/$p")) { $cand = "$d/$p"; break }
                    $d = if ($d -match '/') { $d.Substring(0, $d.LastIndexOf('/')) } else { '' }
                }
                $p = $cand
            }
            $prevDir = if ($p -match '/') { $p.Substring(0, $p.LastIndexOf('/')) } else { '' }
            $from = $ms[$k].Index + $ms[$k].Length
            $to = if ($k + 1 -lt $ms.Count) { $ms[$k + 1].Index } else { $line.Length }
            $spec = $line.Substring($from, $to - $from)
            $heads = @([regex]::Matches($spec, '「([^」]+)」') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ })
            $rest = [regex]::Replace($spec, '「[^」]*」', ' ')
            $ids = @(Get-IdsInText (Expand-IdShorthand $rest $IdRegex) $IdRegex)
            $out.Add([pscustomobject]@{ Path = $p; Headings = $heads; Ids = $ids; Line = $line.Trim() })
        }
    }
    return $out
}

function Get-IdDefinitionRows([string]$Path, [string[]]$Ids) {
    # ファイル中の表から、ID 列が Ids のどれかである行を、表の見出し行と合わせて返す (表ごとに 1 つの文字列)。行は原文のまま
    $src = (Read-Utf8 $Path) -split "`r?`n"
    $parts = [System.Collections.Generic.List[string]]::new()
    $rowTexts = [System.Collections.Generic.List[string]]::new()
    foreach ($tb in Get-MdTables $Path) {
        $ci = Get-ColumnIndex $tb.Headers @('ID')
        if ($ci -lt 0) { continue }
        $rows = @($tb.Rows | Where-Object { $_.Cells.Count -gt $ci -and $Ids -contains (ConvertTo-PlainCell $_.Cells[$ci]) })
        if ($rows.Count -eq 0) { continue }
        $head = '| ' + ($tb.Headers -join ' | ') + ' |'
        $sep = '|' + (($tb.Headers | ForEach-Object { '---' }) -join '|') + '|'
        $body = @($rows | ForEach-Object { $src[$_.No - 1] })
        foreach ($b in $body) { $rowTexts.Add($b) }
        $parts.Add((@($head, $sep) + $body) -join "`n")
    }
    return [pscustomobject]@{ Text = ($parts -join "`n`n"); RowTexts = @($rowTexts) }
}

function Compress-DesignHtml([string]$Html) {
    # 画面デザインの HTML を、実装者が構造・文言・状態を読める最小の形にする:
    # svg の中身・script・コメントを除き、空白を詰める (アイコンの path などが大半を占め、読む量を増やすだけなので)
    $h = [regex]::Replace($Html, '(?s)<!--.*?-->', '')
    $h = [regex]::Replace($h, '(?s)<script\b.*?</script>', '')
    $h = [regex]::Replace($h, '(?s)<svg\b([^>]*)>.*?</svg>', '<svg$1/>')
    $h = [regex]::Replace($h, '>\s+<', ">`n<")
    $h = [regex]::Replace($h, '[ \t]+', ' ')
    return $h.Trim()
}

function Get-HtmlElementsById([string]$Html, [string]$Id) {
    # data-state-id="Id" (なければ data-id="Id") を持つ要素を、閉じタグまで切り出す
    foreach ($attr in 'data-state-id', 'data-id') {
        $ms = [regex]::Matches($Html, '<([a-zA-Z][\w-]*)\b[^>]*\b' + $attr + '="' + [regex]::Escape($Id) + '"[^>]*>')
        if ($ms.Count -eq 0) { continue }
        $out = @()
        foreach ($m in $ms) {
            $tag = $m.Groups[1].Value
            # 閉じタグのない要素 (input・img など) と自己終了のタグは、開始タグだけを切り出す (文書の末尾まで切り出さないため)
            if ($tag.ToLowerInvariant() -in $script:VoidHtmlElements -or $m.Value.EndsWith('/>')) { $out += $m.Value; continue }
            $re = [regex]::new('<(/?)' + [regex]::Escape($tag) + '\b[^>]*?(/?)>')
            $depth = 0; $end = $Html.Length
            foreach ($t in $re.Matches($Html, $m.Index)) {
                if ($t.Groups[2].Value -eq '/') { if ($depth -eq 0) { $end = $t.Index + $t.Length; break } else { continue } }
                if ($t.Groups[1].Value -eq '/') { $depth--; if ($depth -eq 0) { $end = $t.Index + $t.Length; break } } else { $depth++ }
            }
            $out += $Html.Substring($m.Index, $end - $m.Index)
        }
        return $out
    }
    return @()
}

$script:VoidHtmlElements = @('area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr')

function Get-TaskContext([string]$Root, $Config, [string]$TaskId, [switch]$WithNotes) {
    # 実装担当・レビュー担当が読む「タスクの読み物」を組み立てる:
    # タスクファイル + 「参照すべき設計」で指した節・ID の定義行 (+ 依存タスクの実装メモ)。
    # 戻り値: @{ Text; Bytes (設計部分の大きさ。実装メモは含めない); Missing (見つからなかった参照の説明の列) }
    $rel = "docs/04-detailed-design/tasks/$TaskId.md"
    $full = Join-DevflowPath $Root $rel
    if (-not (Test-Path -LiteralPath $full)) { throw "タスクファイル $rel がありません" }
    $idre = Get-IdRegex $Config
    $sb = [System.Text.StringBuilder]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    [void]$sb.AppendLine("<!-- devflow:context $TaskId -->").AppendLine("# [タスク] $rel").AppendLine().AppendLine((Read-Utf8 $full).TrimEnd()).AppendLine()
    foreach ($ref in Get-TaskReferences (Get-MdSection $full '参照すべき設計') $idre $Root) {
        $p = Join-DevflowPath $Root $ref.Path
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing.Add("$($ref.Path): ファイルがありません"); continue }
        $chunks = [System.Collections.Generic.List[string]]::new()
        if ($ref.Path -match '\.html?$') {
            # 画面デザイン: ID を書いたら、その状態・要素だけを切り出す。なければ全体 (どちらも圧縮した形)
            $html = Compress-DesignHtml (Read-Utf8 $p)
            foreach ($id in $ref.Ids) {
                $els = @(Get-HtmlElementsById $html $id)
                if ($els.Count -eq 0) { $missing.Add("$($ref.Path): data-state-id / data-id「$id」がありません"); continue }
                foreach ($e in $els) { $chunks.Add($e) }
            }
            if ($ref.Ids.Count -eq 0) { $chunks.Add($html) }
            if ($chunks.Count -gt 0) {
                [void]$sb.AppendLine("# [設計] $($ref.Path) (圧縮: svg の中身・script を除いた)").AppendLine("<!-- 指定: $($ref.Line) -->").AppendLine()
                foreach ($c in $chunks) { [void]$sb.AppendLine($c).AppendLine() }
            }
            continue
        }
        foreach ($h in $ref.Headings) {
            $secs = @(Get-MdHeadingSections $p $h)
            if ($secs.Count -eq 0) { $missing.Add("$($ref.Path): 見出し「$h」がありません"); continue }
            foreach ($s in $secs) { $chunks.Add($s) }
        }
        if ($ref.Ids.Count -gt 0) {
            # ID の詳細の節 (見出しが ID で始まる) と、ID の定義行
            foreach ($id in $ref.Ids) {
                foreach ($s in @(Get-MdHeadingSections $p $id | Where-Object { $_ -match ('^#+\s+' + [regex]::Escape($id) + '(?![A-Za-z0-9-])') })) {
                    if (-not ($chunks | Where-Object { $_.Contains($s) })) { $chunks.Add($s) }
                }
            }
            # 定義行は、指定した見出しの節に入っていなければ足す
            $def = Get-IdDefinitionRows $p $ref.Ids
            $already = ($chunks -join "`n")
            if ($def.Text -and @($def.RowTexts | Where-Object { -not $already.Contains($_) }).Count -gt 0) { $chunks.Add($def.Text) }
            # 定義行も ID の節も見つからない ID は報告する (別のファイルの ID を書き間違えると、黙ってファイル全体が入っていたため)
            $got = ($chunks -join "`n")
            foreach ($id in $ref.Ids) { if (-not $got.Contains($id)) { $missing.Add("$($ref.Path): ID「$id」の定義行・節がありません") } }
        }
        if ($ref.Headings.Count -eq 0 -and $ref.Ids.Count -eq 0) { $chunks.Add((Read-Utf8 $p).TrimEnd()) }
        if ($chunks.Count -eq 0) { continue }
        [void]$sb.AppendLine("# [設計] $($ref.Path)").AppendLine("<!-- 指定: $($ref.Line) -->").AppendLine()
        foreach ($c in $chunks) { [void]$sb.AppendLine($c).AppendLine() }
    }
    if ($TaskId -like 'TASK-AT-*') {
        # 受け入れテストのタスク: 担当の要件の定義行と、受け入れ例の印 (テストの期待値側に書く値) を添える
        $ex = Get-RequirementExamples $Root $Config
        $mine = @(Get-TaskAssignedIds $Root $Config $TaskId | Where-Object { $ex.Contains($_) } | ForEach-Object { $ex[$_] })
        if ($mine.Count -gt 0) {
            [void]$sb.AppendLine('# [受け入れ例] 担当の要件の Then の印 (アサーションの期待値側に、この値をそのまま書く。!値 は否定のアサーション、→ は並び順)').AppendLine()
            foreach ($e in $mine) {
                [void]$sb.AppendLine("## $($e.Id) ($($e.Where))").AppendLine().AppendLine($e.Text.Trim()).AppendLine()
                foreach ($mk in $e.Marks) { [void]$sb.AppendLine("- 値: ``$(if ($mk.Neg) { '!' })$($mk.Value)``$(if ($mk.Dec) { " ($($mk.Dec))" })") }
                foreach ($o in $e.Orders) { [void]$sb.AppendLine("- 並び順: $(($o | ForEach-Object { '`' + $_ + '`' }) -join ' → ')") }
                [void]$sb.AppendLine()
            }
        }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($sb.ToString())
    if ($WithNotes) {
        $task = Read-TaskIndex $Root $Config | Where-Object { $_.Id -eq $TaskId } | Select-Object -First 1
        foreach ($d in @($task.Deps)) {
            $np = Join-DevflowPath $Root ".devflow/notes/$d.md"
            if (Test-Path -LiteralPath $np) { [void]$sb.AppendLine("# [依存タスクの実装メモ] .devflow/notes/$d.md").AppendLine().AppendLine((Read-Utf8 $np).TrimEnd()).AppendLine() }
        }
    }
    return [pscustomobject]@{ Text = $sb.ToString(); Bytes = $bytes; Missing = @($missing) }
}

# ---------------------------------------------------------------------------
# ID
# ---------------------------------------------------------------------------

function Get-IdRegex($Config) {
    $p = ($Config.idPrefixes | ForEach-Object { [regex]::Escape([string]$_) }) -join '|'
    return [regex]::new("(?<![A-Za-z0-9_-])(?:$p)-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*(?![A-Za-z0-9_]|-\*)")
}

function Get-IdsInText([string]$Text, [regex]$IdRegex) {
    if (-not $Text) { return @() }
    return @($IdRegex.Matches($Text) | ForEach-Object { $_.Value } | Select-Object -Unique)
}

function Test-IsId([string]$Text, [regex]$IdRegex) {
    $m = $IdRegex.Match($Text)
    return ($m.Success -and $m.Index -eq 0 -and $m.Length -eq $Text.Length)
}

# ---------------------------------------------------------------------------
# タスク一覧 (docs/04-detailed-design/tasks/index.md)
# ---------------------------------------------------------------------------

function Get-TasksIndexPath([string]$Root) { return Join-DevflowPath $Root 'docs/04-detailed-design/tasks/index.md' }

function Read-TaskIndex([string]$Root, $Config) {
    # 戻り値: 順序付きの @{ Id; Title; Deps; Status; Line }
    $path = Get-TasksIndexPath $Root
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $path)) { return $result }
    $idre = Get-IdRegex $Config
    foreach ($tb in Get-MdTables $path) {
        $ci = Get-ColumnIndex $tb.Headers @('ID')
        $cs = Get-ColumnIndex $tb.Headers @('状態', 'Status')
        if ($ci -lt 0 -or $cs -lt 0) { continue }
        $ct = Get-ColumnIndex $tb.Headers @('タイトル', 'Title')
        $cd = Get-ColumnIndex $tb.Headers @('依存', 'Deps')
        foreach ($r in $tb.Rows) {
            if ($r.Cells.Count -le [Math]::Max($ci, $cs)) { continue }
            $id = ConvertTo-PlainCell $r.Cells[$ci]
            if (-not (Test-IsId $id $idre)) { continue }
            $deps = @()
            if ($cd -ge 0 -and $cd -lt $r.Cells.Count) { $deps = Get-IdsInText (ConvertTo-PlainCell $r.Cells[$cd]) $idre }
            $result.Add([pscustomobject]@{
                Id     = $id
                Title  = if ($ct -ge 0 -and $ct -lt $r.Cells.Count) { ConvertTo-PlainCell $r.Cells[$ct] } else { '' }
                Deps   = @($deps)
                Status = (ConvertTo-PlainCell $r.Cells[$cs]).ToLowerInvariant()
                Line   = $r.No
            })
        }
    }
    return $result
}

function Get-TaskAssignedIds([string]$Root, $Config, [string]$TaskId) {
    # タスクファイルの「担当ID」。タスクファイルがなければ $null
    $path = Join-DevflowPath $Root "docs/04-detailed-design/tasks/$TaskId.md"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $idre = Get-IdRegex $Config
    foreach ($tb in Get-MdTables $path) {
        foreach ($r in $tb.Rows) {
            if ($r.Cells.Count -ge 2 -and (ConvertTo-PlainCell $r.Cells[0]) -eq '担当ID') { return @(Get-IdsInText (ConvertTo-PlainCell $r.Cells[1]) $idre) }
        }
    }
    return @()
}

function Set-TaskIndexStatus([string]$Root, $Config, [string]$TaskId, [string]$Status) {
    $path = Get-TasksIndexPath $Root
    $lines = (Read-Utf8 $path) -split "`r?`n"
    $tasks = Read-TaskIndex $Root $Config
    $task = $tasks | Where-Object { $_.Id -eq $TaskId } | Select-Object -First 1
    if (-not $task) { throw "tasks/index.md に $TaskId がありません" }
    $tb = (Get-MdTables $path) | Where-Object { $_.Rows.No -contains $task.Line } | Select-Object -First 1
    $cs = Get-ColumnIndex $tb.Headers @('状態', 'Status')
    $cells = @(Split-MdRow $lines[$task.Line - 1])
    $cells[$cs] = $Status
    $lines[$task.Line - 1] = '| ' + (($cells | ForEach-Object { $_.Replace('|', '\|') }) -join ' | ') + ' |'
    Write-Utf8 $path (($lines -join "`n"))
}

function Add-TaskDependency([string]$Root, $Config, [string]$TaskId, [string]$DepId) {
    # tasks/index.md の「依存」列とタスクファイルの「依存」行の両方に DepId を足す (両者は trace が一致を確かめる)
    $path = Get-TasksIndexPath $Root
    $lines = (Read-Utf8 $path) -split "`r?`n"
    $task = Read-TaskIndex $Root $Config | Where-Object { $_.Id -eq $TaskId } | Select-Object -First 1
    if (-not $task) { throw "tasks/index.md に $TaskId がありません" }
    $tb = (Get-MdTables $path) | Where-Object { $_.Rows.No -contains $task.Line } | Select-Object -First 1
    $cd = Get-ColumnIndex $tb.Headers @('依存', 'Deps')
    if ($cd -lt 0) { throw 'tasks/index.md に「依存」列がありません' }
    $deps = (@($task.Deps) + $DepId | Select-Object -Unique) -join ', '
    $cells = @(Split-MdRow $lines[$task.Line - 1])
    $cells[$cd] = $deps
    $lines[$task.Line - 1] = '| ' + (($cells | ForEach-Object { $_.Replace('|', '\|') }) -join ' | ') + ' |'
    Write-Utf8 $path (($lines -join "`n"))

    $tf = Join-DevflowPath $Root "docs/04-detailed-design/tasks/$TaskId.md"
    if (Test-Path -LiteralPath $tf) {
        $tl = (Read-Utf8 $tf) -split "`r?`n"
        for ($i = 0; $i -lt $tl.Count; $i++) {
            if ($tl[$i] -match '^\s*\|' ) {
                $c = @(Split-MdRow $tl[$i])
                if ($c.Count -ge 2 -and (ConvertTo-PlainCell $c[0]) -eq '依存') {
                    $c[1] = $deps
                    $tl[$i] = '| ' + (($c | ForEach-Object { $_.Replace('|', '\|') }) -join ' | ') + ' |'
                    break
                }
            }
        }
        Write-Utf8 $tf (($tl -join "`n"))
    }
}

function Test-TaskDependsOn($Tasks, [string]$From, [string]$To) {
    # From から依存をたどって To に着くか
    $byId = @{}
    foreach ($t in $Tasks) { $byId[$t.Id] = $t }
    $seen = @{}
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($From)
    while ($stack.Count -gt 0) {
        $c = $stack.Pop()
        if ($c -eq $To) { return $true }
        if ($seen.ContainsKey($c) -or -not $byId.ContainsKey($c)) { continue }
        $seen[$c] = $true
        foreach ($d in $byId[$c].Deps) { $stack.Push($d) }
    }
    return $false
}

function Get-ReadyTask($Tasks) {
    # 作業中のタスクを優先し、次に依存がすべて done の todo タスクを一覧順に返す
    $byId = @{}
    foreach ($t in $Tasks) { $byId[$t.Id] = $t }
    $inprog = $Tasks | Where-Object { $_.Status -eq 'in_progress' } | Select-Object -First 1
    if ($inprog) { return $inprog }
    foreach ($t in $Tasks) {
        if ($t.Status -ne 'todo') { continue }
        $ok = $true
        foreach ($d in $t.Deps) {
            if (-not $byId.ContainsKey($d) -or $byId[$d].Status -ne 'done') { $ok = $false; break }
        }
        if ($ok) { return $t }
    }
    return $null
}

# ---------------------------------------------------------------------------
# コンテキスト使用率
# ---------------------------------------------------------------------------

function Get-TranscriptContextTokens([string]$TranscriptPath, [switch]$IncludeSidechain) {
    # transcript (JSONL) の末尾から、最新 assistant 応答の usage を探す。
    # 既定ではメイン会話の応答だけを見る。サブエージェントの transcript を読むときは -IncludeSidechain を付ける (全行が isSidechain=true)。
    # 入力トークン = input + cache_creation + cache_read (= 次の要求で再送される文脈量)
    if (-not $TranscriptPath -or -not (Test-Path -LiteralPath $TranscriptPath)) { return $null }
    $fs = [System.IO.File]::Open($TranscriptPath, 'Open', 'Read', 'ReadWrite')
    try {
        $len = $fs.Length
        $chunk = [Math]::Min($len, 4MB)
        $fs.Seek($len - $chunk, 'Begin') | Out-Null
        $buf = [byte[]]::new($chunk)
        $read = 0
        while ($read -lt $chunk) { $n = $fs.Read($buf, $read, $chunk - $read); if ($n -le 0) { break }; $read += $n }
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } finally { $fs.Dispose() }
    $lines = $text -split "`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $l = $lines[$i]
        if ($l -notmatch '"type":"assistant"' -or $l -notmatch '"usage"') { continue }
        try { $o = $l | ConvertFrom-Json } catch { continue }
        if (-not $IncludeSidechain -and $o.PSObject.Properties['isSidechain'] -and $o.isSidechain) { continue }
        $u = $o.message.usage
        if (-not $u) { continue }
        $sum = 0
        foreach ($k in 'input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens') {
            if ($u.PSObject.Properties[$k] -and $u.$k) { $sum += [double]$u.$k }
        }
        return $sum
    }
    return $null
}

function Get-AgentTranscriptPath($HookInput) {
    # サブエージェントの transcript のパス。SubagentStop は agent_transcript_path を持つ。
    # ツールのイベント (PostToolUse など) は agent_id だけなので、<セッションの transcript と同じ場所>/<session_id>/subagents/agent-<agent_id>.jsonl を組み立てる
    if (-not $HookInput) { return $null }
    if ($HookInput.PSObject.Properties['agent_transcript_path'] -and $HookInput.agent_transcript_path) { return [string]$HookInput.agent_transcript_path }
    if (-not ($HookInput.PSObject.Properties['agent_id'] -and $HookInput.agent_id)) { return $null }
    if (-not ($HookInput.PSObject.Properties['transcript_path'] -and $HookInput.transcript_path)) { return $null }
    $dir = Split-Path -Parent ([string]$HookInput.transcript_path)
    return (Join-Path $dir ("{0}/subagents/agent-{1}.jsonl" -f $HookInput.session_id, $HookInput.agent_id))
}

function Get-AgentContextUsage($Config, $HookInput) {
    # サブエージェント自身のコンテキスト使用量 (最新の応答の入力トークン)
    $tokens = Get-TranscriptContextTokens (Get-AgentTranscriptPath $HookInput) -IncludeSidechain
    if ($null -eq $tokens) { return $null }
    $window = [double]$Config.contextWindowTokens
    $pct = if ($window -gt 0) { $tokens / $window * 100 } else { 0 }
    return [pscustomobject]@{ Percent = $pct; Tokens = $tokens; Window = $window; Source = 'agent-transcript' }
}

function Test-ContextOver($Config, $Usage, $BaseTokens) {
    # 引き継ぐべきかを判定する。
    # 閾値だけで判定すると、起動直後の固定分が閾値に近い環境では何も進めないまま引き継ぎだけを繰り返す。
    # そこで、開始時の使用量 ($BaseTokens) から minSessionWorkTokens 以上進んでいることも条件にする。
    # ただし hardLimitPercent に達したら、作業量にかかわらず引き継ぐ。
    if (-not $Usage) { return $false }
    $threshold = [double]$Config.contextThresholdPercent
    if ($Usage.Percent -lt $threshold) { return $false }
    $hard = if ($Config.Contains('hardLimitPercent') -and $Config.hardLimitPercent) { [double]$Config.hardLimitPercent } else { 85 }
    if ($Usage.Percent -ge $hard) { return $true }
    $minWork = if ($Config.Contains('minSessionWorkTokens')) { [double]$Config.minSessionWorkTokens } else { 0 }
    if ($minWork -le 0 -or -not $BaseTokens) { return $true }
    return (($Usage.Tokens - [double]$BaseTokens) -ge $minWork)
}

# ---------------------------------------------------------------------------
# 実装担当 (tdd-implementer) の実行記録 .devflow/implementer.json
#   agentId / startedAt / baseTokens (最初に測った使用量) / blocks / lastFingerprint
# ---------------------------------------------------------------------------

function Read-ImplementerRun([string]$Root) {
    $p = Join-DevflowPath $Root '.devflow/implementer.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Read-Utf8 $p | ConvertFrom-Json -AsHashtable) } catch { return $null }
}

function Write-ImplementerRun([string]$Root, $Run) {
    Write-Utf8 (Join-DevflowPath $Root '.devflow/implementer.json') (($Run | ConvertTo-Json -Compress) + "`n")
}

function Get-ProcessedTaskCount([string]$Root) {
    # done か blocked のタスクの数 (1 タスク 1 体の判定に使う: 開始時より増えたら、その実装担当の担当分は処理済み)
    $cfg = Get-DevflowConfig $Root
    return @(Read-TaskIndex $Root $cfg | Where-Object { $_.Status -in @('done', 'blocked') }).Count
}

function New-ImplementerRun([string]$Root, [string]$AgentId) {
    $run = [ordered]@{ agentId = $AgentId; startedAt = (Get-Date).ToString('o'); baseTokens = $null; blocks = 0; lastFingerprint = ''
                       processedAtStart = (Get-ProcessedTaskCount $Root) }
    Write-ImplementerRun $Root $run
    return $run
}

function Get-ImplementerRun([string]$Root, [string]$AgentId) {
    # 記録がない、または別の実装担当の記録なら作り直す (SubagentStart フックが動かなかった場合の保険)
    $run = Read-ImplementerRun $Root
    if (-not $run -or [string]$run.agentId -ne $AgentId) { $run = New-ImplementerRun $Root $AgentId }
    return $run
}

function Get-ProgressFingerprint([string]$Root) {
    # 進捗の指紋: HEAD とタスク一覧 (状態欄)
    $parts = @((& git -C $Root rev-parse HEAD 2>$null))
    $p = Join-DevflowPath $Root 'docs/04-detailed-design/tasks/index.md'
    if (Test-Path -LiteralPath $p) { $parts += (Get-FileHash -LiteralPath $p -Algorithm SHA1).Hash }
    return ($parts -join ':')
}

# ---------------------------------------------------------------------------
# 決定台帳 (.devflow/decisions/ledger.md)
#   ユーザーに聞いて決めたこと (確定)・聞かずに決めたこと (仮)・自動区間の処置 (処置-C / 処置-B / 要回答) を、
#   照合パターン (その値が文書に現れたときに当たる正規表現) 付きの 1 本の表に持つ。
#   | DEC | 論点 | 決定 | 照合 | 区分 | 根拠 | 状態 | 版 | 旧照合 |
# ---------------------------------------------------------------------------

$script:LedgerHeaders = @('DEC', '論点', '決定', '照合', '区分', '根拠', '状態', '版', '旧照合')
$script:LedgerKinds = @('確定', '仮', '処置-C', '処置-B', '要回答')
$script:LedgerStatuses = @('有効', 'open', '解決')
$script:DecRegex = [regex]::new('(?<![A-Za-z0-9_-])DEC-\d+(?![A-Za-z0-9_])')
$script:LedgerPreamble = @'
# 決定台帳

> ユーザーに聞いて決めたこと (確定)・聞かずに決めたこと (仮)・自動区間の処置 (処置-C / 処置-B / 要回答) を 1 行ずつ持つ。
> 行の追加・変更は `scripts/devflow-state.ps1` の `ledger add` / `override` / `amend` で行う (論点・根拠の誤記は手で直してよい)。
> 照合: その値が docs/ に現れたときに当たる正規表現 (他の値と区別できる部分と、派生値を含める)。DEC を書いていない当たりは
> trace が DEC-UNCITED にする。別の意味で同じ語を使う行には `DEC 対象外: DEC-…` と書く。
> 状態: 有効 / open (処置-B・要回答の未解決) / 解決。版: override のたびに 1 増え、前の照合は「旧照合」に残る (DEC-STALE の検出に使う)。

'@

function Get-LedgerPath([string]$Root) { return Join-DevflowPath $Root '.devflow/decisions/ledger.md' }
function Get-DecRegex { return $script:DecRegex }
function Get-LedgerKinds { return $script:LedgerKinds }

function Get-CodeSpans([string]$Text) {
    if (-not $Text) { return @() }
    return @([regex]::Matches($Text, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value })
}

function Read-Ledger([string]$Root) {
    # 戻り値: 行の列 (@{ Dec; Topic; Value; Match; Kind; Basis; Status; Version; OldMatches; Line })。台帳がなければ $null
    $p = Get-LedgerPath $Root
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($tb in Get-MdTables $p) {
        $ci = Get-ColumnIndex $tb.Headers @('DEC')
        if ($ci -lt 0) { continue }
        $col = @{}
        foreach ($h in $script:LedgerHeaders) { $col[$h] = Get-ColumnIndex $tb.Headers @($h) }
        foreach ($r in $tb.Rows) {
            $cell = { param($h) $k = $col[$h]; if ($k -ge 0 -and $k -lt $r.Cells.Count) { [string]$r.Cells[$k] } else { '' } }
            $dec = ConvertTo-PlainCell (& $cell 'DEC')
            if ($dec -notmatch '^DEC-\d+$') { continue }
            $mraw = (& $cell '照合').Trim()
            $spans = @(Get-CodeSpans $mraw)
            $match = if ($spans.Count -gt 0) { $spans[0] } elseif ($mraw -in @('', '-', '—')) { '' } else { $mraw }
            $ver = 1; [void][int]::TryParse((ConvertTo-PlainCell (& $cell '版')), [ref]$ver)
            $rows.Add([pscustomobject]@{
                Dec = $dec; Topic = (& $cell '論点').Trim(); Value = (& $cell '決定').Trim(); Match = $match
                Kind = (ConvertTo-PlainCell (& $cell '区分')); Basis = (& $cell '根拠').Trim(); Status = (ConvertTo-PlainCell (& $cell '状態'))
                Version = $ver; OldMatches = @(Get-CodeSpans (& $cell '旧照合')); Line = $r.No
            })
        }
    }
    return $rows
}

function Format-LedgerCell([string]$Text) { return ($Text -replace '\r?\n', ' ').Replace('|', '\|') }

function Write-Ledger([string]$Root, $Rows) {
    $sb = [System.Text.StringBuilder]::new($script:LedgerPreamble)
    [void]$sb.AppendLine('| ' + ($script:LedgerHeaders -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + (($script:LedgerHeaders | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in @($Rows | Where-Object { $_ })) {
        $m = if ($r.Match) { '`' + $r.Match + '`' } else { '-' }
        $old = if (@($r.OldMatches).Count -gt 0) { (@($r.OldMatches) | ForEach-Object { '`' + $_ + '`' }) -join ' ' } else { '-' }
        $cells = @($r.Dec, $r.Topic, $r.Value, $m, $r.Kind, $r.Basis, $r.Status, [string]$r.Version, $old) | ForEach-Object { Format-LedgerCell ([string]$_) }
        [void]$sb.AppendLine('| ' + ($cells -join ' | ') + ' |')
    }
    Write-Utf8 (Get-LedgerPath $Root) $sb.ToString().Replace("`r`n", "`n")
}

function Get-NextDecId($Rows) {
    $max = 0
    foreach ($r in @($Rows | Where-Object { $_ })) { $n = [int]($r.Dec.Substring(4)); if ($n -gt $max) { $max = $n } }
    return ('DEC-{0:D3}' -f ($max + 1))
}

function Test-RegexValid([string]$Pattern) {
    try { [void][regex]::new($Pattern); return $true } catch { return $false }
}

function Get-DocScanLines([string]$Root) {
    # 照合の対象: docs/ の全行 (表の行・地の文・タスクファイル)。生成物 (traceability.md・レポート・ids.md) とコードブロックは除く
    $generated = @('docs/traceability.md', 'docs/verification-report.md', 'docs/deployment-report.md')
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in @(Get-TrackedFiles $Root | Where-Object { $_ -like 'docs/*.md' -and $generated -notcontains $_ -and $_ -notlike '*/ids.md' })) {
        $full = Join-DevflowPath $Root $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        foreach ($ln in Get-MdLines $full) { if ($ln.Text.Trim()) { $out.Add([pscustomobject]@{ File = $rel; No = $ln.No; Text = $ln.Text }) } }
    }
    return $out
}

function Test-LineExcludesDec([string]$Text, [string]$Dec) {
    # `DEC 対象外: DEC-001, DEC-002` の形で、その DEC を対象外にした行か
    foreach ($m in [regex]::Matches($Text, 'DEC\s*対象外\s*[:：]\s*([^|)）]*)')) {
        if (@($script:DecRegex.Matches($m.Groups[1].Value) | ForEach-Object { $_.Value }) -contains $Dec) { return $true }
    }
    return $false
}

function Test-LineCitesDec([string]$Text, [string]$Dec) {
    if (Test-LineExcludesDec $Text $Dec) {
        # 対象外の書き方に含まれる DEC は引用に数えない
        $t = [regex]::Replace($Text, 'DEC\s*対象外\s*[:：]\s*[^|)）]*', '')
        return (@($script:DecRegex.Matches($t) | ForEach-Object { $_.Value }) -contains $Dec)
    }
    return (@($script:DecRegex.Matches($Text) | ForEach-Object { $_.Value }) -contains $Dec)
}

function Get-IdDefinitionIndex([string]$Root, $Config) {
    # docs の ID 定義 (見出しに ID と 検証 を持つ表の行)。戻り値: @{ ByLine = @{ 'file:no' = id }; ById = @{ id = @{ File; No; Verify; Upstream; Text } } }
    $idre = Get-IdRegex $Config
    $byLine = @{}; $byId = @{}
    foreach ($rel in @(Get-TrackedFiles $Root | Where-Object { ($_ -like 'docs/02-*' -or $_ -like 'docs/03-*' -or $_ -like 'docs/04-*') -and $_ -like '*.md' -and $_ -notlike 'docs/04-detailed-design/tasks/*' -and $_ -notlike '*/ids.md' })) {
        $full = Join-DevflowPath $Root $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $src = (Read-Utf8 $full) -split "`r?`n"
        foreach ($tb in Get-MdTables $full) {
            $ci = Get-ColumnIndex $tb.Headers @('ID')
            $cv = Get-ColumnIndex $tb.Headers @('検証', 'Verify')
            if ($ci -lt 0 -or $cv -lt 0) { continue }
            $cu = Get-ColumnIndex $tb.Headers @('上流', 'Trace')
            foreach ($r in $tb.Rows) {
                if ($r.Cells.Count -le $ci) { continue }
                $id = ConvertTo-PlainCell $r.Cells[$ci]
                if (-not (Test-IsId $id $idre)) { continue }
                $byLine["${rel}:$($r.No)"] = $id
                if (-not $byId.ContainsKey($id)) {
                    $up = if ($cu -ge 0 -and $cu -lt $r.Cells.Count) { @(Get-IdsInText (ConvertTo-PlainCell $r.Cells[$cu]) $idre) } else { @() }
                    $byId[$id] = [pscustomobject]@{ File = $rel; No = $r.No; Verify = ((ConvertTo-PlainCell $r.Cells[$cv]).ToLowerInvariant()); Upstream = $up; Text = $src[$r.No - 1] }
                }
            }
        }
    }
    return [pscustomobject]@{ ByLine = $byLine; ById = $byId }
}

function Get-LedgerIssues([string]$Root, $Config, $Rows, $DocLines = $null) {
    # 台帳そのものと docs/ の全行の照合。戻り値: @{ code; id; message; where } の列
    # LEDGER-INVALID (区分・状態・照合の誤り、DEC の重複) / LEDGER-BASIS (根拠の ID・引用が実在しない) /
    # DEC-UNKNOWN (台帳にない DEC の引用) / DEC-UNCITED (照合に当たるのに DEC を書いていない行) / DEC-STALE (旧照合に当たる行)
    $out = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Rows) { return $out }
    $lp = '.devflow/decisions/ledger.md'
    $add = { param($c, $i, $m, $w) $out.Add([pscustomobject]@{ code = $c; id = $i; message = $m; where = $w }) }
    $seen = @{}
    foreach ($r in $Rows) {
        $w = "${lp}:$($r.Line)"
        if ($seen.ContainsKey($r.Dec)) { & $add 'LEDGER-INVALID' $r.Dec "DEC が重複しています (先の行: $($seen[$r.Dec]))" $w; continue }
        $seen[$r.Dec] = $w
        if ($script:LedgerKinds -notcontains $r.Kind) { & $add 'LEDGER-INVALID' $r.Dec "区分が $($script:LedgerKinds -join ' / ') のいずれでもありません: '$($r.Kind)'" $w }
        if ($script:LedgerStatuses -notcontains $r.Status) { & $add 'LEDGER-INVALID' $r.Dec "状態が $($script:LedgerStatuses -join ' / ') のいずれでもありません: '$($r.Status)'" $w }
        if (-not $r.Match -and $r.Kind -eq '仮') { & $add 'LEDGER-INVALID' $r.Dec '仮の決定に照合がありません (照合が書けない「形」の論点は、仮にせずユーザーに聞く)' $w }
        foreach ($p in @(@($r.Match) + @($r.OldMatches) | Where-Object { $_ })) {
            if (-not (Test-RegexValid $p)) { & $add 'LEDGER-INVALID' $r.Dec "照合が正規表現として読めません: $p" $w }
        }
    }
    # 根拠: 上流の ID か、01 (企画・構想) などでのユーザーの発言の逐語引用「…」。処置の行はタスク ID
    $idre = Get-IdRegex $Config
    $defIdx = Get-IdDefinitionIndex $Root $Config
    $taskIds = @(Read-TaskIndex $Root $Config | ForEach-Object { $_.Id })
    $quoteSrc = [System.Text.StringBuilder]::new()
    $vp = Join-DevflowPath $Root 'docs/01-vision.md'
    if (Test-Path -LiteralPath $vp) { [void]$quoteSrc.AppendLine((Read-Utf8 $vp)) }
    $dd = Join-DevflowPath $Root '.devflow/decisions'
    if (Test-Path -LiteralPath $dd) {
        foreach ($f in Get-ChildItem -LiteralPath $dd -File -Filter '*.md' | Where-Object { $_.Name -ne 'ledger.md' }) { [void]$quoteSrc.AppendLine((Read-Utf8 $f.FullName)) }
    }
    $quotes = $quoteSrc.ToString()
    foreach ($r in $Rows) {
        $w = "${lp}:$($r.Line)"
        $ids = @(Get-IdsInText $r.Basis $idre)
        $qs = @([regex]::Matches($r.Basis, '「([^」]+)」') | ForEach-Object { $_.Groups[1].Value })
        # 慣習で決めた仮の値 (文字コード・日付の書式など) は、上流に根拠がないので「慣習: <何の慣習か>」と書く
        if ($r.Kind -eq '仮' -and $r.Basis -match '^\s*慣習\s*[:：]\s*\S') { continue }
        if ($ids.Count -eq 0 -and $qs.Count -eq 0) { & $add 'LEDGER-BASIS' $r.Dec '根拠に上流の ID も、発言の逐語引用「…」も、(仮なら) 「慣習: …」もありません' $w; continue }
        foreach ($i in $ids) { if (-not $defIdx.ById.ContainsKey($i) -and $taskIds -notcontains $i) { & $add 'LEDGER-BASIS' $r.Dec "根拠の ID $i が定義されていません" $w } }
        foreach ($q in $qs) { if (-not $quotes.Contains($q)) { & $add 'LEDGER-BASIS' $r.Dec "根拠の引用「$q」が docs/01-vision.md と .devflow/decisions/ の質問ログにありません (逐語で引用する)" $w } }
    }
    if ($null -eq $DocLines) { $DocLines = @(Get-DocScanLines $Root) }
    $known = @{}; foreach ($r in $Rows) { $known[$r.Dec] = $r }
    $compiled = @{}
    foreach ($r in $Rows) {
        $compiled[$r.Dec] = [pscustomobject]@{
            Cur = if ($r.Match -and (Test-RegexValid $r.Match)) { [regex]::new($r.Match) } else { $null }
            Old = @(@($r.OldMatches) | Where-Object { $_ -and (Test-RegexValid $_) } | ForEach-Object { [regex]::new($_) })
        }
    }
    foreach ($ln in $DocLines) {
        $where = "$($ln.File):$($ln.No)"
        foreach ($d in @($script:DecRegex.Matches($ln.Text) | ForEach-Object { $_.Value } | Select-Object -Unique)) {
            if (-not $known.ContainsKey($d)) { & $add 'DEC-UNKNOWN' $d '台帳にない DEC を引用しています' $where }
        }
        foreach ($r in $Rows) {
            $c = $compiled[$r.Dec]
            if (Test-LineExcludesDec $ln.Text $r.Dec) { continue }
            $staleHit = @($c.Old | Where-Object { $_.IsMatch($ln.Text) })
            if ($staleHit.Count -gt 0) {
                & $add 'DEC-STALE' $r.Dec "旧照合 ($($staleHit[0].ToString())) に当たる行が残っています (版 $($r.Version) の値: $($r.Value)): $($ln.Text.Trim())" $where
                continue
            }
            # 自動区間の処置 (処置-C / 処置-B / 要回答) の照合は影響の算出用で、文書に引用を求めない (実装担当は docs/ を編集しないため)
            if ($r.Kind -in @('処置-C', '処置-B', '要回答')) { continue }
            if ($c.Cur -and $c.Cur.IsMatch($ln.Text) -and -not (Test-LineCitesDec $ln.Text $r.Dec)) {
                & $add 'DEC-UNCITED' $r.Dec "照合 ($($r.Match)) に当たる行が $($r.Dec) を引用していません (別の意味なら行に ``DEC 対象外: $($r.Dec)`` と書く): $($ln.Text.Trim())" $where
            }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# 受け入れ例 (要件の Then の印) と lock
#   Then の中で、プログラムが出す値を `…` で印す。台帳の DEC に依る値は印の直後に [DEC-…]、
#   「無い」性質は否定印 `!…`、並び順は `a` → `b` で宣言する
# ---------------------------------------------------------------------------

function Get-ExampleMarks([string]$Cell) {
    # 戻り値: @{ Marks = @(@{ Value; Neg; Dec }); Orders = @(@(値, 値, ...)) }
    $t = $Cell
    $k = $t.IndexOf('Then', [StringComparison]::OrdinalIgnoreCase)
    if ($k -ge 0) { $t = $t.Substring($k + 4) }
    $marks = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($t, '`([^`]+)`(\s*\[(DEC-\d+)\])?')) {
        $v = $m.Groups[1].Value
        $neg = $v.StartsWith('!') -and $v.Length -gt 1
        if ($neg) { $v = $v.Substring(1) }
        $marks.Add([pscustomobject]@{ Value = $v; Neg = $neg; Dec = $m.Groups[3].Value })
    }
    $orders = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($t, '`[^`]+`(?:\s*\[DEC-\d+\])?(?:\s*(?:→|->)\s*`[^`]+`(?:\s*\[DEC-\d+\])?)+')) {
        $vals = @([regex]::Matches($m.Value, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.TrimStart('!') })
        $orders.Add($vals)
    }
    return [pscustomobject]@{ Marks = @($marks); Orders = @($orders) }
}

function Get-RequirementExamples([string]$Root, $Config) {
    # docs/02-requirements の REQ の定義行から受け入れ例の印を読む。戻り値: 順序付き辞書 REQ → @{ Id; Verify; Where; Text; Marks; Orders; Decs }
    $idre = Get-IdRegex $Config
    $out = [ordered]@{}
    foreach ($rel in @(Get-TrackedFiles $Root | Where-Object { $_ -like 'docs/02-requirements/*.md' -and $_ -notlike '*/ids.md' })) {
        $full = Join-DevflowPath $Root $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $src = (Read-Utf8 $full) -split "`r?`n"
        foreach ($tb in Get-MdTables $full) {
            $ci = Get-ColumnIndex $tb.Headers @('ID')
            $cv = Get-ColumnIndex $tb.Headers @('検証', 'Verify')
            if ($ci -lt 0 -or $cv -lt 0) { continue }
            $ca = -1
            for ($h = 0; $h -lt $tb.Headers.Count; $h++) { if ($tb.Headers[$h] -match '受け入れ基準|Then') { $ca = $h; break } }
            if ($ca -lt 0) { $ca = 0..($tb.Headers.Count - 1) | Where-Object { $_ -ne $ci -and $_ -ne $cv } | Select-Object -First 1 }
            foreach ($r in $tb.Rows) {
                if ($r.Cells.Count -le [Math]::Max($ci, $ca)) { continue }
                $id = ConvertTo-PlainCell $r.Cells[$ci]
                if (-not $id.StartsWith('REQ-') -or -not (Test-IsId $id $idre) -or $out.Contains($id)) { continue }
                $ex = Get-ExampleMarks ([string]$r.Cells[$ca])
                $out[$id] = [pscustomobject]@{
                    Id = $id; Verify = if ($cv -lt $r.Cells.Count) { (ConvertTo-PlainCell $r.Cells[$cv]).ToLowerInvariant() } else { '' }
                    Where = "${rel}:$($r.No)"; Text = $src[$r.No - 1]; Cell = [string]$r.Cells[$ca]; Marks = $ex.Marks; Orders = $ex.Orders
                    Decs = @($script:DecRegex.Matches($src[$r.No - 1]) | ForEach-Object { $_.Value } | Select-Object -Unique)
                }
            }
        }
    }
    return $out
}

function Get-ExampleSignature($Example) {
    $m = @($Example.Marks | ForEach-Object { '`' + $(if ($_.Neg) { '!' } else { '' }) + $_.Value + '`' + $(if ($_.Dec) { "[$($_.Dec)]" } else { '' }) })
    $o = @($Example.Orders | ForEach-Object { ($_ | ForEach-Object { '`' + $_ + '`' }) -join ' → ' })
    return [pscustomobject]@{ marks = @($m); orders = @($o) }
}

function Get-ExampleLockPath([string]$Root) { return Join-DevflowPath $Root '.devflow/examples.lock.json' }

function Write-ExampleLock([string]$Root, $Config) {
    $ex = Get-RequirementExamples $Root $Config
    $map = [ordered]@{}
    foreach ($e in $ex.Values) { if ($e.Marks.Count -gt 0) { $map[$e.Id] = Get-ExampleSignature $e } }
    $obj = [ordered]@{ version = 1; at = (Get-Date).ToString('o'); examples = $map }
    Write-Utf8 (Get-ExampleLockPath $Root) (($obj | ConvertTo-Json -Depth 6) + "`n")
    return $map.Count
}

function Get-ExampleLockIssues([string]$Root, $Config, $Examples) {
    # 承認時に凍結した例と、今の要件の例の差。lock がなければ何もしない (以前の版で進めたプロジェクト)
    $out = [System.Collections.Generic.List[object]]::new()
    $lp = Get-ExampleLockPath $Root
    if (-not (Test-Path -LiteralPath $lp)) { return $out }
    $lock = (Read-Utf8 $lp | ConvertFrom-Json -AsHashtable)
    $locked = if ($lock.Contains('examples') -and $lock.examples) { $lock.examples } else { @{} }
    foreach ($id in $locked.Keys) {
        $was = $locked[$id]
        if (-not $Examples.Contains($id) -or $Examples[$id].Marks.Count -eq 0) {
            $out.Add([pscustomobject]@{ code = 'EXAMPLE-CHANGED'; id = $id; message = '承認時の受け入れ例が消えています (override / amend の後なら devflow-state.ps1 relock)'; where = '.devflow/examples.lock.json' }); continue
        }
        $now = Get-ExampleSignature $Examples[$id]
        $a = (@($was.marks) -join ' ') + ' / ' + (@($was.orders) -join ' ')
        $b = (@($now.marks) -join ' ') + ' / ' + (@($now.orders) -join ' ')
        if ($a -ne $b) {
            $out.Add([pscustomobject]@{ code = 'EXAMPLE-CHANGED'; id = $id; message = "受け入れ例が承認時と違います (承認時: $a → 今: $b)。覆しなら override / amend を通してから devflow-state.ps1 relock"; where = $Examples[$id].Where })
        }
    }
    foreach ($e in $Examples.Values) {
        if ($e.Marks.Count -gt 0 -and -not $locked.Contains($e.Id)) {
            $out.Add([pscustomobject]@{ code = 'EXAMPLE-UNLOCKED'; id = $e.Id; message = '承認後に足された受け入れ例です (amend の後なら devflow-state.ps1 relock)'; where = $e.Where })
        }
    }
    return $out
}

function Get-ExampleDecIssues($Examples, $Rows) {
    # DEC を引用する test の REQ は、Then にその DEC の値が現れるなら (照合に当たるなら)、その印を持つこと (仮の値を例に結び付け、受け入れテストで確かめさせるため)。
    # プログラムが出す値でない決定 (「外部に送らない」など) は Then に現れないので、備考で引用しても求めない
    $out = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Rows) { return $out }
    $decs = @{}; foreach ($r in $Rows) { $decs[$r.Dec] = $r }
    foreach ($e in $Examples.Values) {
        if ($e.Verify -ne 'test') { continue }
        foreach ($d in $e.Decs) {
            if (-not $decs.ContainsKey($d) -or -not $decs[$d].Match -or -not (Test-RegexValid $decs[$d].Match)) { continue }
            $then = $e.Cell; $k = $then.IndexOf('Then', [StringComparison]::OrdinalIgnoreCase); if ($k -ge 0) { $then = $then.Substring($k) }
            if (-not [regex]::IsMatch($then, $decs[$d].Match) -and @($e.Marks | Where-Object { [regex]::IsMatch($_.Value, $decs[$d].Match) }).Count -eq 0) { continue }
            if (@($e.Marks | Where-Object { $_.Dec -eq $d }).Count -eq 0) {
                $out.Add([pscustomobject]@{ code = 'DEC-NOT-IN-EXAMPLE'; id = $e.Id; message = "$d を引用していますが、Then にその値の印 (``値`` [$d]) がありません"; where = $e.Where })
            }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# 受け入れテストとの照合 (期待値側の照合)
#   [AT][REQ-…] の名前のテストの範囲から、アサーションの期待値側の引数と、そこから名前で参照される同じファイルの定数だけを取り出し、
#   例の印の値がそこにあるかを見る。テスト名・コメント・Given の行は見ない。
# ---------------------------------------------------------------------------

function Get-BalancedArgs([string]$Text, [int]$Open) {
    # $Text[$Open] が '(' のとき、対応する ')' までの中身と、トップレベルの引数の列を返す。文字列リテラルの中の括弧・カンマは数えない
    $depth = 0; $q = [char]0; $parts = [System.Collections.Generic.List[string]]::new(); $start = $Open + 1
    for ($i = $Open; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($q -ne [char]0) {
            if ($c -eq '\') { $i++; continue }
            if ($c -eq $q) { $q = [char]0 }
            continue
        }
        if ($c -eq '"' -or $c -eq "'" -or $c -eq '`') { $q = $c; continue }
        if ($c -eq '(' -or $c -eq '[' -or $c -eq '{') { $depth++; continue }
        if ($c -eq ')' -or $c -eq ']' -or $c -eq '}') {
            $depth--
            if ($depth -eq 0) { $parts.Add($Text.Substring($start, $i - $start).Trim()); return [pscustomobject]@{ Inner = $Text.Substring($Open + 1, $i - $Open - 1); Args = @($parts | Where-Object { $_ -ne '' }); End = $i } }
            continue
        }
        if ($c -eq ',' -and $depth -eq 1) { $parts.Add($Text.Substring($start, $i - $start).Trim()); $start = $i + 1 }
    }
    return $null
}

function Get-FileConstants([string]$Text) {
    # 同じファイルの定数・変数の代入 (名前 → 右辺)。期待値の引数が名前で参照するときに展開する。
    # 右辺が [ { ( で始まるときは対応する括弧まで (複数行の配列・オブジェクト)、それ以外は ; か行末まで
    $map = @{}
    foreach ($m in [regex]::Matches($Text, '(?m)(?:^|[;{])[ \t]*(?:(?:export|const|let|var|final|static|readonly|private|public|internal|string|int|val)\s+)*([A-Za-z_]\w*)[ \t]*(?::[ \t]*[^=\r\n;]+)?=(?![=>])[ \t]*')) {
        $n = $m.Groups[1].Value
        if ($map.ContainsKey($n)) { continue }
        $at = $m.Index + $m.Length
        if ($at -ge $Text.Length) { continue }
        if ('[{('.Contains([string]$Text[$at])) {
            $b = Get-BalancedArgs $Text $at
            if ($b) { $map[$n] = $b.Inner; continue }
        }
        $rest = [regex]::Match($Text.Substring($at), '^[^;\r\n]+')
        if ($rest.Success) { $map[$n] = $rest.Value }
    }
    return $map
}

function Expand-Constants([string]$Expr, $Consts) {
    $sb = [System.Text.StringBuilder]::new($Expr)
    foreach ($m in [regex]::Matches($Expr, '\b[A-Za-z_]\w*\b')) {
        if ($Consts.ContainsKey($m.Value)) { [void]$sb.Append(' ').Append($Consts[$m.Value]) }
    }
    return $sb.ToString()
}

function Get-Assertions([string]$Body, $Consts) {
    # 戻り値: @{ Pos; Neg; Text (期待値側 + 参照した定数) } の列 (出現順)
    $out = [System.Collections.Generic.List[object]]::new()
    # 1. expect(x)[.not].matcher(期待値)  (Jest / Vitest)
    foreach ($m in [regex]::Matches($Body, '\bexpect\s*\(')) {
        $a = Get-BalancedArgs $Body ($m.Index + $m.Length - 1)
        if (-not $a) { continue }
        $rest = $Body.Substring($a.End + 1)
        $cm = [regex]::Match($rest, '^((?:\s*\.\s*(?:not|resolves|rejects))*)\s*\.\s*(toBe|toEqual|toStrictEqual|toContain|toContainEqual|toMatch|toMatchObject|toHaveProperty|toHaveLength|toBeCloseTo|toThrow)\s*\(')
        if (-not $cm.Success) { continue }
        $b = Get-BalancedArgs $Body ($a.End + 1 + $cm.Length - 1)
        if (-not $b) { continue }
        $out.Add([pscustomobject]@{ Pos = $m.Index; Neg = ($cm.Groups[1].Value -match 'not'); Text = (Expand-Constants $b.Inner $Consts) })
    }
    # 2. 関数形のアサーション
    foreach ($m in [regex]::Matches($Body, '(?<![\w.])((?:self\.)?assert\w*|assert\.\w+|Assert\.\w+)\s*\(')) {
        $name = $m.Groups[1].Value
        $a = Get-BalancedArgs $Body ($m.Index + $m.Length - 1)
        if (-not $a -or $a.Args.Count -eq 0) { continue }
        $exp = if ($name -clike 'assert.*') { if ($a.Args.Count -ge 2) { @($a.Args[1]) } else { @($a.Args[0]) } }            # node:assert / chai: (actual, expected, message)
               elseif ($name -clike 'Assert.*') { if ($name -ceq 'Assert.That' -and $a.Args.Count -ge 2) { @($a.Args[1]) } else { @($a.Args[0]) } }   # xUnit / NUnit: (expected, actual)
               else { @($a.Args | Select-Object -First 2) }                                                                       # unittest / JUnit / assert(cond)
        $neg = ($name -match '(?i)(\.|assert)(not|doesnot)' -or $name -match 'False$')
        $out.Add([pscustomobject]@{ Pos = $m.Index; Neg = $neg; Text = (Expand-Constants ($exp -join ' ') $Consts) })
    }
    # 3. Python の assert 文
    foreach ($m in [regex]::Matches($Body, '(?m)^[ \t]*assert[ \t]+(?!\()(.+)$')) {
        $e = $m.Groups[1].Value
        $neg = $false; $exp = $e
        if ($e -match '^(.*?)\s+not\s+in\s+') { $neg = $true; $exp = $Matches[1] }
        elseif ($e -match '^(.*?)\s+in\s+') { $exp = $Matches[1] }
        elseif ($e -match '!=\s*(.+)$') { $neg = $true; $exp = $Matches[1] }
        elseif ($e -match '==\s*(.+)$') { $exp = $Matches[1] }
        elseif ($e -match '^not\s') { $neg = $true }
        $out.Add([pscustomobject]@{ Pos = $m.Index; Neg = $neg; Text = (Expand-Constants $exp $Consts) })
    }
    return @($out | Sort-Object Pos)
}

function Remove-CodeComments([string]$Text) {
    $t = [regex]::Replace($Text, '(?s)/\*.*?\*/', '')
    $t = [regex]::Replace($t, '(?m)^[ \t]*(//|#(?!!)).*$', '')
    return $t
}

function Get-AcceptanceBlocks([string]$Root, $Config) {
    # 受け入れテストの範囲: [AT] と [REQ-…] を含む行から、次の [AT] の行の前まで。戻り値: @{ File; Line; Reqs; Body; Consts } の列
    $idre = Get-IdRegex $Config
    $globs = @($Config.acceptance.files | Where-Object { $_ })
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in @(Select-ByGlobs (Get-TrackedFiles $Root) $globs)) {
        $full = Join-DevflowPath $Root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $raw = Read-Utf8 $full
        $consts = Get-FileConstants $raw
        $lines = $raw -split "`r?`n"
        $starts = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '\[AT\]' -and $lines[$i] -match '\[REQ-') { $i } })
        for ($k = 0; $k -lt $starts.Count; $k++) {
            $s = $starts[$k]; $e = if ($k + 1 -lt $starts.Count) { $starts[$k + 1] - 1 } else { $lines.Count - 1 }
            $head = $lines[$s]
            $reqs = @([regex]::Matches($head, '\[(REQ-[^\]]+)\]') | ForEach-Object { $_.Groups[1].Value } | Where-Object { Test-IsId $_ $idre })
            # 名前の文字列は期待値ではないので、範囲の 1 行目から名前の部分 ('…[AT]…' の文字列) を除く
            $head2 = [regex]::Replace($head, '([''"`])[^''"`]*\[AT\][^''"`]*\1', '""')
            $body = Remove-CodeComments ((@($head2) + @($lines[($s + 1)..$e])) -join "`n")
            $out.Add([pscustomobject]@{ File = $rel; Line = $s + 1; Reqs = $reqs; Body = $body; Consts = $consts })
        }
    }
    return $out
}

function Test-AcceptanceExamples([string]$Root, $Config, $Examples, [string[]]$OnlyReqs = @()) {
    # 承認した例の値が、受け入れテストの期待値側にあるかを見る。戻り値: @{ code; id; message; where } の列
    # REQ-NO-ACCEPTANCE: 印のある test の REQ に [AT][REQ-…] のテストがない / EXAMPLE-NOT-IN-AT: 印の値が期待値側にない /
    # EXAMPLE-ORDER: 順序の宣言どおりに並んでいない
    $out = [System.Collections.Generic.List[object]]::new()
    $blocks = @(Get-AcceptanceBlocks $Root $Config)
    foreach ($e in $Examples.Values) {
        if ($e.Verify -ne 'test' -or $e.Marks.Count -eq 0) { continue }
        if ($OnlyReqs.Count -gt 0 -and $OnlyReqs -notcontains $e.Id) { continue }
        $mine = @($blocks | Where-Object { $_.Reqs -contains $e.Id })
        if ($mine.Count -eq 0) {
            $out.Add([pscustomobject]@{ code = 'REQ-NO-ACCEPTANCE'; id = $e.Id; message = "受け入れ例のある要件に [AT][$($e.Id)] の受け入れテストがありません ($(@($Config.acceptance.files) -join ', '))"; where = $e.Where }); continue
        }
        $asserts = @(foreach ($b in $mine) { foreach ($a in Get-Assertions $b.Body $b.Consts) { $a | Add-Member -NotePropertyName File -NotePropertyValue $b.File -PassThru -Force } })
        $where = ($mine | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', '
        foreach ($mk in $e.Marks) {
            $hit = @($asserts | Where-Object { $_.Neg -eq $mk.Neg -and $_.Text.Contains($mk.Value) })
            if ($hit.Count -eq 0) {
                $kind = if ($mk.Neg) { '否定のアサーション (.not. / assertNot… / Assert.NotEqual など)' } else { 'アサーションの期待値側' }
                $out.Add([pscustomobject]@{ code = 'EXAMPLE-NOT-IN-AT'; id = $e.Id; message = "例の値 ``$(if ($mk.Neg) { '!' })$($mk.Value)`` が受け入れテストの$kind にありません"; where = $where })
            }
        }
        foreach ($ord in $e.Orders) {
            $pos = @($asserts | Where-Object { -not $_.Neg })
            $inOne = @($pos | Where-Object {
                $t = $_.Text; $ok = $true; $last = -1
                foreach ($v in $ord) { $i = $t.IndexOf($v, $last + 1); if ($i -lt 0) { $ok = $false; break }; $last = $i }
                $ok })
            if ($inOne.Count -gt 0) { continue }
            # 1 つのアサーションの中で確かめていなければ、各値の最後の出現の順で確かめる
            $lastIdx = @(foreach ($v in $ord) { $k = -1; for ($j = 0; $j -lt $pos.Count; $j++) { if ($pos[$j].Text.Contains($v)) { $k = $j } }; $k })
            $ok = ($lastIdx -notcontains -1)
            for ($j = 1; $ok -and $j -lt $lastIdx.Count; $j++) { if ($lastIdx[$j] -le $lastIdx[$j - 1]) { $ok = $false } }
            if (-not $ok) {
                $out.Add([pscustomobject]@{ code = 'EXAMPLE-ORDER'; id = $e.Id; message = "並び順 $(($ord | ForEach-Object { '`' + $_ + '`' }) -join ' → ') を確かめるアサーションがありません"; where = $where })
            }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# 覆しの影響 (impact) と補償タスク
# ---------------------------------------------------------------------------

function Get-DecImpact([string]$Root, $Config, $Row, $DocLines = $null, $DefIdx = $null) {
    # DEC を引用する行と、照合 (今の照合と旧照合) に当たる行を docs/ の全行から集め、担当タスクを列挙する。読み取りのみ
    if ($null -eq $DocLines) { $DocLines = @(Get-DocScanLines $Root) }
    if ($null -eq $DefIdx) { $DefIdx = Get-IdDefinitionIndex $Root $Config }
    $pats = @(@($Row.Match) + @($Row.OldMatches) | Where-Object { $_ -and (Test-RegexValid $_) } | ForEach-Object { [regex]::new($_) })
    $cites = [System.Collections.Generic.List[object]]::new(); $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($ln in $DocLines) {
        if (Test-LineExcludesDec $ln.Text $Row.Dec) { continue }
        if (Test-LineCitesDec $ln.Text $Row.Dec) { $cites.Add($ln) }
        elseif (@($pats | Where-Object { $_.IsMatch($ln.Text) }).Count -gt 0) { $hits.Add($ln) }
    }
    $ids = [System.Collections.Generic.List[string]]::new()
    $taskSet = [ordered]@{}
    $tasks = @(Read-TaskIndex $Root $Config)
    foreach ($ln in @($cites) + @($hits)) {
        $k = "$($ln.File):$($ln.No)"
        if ($DefIdx.ByLine.ContainsKey($k) -and -not $ids.Contains($DefIdx.ByLine[$k])) { $ids.Add($DefIdx.ByLine[$k]) }
        if ($ln.File -like 'docs/04-detailed-design/tasks/*' -and $ln.File -notlike '*/index.md') {
            $tid = [System.IO.Path]::GetFileNameWithoutExtension($ln.File); $taskSet[$tid] = $true
        }
    }
    foreach ($t in $tasks) {
        $as = @(Get-TaskAssignedIds $Root $Config $t.Id)
        if (@($as | Where-Object { $ids.Contains($_) }).Count -gt 0) { $taskSet[$t.Id] = $true }
    }
    $taskObjs = @($tasks | Where-Object { $taskSet.Contains($_.Id) })
    return [pscustomobject]@{ Cites = @($cites); Hits = @($hits); Ids = @($ids); Tasks = $taskObjs }
}

function Test-SensitiveDecision([string]$Root, $Config, [string]$Text, [string]$TaskId) {
    # 処置 C の判断が、お金・権限・個人情報などに関わるか (決定の本文、担当タスクの担当 ID の定義行とその上流の定義行を見る)
    $words = @($Config.ledger.sensitiveWords | Where-Object { $_ })
    $buf = [System.Text.StringBuilder]::new($Text)
    if ($TaskId) {
        $idx = Get-IdDefinitionIndex $Root $Config
        foreach ($a in @(Get-TaskAssignedIds $Root $Config $TaskId)) {
            if (-not $idx.ById.ContainsKey($a)) { continue }
            [void]$buf.AppendLine($idx.ById[$a].Text)
            foreach ($u in $idx.ById[$a].Upstream) { if ($idx.ById.ContainsKey($u)) { [void]$buf.AppendLine($idx.ById[$u].Text) } }
        }
    }
    $s = $buf.ToString()
    return @($words | Where-Object { $s.Contains([string]$_) })
}

Export-ModuleMember -Function *
