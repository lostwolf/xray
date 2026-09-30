#!/bin/bash
# ============================================================================
# xctl: 客户端订阅生成与托管 (src/sub.sh)
#
# 产物 (默认 $is_sub_dir/<token>/):
#   default.txt   base64(分享链接) —— v2rayN / Shadowrocket / v2rayNG
#   clash.yaml    Clash Meta (mihomo) 完整 profile
#   singbox.json  sing-box (>= 1.14) 完整 profile
#   index.html    订阅落地页
#
# 设计要点:
#   1. 节点枚举通过 get info + info() 获取, 统一协议解析;
#      分享链接直接取内置构造好的 is_url
#   2. 客户端 endpoint 与 info() 语义一致:
#        有 host  -> host:https_port (TLS, 走 Caddy / CDN)
#        无 host  -> IP:inbound_port (reality 例外, 仍为 TLS)
#   3. 渲染先写临时文件再 mv, 避免 Caddy 读到半个文件
#   4. 订阅是纯静态文件, 没有动态后端; 鉴权靠路径里的随机 token
# ============================================================================

# 代理类 geosite (规则顺序: 必须先于 CN 直连规则)
is_sub_geosite_proxy=(google youtube telegram twitter facebook instagram openai anthropic github netflix disney spotify bing geolocation-!cn)

# ---------------------------------------------------------------------------
# token 管理
# ---------------------------------------------------------------------------

sub_token_new_str() {
    head -c 16 /dev/urandom | od -An -tx1 | tr -d '[:space:]'
}

sub_token_get() {
    xctl_load_env
    [[ ! $IS_SUB_TOKEN ]] && {
        IS_SUB_TOKEN=$(sub_token_new_str)
        IS_SUB_ENABLE=1
        xctl_save_env
    }
    echo "$IS_SUB_TOKEN"
}

# 把 filename 转成精确匹配的正则, 避免 get file 误匹配到别的配置
sub_re_escape() {
    printf '%s' "$1" | sed 's/[].[^$*+?(){}|]/\\&/g'
}

# ---------------------------------------------------------------------------
# 节点采集
# ---------------------------------------------------------------------------

# 重置 get info 导出的全局变量, 避免跨配置污染
# (只在值为 null 时 unset, 上一个配置的残留值会串味)
sub_reset_vars() {
    unset is_protocol net port uuid trojan_password ss_method ss_password door_addr door_port
    unset is_dynamic_port is_socks_user is_socks_pass tcp_type kcp_seed kcp_type quic_type
    unset ws_path h2_path grpc_path xhttp_path grpc_host ws_host h2_host xhttp_host
    unset is_reality is_servername is_public_key is_private_key path host header_type
    unset is_stream is_client_id_json is_server_id_json is_config_name is_no_auto_tls
    unset is_trojan is_url is_dynamic_port_file is_dynamic_port_range is_addr
}

# 客户端应连接的地址 / 端口 / TLS
sub_endpoint() {
    is_server_tls=0
    is_server_sni=
    is_flow=
    if [[ $host ]]; then
        is_server=$host
        is_server_port=$is_https_port
        is_server_tls=1
        is_server_sni=$host
    else
        get_ip
        is_server=$ip
        is_server_port=$port
        [[ $is_reality ]] && {
            is_server_tls=1
            is_server_sni=$is_servername
        }
    fi
    [[ $is_reality ]] && is_flow=xtls-rprx-vision
    is_server_port=${is_server_port:-443}
}

