#!/bin/bash
# ============================================================================
# xctl: Cloudflare CDN 回源自动化 (src/cdn.sh)
#
#   xray cdn [domain] [options]      一键配置 CDN 回源
#   xray cdn info [domain]           查看配置 + Cloudflare 设置清单
#   xray cdn sync [domain]           重新生成 Caddy 站点与订阅
#   xray cdn doctor [domain]         链路自检
#   xray cdn cert <cert> <key> [域]  安装并校验源站证书 (Origin Certificate)
#   xray cdn remove [domain]         移除 CDN 站点 (保留 inbound 与证书)
#
# 一键配置做的事:
#   1. 调用内置 add (no-auto-tls) 创建 VLESS-WS-TLS inbound
#      —— 有域名时自动让 inbound 只监听 127.0.0.1, 不会暴露源站端口
#   2. 校验并安装源站证书 (Origin Certificate / ACME / 自签)
#   3. 写独立 Caddy 站点 $is_caddy_sites/<domain>.conf:
#        443 -> 反代 WS 回源 + /sub/<token>/* 订阅 + 伪装站兜底
#   4. 生成客户端订阅 (src/sub.sh)
#   5. 打印 Cloudflare 面板配置清单, 并落一份 $is_cdn_dir/<domain>.md
# ============================================================================

# Cloudflare 官方回源 IP 段 (用于可选的 Caddy 层白名单)
is_cdn_cf_ipv4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
is_cdn_cf_ipv6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"

cdn_help() {
    msg "$is_core cdn — Cloudflare CDN 回源自动化"
    msg
    msg "用法: $is_core cdn [domain] [选项]"
    msg "  -d, --domain <域名>      用于 CDN 的域名"
    msg "  -p, --port <端口>        回源 inbound 本地端口 (默认自动挑一个空闲端口)"
    msg "      --path <路径>        WS 路径 (默认 /<uuid>)"
    msg "  -u, --uuid <uuid>        UUID (默认自动生成)"
    msg "      --net <ws|grpc|xhttp>  回源传输 (默认 ws)"
    msg "      --cert <文件> --key <文件>   安装 Cloudflare Origin Certificate"
    msg "      --tls <origin|acme|internal> 源站 TLS 方式 (默认 origin, 无证书时回退 internal)"
    msg "      --email <邮箱>       ACME 邮箱 (--tls acme 时可选)"
    msg "      --camouflage <site|none|https://...>  兜底站点 (默认 site)"
    msg "      --cf-only            只在 Caddy 层放行 Cloudflare 回源 IP"
    msg "      --token <token>      指定订阅 token"
    msg "      --no-tun             生成的 sing-box profile 不带 TUN"
    msg "  -y, --yes                非交互, 缺少参数直接报错"
    msg
    msg "子命令: info | sync | doctor | cert | remove"
}

# ---------------------------------------------------------------------------
# 参数与状态
# ---------------------------------------------------------------------------

cdn_parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        -d | --domain) is_cdn_domain=$2; shift 2 ;;
        -p | --port) is_cdn_port=$2; shift 2 ;;
        --path) is_cdn_path=$2; shift 2 ;;
        -u | --uuid) is_cdn_uuid=$2; shift 2 ;;
        --net) is_cdn_net=$2; shift 2 ;;
        --cert) is_cdn_cert=$2; shift 2 ;;
        --key) is_cdn_key=$2; shift 2 ;;
        --cf-key | --cf-token) is_cdn_cf_token=$2; shift 2 ;;
        --tls) is_cdn_tls=$2; shift 2 ;;
        --email) is_cdn_email=$2; shift 2 ;;
        --camouflage | --site) is_cdn_camouflage=$2; shift 2 ;;
        --cf-only) is_cdn_cf_only=1; shift ;;
        --token) is_cdn_token=$2; shift 2 ;;
        --no-tun) IS_SUB_NO_TUN=true; shift ;;
        -y | --yes) is_cdn_yes=1; shift ;;
        -*) err "未知参数: ($1), 使用 $is_core cdn help 查看用法" ;;
        *)
            [[ ! $is_cdn_domain ]] && is_cdn_domain=$1 || err "多余参数: ($1)"
            shift
            ;;
        esac
    done
}

