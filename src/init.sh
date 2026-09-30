#!/bin/bash

author=lostwolf
# https://github.com/lostwolf/xray

# bash fonts colors
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

_red() { echo -e ${red}$@${none}; }
_blue() { echo -e ${blue}$@${none}; }
_cyan() { echo -e ${cyan}$@${none}; }
_green() { echo -e ${green}$@${none}; }
_yellow() { echo -e ${yellow}$@${none}; }
_magenta() { echo -e ${magenta}$@${none}; }
_red_bg() { echo -e "\e[41m$@${none}"; }

_rm() {
    rm -rf "$@"
}
_cp() {
    cp -rf "$@"
}
_sed() {
    sed -i "$@"
}
_mkdir() {
    mkdir -p "$@"
}

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $@\n"
    [[ $is_dont_auto_exit ]] && return
    exit 1
}

warn() {
    echo -e "\n$is_warn $@\n"
}

# load bash script.
load() {
    . $is_sh_dir/src/$1
}

# wget add --no-check-certificate
_wget() {
    # [[ $proxy ]] && export https_proxy=$proxy
    wget --no-check-certificate "$@"
}

# yum or apt-get or apk
cmd=$(type -P apt-get || type -P yum || type -P apk)

# alpine linux
is_alpine=
[[ $cmd =~ apk ]] && is_alpine=1

# x64
case $(arch) in
amd64 | x86_64)
    is_core_arch="64"
    caddy_arch="amd64"
    ;;
*aarch64* | *armv8*)
    is_core_arch="arm64-v8a"
    caddy_arch="arm64"
    ;;
*)
    err "此脚本仅支持 64 位系统..."
    ;;
esac

is_core=xray
is_core_name=Xray
is_core_dir=/etc/$is_core
is_core_bin=$is_core_dir/bin/$is_core
is_core_repo=xtls/$is_core-core
is_conf_dir=$is_core_dir/conf
is_log_dir=/var/log/$is_core
is_sh_bin=/usr/local/bin/$is_core
is_sh_dir=$is_core_dir/sh
is_sh_repo=$author/$is_core
is_pkg="wget unzip jq qrencode"
is_config_json=$is_core_dir/config.json
is_caddy_bin=/usr/local/bin/caddy
is_caddy_dir=/etc/caddy
is_caddy_repo=caddyserver/caddy
is_caddyfile=$is_caddy_dir/Caddyfile
is_caddy_conf=$is_caddy_dir/$author
is_caddy_service=$(systemctl list-units --full -all 2>/dev/null | grep caddy.service)
[[ $is_alpine && -f /etc/init.d/caddy ]] && is_caddy_service=1
is_http_port=80
is_https_port=443

# ============================================================================
# xctl: fork 扩展区
# ============================================================================

# 自定义安装前缀: 用于容器 / 无 root 沙箱 (测试用), 不设置时与默认行为完全一致
if [[ $XCTL_PREFIX ]]; then
    is_core_dir=$XCTL_PREFIX/etc/$is_core
    is_core_bin=$is_core_dir/bin/$is_core
    is_conf_dir=$is_core_dir/conf
    is_log_dir=$XCTL_PREFIX/var/log/$is_core
    is_sh_bin=$XCTL_PREFIX/usr/local/bin/$is_core
    is_sh_dir=$is_core_dir/sh
    is_config_json=$is_core_dir/config.json
    is_caddy_bin=$XCTL_PREFIX/usr/local/bin/caddy
    is_caddy_dir=$XCTL_PREFIX/etc/caddy
    is_caddyfile=$is_caddy_dir/Caddyfile
    is_caddy_conf=$is_caddy_dir/$author
fi

# 在仓库目录直接运行 (未安装, 如 XCTL_PREFIX 首次引导) 时回退到脚本自身目录
is_src_self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ ! -d $is_sh_dir/src && -d $is_src_self ]] && is_sh_dir=$(dirname "$is_src_self")