# 节点描述符 (clash / singbox 渲染共用)
sub_node_desc() {
    local name=$1 service
    service=$(sed 's#/##g' <<<"${path:-/}")
    jq -nc         --arg name "$name"         --arg protocol "$is_protocol"         --arg server "$is_server"         --argjson port "$is_server_port"         --arg uuid "${uuid:-$trojan_password}"         --arg password "${trojan_password:-$ss_password}"         --arg cipher "$ss_method"         --arg network "${net:-tcp}"         --arg path "${path:-/}"         --arg service_name "$service"         --arg host "${host:-$is_server}"         --arg sni "$is_server_sni"         --arg flow "$is_flow"         --arg xhttp_mode "${is_xhttp_mode:-packet-up}"         --arg public_key "$is_public_key"         --arg short_id "$is_short_id"         --argjson tls "${is_server_tls:-0}"         --argjson reality "$([[ $is_reality ]] && echo true || echo false)"         '{
            name: $name, protocol: $protocol, server: $server, port: $port,
            uuid: $uuid, password: $password, cipher: $cipher,
            network: $network, path: $path, serviceName: $service_name,
            host: $host, sni: $sni, flow: $flow,
            xhttpMode: $xhttp_mode,
            publicKey: $public_key, shortId: $short_id,
            tls: $tls, reality: $reality, alterId: 0,
            fingerprint: "chrome", udp: true
        }
        | with_entries(select(.value != "" and .value != null))'
}

# 遍历 $is_conf_dir 采集所有可订阅节点
# 输出: is_sub_nodes / is_sub_name_list / is_sub_links / is_sub_skipped / is_sub_count
sub_collect() {
    xctl_need_jq
    local f old_exit=$is_dont_auto_exit https_port_save=$is_https_port n=0
    local -a names=()
    local base name dup d
    is_dont_auto_exit=1
    is_sub_links=()
    is_sub_skipped=()
    is_sub_nodes='[]'
    is_sub_name_list='[]'

    for f in $(ls $is_conf_dir 2>/dev/null | grep -E -i '[.]json$' | grep -v -E -- '-link[.]json$'); do
        is_https_port=$https_port_save
        sub_reset_vars
        get info "$(sub_re_escape "$f")" >/dev/null 2>&1
        case $is_protocol in
        vless | vmess | trojan | shadowsocks) ;;
        *) continue ;;
        esac
        [[ ! $is_client_id_json ]] && continue
        case $net in
        ws | grpc | tcp | ss | xhttp | splithttp) ;;
        *)
            is_sub_skipped+=("$f: 传输 ($net) 暂不被支持")
            continue
            ;;
        esac
        sub_endpoint
        n=$((n + 1))
        base="${is_protocol}-${net}-${is_server}"
        name=$base
        dup=0
        for d in "${names[@]}"; do
            [[ $d == "$name" ]] && { dup=1; break; }
        done
        [[ $dup == 1 ]] && name="$base-$n"
        names+=("$name")

        is_sub_nodes=$(jq -c --argjson n "$(sub_node_desc "$name")" '. + [$n]' <<<"$is_sub_nodes")
        is_sub_name_list=$(jq -c --arg n "$name" '. + [$n]' <<<"$is_sub_name_list")

        # 分享链接: 直接取 info() 构造的 is_url
        is_dont_show_info=1
        info >/dev/null 2>&1
        [[ $is_url ]] && is_sub_links+=("$is_url")
        unset is_url
    done
    is_dont_auto_exit=$old_exit
    is_sub_count=$n
}