cdn_state_file() { echo "$is_cdn_dir/$1.env"; }

cdn_load_state() {
    local f
    f=$(cdn_state_file "$1")
    [[ -f $f ]] && . $f
    CDN_DOMAIN=$1
}

cdn_save_state() {
    mkdir -p $is_cdn_dir
    cat >"$(cdn_state_file "$CDN_DOMAIN")" <<EOF
# xctl CDN 状态文件 (自动生成, 可安全删除后重跑 $is_core cdn)
CDN_DOMAIN=$CDN_DOMAIN
CDN_NET=$CDN_NET
CDN_CONFIG=$CDN_CONFIG
CDN_PORT=$CDN_PORT
CDN_PATH=$CDN_PATH
CDN_UUID=$CDN_UUID
CDN_TLS=$CDN_TLS
CDN_EMAIL=$CDN_EMAIL
CDN_CAMOUFLAGE=$CDN_CAMOUFLAGE
CDN_CF_ONLY=$CDN_CF_ONLY
CDN_CREATED=$CDN_CREATED
EOF
    chmod 600 "$(cdn_state_file "$CDN_DOMAIN")"
}

# ---------------------------------------------------------------------------
# Caddy / inbound 探测
# ---------------------------------------------------------------------------

cdn_inbound_net() {
    jq -r '.inbounds[0].streamSettings.network // empty' "$1" 2>/dev/null
}

cdn_inbound_port() {
    jq -r '.inbounds[0].port // empty' "$1" 2>/dev/null
}

cdn_inbound_path() {
    jq -r '.inbounds[0].streamSettings as $s | ($s.wsSettings.path // $s.httpSettings.path // $s.grpcSettings.serviceName // $s.xhttpSettings.path // empty)' "$1" 2>/dev/null
}

cdn_inbound_host() {
    jq -r '.inbounds[0].streamSettings as $s | ($s.wsSettings.headers.Host // $s.httpSettings.host[0] // $s.grpc_host // $s.xhttpSettings.host // empty)' "$1" 2>/dev/null
}

cdn_inbound_uuid() {
    jq -r '.inbounds[0].settings.clients[0].id // .inbounds[0].settings.clients[0].password // empty' "$1" 2>/dev/null
}

cdn_inbound_listen() {
    jq -r '.inbounds[0].listen // "0.0.0.0"' "$1" 2>/dev/null
}

