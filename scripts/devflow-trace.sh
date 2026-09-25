#!/usr/bin/env bash
# ID の網羅性チェック。本体は devflow-trace.ps1 (PowerShell 7+)。終了コードはそのまま返す。
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec pwsh -NoProfile -File "$here/devflow-trace.ps1" "$@"
