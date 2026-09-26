# devflow 共通ライブラリ (PowerShell 7+)
#
# state.json / config.json の読み書き、Markdown 表の解析、ID の抽出、
# ファイル列挙、コンテキスト使用率の計算をまとめる。
# hooks と scripts の両方から Import-Module で読み込む。

Set-StrictMode -Version 3.0

$script:PhaseOrder = @(
    'vision', 'requirements', 'basic-design', 'detailed-design',
    'implementation', 'verification', 'done'
)
$script:PhaseFiles = @{
    'vision'          = '01-vision.md'
    'requirements'    = '02-requirements.md'
    'basic-design'    = '03-basic-design.md'
    'detailed-design' = '04-detailed-design.md'
    'implementation'  = '05-implementation.md'
    'verification'    = '06-verification.md'
}
$script:PhaseLabels = @{
    'vision'          = '企画・構想'
    'requirements'    = '要件定義'
    'basic-design'    = '基本設計'
    'detailed-design' = '詳細設計'
    'implementation'  = '実装'
    'verification'    = '検証'
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
        contextThresholdPercent = 50
        minSessionWorkTokens    = 40000
        hardLimitPercent        = 65
        maxVerificationRounds   = 3
        maxAttemptsPerTest      = 3
        idPrefixes              = @('REQ', 'NFR', 'ARC', 'SCR', 'TRN', 'API', 'ERR', 'EXT', 'DM',
                                    'MOD', 'IF', 'VAL', 'EC', 'DBC', 'BR', 'TASK')
        test                    = [ordered]@{
            command        = ''
            timeoutSeconds = 900
            resultGlobs    = @('**/TestResults/*.trx', '**/junit*.xml', '**/test-results/**/*.xml')
            files       = @('tests/**', 'test/**', '**/*.test.*', '**/*_test.*', '**/*Tests.cs', '**/test_*.py')
        }
        source                  = [ordered]@{
            files = @('src/**')
        }
        # コメント中の TODO/FIXME/XXX だけを大文字小文字を区別して拾う (識別子の Todo などに反応しないため)
        stubPatterns            = @(
            '(?-i)(//|#|/\*|--|<!--|\*)\s*(TODO|FIXME|XXX)\b', 'NotImplementedException', 'NotImplementedError',
            'raise NotImplemented', 'unimplemented!\(', '(?-i)\btodo!\(', 'not implemented'
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

function Invoke-TestCommand([string]$Root, $Config, [string]$LogRel) {
    # 結果ファイルを消してから test.command を実行する。test.timeoutSeconds を超えたらプロセスツリーごと止める。
    # 戻り値: @{ ExitCode; TimedOut; Log (ルートからの相対パス) }
    foreach ($rel in Find-FilesOnDisk $Root $Config.test.resultGlobs) { Remove-Item -LiteralPath (Join-DevflowPath $Root $rel) -Force }
    $log = Join-DevflowPath $Root $LogRel
    New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
    $err = "$log.stderr"
    $cmd = "`$PSStyle.OutputRendering = 'PlainText'`n" + [string]$Config.test.command
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $p = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', $enc) `
        -WorkingDirectory $Root -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError $err
    $null = $p.Handle   # ExitCode を確実に取れるようにする
    $sec = [int]$Config.test.timeoutSeconds
    $timedOut = $false
    if ($sec -gt 0) {
        if (-not $p.WaitForExit($sec * 1000)) {
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
    if ($timedOut) { Add-Content -LiteralPath $log -Value "dev-flow: test.timeoutSeconds ($sec 秒) を超えたため停止しました" -Encoding utf8 }
    $code = if ($timedOut) { 124 } else { $p.ExitCode }
    return [pscustomobject]@{ ExitCode = $code; TimedOut = $timedOut; Log = $LogRel }
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
    $hard = if ($Config.Contains('hardLimitPercent') -and $Config.hardLimitPercent) { [double]$Config.hardLimitPercent } else { 65 }
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

function New-ImplementerRun([string]$Root, [string]$AgentId) {
    $run = [ordered]@{ agentId = $AgentId; startedAt = (Get-Date).ToString('o'); baseTokens = $null; blocks = 0; lastFingerprint = '' }
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

Export-ModuleMember -Function *