# 找出 host + net 匹配的配置文件
cdn_find_inbound() {
    local domain=$1 want_net=$2 f
    for f in $is_conf_dir/*.json; do
        [[ -f $f ]] || continue
        [[ $f == *-link.json ]] && continue
        [[ $(cdn_inbound_host "$f") == "$domain" ]] || continue
        [[ $(cdn_inbound_net "$f") == "$want_net" ]] || continue
        echo "$f"
        return 0
    done
    return 1
}

cdn_ensure_caddyfile() {
    mkdir -p $is_caddy_dir $is_caddy_sites $is_log_dir
    if [[ ! -f $is_caddyfile ]]; then
        is_install_caddy=1
        load caddy.sh
        caddy_config new
    fi
    grep -q -- "$is_caddy_sites" $is_caddyfile || printf 'import %s/*.conf\n' "$is_caddy_sites" >>$is_caddyfile
}

# ---------------------------------------------------------------------------
# 一键配置
# ---------------------------------------------------------------------------

cdn_setup() {
    xctl_need_jq
    cdn_parse_args "$@"

    # 已有状态文件时作为默认值
    [[ $is_cdn_domain ]] && cdn_load_state "$is_cdn_domain"
    [[ ! $CDN_DOMAIN ]] && CDN_DOMAIN=$is_cdn_domain

    if [[ ! $CDN_DOMAIN ]]; then
        [[ $is_cdn_yes ]] && err "缺少域名, 请使用: $is_core cdn <domain>"
        ask string is_cdn_domain "请输入用于 CDN 的域名 (例如 cdn.example.com):"
        CDN_DOMAIN=$is_cdn_domain
    fi
    [[ ! $CDN_DOMAIN ]] && err "缺少域名"
    CDN_DOMAIN=$(echo "$CDN_DOMAIN" | tr 'A-Z' 'a-z' | sed 's#^https\?://##;s#/.*$##')
    [[ $(grep -E '^[a-z0-9.-]+$' <<<"$CDN_DOMAIN") ]] || err "域名格式不正确: ($CDN_DOMAIN)"

    CDN_NET=$([[ $is_cdn_net ]] && echo "$is_cdn_net" || echo "${CDN_NET:-ws}")
    case $CDN_NET in
    ws | grpc | xhttp) ;;
    *) err "不支持的回源传输: ($CDN_NET), 仅支持 ws / grpc / xhttp" ;;
    esac

    # 1. Caddy
    if [[ ! $is_caddy ]]; then
        _yellow "未检测到 Caddy, 开始安装 (用于 TLS 与订阅托管)..."
        get install-caddy
        is_caddy=1
    fi
    cdn_ensure_caddyfile

    # 2. 源站证书
    cdn_setup_cert

    # 3. inbound
    cdn_setup_inbound

    # 4. 订阅 token
    load sub.sh
    xctl_load_env
    if [[ $is_cdn_token ]]; then
        IS_SUB_TOKEN=$is_cdn_token
        xctl_save_env
    elif [[ ! $IS_SUB_TOKEN ]]; then
        IS_SUB_TOKEN=$(sub_token_new_str)
        xctl_save_env
    fi

    # 5. 伪装站
    cdn_setup_camouflage

    # 6. Caddy 站点 + 订阅产物
    CDN_CF_ONLY=${is_cdn_cf_only:-${CDN_CF_ONLY:-0}}
    CDN_CREATED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    cdn_site_write
    sub_gen_all

    # 7. 校验 + 生效
    cdn_validate_or_die
    cdn_restart

    cdn_save_state
    cdn_print_cf_guide
    _green "\nCDN 回源配置完成."
    msg "自检请执行: $is_core cdn doctor $CDN_DOMAIN"
}

cdn_setup_cert() {
    local domain=$CDN_DOMAIN
    CDN_TLS=${is_cdn_tls:-${CDN_TLS:-}}
    if [[ $is_cdn_cf_token ]]; then
        _yellow "正在通过 Cloudflare API 自动签发并下载 15 年 Origin Certificate..."
        cert_cf_api "$domain" "$is_cdn_cf_token" || err "通过 Cloudflare API 签发证书失败"
        CDN_TLS=origin
    elif [[ $is_cdn_cert && $is_cdn_key ]]; then
        cert_install "$is_cdn_cert" "$is_cdn_key" "$domain" || err "源站证书校验失败, 已中止"
        CDN_TLS=origin
    fi
    if [[ ! $CDN_TLS ]]; then
        [[ -f $is_cert_dir/$domain.pem && -f $is_cert_dir/$domain.key ]] && CDN_TLS=origin || CDN_TLS=internal
    fi
    case $CDN_TLS in
    origin)
        [[ -f $is_cert_dir/$domain.pem ]] || err "未找到 $is_cert_dir/$domain.pem, 请先安装 Origin Certificate:
  $is_core cdn cert <cert.pem> <key.pem> $domain
或在 Cloudflare 面板: SSL/TLS -> Origin Server -> Create Certificate"
        cert_check_pair $is_cert_dir/$domain.pem $is_cert_dir/$domain.key || err "证书与私钥不匹配"
        CDN_EMAIL=
        ;;
    acme)
        CDN_TLS=acme
        CDN_EMAIL=$is_cdn_email
        _yellow "使用 Caddy 自动 ACME 签发证书: 需要域名已解析到本机且 80 端口可从公网访问."
        ;;
    internal)
        [[ ! -f $is_cert_dir/$domain.pem ]] && {
            _yellow "未提供源站证书, 使用 Caddy 自签证书 (tls internal) 保证链路可跑通."
            cert_selfsign $domain
        }
        CDN_TLS=internal
        ;;
    *) err "不支持的 TLS 方式: ($CDN_TLS), 可用 origin / acme / internal" ;;
    esac
}

cdn_setup_inbound() {
    local domain=$CDN_DOMAIN f
    f=$(cdn_find_inbound "$domain" "$CDN_NET")
    if [[ ! $f ]]; then
        _yellow "创建回源 inbound ($CDN_NET) ..."
        local uuid=$is_cdn_uuid path=$is_cdn_path proto
        [[ ! $uuid ]] && uuid=$(get_uuid; echo $tmp_uuid)
        [[ ! $path ]] && path="/$uuid"
        # 先定好端口再调用 add (create server 的 get new 只在 port 为空时才随机取),
        # 并保证不是 1024 以下的特权端口, 便于容器 / 非 root 场景
        if [[ ! $is_cdn_port ]]; then
            while :; do
                get_port
                [[ $tmp_port -ge 1024 ]] && break
            done
            is_cdn_port=$tmp_port
        fi
        port=$is_cdn_port
        case $CDN_NET in
        ws) proto=vws ;;
        grpc) proto=vgrpc ;;
        xhttp) proto=xhttp ;;
        esac
        # 调用 add: 有域名时 inbound 自动只监听 127.0.0.1
        is_no_auto_tls=1
        is_dont_show_info=1
        add $proto "$domain" "$uuid" "$path"
        is_no_auto_tls=
        is_dont_show_info=
        f=$(cdn_find_inbound "$domain" "$CDN_NET")
        [[ ! $f ]] && err "回源 inbound 创建失败, 请检查 $is_conf_dir"
    fi
    CDN_CONFIG=$(basename "$f")
    CDN_PORT=${is_cdn_port:-$(cdn_inbound_port "$f")}
    CDN_PATH=$(cdn_inbound_path "$f")
    CDN_UUID=$(cdn_inbound_uuid "$f")
    local listen
    listen=$(cdn_inbound_listen "$f")
    if [[ $listen != "127.0.0.1" && $listen != "::1" ]]; then
        warn "inbound 监听在 ($listen), 不是回环地址!"
        _red "这会把 Xray 端口直接暴露到公网, 绕过 Cloudflare. 请确认端口未被防火墙放行."
    fi
    # 用户显式指定端口时, 用 change 改端口
    if [[ $is_cdn_port && $is_cdn_port != $(cdn_inbound_port "$f") ]]; then
        _yellow "把回源端口改为 $is_cdn_port ..."
        change "$CDN_CONFIG" port "$is_cdn_port" >/dev/null 2>&1
        f=$is_conf_dir/$CDN_CONFIG
        CDN_PORT=$(cdn_inbound_port "$f")
    fi
    msg "回源: $CDN_CONFIG  ->  127.0.0.1:$CDN_PORT  路径: $CDN_PATH"
}

cdn_setup_camouflage() {
    local domain=$CDN_DOMAIN
    CDN_CAMOUFLAGE=${is_cdn_camouflage:-${CDN_CAMOUFLAGE:-site}}
    case $CDN_CAMOUFLAGE in
    none) ;;
    site | "")
        CDN_CAMOUFLAGE=site
        mkdir -p $is_www_dir/$domain
        [[ ! -f $is_www_dir/$domain/index.html ]] && cp -f $is_tpl_dir/site.index.html $is_www_dir/$domain/index.html
        ;;
    http*)
        _yellow "兜底站点使用反代: $CDN_CAMOUFLAGE"
        ;;
    *) err "不支持的兜底方式: ($CDN_CAMOUFLAGE), 可用 site / none / https://..." ;;
    esac
}

# ---------------------------------------------------------------------------
# Caddy 站点
# ---------------------------------------------------------------------------

cdn_tls_line() {
    case $CDN_TLS in
    origin) echo "tls $is_cert_dir/$CDN_DOMAIN.pem $is_cert_dir/$CDN_DOMAIN.key" ;;
    acme) echo "tls${CDN_EMAIL:+ $CDN_EMAIL}" ;;
    *) echo "tls internal" ;;
    esac
}

cdn_site_write() {
    local domain=$CDN_DOMAIN file=$is_caddy_sites/$CDN_DOMAIN.conf
    local target="127.0.0.1:$CDN_PORT" fallback= cf_block=
    [[ $CDN_NET != ws ]] && target="h2c://127.0.0.1:$CDN_PORT"
    case $CDN_CAMOUFLAGE in
    none) fallback=$(printf '    respond "Not Found" 404') ;;
    http*) fallback=$(printf '    reverse_proxy %s' "$CDN_CAMOUFLAGE") ;;
    *) fallback=$(printf '    root * %s/%s\n    file_server' "$is_www_dir" "$domain") ;;
    esac
    [[ $CDN_CF_ONLY == 1 ]] && cf_block="    # 只放行 Cloudflare 回源 IP, 其余直接拒绝 (在 Caddy 层挡住扫端口)
    @xctl_not_cf not remote_ip 127.0.0.1/32 ::1 $is_cdn_cf_ipv4 $is_cdn_cf_ipv6
    respond @xctl_not_cf 403
"

    mkdir -p $is_caddy_sites $is_log_dir
    cat >"$file" <<EOF
# ============================================================================
# xctl CDN 站点 — 由 \`$is_core cdn\` 生成, 请勿手工编辑
# domain : $domain
# 回源   : $CDN_NET://$target$CDN_PATH
# TLS    : $CDN_TLS
# 更新   : $CDN_CREATED
# ============================================================================
$domain:$is_https_port {
    encode zstd gzip

    $(cdn_tls_line)

$cf_block    # ---- 1. 代理回源 ----
    @xctl_proxy path $CDN_PATH $CDN_PATH/*
    handle @xctl_proxy {
        reverse_proxy $target {
            header_up Host {http.request.host}
        }
    }

    # ---- 2. 订阅托管 (与代理共用同一站点, 继承 CF 隐藏与 TLS) ----
    handle_path /sub/$IS_SUB_TOKEN/* {
        header Cache-Control "no-store"
        header X-Robots-Tag "noindex"
        root * $is_sub_dir/$IS_SUB_TOKEN
        file_server
    }
    redir /sub/$IS_SUB_TOKEN /sub/$IS_SUB_TOKEN/ 308

    # ---- 3. 兜底 ----
    handle {
$fallback
    }

    log {
        output file $is_log_dir/caddy-$domain.log
        format console
        level INFO
    }
}
EOF
    _green "已写入 Caddy 站点: $file"
}

cdn_validate_or_die() {
    [[ -x $is_caddy_bin ]] || { warn "找不到 $is_caddy_bin, 跳过 Caddy 配置校验"; return 0; }
    local out
    out=$($is_caddy_bin validate --config $is_caddyfile --adapter caddyfile 2>&1) || {
        _red "Caddy 配置校验失败:"
        msg "$out"
        err "已中止, 未重启 Caddy (修好 $is_caddy_sites/$CDN_DOMAIN.conf 后执行 $is_core cdn sync)"
    }
    _green "Caddy 配置校验通过"
}

cdn_restart() {
    [[ $XCTL_NO_RESTART ]] && { _yellow "XCTL_NO_RESTART=1, 跳过服务重启"; return 0; }
    manage restart &
    msg ""
}

# ---------------------------------------------------------------------------
# 查看 / 同步 / 自检 / 移除
# ---------------------------------------------------------------------------

cdn_pick_domain() {
    local d=$1 f
    if [[ ! $d ]]; then
        for f in $is_cdn_dir/*.env; do
            [[ -f $f ]] || continue
            d=$(basename "$f" .env)
            break
        done
    fi
    [[ ! $d ]] && err "没有已配置的 CDN 域名, 请先执行: $is_core cdn <domain>"
    [[ ! -f $(cdn_state_file "$d") ]] && err "找不到 ($d) 的 CDN 状态, 请先执行: $is_core cdn $d"
    echo "$d"
}

cdn_sync_cmd() {
    local d
    d=$(cdn_pick_domain "$1")
    cdn_load_state "$d"
    cdn_ensure_caddyfile
    load sub.sh
    IS_SUB_TOKEN=$(sub_token_get)
    cdn_site_write
    sub_gen_all
    cdn_validate_or_die
    cdn_restart
}

cdn_sync_all() {
    local f d
    for f in $is_cdn_dir/*.env; do
        [[ -f $f ]] || continue
        d=$(basename "$f" .env)
        cdn_load_state "$d"
        cdn_site_write
    done
}

cdn_info_cmd() {
    local d
    d=$(cdn_pick_domain "$1")
    cdn_load_state "$d"
    load sub.sh
    cdn_print_cf_guide
}

cdn_remove() {
    local d
    d=$(cdn_pick_domain "$1")
    rm -f $is_caddy_sites/$d.conf
    rm -f "$(cdn_state_file "$d")"
    _green "已移除 CDN 站点: $d (inbound 与证书保留)"
    cdn_validate_or_die
    cdn_restart
}

cdn_doctor() {
    local d fails=0 warns=0
    d=$(cdn_pick_domain "$1")
    cdn_load_state "$d"
    load sub.sh
    IS_SUB_TOKEN=$(sub_token_get)
    msg "\n===== xctl doctor: $d ====="

    # 1. inbound
    local f=$is_conf_dir/$CDN_CONFIG listen
    if [[ -f $f ]]; then
        listen=$(cdn_inbound_listen "$f")
        if [[ $listen == "127.0.0.1" || $listen == "::1" ]]; then
            _green "[PASS] inbound 只监听回环 ($listen)"
        else
            _red "[FAIL] inbound 监听在 ($listen), 源站端口暴露风险"
            fails=$((fails + 1))
        fi
        if [[ $(cdn_inbound_host "$f") == "$d" ]]; then
            _green "[PASS] inbound 域名匹配 ($d)"
        else
            _red "[FAIL] inbound 域名不匹配"
            fails=$((fails + 1))
        fi
    else
        _red "[FAIL] 找不到 inbound 文件: $f"
        fails=$((fails + 1))
    fi

    # 2. xray 配置语法
    if [[ -x $is_core_bin ]]; then
        if $is_core_bin run -test -c $is_config_json -confdir $is_conf_dir &>/dev/null; then
            _green "[PASS] Xray 配置语法正确"
        else
            _red "[FAIL] Xray 配置语法错误"
            fails=$((fails + 1))
        fi
    else
        _yellow "[WARN] 找不到 $is_core_bin, 跳过 Xray 配置校验"
        warns=$((warns + 1))
    fi

    # 3. Caddy
    if [[ -x $is_caddy_bin ]]; then
        if $is_caddy_bin validate --config $is_caddyfile --adapter caddyfile &>/dev/null; then
            _green "[PASS] Caddy 配置语法正确"
        else
            _red "[FAIL] Caddy 配置语法错误"
            fails=$((fails + 1))
        fi
    else
        _yellow "[WARN] 找不到 $is_caddy_bin, 跳过 Caddy 校验"
        warns=$((warns + 1))
    fi

    # 4. 站点文件
    local site=$is_caddy_sites/$d.conf
    if [[ -f $site ]] && grep -q "sub/$IS_SUB_TOKEN" "$site" && grep -q "$CDN_PATH" "$site"; then
        _green "[PASS] Caddy 站点包含回源与订阅 handle"
    else
        _red "[FAIL] Caddy 站点缺失或未包含订阅/回源 handle: $site"
        fails=$((fails + 1))
    fi

    # 5. 证书
    if [[ $CDN_TLS == origin || $CDN_TLS == internal ]]; then
        if cert_check_pair $is_cert_dir/$d.pem $is_cert_dir/$d.key &>/dev/null; then
            local days
            days=$(cert_days_left $is_cert_dir/$d.pem)
            if [[ $days -gt 15 ]]; then
                _green "[PASS] 源站证书有效 (剩余 $days 天, $CDN_TLS)"
            else
                _red "[FAIL] 源站证书即将过期 (剩余 $days 天)"
                fails=$((fails + 1))
            fi
            if cert_covers_domain $is_cert_dir/$d.pem "$d"; then
                _green "[PASS] 证书 SAN 覆盖 $d"
            else
                _red "[FAIL] 证书 SAN 未覆盖 $d"
                fails=$((fails + 1))
            fi
        else
            _red "[FAIL] 源站证书缺失或与私钥不匹配"
            fails=$((fails + 1))
        fi
    else
        _yellow "[WARN] TLS 方式为 acme, 证书由 Caddy 管理, 跳过文件校验"
        warns=$((warns + 1))
    fi

    # 6. 端口监听
    if type -P ss &>/dev/null; then
        if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ":$is_https_port\$"; then
            _green "[PASS] Caddy 正在监听 $is_https_port"
        else
            _yellow "[WARN] 未发现 $is_https_port 监听 (Caddy 未运行?)"
            warns=$((warns + 1))
        fi
        if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "(^|\[::\]|0\.0\.0\.0):$CDN_PORT\$"; then
            _red "[FAIL] 回源端口 $CDN_PORT 监听在公网地址上"
            fails=$((fails + 1))
        else
            _green "[PASS] 回源端口 $CDN_PORT 未暴露到公网"
        fi
    fi

    # 7. 订阅产物
    local subdir=$is_sub_dir/$IS_SUB_TOKEN ok=1 l
    for l in default.txt clash.yaml singbox.json; do
        [[ -s $subdir/$l ]] || ok=
    done
    if [[ $ok ]]; then
        _green "[PASS] 订阅产物齐全 ($subdir)"
    else
        _red "[FAIL] 订阅产物缺失, 请执行: $is_core sub"
        fails=$((fails + 1))
    fi

    # 8. 分享链接
    if [[ -s $subdir/default.txt ]] && base64 -d "$subdir/default.txt" 2>/dev/null | grep -qE '^(vless|vmess|trojan|ss)://'; then
        _green "[PASS] base64 分享链接可解码且包含节点"
    else
        _yellow "[WARN] 分享链接为空 (没有可订阅的节点?)"
        warns=$((warns + 1))
    fi

    msg ""
    if [[ $fails -eq 0 ]]; then
        _green "doctor 通过 (warn: $warns)"
    else
        _red "doctor 失败项: $fails (warn: $warns)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Cloudflare 配置清单
# ---------------------------------------------------------------------------

cdn_print_cf_guide() {
    [[ ! $CDN_DOMAIN ]] && return
    local ssl_mode="Full (strict)" ssl_note=
    [[ $CDN_TLS != origin ]] && {
        ssl_mode="Full"
        ssl_note="当前源站是自签证书, 只能选 Full; 安装 Origin Certificate 后请改成 Full (strict)"
    }
    local ip guide note_line
    get_ip
    ip=$ip
    guide=$is_cdn_dir/$CDN_DOMAIN.md
    note_line=
    [[ $ssl_note ]] && note_line="- 注意: $ssl_note"
    mkdir -p $is_cdn_dir

    cat >$guide <<EOF
# Cloudflare 配置清单 - $CDN_DOMAIN

> 由 \`$is_core cdn\` 生成于 $CDN_CREATED

## 1. DNS

| 类型 | 名称 | 内容 | 代理状态 |
|---|---|---|---|
| A | $CDN_DOMAIN | $ip (源站 IP) | **Proxied / 橙云** |

要点:
- 必须是橙云. 灰云 (DNS only) 等于直连源站, CDN 隐藏无意义.
- 源站 IP 不要写错; 有 IPv6 时优先只加 A 记录, 避免 AAAA 把 IPv6 源站暴露.
- 其它解析到同一台源站的域名同样会泄露源站, 检查历史记录.

## 2. SSL/TLS

- Overview -> 加密模式: **$ssl_mode**
$note_line
- Edge Certificates -> **Always Use HTTPS = On**
- Edge Certificates -> **Minimum TLS Version = 1.2**
- Origin Server: 在 CF 面板签发 Origin Certificate 后执行:

\t$is_core cdn cert <cert.pem> <key.pem> $CDN_DOMAIN
\t$is_core cdn sync $CDN_DOMAIN

## 3. 网络

- Network -> **WebSockets = On** (默认开启; 关闭会导致 WS 回源 100% 失败)
- 橙色云默认回源 443, CF 侧无需额外端口配置

## 4. 缓存

- Caching -> Cache Rules 新建两条 **Bypass** 规则:
  - 路径 \`$CDN_PATH\` 与 \`$CDN_PATH/*\` (WS 升级必须绕过缓存)
  - 路径 \`/sub/*\` (订阅必须实时)

## 5. 源站端口与防火墙

- Xray 回源端口 \`$CDN_PORT\` 只监听 \`127.0.0.1\`, **不要**在安全组 / ufw 里放行它
- 只放行 443/tcp (可选 80/tcp, 仅当使用 ACME 签发时)
- 可选硬化: 在 Caddy 层只放行 Cloudflare 回源 IP

\t$is_core cdn $CDN_DOMAIN --cf-only

ufw 参考:

\tufw allow 443/tcp
\tufw deny $CDN_PORT/tcp

## 6. 客户端订阅

\tClash Meta : https://$CDN_DOMAIN/sub/$IS_SUB_TOKEN/clash.yaml
\tsing-box   : https://$CDN_DOMAIN/sub/$IS_SUB_TOKEN/singbox.json
\tbase64     : https://$CDN_DOMAIN/sub/$IS_SUB_TOKEN/default.txt

订阅与代理共用同一条 Caddy 站点, 因此同样被 CF 隐藏并继承边缘 TLS.
EOF

    msg ""
    _cyan "========== Cloudflare 配置清单 ($CDN_DOMAIN) =========="
    msg "1. DNS   : A $CDN_DOMAIN -> $ip , 代理状态 = 橙云 (Proxied)"
    msg "2. SSL   : 加密模式 = $ssl_mode"
    [[ $ssl_note ]] && warn "$ssl_note"
    msg "3. 网络  : WebSockets = On (必须)"
    msg "4. 缓存  : Bypass $CDN_PATH 与 /sub/*"
    msg "5. 端口  : 只放行 443/tcp; 回源端口 $CDN_PORT 保持仅回环"
    msg "6. 订阅  : https://$CDN_DOMAIN/sub/$IS_SUB_TOKEN/clash.yaml"
    msg "完整清单已写入: $guide"
    msg "========================================================"
    msg ""
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

cdn_main() {
    local cmd=${1:-setup}
    load cert.sh
    case $cmd in
    help | -h | --help) cdn_help ;;
    info | show) shift; cdn_info_cmd "$@" ;;
    sync | regen) shift; cdn_sync_cmd "$@" ;;
    doctor | check) shift; cdn_doctor "$@" ;;
    list)
        local f
        for f in $is_cdn_dir/*.env; do
            [[ -f $f ]] || continue
            msg "$(basename "$f" .env)"
        done
        ;;
    cert)
        shift
        [[ ! $1 || ! $2 ]] && err "用法: $is_core cdn cert <cert.pem> <key.pem> [domain]"
        local domain=$3
        [[ ! $domain ]] && domain=$(cdn_pick_domain)
        cert_install "$1" "$2" "$domain" || err "源站证书校验失败"
        if [[ -f $(cdn_state_file "$domain") ]]; then
            cdn_load_state "$domain"
            cdn_site_write
            cdn_validate_or_die
            cdn_restart
            _green "证书已生效, 现在可以在 Cloudflare 把加密模式改成 Full (strict)."
        else
            _green "证书已安装; 继续执行 $is_core cdn $domain 完成回源配置."
        fi
        ;;
    remove | del | rm) shift; cdn_remove "$@" ;;
    setup) shift; cdn_setup "$@" ;;
    *) cdn_setup "$cmd" "${@:2}" ;;
    esac
}