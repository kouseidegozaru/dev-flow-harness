#!/usr/bin/env bash
# SessionStart フック (pwsh がない環境用)
#
# dev-flow のフックは pwsh で動くため、pwsh がないと SessionStart の自動再開が働かない。
# - pwsh がある: 何もしない (session-start.ps1 の項目が同時に動いている)
# - クラウドのセッション (CLAUDE_CODE_REMOTE=true) で pwsh がない: scripts/devflow-setup-cloud.sh で入れてから、
#   session-start.ps1 を代わりに実行してその出力を返す (同時に動いた pwsh の項目は、pwsh がなくて失敗しているため)
# - それ以外で pwsh がない: 入れ方を知らせる

input="$(cat)"
command -v pwsh >/dev/null 2>&1 && exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  printf '%s\n' '{"systemMessage":"dev-flow: pwsh (PowerShell 7) が見つからないため、dev-flow のフックが動きません。PowerShell 7 を入れてください (README の「必要なもの」)"}'
  exit 0
fi

if ! bash "$root/scripts/devflow-setup-cloud.sh" >&2; then
  printf '%s\n' '{"systemMessage":"dev-flow: pwsh (PowerShell 7) を入れられませんでした。環境のセットアップスクリプトに `bash scripts/devflow-setup-cloud.sh` を書いてください (README の「クラウドで使う」)"}'
  exit 0
fi
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
hash -r
printf '%s' "$input" | pwsh -NoProfile -File "$root/.claude/hooks/session-start.ps1"
