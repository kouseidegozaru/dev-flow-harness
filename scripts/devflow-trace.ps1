<#
.SYNOPSIS
  ID の網羅性を機械的に検証し、docs/traceability.md を生成する。

.DESCRIPTION
  ID の書式と検査内容は .claude/skills/dev-flow/references/traceability.md を参照。

  -Mode docs   : ドキュメントの書式だけ (重複・検証方法・未定義参照・上流の記載)。要件定義・基本設計の終了時に使う。
                 要件の被覆・タスク割当の不足は警告として表示するが、終了コードには含めない
  -Mode design : 設計の整合 (要件の被覆、タスク割当、未定義参照、タスク定義の整合)
  -Mode full   : design に加えて、全タスク完了・テストの存在と成功・スタブ残り (既定)
  -Mode task   : -Task で指定した 1 タスクの完了判定 (担当 ID のテスト成功、スタブなし)

  終了コード: 0 = 漏れなし / 1 = 漏れあり / 2 = 設定・実行エラー

.EXAMPLE
  pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode design -UpdateIndexes
  pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode full
  pwsh -NoProfile -File scripts/devflow-trace.ps1 -Mode task -Task TASK-004
#>
param(
    [ValidateSet('docs', 'design', 'full', 'task')][string]$Mode = 'full',
    [string]$Task = '',
    [switch]$NoRun,          # テストを実行せず、既存の結果ファイルを使う
    [switch]$UpdateIndexes,  # 各 index.md と同じ場所の ids.md (ID 一覧) を生成し、index.md に ids.md へのリンクを置く
    [switch]$NoReport        # docs/traceability.md を書き出さない
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'devflow-lib.psm1') -Force
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

$root = Get-DevflowRoot
$config = Get-DevflowConfig $root
$idre = Get-IdRegex $config
$docsRoot = Join-DevflowPath $root 'docs'
$generated = @('docs/traceability.md', 'docs/verification-report.md')

if ($Mode -eq 'task' -and -not $Task) { Write-Error '-Mode task には -Task <TASK-ID> が必要です'; exit 2 }

$issues = [System.Collections.Generic.List[object]]::new()
function Add-Issue([string]$Code, [string]$Id, [string]$Message, [string]$Where = '') {
    $issues.Add([pscustomobject]@{ code = $Code; id = $Id; message = $Message; where = $Where })
}

function Get-Layer([string]$Rel) {
    if ($Rel -like 'docs/02-requirements/*') { return 'requirement' }
    if ($Rel -like 'docs/03-basic-design/*') { return 'basic' }
    if ($Rel -like 'docs/04-detailed-design/tasks/*') { return 'task' }
    if ($Rel -like 'docs/04-detailed-design/*') { return 'detailed' }
    return $null
}

# ---------------------------------------------------------------------------
# 1. 設計ドキュメントから ID 定義と参照を集める
# ---------------------------------------------------------------------------
$allFiles = Get-TrackedFiles $root
$docFiles = @($allFiles | Where-Object { $_ -like 'docs/*.md' -and $generated -notcontains $_ })

$defs = [ordered]@{}
$refs = [System.Collections.Generic.List[object]]::new()   # @{ id; file; line }