# 沙箱下可强制认定 Caddy 已安装 (仅测试用, 不改变默认行为)
[[ $XCTL_ASSUME_CADDY ]] && is_caddy=1
# 沙箱/容器里没有 systemd 服务, 上面的探测不会跑; 这里补一次 Caddyfile 端口解析
if [[ $XCTL_ASSUME_CADDY && -f $is_caddyfile ]]; then
    is_tmp_http_port=$(grep -E '^[[:space:]]*http_port' $is_caddyfile | grep -E -o '[0-9]+')
    is_tmp_https_port=$(grep -E '^[[:space:]]*https_port' $is_caddyfile | grep -E -o '[0-9]+')
    [[ $is_tmp_http_port ]] && is_http_port=$is_tmp_http_port
    [[ $is_tmp_https_port ]] && is_https_port=$is_tmp_https_port
fi

# xctl 扩展路径与版本
is_xctl_ver=${is_xctl_ver:-v1.0}
is_tpl_dir=$is_sh_dir/template
is_xctl_dir=$is_core_dir/xctl
is_cdn_dir=$is_xctl_dir/cdn
is_cert_dir=$is_core_dir/cert
is_sub_dir=$is_core_dir/sub
is_caddy_sites=$is_caddy_dir/sites
is_www_dir=${XCTL_PREFIX}/var/www
is_xctl_env=$is_xctl_dir/xctl.env

# 确保 jq 可用: 优先系统 jq, 其次随脚本分发的静态 jq (tools/jq)
xctl_need_jq() {
    type -P jq &>/dev/null && return
    [[ -x $is_sh_dir/tools/jq ]] || err "缺少 jq 命令, 请先安装: apt install -y jq"
    mkdir -p $is_sh_dir/run
    ln -sf ../tools/jq $is_sh_dir/run/jq
    export PATH=$is_sh_dir/run:$PATH
}

# 读取 xctl 全局状态 (订阅 token 等)
xctl_load_env() {
    [[ -f $is_xctl_env ]] && . $is_xctl_env
}

# 保存 xctl 全局状态
xctl_save_env() {
    mkdir -p $is_xctl_dir
    cat >$is_xctl_env <<-EOF
# xctl 状态文件, 由脚本自动维护
IS_SUB_TOKEN=$IS_SUB_TOKEN
IS_SUB_ENABLE=$IS_SUB_ENABLE
EOF
    chmod 600 $is_xctl_env
}

# 在 add / change / del 之后自动同步订阅; sub.sh 缺失时为空操作, 且永不中断主流程
xctl_hook() {
    [[ $is_xctl_no_hook || $is_gen ]] && return
    [[ -f $is_sh_dir/src/sub.sh ]] || return
    load sub.sh
    sub_auto_sync
}

# core ver
is_core_ver=$($is_core_bin version | head -n1 | cut -d " " -f1-2)

if [[ $(pgrep -f $is_core_bin) ]]; then
    is_core_status=$(_green running)
else
    is_core_status=$(_red_bg stopped)
    is_core_stop=1
fi
if [[ -f $is_caddy_bin && -d $is_caddy_dir && $is_caddy_service ]]; then
    is_caddy=1
    # fix caddy run; ver >= 2.8.2 (仅 systemd)
    [[ ! $is_alpine ]] && [[ ! $(grep '\-\-adapter caddyfile' /lib/systemd/system/caddy.service) ]] && {
        load systemd.sh
        install_service caddy
        systemctl restart caddy &
    }
    is_caddy_ver=$($is_caddy_bin version | head -n1 | cut -d " " -f1)
    is_tmp_http_port=$(grep -E '^ {2,}http_port|^http_port' $is_caddyfile | grep -E -o [0-9]+)
    is_tmp_https_port=$(grep -E '^ {2,}https_port|^https_port' $is_caddyfile | grep -E -o [0-9]+)
    [[ $is_tmp_http_port ]] && is_http_port=$is_tmp_http_port
    [[ $is_tmp_https_port ]] && is_https_port=$is_tmp_https_port
    if [[ $(pgrep -f $is_caddy_bin) ]]; then
        is_caddy_status=$(_green running)
    else
        is_caddy_status=$(_red_bg stopped)
        is_caddy_stop=1
    fi
fi

load core.sh
[[ ! $args ]] && args=main
main $args