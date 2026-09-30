#!/usr/bin/env bash
# ============================================================================
# xctl 一键安装脚本
# 支持: Debian 10+, Ubuntu 20.04+, CentOS 8+, AlmaLinux/Rocky 8+, Alpine 3.16+
# 架构: x86_64 (amd64), aarch64 (arm64)
# ============================================================================
set -e

REPO="lostwolf/xray"
BRANCH="main"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
PLAIN='\033[0m'

_info() { echo -e "${CYAN}[信息]${PLAIN} $*"; }
_ok() { echo -e "${GREEN}[成功]${PLAIN} $*"; }
_warn() { echo -e "${YELLOW}[警告]${PLAIN} $*"; }
_err() { echo -e "${RED}[错误]${PLAIN} $*"; exit 1; }

# 1. Root 权限检查
if [[ $EUID -ne 0 ]]; then
    _err "请使用 root 权限执行此脚本 (例如: sudo bash install.sh)"
fi

# 2. 架构检测
ARCH=$(uname -m)
case $ARCH in
x86_64 | amd64)
    CORE_ARCH="64"
    CADDY_ARCH="amd64"
    ;;
aarch64 | arm64)
    CORE_ARCH="arm64-v8a"
    CADDY_ARCH="arm64"
    ;;
*)
    _err "暂不支持的 CPU 架构: ($ARCH)"
    ;;
esac

# 3. 安装依赖包
_info "安装必要系统依赖..."
if type -P apt-get &>/dev/null; then
    apt-get update -y
    apt-get install -y curl wget unzip tar jq openssl
elif type -P dnf &>/dev/null; then
    dnf install -y curl wget unzip tar jq openssl
elif type -P yum &>/dev/null; then
    yum install -y curl wget unzip tar jq openssl
elif type -P apk &>/dev/null; then
    apk update
    apk add curl wget unzip tar jq openssl
else
    _warn "未识别的包管理器, 请确保已安装 curl wget unzip tar jq openssl"
fi

# 4. 创建工作目录
_info "初始化系统目录..."
mkdir -p /etc/xray/bin \
         /etc/xray/conf \
         /etc/xray/cert \
         /etc/xray/sub \
         /etc/xray/sh \
         /var/log/xray \
         /etc/caddy/xctl \
         /etc/caddy/sites \
         /var/www

TMP_DIR=$(mktemp -d /tmp/xctl-install.XXXXXX)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# 5. 下载并安装 Xray Core
_info "获取 Xray Core 最新版本..."
XRAY_VER=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' || true)
if [[ ! $XRAY_VER ]]; then
    XRAY_VER="v26.3.27"
    _warn "从 GitHub API 获取 Xray 最新版本失败，回退至内置默认版本: $XRAY_VER"
fi
_info "下载并解压 Xray Core ($XRAY_VER, $CORE_ARCH)..."
curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${CORE_ARCH}.zip" -o "$TMP_DIR/xray.zip"
unzip -qo "$TMP_DIR/xray.zip" -d /etc/xray/bin/
chmod +x /etc/xray/bin/xray

# 确保路由数据文件就绪
if [[ ! -f /etc/xray/bin/geoip.dat || ! -f /etc/xray/bin/geosite.dat ]]; then
    _info "下载 GeoIP 与 GeoSite 路由规则文件..."
    curl -fsSL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -o /etc/xray/bin/geoip.dat || true
    curl -fsSL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -o /etc/xray/bin/geosite.dat || true
fi

# 6. 下载并安装 Caddy
_info "获取 Caddy 最新版本..."
CADDY_VER=$(curl -s "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' || true)
if [[ ! $CADDY_VER ]]; then
    CADDY_VER="v2.10.2"
    _warn "从 GitHub API 获取 Caddy 最新版本失败，回退至内置默认版本: $CADDY_VER"
fi
_info "下载并安装 Caddy ($CADDY_VER, $CADDY_ARCH)..."
CADDY_NUM="${CADDY_VER#v}"
curl -fsSL "https://github.com/caddyserver/caddy/releases/download/${CADDY_VER}/caddy_${CADDY_NUM}_linux_${CADDY_ARCH}.tar.gz" -o "$TMP_DIR/caddy.tar.gz"
tar -xzf "$TMP_DIR/caddy.tar.gz" -C "$TMP_DIR"
install -m 755 "$TMP_DIR/caddy" /usr/local/bin/caddy

# 初始化默认 Caddyfile
if [[ ! -f /etc/caddy/Caddyfile ]]; then
    cat >/etc/caddy/Caddyfile <<'EOF'
{
	admin off
	http_port 80
	https_port 443
}
import /etc/caddy/xctl/*.conf
import /etc/caddy/sites/*.conf
EOF
fi

# 7. 下载并安装 xctl 脚本套件
_info "下载 xctl 管理脚本..."
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" -o "$TMP_DIR/xctl.tar.gz"
tar -xzf "$TMP_DIR/xctl.tar.gz" -C "$TMP_DIR"
SRC_UNPACK=$(ls -d "$TMP_DIR"/*-main 2>/dev/null | head -n1 || true)
if [[ ! $SRC_UNPACK ]]; then
    SRC_UNPACK=$(ls -d "$TMP_DIR"/xray* 2>/dev/null | head -n1 || true)
fi
[[ ! $SRC_UNPACK ]] && _err "解压 xctl 仓库失败"

cp -rf "$SRC_UNPACK/src" "$SRC_UNPACK/template" "$SRC_UNPACK/xray.sh" /etc/xray/sh/
chmod +x /etc/xray/sh/xray.sh
ln -sf /etc/xray/sh/xray.sh /usr/local/bin/xray

# 8. 安装 systemd 服务
if type -P systemctl &>/dev/null; then
    _info "配置 systemd 系统服务..."
    cat >/etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/xray/bin/xray run -c /etc/xray/config.json -confdir /etc/xray/conf
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    cat >/etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray caddy &>/dev/null || true
fi

# 9. 初始化基础配置
_info "初始化 Xray 基础配置..."
/usr/local/bin/xray fix-config.json >/dev/null 2>&1 || true

echo
echo -e "${GREEN}========================================================${PLAIN}"
echo -e "${GREEN}           🎉 xctl 一键安装完成！                       ${PLAIN}"
echo -e "${GREEN}========================================================${PLAIN}"
echo -e "  Xray Core 版本 : $(/etc/xray/bin/xray version | head -n1 2>/dev/null || echo '已就绪')"
echo -e "  Caddy 版本     : $(/usr/local/bin/caddy version 2>/dev/null || echo '已就绪')"
echo -e "  CLI 管理命令   : ${CYAN}xray${PLAIN}"
echo
echo -e "${YELLOW}下一步推荐：配置 Cloudflare CDN 回源与全自动订阅：${PLAIN}"
echo -e "  ${CYAN}xray cdn <你的域名> --cf-token <你的Cloudflare_API_Token>${PLAIN}"
echo
echo -e "如需查看帮助信息，请执行："
echo -e "  ${CYAN}xray help${PLAIN}"
echo -e "${GREEN}========================================================${PLAIN}"
echo
