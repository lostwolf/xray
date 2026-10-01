# ============================================================================
# menu.sh — xctl 交互式主面板 (现代化 TUI)
#
# 由 core.sh::is_main_menu 按需加载, 仅无参数交互模式使用.
# 设计要点:
#   · 顶部实时状态总览: core / caddy 运行态, 节点数, CDN 站点明细, 订阅, BBR
#   · 分组两列菜单, 覆盖 xctl 全部高频能力 (cdn / sub 不再只能靠背命令)
#   · 每个动作执行完毕后 exec 重载脚本: 状态零污染, 面板永远显示最新状态
# ============================================================================

# 字符串的终端显示宽度 (CJK / 全角按 2 列)
menu_w() {
    local s=$1 b
    b=$(printf '%s' "$s" | wc -c)
    echo $(( ${#s} + (b - ${#s}) / 2 ))
}

# 菜单单元格: " 编号) 标签" 补空格到指定显示宽度 (width=0 为行尾, 不补)
menu_cell() {
    local num label width vis pad
    num=$(printf '%2s' "$1")
    label=$2
    width=${3:-0}
    vis=" $num) $label"
    pad=
    if (( width > 0 )); then
        pad=$(( width - $(menu_w "$vis") ))
        (( pad < 2 )) && pad=2
        pad=$(printf '%*s' "$pad" '')
    fi
    printf ' \e[92m%s)\e[0m %s%s' "$num" "$label" "$pad"
}

# 运行状态徽标
menu_run() {
    if [[ $(pgrep -f "$1") ]]; then
        printf '\e[92m● 运行中\e[0m'
    else
        printf '\e[91m● 已停止\e[0m'
    fi
}

# 当前节点配置数 (排除动态端口 link 文件)
menu_node_count() {
    ls $is_conf_dir 2>/dev/null | grep -E -i '\.json$' | sed '/dynamic-port-.*-link/d' | wc -l
}

# 已配置的 CDN 域名列表
menu_cdn_domains() {
    local f
    for f in $is_cdn_dir/*.env; do
        [[ -f $f ]] || continue
        basename "$f" .env
    done
}

# 无节点时的友好拦截 (返回 1)
menu_need_nodes() {
    if [[ $(menu_node_count) -eq 0 ]]; then
        warn "当前没有任何节点配置, 请先选择 (1) 添加配置."
        return 1
    fi
    return 0
}

# 顶部状态总览
menu_header() {
    local nodes cdns bbr sub f d net port i=0
    nodes=$(menu_node_count)
    cdns=$(ls $is_cdn_dir/*.env 2>/dev/null | wc -l)
    bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    xctl_load_env
    msg ""
    msg "\e[90m──────────────────────────────────────────────────────\e[0m"
    msg "  \e[1;95mxctl\e[0m \e[90m·\e[0m \e[1;96m${is_core_name} 服务管理面板\e[0m \e[90m${is_xctl_ver#v}\e[0m"
    msg "  \e[96m${is_core_name}\e[0m \e[90m${is_core_ver#* }\e[0m   $(menu_run $is_core_bin)"
    [[ $is_caddy ]] && msg "  \e[96mCaddy\e[0m \e[90m$is_caddy_ver\e[0m   $(menu_run $is_caddy_bin)"
    sub=未配置
    [[ $IS_SUB_TOKEN && $IS_SUB_ENABLE ]] && sub="\e[92m已启用\e[0m \e[90m(${IS_SUB_TOKEN:0:8}…)\e[0m"
    [[ $IS_SUB_TOKEN && ! $IS_SUB_ENABLE ]] && sub="\e[93m已关闭\e[0m"
    msg "  \e[96m节点\e[0m $nodes    \e[96mCDN\e[0m ${cdns} 域名    \e[96m订阅\e[0m $sub$([[ $bbr == bbr ]] && printf '    \e[96mBBR\e[0m \e[92m已启用\e[0m')"
    for f in $is_cdn_dir/*.env; do
        [[ -f $f ]] || continue
        i=$((i + 1))
        if (( i > 2 )); then
            msg "  \e[90m└ 还有 $((cdns - 2)) 个域名, 详见 (5) CDN 管理\e[0m"
            break
        fi
        d=$(basename "$f" .env)
        net=$(sed -n 's/^CDN_NET=//p' "$f")
        port=$(sed -n 's/^CDN_PORT=//p' "$f")
        msg "  \e[90m└\e[0m $d \e[90m($net → 127.0.0.1:$port)\e[0m"
    done
    if (( nodes == 0 && cdns == 0 )); then
        msg "  \e[93m快速开始\e[0m \e[90m: (1) 添加节点 → (5) 配置 CDN 回源 → (7) 生成客户端订阅\e[0m"
    fi
    msg "\e[90m──────────────────────────────────────────────────────\e[0m"
}

# 分组两列菜单主体
menu_body() {
    msg "  \e[95m── 节点配置 ──────────────────────────────\e[0m"
    msg "$(menu_cell 1 添加配置 26)$(menu_cell 2 更改配置)"
    msg "$(menu_cell 3 查看配置 26)$(menu_cell 4 删除配置)"
    msg "  \e[95m── CDN 与订阅 ────────────────────────────\e[0m"
    msg "$(menu_cell 5 'CDN 管理' 26)$(menu_cell 6 'CDN 自检')"
    msg "$(menu_cell 7 订阅管理 26)$(menu_cell 8 订阅地址)"
    msg "  \e[95m── 系统管理 ─────────────────────────────\e[0m"
    msg "$(menu_cell 9 运行管理 26)$(menu_cell 10 更新)"
    msg "$(menu_cell 11 实用工具 26)$(menu_cell 12 帮助)"
    msg "\e[90m──────────────────────────────────────────────────────\e[0m"
}

# 子菜单通用选择器: menu_pick <最大编号>
#   REPLY 中保留所选编号; 返回 1 = 取消/返回, 2 = 无效输入 (已提示)
menu_pick() {
    local max=$1
    echo -ne "  \e[96m选择\e[0m \e[90m[1-$max · Enter 返回]\e[0m : "
    read REPLY || return 1
    case ${REPLY,,} in
    "" | q | quit | 0) return 1 ;;
    esac
    [[ ! $REPLY =~ ^[0-9]+$ ]] && { warn "无效的选项: ($REPLY)"; return 2; }
    (( REPLY < 1 || REPLY > max )) && { warn "无效的选项: ($REPLY)"; return 2; }
    return 0
}

# 动作执行完毕后的回面板提示
menu_pause() {
    echo
    echo -ne "按 $(_green Enter 回车键) 返回面板, 或按 $(_red Ctrl + C) 退出."
    read -rs -d $'\n' || true
    echo
}

# ---------------------------------------------------------------------------
# 子菜单
# ---------------------------------------------------------------------------

menu_cdn_domain() {
    local d=$1
    msg ""
    msg "  \e[95m── CDN: $d ───────────────────────────────\e[0m"
    msg "$(menu_cell 1 查看配置与CF指南 0)"
    msg "$(menu_cell 2 重新同步站点与订阅 0)"
    msg "$(menu_cell 3 运行自检doctor 0)"
    msg "$(menu_cell 4 移除该站点反代 0)  \e[90m保留 inbound 与证书\e[0m"
    msg "$(menu_cell 0 返回主面板 0)"
    menu_pick 4 || return 0
    load cdn.sh
    case $REPLY in
    1) cdn_main info "$d" ;;
    2) cdn_main sync "$d" ;;
    3) cdn_main doctor "$d" ;;
    4)
        warn "即将移除 ($d) 的 Caddy 反代站点!"
        pause
        cdn_main remove "$d"
        ;;
    esac
}

menu_cdn() {
    local -a doms=()
    local d
    while IFS= read -r d; do doms+=("$d"); done < <(menu_cdn_domains)
    if [[ ${#doms[@]} -eq 0 ]]; then
        _yellow "\n暂无 CDN 站点, 进入新增向导 (可随时 Ctrl + C 取消) ...\n"
        load cdn.sh
        cdn_main setup
        return 0
    fi
    msg ""
    msg "  \e[95m── CDN 管理 ──────────────────────────────\e[0m"
    msg "$(menu_cell 1 新增域名 0)"
    local i=2
    for d in "${doms[@]}"; do
        msg "$(menu_cell $i "$d" 0)"
        i=$((i + 1))
    done
    msg "$(menu_cell 0 返回主面板 0)"
    menu_pick $(( ${#doms[@]} + 1 )) || return 0
    if [[ $REPLY == 1 ]]; then
        load cdn.sh
        cdn_main setup
        return 0
    fi
    menu_cdn_domain "${doms[REPLY - 2]}"
}

menu_cdn_doctor() {
    local -a doms=()
    local d
    while IFS= read -r d; do doms+=("$d"); done < <(menu_cdn_domains)
    if [[ ${#doms[@]} -eq 0 ]]; then
        warn "暂无 CDN 站点, 无法自检; 请先选择 (5) CDN 管理 新增域名."
        return 0
    fi
    if [[ ${#doms[@]} -eq 1 ]]; then
        load cdn.sh
        cdn_main doctor "${doms[0]}"
        return 0
    fi
    msg ""
    msg "  \e[95m── CDN 自检 ──────────────────────────────\e[0m"
    local i=1
    for d in "${doms[@]}"; do
        msg "$(menu_cell $i "$d" 0)"
        i=$((i + 1))
    done
    msg "$(menu_cell 0 返回主面板 0)"
    menu_pick ${#doms[@]} || return 0
    load cdn.sh
    cdn_main doctor "${doms[REPLY - 1]}"
}

menu_sub() {
    load sub.sh
    msg ""
    msg "  \e[95m── 订阅管理 ──────────────────────────────\e[0m"
    msg "$(menu_cell 1 重新生成全部订阅 0)"
    msg "$(menu_cell 2 查看订阅地址 0)"
    msg "$(menu_cell 3 重置订阅Token 0)  \e[93m旧链接立即失效\e[0m"
    msg "$(menu_cell 4 关闭订阅分发 0)"
    msg "$(menu_cell 0 返回主面板 0)"
    menu_pick 4 || return 0
    case $REPLY in
    1) sub_main gen ;;
    2) menu_sub_info ;;
    3)
        warn "重置后旧的订阅链接将立即失效, 客户端需要更换新地址!"
        pause
        sub_main token new
        ;;
    4) sub_main off ;;
    esac
}

menu_sub_info() {
    xctl_load_env
    if [[ ! $IS_SUB_TOKEN ]]; then
        warn "订阅尚未配置, 请先选择 (7) 订阅管理 生成订阅."
        return 0
    fi
    load sub.sh
    sub_main info
}

menu_tools() {
    msg ""
    msg "  \e[95m── 实用工具 ──────────────────────────────\e[0m"
    msg "$(menu_cell 1 启用BBR 0)"
    msg "$(menu_cell 2 查看日志 0)      \e[90mCtrl + C 退出\e[0m"
    msg "$(menu_cell 3 查看错误日志 0)  \e[90mCtrl + C 退出\e[0m"
    msg "$(menu_cell 4 测试运行自检 0)"
    msg "$(menu_cell 5 查看节点URL 0)"
    msg "$(menu_cell 6 节点二维码 0)"
    msg "$(menu_cell 7 生成客户端JSON 0)"
    msg "$(menu_cell 8 设置DNS 0)"
    msg "$(menu_cell 9 设置出站IP优先级 0)"
    msg "$(menu_cell 10 重装脚本 0)"
    msg "$(menu_cell 11 卸载 0)"
    msg "$(menu_cell 0 返回主面板 0)"
    menu_pick 11 || return 0
    case $REPLY in
    1) load bbr.sh; _try_enable_bbr ;;
    2) get log ;;
    3) get logerr ;;
    4) get test-run ;;
    5) menu_need_nodes && url_qr url ;;
    6) menu_need_nodes && url_qr qr ;;
    7) menu_need_nodes && create client ;;
    8) load dns.sh; dns_set ;;
    9) load ip.sh; ip_set ;;
    10)
        warn "重装脚本会先卸载再重新安装 (节点配置保留)."
        pause
        get reinstall
        ;;
    11) uninstall; exit 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# 主面板
# ---------------------------------------------------------------------------

menu_dispatch() {
    case $1 in
    1) add ;;
    2) menu_need_nodes && change ;;
    3) menu_need_nodes && info ;;
    4) menu_need_nodes && del ;;
    5) menu_cdn ;;
    6) menu_cdn_doctor ;;
    7) menu_sub ;;
    8) menu_sub_info ;;
    9)
        ask list is_do_manage "启动 停止 重启"
        manage $REPLY &
        msg "\n管理状态执行: $(_green $is_do_manage)\n"
        ;;
    10)
        is_tmp_list=("更新$is_core_name" "更新脚本")
        [[ $is_caddy ]] && is_tmp_list+=("更新Caddy")
        ask list is_do_update null "\n请选择更新:\n"
        update $REPLY
        ;;
    11) menu_tools ;;
    12) load help.sh; show_help; msg; about ;;
    esac
    return 0
}

menu_main() {
    is_main_start=1
    while :; do
        [[ -t 1 ]] && clear
        menu_header
        menu_body
        echo -ne "  \e[96m选择\e[0m \e[90m[1-12 · Enter 刷新 · q 退出]\e[0m : "
        read REPLY || exit 0
        case ${REPLY,,} in
        q | quit | exit) exit 0 ;;
        "") continue ;;
        esac
        if [[ ! $REPLY =~ ^[0-9]+$ ]] || (( REPLY < 1 || REPLY > 12 )); then
            warn "无效的选项: ($REPLY)"
            menu_pause
            continue
        fi
        menu_dispatch "$REPLY"
        menu_pause
        # 重载自身: 状态零污染, 面板数据 (运行态/节点/CDN/订阅) 全部重新采集
        exec bash "$0" main
    done
}
