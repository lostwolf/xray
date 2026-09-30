#!/bin/bash

args=$@
is_sh_ver=v1.35
is_xctl_ver=v1.0

# xctl: 跟随脚本自身位置加载, 不再硬编码 /etc/xray/sh
# 这样既能安装到 /etc/xray/sh 后运行, 也能在仓库内直接调试 (XCTL_PREFIX 沙箱)
is_sh_link=$(readlink -f "$0")
. "$(dirname "$is_sh_link")/src/init.sh"