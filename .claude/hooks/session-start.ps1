# SessionStart フック
#
# - source=clear   : 前フェーズ完了後の /clear。次フェーズの開始指示を注入する
#                    (実装・検証フェーズは、このセッションをオーケストレーターとして開始させる)
# - source=startup : 進行中フェーズを知らせる。実装・検証フェーズが未開始なら (詳細設計の後に起動し直した)、clear と同じく開始させる
# - source=compact : 手順書と決定ツリー (実装・検証なら状態と引き継ぎ) の再読を指示する
# - source=resume  : 会話がそのまま残るので何もしない

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../scripts/devflow-lib.psm1') -Force

$in = Read-StdinJson
$root = Get-DevflowRoot
$state = Read-DevflowState $root
if (-not $state) { exit 0 }

$source = if ($in -and $in.PSObject.Properties['source']) { [string]$in.source } else { 'startup' }
$phase = [string]$state.phase
$label = Get-PhaseLabel $phase
$phaseFile = Get-PhaseFile $phase
$interactivePhases = @('vision', 'requirements', 'basic-design', 'detailed-design')
$autoPhases = @('implementation', 'verification')

function Out-Context([string]$Text) {
    Write-HookJson @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $Text } }
    exit 0
}

switch ($source) {
    'clear' {
        if ($interactivePhases -contains $phase) {
            Out-Context @"
[dev-flow 自動再開]
前フェーズが完了し、コンテキストがクリアされた。現在フェーズ: $phase ($label)。
ユーザーの最初のメッセージが何であっても (「続けて」「ok」、挨拶など)、それを開始の合図とみなし、
直ちに .claude/skills/dev-flow/SKILL.md を読んで、その手順どおりに $label フェーズを開始すること。
前フェーズまでの会話内容は参照せず、docs/ の成果物だけを入力とする。
"@
        }
        if ($autoPhases -contains $phase) {
            Out-Context @"
[dev-flow 自動再開]
コンテキストがクリアされた。現在フェーズ: $phase ($label)。このフェーズはユーザーに質問せず最後まで自動で進める。
ユーザーの最初のメッセージが何であっても、それを開始の合図とみなし、直ちに .claude/skills/dev-flow/SKILL.md を読んで、
このセッションをオーケストレーターとして $label フェーズを開始すること (実装そのものは tdd-implementer サブエージェントが行う)。
"@
        }
        if ($phase -eq 'done') {
            Out-Context '[dev-flow] 全フェーズが完了している。ユーザーには docs/verification-report.md の要点 (漏れ・blocked・人が確認する項目) を案内すること。'
        }
    }
    'startup' {
        if ($interactivePhases -contains $phase) {
            $started = if ($state.phaseStarted) { '途中まで進んでいる' } else { 'まだ始まっていない' }
            Out-Context "[dev-flow] 開発フローが進行中 (現在フェーズ: $label, $started)。ユーザーが続きを望んだら .claude/skills/dev-flow/SKILL.md に従って再開する。"
        }
        if ($autoPhases -contains $phase -and -not $state.phaseStarted) {
            # 詳細設計の終わりに「権限モードを変えて起動し直し、一言送る」と案内している。/clear のときと同じく開始させる
            Out-Context @"
[dev-flow 自動再開]
前フェーズが完了し、Claude Code が起動し直された。現在フェーズ: $phase ($label)。このフェーズはユーザーに質問せず最後まで自動で進める。
ユーザーの最初のメッセージが何であっても (「続けて」「ok」、挨拶など)、それを開始の合図とみなし、直ちに .claude/skills/dev-flow/SKILL.md を読んで、
このセッションをオーケストレーターとして $label フェーズを開始すること (実装そのものは tdd-implementer サブエージェントが行う)。
"@
        }
        if ($autoPhases -contains $phase) {
            Out-Context "[dev-flow] 開発フローが進行中 (現在フェーズ: $label、途中で止まっている)。ユーザーが続きを望んだら .claude/skills/dev-flow/SKILL.md に従い、このセッションをオーケストレーターとして再開する。"
        }
    }
    'compact' {
        if ($interactivePhases -contains $phase) {
            Out-Context @"
[dev-flow] コンテキストが圧縮された。圧縮前の会話の記憶に頼らず、次を読み直してから続けること:
1. .claude/skills/dev-flow/phases/$phaseFile (手順書)
2. .devflow/decisions/$phase.md (決定ツリー: 決定済み / 未決定)
"@
        }
        if ($autoPhases -contains $phase) {
            Out-Context @"
[dev-flow] コンテキストが圧縮された。圧縮前の会話の記憶に頼らず、次を読み直してからオーケストレーターの作業を続けること:
1. .claude/skills/dev-flow/phases/$phaseFile (手順書)
2. ``pwsh -NoProfile -File scripts/devflow-state.ps1 impl-status`` の出力と .devflow/handoff.md
"@
        }
    }
}
exit 0