foreach ($rel in $docFiles) {
    $full = Join-DevflowPath $root $rel
    $layer = Get-Layer $rel
    # 参照 (フェンスコードブロックと自動生成ブロックは Get-MdLines が除く)
    foreach ($ln in Get-MdLines $full) {
        foreach ($id in Get-IdsInText $ln.Text $idre) { $refs.Add([pscustomobject]@{ id = $id; file = $rel; line = $ln.No }) }
    }

    if (-not $layer -or $layer -eq 'task') { continue }

    # 定義: 見出しに ID と 検証 を持つ表の各行
    foreach ($tb in Get-MdTables $full) {
        $ci = Get-ColumnIndex $tb.Headers @('ID')
        $cv = Get-ColumnIndex $tb.Headers @('検証', 'Verify')
        if ($ci -lt 0 -or $cv -lt 0) { continue }
        $cu = Get-ColumnIndex $tb.Headers @('上流', 'Trace')
        foreach ($r in $tb.Rows) {
            if ($r.Cells.Count -le $ci) { continue }
            $id = ConvertTo-PlainCell $r.Cells[$ci]
            if (-not (Test-IsId $id $idre)) { continue }
            $where = "${rel}:$($r.No)"
            if ($defs.Contains($id)) { Add-Issue 'DUPLICATE-ID' $id "ID が重複定義されています (先の定義: $($defs[$id].where))" $where; continue }
            $verify = if ($cv -lt $r.Cells.Count) { (ConvertTo-PlainCell $r.Cells[$cv]).ToLowerInvariant() } else { '' }
            $up = if ($cu -ge 0 -and $cu -lt $r.Cells.Count) { @(Get-IdsInText (ConvertTo-PlainCell $r.Cells[$cu]) $idre) } else { @() }
            $sumIdx = 0..($tb.Headers.Count - 1) | Where-Object { $_ -notin @($ci, $cv, $cu) } | Select-Object -First 1
            $summary = if ($null -ne $sumIdx -and $sumIdx -lt $r.Cells.Count) { ConvertTo-PlainCell $r.Cells[$sumIdx] } else { '' }
            if ($summary.Length -gt 80) { $summary = $summary.Substring(0, 79) + '…' }
            $defs[$id] = [pscustomobject]@{
                id = $id; layer = $layer; file = $rel; where = $where; verify = $verify
                upstream = $up; summary = $summary
                downstream = [System.Collections.Generic.List[string]]::new()
                tasks = [System.Collections.Generic.List[string]]::new()
                tests = [System.Collections.Generic.List[object]]::new()
            }
            if ($verify -notin @('test', 'review', 'manual')) {
                Add-Issue 'INVALID-VERIFY' $id "検証方法が test / review / manual のいずれでもありません: '$verify'" $where
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 2. タスク
# ---------------------------------------------------------------------------
$taskIndex = @(Read-TaskIndex $root $config)
$tasks = [ordered]@{}
foreach ($t in $taskIndex) {
    if ($tasks.Contains($t.Id)) { Add-Issue 'DUPLICATE-TASK' $t.Id 'tasks/index.md にタスクが重複しています'; continue }
    $tasks[$t.Id] = [pscustomobject]@{
        id = $t.Id; title = $t.Title; deps = $t.Deps; status = $t.Status
        file = "docs/04-detailed-design/tasks/$($t.Id).md"; assigned = @(); files = @(); testCaseIds = @()
    }
    if ((Get-TaskStatuses) -notcontains $t.Status) { Add-Issue 'INVALID-STATUS' $t.Id "未知の状態: '$($t.Status)'" 'docs/04-detailed-design/tasks/index.md' }
}

$taskFiles = @($docFiles | Where-Object { $_ -like 'docs/04-detailed-design/tasks/*.md' -and $_ -notlike '*/index.md' })
foreach ($rel in $taskFiles) {
    $tid = [System.IO.Path]::GetFileNameWithoutExtension($rel)
    if (-not $tasks.Contains($tid)) { Add-Issue 'TASK-NOT-IN-INDEX' $tid 'タスクファイルがありますが tasks/index.md に載っていません' $rel; continue }
    $full = Join-DevflowPath $root $rel
    $meta = @{}
    foreach ($tb in Get-MdTables $full) {
        if ($tb.Headers.Count -lt 2) { continue }
        foreach ($r in $tb.Rows) {
            if ($r.Cells.Count -ge 2) { $meta[(ConvertTo-PlainCell $r.Cells[0])] = ConvertTo-PlainCell $r.Cells[1] }
        }
    }
    $t = $tasks[$tid]
    $t.assigned = @(Get-IdsInText ([string]$meta['担当ID']) $idre)
    if ($t.assigned.Count -eq 0) { Add-Issue 'TASK-NO-ASSIGNED' $tid 'タスクファイルに「担当ID」がありません' $rel }
    $fileDeps = @(Get-IdsInText ([string]$meta['依存']) $idre)
    $d1 = ($fileDeps | Sort-Object) -join ','
    $d2 = ($t.deps | Sort-Object) -join ','
    if ($d1 -ne $d2) { Add-Issue 'TASK-DEPS-MISMATCH' $tid "依存がタスクファイル ($d1) と index.md ($d2) で異なります" $rel }
    $filesSection = Get-MdSection $full '作成・変更するファイル'
    $t.files = @([regex]::Matches($filesSection, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ -match '[/.]' })
    $t.testCaseIds = @(Get-IdsInText (Get-MdSection $full 'テストケース') $idre)
}
foreach ($t in $tasks.Values) {
    if ($taskFiles -notcontains $t.file) { Add-Issue 'TASK-FILE-MISSING' $t.id "タスクファイル $($t.file) がありません" }
    foreach ($d in $t.deps) { if (-not $tasks.Contains($d)) { Add-Issue 'UNKNOWN-DEP' $t.id "依存タスク $d が存在しません" } }
    foreach ($a in $t.assigned) {
        if ($defs.Contains($a)) { $defs[$a].tasks.Add($t.id) }
        else { Add-Issue 'UNKNOWN-ASSIGNED' $t.id "担当ID $a が定義されていません" $t.file }
    }
    foreach ($a in $t.assigned) {
        if ($defs.Contains($a) -and $defs[$a].verify -eq 'test' -and $t.testCaseIds -notcontains $a) {
            Add-Issue 'TASK-NO-TESTCASE' $t.id "担当ID $a (test) のテストケースがタスクファイルの「テストケース」節にありません" $t.file
        }
    }
}

# 依存の循環
$visiting = @{}; $visited = @{}
function Test-Cycle([string]$Id, [string[]]$Path) {
    if ($visited.ContainsKey($Id)) { return }
    if ($visiting.ContainsKey($Id)) { Add-Issue 'DEP-CYCLE' $Id "依存が循環しています: $((@($Path) + $Id) -join ' → ')"; return }
    $visiting[$Id] = $true
    if ($tasks.Contains($Id)) { foreach ($d in $tasks[$Id].deps) { Test-Cycle $d (@($Path) + $Id) } }
    $visiting.Remove($Id); $visited[$Id] = $true
}
foreach ($id in @($tasks.Keys)) { Test-Cycle $id @() }

# ---------------------------------------------------------------------------
# 3. 設計の整合チェック
# ---------------------------------------------------------------------------
$known = @{}
foreach ($k in $defs.Keys) { $known[$k] = $true }
foreach ($k in $tasks.Keys) { $known[$k] = $true }

foreach ($r in $refs) {
    if (-not $known.ContainsKey($r.id)) { Add-Issue 'UNKNOWN-REF' $r.id '定義されていない ID を参照しています' "$($r.file):$($r.line)" }
}

foreach ($d in $defs.Values) {
    foreach ($u in $d.upstream) {
        # 未定義の上流 ID は、本文の参照チェック (UNKNOWN-REF) で検出済み
        if ($defs.Contains($u)) { $defs[$u].downstream.Add($d.id) }
    }
}
foreach ($d in $defs.Values) {
    switch ($d.layer) {
        'requirement' {
            $cov = @($d.downstream | Where-Object { $defs[$_].layer -in @('basic', 'detailed') })
            if ($cov.Count -eq 0) { Add-Issue 'REQ-NOT-COVERED' $d.id '基本設計・詳細設計のどの ID からも参照されていません' $d.where }
        }
        'basic' {
            if (@($d.upstream | Where-Object { $defs.Contains($_) -and $defs[$_].layer -eq 'requirement' }).Count -eq 0) {
                Add-Issue 'NO-UPSTREAM' $d.id '「上流」に要件 ID がありません' $d.where
            }
        }
        'detailed' {
            if (@($d.upstream | Where-Object { $defs.Contains($_) }).Count -eq 0) {
                Add-Issue 'NO-UPSTREAM' $d.id '「上流」に基本設計 ID (または要件 ID) がありません' $d.where
            }
        }
    }
    if ($d.verify -in @('test', 'review') -and $d.tasks.Count -eq 0) {
        Add-Issue 'NOT-ASSIGNED' $d.id "検証方法 $($d.verify) の ID がどのタスクにも割り当てられていません" $d.where
    }
}

# ---------------------------------------------------------------------------
# 4. テスト実行と結果の収集 (full / task)
# ---------------------------------------------------------------------------
$testRun = $null
$testsByName = [System.Collections.Generic.List[object]]::new()

if ($Mode -in @('full', 'task')) {
    if (-not $config.test.command) {
        Add-Issue 'NO-TEST-COMMAND' '' '.devflow/config.json の test.command が未設定です (詳細設計で設定する)'
    } else {
        if (-not $NoRun) {
            $r = Invoke-TestCommand $root $config '.devflow/logs/last-test-run.log'
            $testRun = [pscustomobject]@{ exitCode = $r.ExitCode; timedOut = $r.TimedOut; log = $r.Log }
            if ($r.TimedOut) { Add-Issue 'TESTS-FAILING' '' "テストが test.timeoutSeconds ($($config.test.timeoutSeconds) 秒) 以内に終わりませんでした。ログ: $($r.Log)" }
            elseif ($r.ExitCode -ne 0) { Add-Issue 'TESTS-FAILING' '' "テストコマンドが失敗しました (exit $($r.ExitCode))。ログ: $($r.Log)" }
        }
        foreach ($tr in Read-TestResultFiles $root $config) { $testsByName.Add($tr) }
        if ($testsByName.Count -eq 0) { Add-Issue 'NO-TEST-RESULTS' '' "テスト結果ファイルが見つかりません (test.resultGlobs: $($config.test.resultGlobs -join ', '))" }
    }

    # テスト名に含まれる ID を集計
    foreach ($tr in $testsByName) {
        foreach ($id in Get-IdsInText $tr.name $idre) {
            if ($defs.Contains($id)) { $defs[$id].tests.Add($tr) }
            elseif (-not $known.ContainsKey($id)) { Add-Issue 'UNKNOWN-REF' $id "テスト名が定義されていない ID を含んでいます: $($tr.name)" $tr.file }
        }
    }
    # テストコード中の ID (タイプミス検出用)
    $testFiles = Select-ByGlobs $allFiles $config.test.files
    foreach ($rel in $testFiles) {
        $text = Read-Utf8 (Join-DevflowPath $root $rel)
        foreach ($id in Get-IdsInText $text $idre) {
            if (-not $known.ContainsKey($id)) { Add-Issue 'UNKNOWN-REF' $id 'テストコードが定義されていない ID を含んでいます' $rel }
        }
    }
}

function Test-IdTests($d) {
    if ($d.verify -ne 'test') { return }
    if ($d.tests.Count -eq 0) { Add-Issue 'NO-TEST' $d.id 'ID を名前に含むテストがありません' $d.where; return }
    $bad = @($d.tests | Where-Object { $_.outcome -ne 'passed' })
    if ($bad.Count -gt 0) { Add-Issue 'TEST-NOT-PASSING' $d.id "ID を含むテストが成功していません: $(($bad | ForEach-Object { "$($_.name) [$($_.outcome)]" }) -join '; ')" $d.where }
}

function Find-Stubs([string[]]$Files) {
    $pat = [regex]::new((($config.stubPatterns | ForEach-Object { "(?:$_)" }) -join '|'), 'IgnoreCase')
    foreach ($rel in $Files) {
        $full = Join-DevflowPath $root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $n = 0
        foreach ($l in (Read-Utf8 $full) -split "`r?`n") {
            $n++
            if ($pat.IsMatch($l)) { Add-Issue 'STUB-LEFT' '' "TODO・スタブ・未実装が残っています: $($l.Trim())" "${rel}:$n" }
        }
    }
}

if ($Mode -eq 'full') {
    foreach ($t in $tasks.Values) {
        if ($t.status -ne 'done') { Add-Issue 'TASK-NOT-DONE' $t.id "タスクが完了していません (状態: $($t.status))" $t.file }
    }
    foreach ($d in $defs.Values) { Test-IdTests $d }
    Find-Stubs (Select-ByGlobs $allFiles $config.source.files)
}

if ($Mode -eq 'task') {
    # タスク単体の完了判定: 設計全体の漏れは見ず、このタスクに関する項目だけを残す
    if (-not $tasks.Contains($Task)) { Write-Error "タスク $Task が tasks/index.md にありません"; exit 2 }
    $t = $tasks[$Task]
    $keep = @($issues | Where-Object { $_.id -eq $Task -or $_.code -in @('TESTS-FAILING', 'NO-TEST-COMMAND', 'NO-TEST-RESULTS') -or ($_.code -eq 'UNKNOWN-REF' -and $_.where -notlike 'docs/*') })
    $issues.Clear(); foreach ($i in $keep) { $issues.Add($i) }
    foreach ($a in $t.assigned) { if ($defs.Contains($a)) { Test-IdTests $defs[$a] } }
    $existing = @($t.files | Where-Object { Test-Path -LiteralPath (Join-DevflowPath $root $_) -PathType Leaf })
    foreach ($f in @($t.files | Where-Object { $existing -notcontains $_ })) { Add-Issue 'FILE-MISSING' $Task "タスクで作成するファイルがありません: $f" $t.file }
    Find-Stubs $existing
}

# ---------------------------------------------------------------------------
# 5. ID 一覧 (index.md と同じディレクトリの ids.md)
#    index.md は各フェーズで最初に読まれるため、大きな ID 一覧は ids.md に分けて index.md を小さく保つ
# ---------------------------------------------------------------------------
if ($UpdateIndexes) {
    $indexFiles = @($docFiles | Where-Object { [System.IO.Path]::GetFileName($_) -eq 'index.md' -and (Get-Layer $_) -in @('requirement', 'basic', 'detailed') })
    # ID は、定義ファイルから見て最も近い上位ディレクトリの index.md に載せる
    function Get-OwnerIndex([string]$Dir) {
        $d = $Dir
        while ($d -and $d -ne 'docs') {
            if ($indexFiles -contains "$d/index.md") { return "$d/index.md" }
            $d = [System.IO.Path]::GetDirectoryName($d).Replace('\', '/')
        }
        return $null
    }
    foreach ($ix in $indexFiles) {
        $dir = [System.IO.Path]::GetDirectoryName($ix).Replace('\', '/')
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('<!-- devflow:ids:begin -->')
        [void]$sb.AppendLine('<!-- このブロックは scripts/devflow-trace.ps1 -UpdateIndexes が生成する。手で編集しない -->')
        [void]$sb.AppendLine('')
        $own = @($defs.Values | Where-Object { (Get-OwnerIndex ([System.IO.Path]::GetDirectoryName($_.file).Replace('\', '/'))) -eq $ix })
        $subIdx = @($indexFiles | Where-Object { $_ -ne $ix -and (Get-OwnerIndex ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($_)).Replace('\', '/'))) -eq $ix })
        if ($own.Count -gt 0) {
            [void]$sb.AppendLine('| ID | 検証 | 定義ファイル | 要約 |')
            [void]$sb.AppendLine('|----|------|--------------|------|')
            foreach ($d in $own) {
                $fileRel = [System.IO.Path]::GetRelativePath($dir, $d.file).Replace('\', '/')
                [void]$sb.AppendLine("| $($d.id) | $($d.verify) | [$fileRel]($fileRel) | $($d.summary.Replace('|', '\|')) |")
            }
        } else {
            [void]$sb.AppendLine('(この index の担当範囲で定義された ID はない)')
        }
        foreach ($s in $subIdx) {
            $sdir = [System.IO.Path]::GetDirectoryName($s).Replace('\', '/')
            $n = @($defs.Values | Where-Object { $_.file -like "$sdir/*" }).Count
            $srel = [System.IO.Path]::GetRelativePath($dir, "$sdir/ids.md").Replace('\', '/')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("- 下位: [$srel]($srel) ($n 件)")
        }
        [void]$sb.Append('<!-- devflow:ids:end -->')
        $block = $sb.ToString().Replace("`r`n", "`n")
        $idsRel = "$dir/ids.md"
        Write-Utf8 (Join-DevflowPath $root $idsRel) ("# ID 一覧 (自動生成)`n`n> 目次: [index.md](index.md)`n`n" + $block + "`n")
        # index.md には ids.md へのリンクだけを置く (以前の版で index.md に書いた ID 一覧のブロックは取り除く)
        $full = Join-DevflowPath $root $ix
        $text = Read-Utf8 $full
        $link = '<!-- devflow:ids-link --> ID 一覧 (自動生成): [ids.md](ids.md)'
        $text = [regex]::Replace($text, '(?s)(\n## ID 一覧 \(自動生成\)\s*\n)?\s*<!-- devflow:ids:begin -->.*?<!-- devflow:ids:end -->\s*', "`n")
        if ($text -match '<!-- devflow:ids-link -->[^\n]*') { $text = [regex]::Replace($text, '<!-- devflow:ids-link -->[^\n]*', $link) }
        else { $text = $text.TrimEnd() + "`n`n" + $link }
        Write-Utf8 $full ($text.TrimEnd() + "`n")
    }
}

# ---------------------------------------------------------------------------
# 6. 出力
# ---------------------------------------------------------------------------
$warnings = [System.Collections.Generic.List[object]]::new()
if ($Mode -eq 'docs') {
    # 後続フェーズで解消する種別は警告に回す
    $later = @('REQ-NOT-COVERED', 'NOT-ASSIGNED')
    $keep = @($issues | Where-Object { $_.code -notin $later -and $_.code -notlike 'TASK-*' })
    foreach ($i in @($issues | Where-Object { $keep -notcontains $_ })) { $warnings.Add($i) }
    $issues.Clear(); foreach ($i in $keep) { $issues.Add($i) }
}
$byCode = $issues | Group-Object code | Sort-Object Name
$summary = [ordered]@{
    mode      = $Mode
    task      = $Task
    ok        = ($issues.Count -eq 0)
    ids       = [ordered]@{
        total       = $defs.Count
        requirement = @($defs.Values | Where-Object { $_.layer -eq 'requirement' }).Count
        basic       = @($defs.Values | Where-Object { $_.layer -eq 'basic' }).Count
        detailed    = @($defs.Values | Where-Object { $_.layer -eq 'detailed' }).Count
        test        = @($defs.Values | Where-Object { $_.verify -eq 'test' }).Count
        review      = @($defs.Values | Where-Object { $_.verify -eq 'review' }).Count
        manual      = @($defs.Values | Where-Object { $_.verify -eq 'manual' }).Count
    }
    tasks     = [ordered]@{
        total   = $tasks.Count
        done    = @($tasks.Values | Where-Object { $_.status -eq 'done' }).Count
        blocked = @($tasks.Values | Where-Object { $_.status -eq 'blocked' }).Count
    }
    testRun   = $testRun
    issues    = @($issues)
    warnings  = @($warnings)
    review    = @($defs.Values | Where-Object { $_.verify -eq 'review' } | ForEach-Object { [ordered]@{ id = $_.id; summary = $_.summary; tasks = @($_.tasks); where = $_.where } })
    manual    = @($defs.Values | Where-Object { $_.verify -eq 'manual' } | ForEach-Object { [ordered]@{ id = $_.id; summary = $_.summary; where = $_.where } })
    at        = (Get-Date).ToString('o')
}
$resultName = if ($Mode -eq 'task') { "trace-$Task.json" } else { 'trace-result.json' }
Write-Utf8 (Join-DevflowPath $root ".devflow/$resultName") (($summary | ConvertTo-Json -Depth 8) + "`n")

if ($Mode -ne 'task' -and -not $NoReport -and (Test-Path -LiteralPath $docsRoot)) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# トレーサビリティ表')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("> このファイルは ``scripts/devflow-trace.ps1 -Mode $Mode`` が生成する。手で編集しない。")
    [void]$sb.AppendLine("> 生成日時: $($summary.at) / 判定: $(if ($summary.ok) { '**漏れなし**' } else { "**漏れあり ($($issues.Count) 件)**" })")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 集計')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| 項目 | 件数 |')
    [void]$sb.AppendLine('|------|------|')
    [void]$sb.AppendLine("| 要件 ID | $($summary.ids.requirement) |")
    [void]$sb.AppendLine("| 基本設計 ID | $($summary.ids.basic) |")
    [void]$sb.AppendLine("| 詳細設計 ID | $($summary.ids.detailed) |")
    [void]$sb.AppendLine("| 検証方法 test / review / manual | $($summary.ids.test) / $($summary.ids.review) / $($summary.ids.manual) |")
    [void]$sb.AppendLine("| タスク (完了 / blocked / 全体) | $($summary.tasks.done) / $($summary.tasks.blocked) / $($summary.tasks.total) |")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 検出された漏れ')
    [void]$sb.AppendLine('')
    if ($issues.Count -eq 0) { [void]$sb.AppendLine('なし') }
    else {
        [void]$sb.AppendLine('| 種別 | ID | 内容 | 場所 |')
        [void]$sb.AppendLine('|------|----|------|------|')
        foreach ($i in $issues) { [void]$sb.AppendLine("| $($i.code) | $($i.id) | $($i.message.Replace('|', '\|')) | $($i.where) |") }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 要件 → 設計 → タスク → テスト')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| 要件 ID | 検証 | 設計 ID | タスク | テスト (成功/全体) |')
    [void]$sb.AppendLine('|---------|------|---------|--------|--------------------|')
    function Get-DescTasks($id) {
        $set = [System.Collections.Generic.HashSet[string]]::new()
        $queue = [System.Collections.Generic.Queue[string]]::new(); $queue.Enqueue($id)
        $seen = @{}
        while ($queue.Count -gt 0) {
            $x = $queue.Dequeue(); if ($seen[$x]) { continue }; $seen[$x] = $true
            foreach ($tk in $defs[$x].tasks) { [void]$set.Add($tk) }
            foreach ($dn in $defs[$x].downstream) { $queue.Enqueue($dn) }
        }
        return @($set | Sort-Object)
    }
    foreach ($d in @($defs.Values | Where-Object { $_.layer -eq 'requirement' })) {
        $pass = @($d.tests | Where-Object { $_.outcome -eq 'passed' }).Count
        $tests = if ($d.verify -eq 'test') { "$pass/$($d.tests.Count)" } else { '-' }
        [void]$sb.AppendLine("| $($d.id) | $($d.verify) | $(($d.downstream | Sort-Object) -join ', ') | $((Get-DescTasks $d.id) -join ', ') | $tests |")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 設計 ID')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| 設計 ID | 層 | 検証 | 上流 | タスク | テスト (成功/全体) | 定義 |')
    [void]$sb.AppendLine('|---------|----|------|------|--------|--------------------|------|')
    foreach ($d in @($defs.Values | Where-Object { $_.layer -ne 'requirement' })) {
        $pass = @($d.tests | Where-Object { $_.outcome -eq 'passed' }).Count
        $tests = if ($d.verify -eq 'test') { "$pass/$($d.tests.Count)" } else { '-' }
        $layerJa = if ($d.layer -eq 'basic') { '基本' } else { '詳細' }
        [void]$sb.AppendLine("| $($d.id) | $layerJa | $($d.verify) | $($d.upstream -join ', ') | $(($d.tasks | Sort-Object) -join ', ') | $tests | $($d.where) |")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 人が確認する項目: review (実装時に tdd-implementer が自己確認済み)')
    [void]$sb.AppendLine('')
    if ($summary.review.Count -eq 0) { [void]$sb.AppendLine('なし') }
    else { foreach ($m in $summary.review) { [void]$sb.AppendLine("- $($m.id): $($m.summary) ($($m.where)) 担当: $(($m.tasks | Sort-Object) -join ', ')") } }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## 手動確認が必要な項目 (manual)')
    [void]$sb.AppendLine('')
    if ($summary.manual.Count -eq 0) { [void]$sb.AppendLine('なし') }
    else { foreach ($m in $summary.manual) { [void]$sb.AppendLine("- $($m.id): $($m.summary) ($($m.where))") } }
    Write-Utf8 (Join-DevflowPath $root 'docs/traceability.md') $sb.ToString().Replace("`r`n", "`n")
}

# コンソール出力 (エージェントが読む)
if ($warnings.Count -gt 0) {
    Write-Output "警告 (後続フェーズで解消する): $($warnings.Count) 件"
    foreach ($g in ($warnings | Group-Object code | Sort-Object Name)) {
        Write-Output "  [$($g.Name)] $($g.Count) 件: $((($g.Group | Select-Object -First 15) | ForEach-Object { $_.id }) -join ', ')$(if ($g.Count -gt 15) { ' …' })"
    }
}
if ($issues.Count -eq 0) {
    Write-Output "devflow-trace ($Mode$(if ($Task) { " $Task" })): OK — 漏れなし (ID $($defs.Count) 件, タスク $($tasks.Count) 件)"
    exit 0
}
Write-Output "devflow-trace ($Mode$(if ($Task) { " $Task" })): NG — $($issues.Count) 件"
foreach ($g in $byCode) {
    Write-Output "[$($g.Name)] $($g.Count) 件"
    foreach ($i in ($g.Group | Select-Object -First 30)) {
        $owner = if ($i.id -and $defs.Contains($i.id) -and @($defs[$i.id].tasks).Count -gt 0) { " 担当: $((@($defs[$i.id].tasks) | Sort-Object) -join ', ')" } else { '' }
        Write-Output "  - $($i.id) $($i.message) $(if ($i.where) { "($($i.where))" })$owner"
    }
    if ($g.Count -gt 30) { Write-Output "  … ほか $($g.Count - 30) 件 (.devflow/$resultName を参照)" }
}
exit 1
