#!/usr/bin/env bash
# PowerShell 7 (pwsh) がなければ入れる。dev-flow のフックとスクリプトは pwsh で動くが、
# クラウドのセッション (claude.ai/code) のコンテナには入っておらず、コンテナが作り直されるたびに消えるため。
#
# 使い方 (どちらか):
#   - 環境のセットアップスクリプトに `bash scripts/devflow-setup-cloud.sh` を書く (セッションの開始前に入るので確実)
#   - 何もしない: SessionStart フック (.claude/hooks/ensure-pwsh.sh) が、クラウドで pwsh がないときにこれを実行する
#
# 環境変数: DEVFLOW_PWSH_VERSION (既定 7.4.6)
set -euo pipefail

if command -v pwsh >/dev/null 2>&1; then
  echo "pwsh は導入済み: $(command -v pwsh)"
  exit 0
fi

ver="${DEVFLOW_PWSH_VERSION:-7.4.6}"
case "$(uname -m)" in
  x86_64 | amd64) arch=x64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "未対応の CPU です: $(uname -m)" >&2; exit 1 ;;
esac

# root なら /opt と /usr/local/bin に、そうでなければホームの下に入れる
if [ -w /usr/local/bin ] && { [ -w /opt ] || mkdir -p /opt/microsoft 2>/dev/null; }; then
  dir="/opt/microsoft/powershell/$ver"
  bin=/usr/local/bin
else
  dir="$HOME/.local/share/powershell/$ver"
  bin="$HOME/.local/bin"
fi
mkdir -p "$dir" "$bin"

url="https://github.com/PowerShell/PowerShell/releases/download/v$ver/powershell-$ver-linux-$arch.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "pwsh $ver を入れます: $url"
curl -fsSL --retry 3 --max-time 300 -o "$tmp/pwsh.tar.gz" "$url"
tar -xzf "$tmp/pwsh.tar.gz" -C "$dir"
chmod +x "$dir/pwsh"

# ICU が無いコンテナでも起動できるよう、無ければ文化情報なしのモードで起動するラッパーを置く
if ldconfig -p 2>/dev/null | grep -q libicu; then
  ln -sf "$dir/pwsh" "$bin/pwsh"
else
  printf '#!/bin/sh\nexport DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1\nexec "%s/pwsh" "$@"\n' "$dir" > "$bin/pwsh"
  chmod +x "$bin/pwsh"
fi

"$bin/pwsh" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' >/dev/null
echo "pwsh を入れました: $bin/pwsh"
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "注意: $bin が PATH にありません。PATH に足してください" >&2 ;;
esac
