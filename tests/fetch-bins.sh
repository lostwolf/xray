#!/bin/bash
# xctl e2e: 下载校验/运行所需二进制到 .e2e/bin (无 root, 不安装系统包)
set -euo pipefail

DEST=${1:-$(cd "$(dirname "$0")/.." && pwd)/.e2e/bin}
mkdir -p "$DEST"
cd "$DEST"
arch=amd64

api() { curl -fsSL -m 30 "https://api.github.com/repos/$1/releases/latest"; }
asset() { # repo regex
    api "$1" | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | grep -E "$2" | head -n1
}

echo "==> xray-core"
[[ -x xray ]] || { curl -fsSL -o xray.zip "$(asset XTLS/Xray-core 'Xray-linux-64\.zip$')"; unzip -oq xray.zip xray && rm -f xray.zip && chmod +x xray; }

echo "==> sing-box"
if [[ ! -x sing-box ]]; then
    url=$(asset SagerNet/sing-box "sing-box-.*-linux-${arch}\.tar\.gz$")
    curl -fsSL -o sb.tgz "$url"
    tar -xzf sb.tgz
    mv -f sing-box-*/sing-box . && rm -rf sb.tgz sing-box-*
    chmod +x sing-box
fi

echo "==> mihomo"
[[ -x mihomo ]] || {
    url=$(asset MetaCubeX/mihomo "mihomo-linux-${arch}-compatible-.*\.gz$")
    curl -fsSL -o mihomo.gz "$url"
    gunzip -f mihomo.gz && mv -f mihomo mihomo.bin && chmod +x mihomo.bin
    mv -f mihomo.bin mihomo
}

echo "==> caddy"
[[ -x caddy ]] || {
    url=$(asset caddyserver/caddy "caddy_[0-9.]*_linux_${arch}\.tar\.gz$")
    curl -fsSL -o caddy.tgz "$url"
    tar -xzf caddy.tgz caddy && rm -f caddy.tgz && chmod +x caddy
}
echo "==> geo assets (Xray geoip/geosite)"
[[ -f geoip.dat ]] || curl -fsSL -o geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
[[ -f geosite.dat ]] || curl -fsSL -o geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

echo "==> done"
./xray version 2>/dev/null | head -1
./sing-box version 2>/dev/null | head -2
./mihomo -v 2>/dev/null | head -1
./caddy version 2>/dev/null