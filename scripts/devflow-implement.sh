#!/usr/bin/env bash
# 実装・検証フェーズの自動ループ。本体は devflow-implement.ps1 (PowerShell 7+)。
# 引数はそのまま渡す。例: scripts/devflow-implement.sh -MaxIterations 5
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec pwsh -NoProfile -File "$here/devflow-implement.ps1" "$@"