# 订阅域名: 取节点里出现的域名 (排除 IP)
sub_domains() {
    jq -r '[.[] | .server | select(test("^[0-9.]+$") | not) | select(test(":") | not)] | unique | .[]' <<<"$is_sub_nodes" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 模板渲染
# ---------------------------------------------------------------------------

# 单行值替换 (替换全部出现位置, 值不做转义处理)
sub_tpl_put() {
    local file=$1 key=$2 val=$3
    local tmp=$file.tmp
    KEY="$key" VAL="$val" awk '
        {
            out = ""; rest = $0
            while ((i = index(rest, ENVIRON["KEY"])) > 0) {
                out = out substr(rest, 1, i - 1) ENVIRON["VAL"]
                rest = substr(rest, i + length(ENVIRON["KEY"]))
            }
            print out rest
        }' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

# 整行替换成另一个文件的内容 (保留插入内容自身的缩进)
sub_tpl_splice() {
    local file=$1 key=$2 ins=$3
    local tmp=$file.tmp
    KEY="$key" INS="$ins" awk '
        $0 == ENVIRON["KEY"] {
            while ((getline l < ENVIRON["INS"]) > 0) print l
            close(ENVIRON["INS"]); next
        }
        { print }' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

sub_render_base64() {
    local out=$1
    if [[ ${#is_sub_links[@]} -eq 0 ]]; then
        : > $out
        return
    fi
    { for l in "${is_sub_links[@]}"; do printf '%s\n' "$l"; done; } | head -c -1 | base64 -w 0 > $out
}

# Clash Meta profile
sub_render_clash() {
    local out=$1 tmp_proxies tmp_names secret
    tmp_proxies=$out.proxies
    tmp_names=$out.names
    secret=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d '[:space:]')

    jq -c -f $is_tpl_dir/jq/clash-proxies.jq <<<"$is_sub_nodes" | jq -r '.[] | "  - " + tojson' > $tmp_proxies
    jq -r '.[] | "      - " + tojson' <<<"$is_sub_name_list" > $tmp_names

    cp -f $is_tpl_dir/clash.yaml.tpl $out
    sub_tpl_put $out "{{SECRET}}" "$secret"
    sub_tpl_put $out "{{UPDATED_AT}}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    sub_tpl_put $out "{{NODE_COUNT}}" "$is_sub_count"
    sub_tpl_splice $out "{{PROXIES}}" $tmp_proxies
    sub_tpl_splice $out "{{NODE_GROUP_ENTRIES}}" $tmp_names
    rm -f $tmp_proxies $tmp_names
}

# sing-box profile
sub_render_singbox() {
    local out=$1 no_tun=$2 rule_sets proxy_rules
    rule_sets=$(printf '%s\n' "${is_sub_geosite_proxy[@]}" | jq -R -s -c '
        split("\n") | map(select(. != ""))
        | map({tag: ("geosite-" + .), type: "remote", format: "binary",
               url: ("https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geosite-" + . + ".srs"),
               download_detour: "proxy"})
        + [{tag: "geosite-category-ads-all", type: "remote", format: "binary",
            url: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geosite-category-ads-all.srs",
            download_detour: "proxy"},
           {tag: "geoip-cn", type: "remote", format: "binary",
            url: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/geoip-cn.srs",
            download_detour: "proxy"}]')
    proxy_rules=$(printf '%s\n' "${is_sub_geosite_proxy[@]}" | jq -R -s -c '
        split("\n") | map(select(. != ""))
        | map({rule_set: ["geosite-" + .], action: "route", outbound: "proxy"})
        + [{rule_set: ["geosite-category-ads-all"], action: "reject"}]')
    jq --argjson nodes "$is_sub_nodes" --argjson rule_sets "$rule_sets"         --argjson proxy_rules "$proxy_rules" --argjson no_tun "${no_tun:-false}"         -f $is_tpl_dir/jq/singbox-build.jq $is_tpl_dir/singbox.json > $out.tmp         && mv -f $out.tmp $out
}

# 订阅落地页
sub_render_index() {
    local out=$1 domain=$2 urls
    urls=$(mktemp)
    for d in $domain; do
        echo "<li><a href=\"https://$d/sub/$IS_SUB_TOKEN/\">https://$d/sub/$IS_SUB_TOKEN/</a></li>"
    done > $urls
    cp -f $is_tpl_dir/sub-index.html.tpl $out
    sub_tpl_put $out "{{DOMAIN}}" "${domain:-unknown}"
    sub_tpl_put $out "{{TOKEN}}" "$IS_SUB_TOKEN"
    sub_tpl_put $out "{{UPDATED_AT}}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    sub_tpl_put $out "{{NODE_COUNT}}" "$is_sub_count"
    sub_tpl_splice $out "{{DOMAIN_LIST}}" $urls
    rm -f $urls
}

# ---------------------------------------------------------------------------
# 对外命令
# ---------------------------------------------------------------------------

sub_gen_all() {
    xctl_need_jq
    [[ -d $is_conf_dir ]] || err "找不到配置目录: $is_conf_dir"
    IS_SUB_TOKEN=$(sub_token_get)
    sub_collect
    local dir=$is_sub_dir/$IS_SUB_TOKEN domain
    mkdir -p $dir
    chmod 755 $is_sub_dir $dir 2>/dev/null
    domain=$(sub_domains | head -n1)
    sub_render_base64 $dir/default.txt
    sub_render_clash $dir/clash.yaml
    sub_render_singbox $dir/singbox.json "${IS_SUB_NO_TUN:-false}"
    sub_render_index $dir/index.html "$domain"
    chmod 644 $dir/* 2>/dev/null
    IS_SUB_ENABLE=1
    xctl_save_env
    sub_last_dir=$dir
    [[ ! $is_dont_show_info ]] && sub_print_summary
}

sub_print_summary() {
    msg "订阅产物: $sub_last_dir"
    msg "  节点数量: $is_sub_count   分享链接: ${#is_sub_links[@]}"
    local d
    for d in $(sub_domains); do
        msg "  base64  : https://$d/sub/$IS_SUB_TOKEN/default.txt"
        msg "  Clash   : https://$d/sub/$IS_SUB_TOKEN/clash.yaml"
        msg "  sing-box: https://$d/sub/$IS_SUB_TOKEN/singbox.json"
    done
    [[ ${#is_sub_skipped[@]} -gt 0 ]] && {
        warn "以下配置被跳过:"
        for v in "${is_sub_skipped[@]}"; do msg "  - $v"; done
    }
    return 0
}

sub_info() {
    xctl_load_env
    [[ ! $IS_SUB_TOKEN ]] && err "订阅尚未启用, 请先执行: $is_core sub"
    is_dont_show_info=1
    sub_collect >/dev/null 2>&1
    msg "订阅 token: $IS_SUB_TOKEN"
    msg "产物目录  : $is_sub_dir/$IS_SUB_TOKEN"
    local d found=
    for d in $(sub_domains); do
        found=1
        _green "订阅地址 ($d):"
        msg "  Clash Meta : https://$d/sub/$IS_SUB_TOKEN/clash.yaml"
        msg "  sing-box   : https://$d/sub/$IS_SUB_TOKEN/singbox.json"
        msg "  base64     : https://$d/sub/$IS_SUB_TOKEN/default.txt"
    done
    [[ ! $found ]] && warn "没有找到带域名的节点, 订阅只能在源站本地访问; 请先执行: $is_core cdn"
    msg ""
}

sub_token_cmd() {
    local action=$1
    xctl_load_env
    case $action in
    "" | show)
        [[ ! $IS_SUB_TOKEN ]] && err "订阅尚未启用, 请先执行: $is_core sub"
        msg "订阅 token: $IS_SUB_TOKEN"
        ;;
    new)
        IS_SUB_TOKEN=$(sub_token_new_str)
        IS_SUB_ENABLE=1
        xctl_save_env
        _yellow "订阅 token 已重置: $IS_SUB_TOKEN"
        sub_gen_all
        [[ -f $is_sh_dir/src/cdn.sh ]] && {
            load cdn.sh
            cdn_sync_all
        }
        ;;
    *)
        IS_SUB_TOKEN=$action
        IS_SUB_ENABLE=1
        xctl_save_env
        _green "订阅 token 已设置为: $IS_SUB_TOKEN"
        sub_gen_all
        ;;
    esac
}

sub_main() {
    case ${1:-gen} in
    "" | gen | sync | update)
        sub_gen_all
        ;;
    info | url | show)
        sub_info
        ;;
    token)
        sub_token_cmd $2
        ;;
    off)
        xctl_load_env
        IS_SUB_ENABLE=
        xctl_save_env
        _yellow "订阅已标记为关闭 (文件保留在 $is_sub_dir)"
        ;;
    *)
        err "未知选项 ($1), 可用: $is_core sub [gen | info | token [new]]"
        ;;
    esac
}

# add / change / del 之后的自动同步钩子; 失败不影响主流程
sub_auto_sync() {
    xctl_load_env
    [[ $is_xctl_no_hook || ! $IS_SUB_TOKEN ]] && return
    local old_exit=$is_dont_auto_exit old_show=$is_dont_show_info
    is_dont_auto_exit=1
    is_dont_show_info=1
    sub_gen_all >/dev/null 2>&1
    local rc=$?
    is_dont_auto_exit=$old_exit
    is_dont_show_info=$old_show
    [[ $rc != 0 ]] && warn "订阅自动同步失败, 请手动执行: $is_core sub"
    return 0
}