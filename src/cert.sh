#!/bin/bash
# ============================================================================
# xctl: 源站证书管理 (src/cert.sh)
#
# 负责 Cloudflare Origin Certificate / 任意 PEM 证书的校验与安装:
#   · cert_check_pair        证书与私钥是否配对 (RSA / ECDSA 都支持)
#   · cert_covers_domain     证书是否覆盖目标域名 (含 *.example.com 通配)
#   · cert_days_left         剩余有效天数
#   · cert_install           校验 + 安装到 $is_cert_dir/<domain>.{pem,key}
#   · cert_selfsign          生成自签证书 (仅调试, CF 模式必须用 Full 而非 strict)
# ============================================================================

# 证书与私钥是否配对
cert_check_pair() {
    local cert=$1 key=$2 a b
    [[ -f $cert ]] || { _red "证书文件不存在: $cert"; return 1; }
    [[ -f $key ]] || { _red "私钥文件不存在: $key"; return 1; }
    a=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl dgst -sha256 2>/dev/null)
    b=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl dgst -sha256 2>/dev/null)
    [[ ! $a || ! $b ]] && { _red "无法解析证书或私钥 (不是有效的 PEM?)"; return 1; }
    [[ $a == "$b" ]] || { _red "证书与私钥不匹配"; return 1; }
    return 0
}

# 证书概要
cert_meta() {
    local cert=$1
    openssl x509 -in "$cert" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/    /'
}

# 剩余有效天数, 失败返回 -1
cert_days_left() {
    local cert=$1 end
    end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)
    [[ ! $end ]] && { echo -1; return 1; }
    echo $(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
}

# 证书是否覆盖域名
cert_covers_domain() {
    local cert=$1 domain=$2 names n
    names=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr ',' '\n' | sed 's/^ *//;s/DNS://g;s/IP Address://g')
    [[ ! $names ]] && names=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | grep -o 'CN *= *[^,]*' | cut -d= -f2 | tr -d ' ')
    for n in $names; do
        [[ $n == "$domain" ]] && return 0
        [[ $n == "*."* && "${domain#*.}" == "${n#*.}" ]] && return 0
    done
    return 1
}

# 是否 Cloudflare Origin Certificate
cert_is_origin() {
    local cert=$1 issuer
    issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null)
    [[ $issuer == *Cloudflare* || $issuer == *"Origin SSL"* ]]
}

# 校验并安装证书
cert_install() {
    local src_cert=$1 src_key=$2 domain=$3 days
    type -P openssl &>/dev/null || err "缺少 openssl, 请先安装"
    [[ ! $domain ]] && err "安装源站证书需要指定域名: $is_core cdn cert <cert> <key> <domain>"
    cert_check_pair "$src_cert" "$src_key" || return 1
    cert_covers_domain "$src_cert" "$domain" || warn "证书 SAN 未覆盖域名 ($domain), Cloudflare Full (strict) 回源会失败."
    mkdir -p $is_cert_dir
    cp -f "$src_cert" $is_cert_dir/$domain.pem
    cp -f "$src_key" $is_cert_dir/$domain.key
    chmod 644 $is_cert_dir/$domain.pem
    chmod 600 $is_cert_dir/$domain.key
    _green "源站证书已安装:"
    cert_meta $is_cert_dir/$domain.pem
    days=$(cert_days_left $is_cert_dir/$domain.pem)
    msg "剩余有效天数: $days"
    cert_is_origin "$src_cert" && _green "识别为 Cloudflare Origin Certificate → CF SSL 模式请选 Full (strict)."
    return 0
}

# 生成自签证书
cert_selfsign() {
    local domain=$1
    type -P openssl &>/dev/null || err "缺少 openssl, 请先安装"
    [[ ! $domain ]] && err "生成自签证书需要指定域名"
    mkdir -p $is_cert_dir
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout $is_cert_dir/$domain.key -out $is_cert_dir/$domain.pem \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain,DNS:*.$domain" &>/dev/null \
        || openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
            -keyout $is_cert_dir/$domain.key -out $is_cert_dir/$domain.pem \
            -subj "/CN=$domain" &>/dev/null
    [[ -f $is_cert_dir/$domain.pem ]] || err "生成自签证书失败"
    chmod 600 $is_cert_dir/$domain.key
    _green "已生成自签证书: $is_cert_dir/$domain.pem"
    _yellow "Cloudflare SSL 模式只能用 Full, 不能用 Full (strict). 生产环境请改用 Origin Certificate."
}

# 通过 Cloudflare Origin CA API 自动签发并下载 15 年源站证书
# 支持 Origin CA Key (v1.0-...) 或 User API Token
cert_cf_api() {
    local domain=$1 token=$2 tmp_dir req_json resp success cert_content
    type -P openssl &>/dev/null || err "缺少 openssl, 请先安装"
    xctl_need_jq
    [[ ! $domain ]] && err "用法: $is_core cert cf <domain> <api_token_or_origin_key>"
    [[ ! $token ]] && err "缺少 Cloudflare API Token 或 Origin CA Key"

    _yellow "正在为域名 ($domain) 生成 RSA 密钥对与 CSR..."
    tmp_dir=$(mktemp -d)
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$tmp_dir/key.pem" -out "$tmp_dir/csr.pem" \
        -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain,DNS:*.$domain" &>/dev/null \
        || openssl req -new -newkey rsa:2048 -nodes \
            -keyout "$tmp_dir/key.pem" -out "$tmp_dir/csr.pem" \
            -subj "/CN=$domain" &>/dev/null

    local csr_str
    csr_str=$(cat "$tmp_dir/csr.pem")
    req_json=$(jq -n \
        --arg csr "$csr_str" \
        --arg d "$domain" \
        --arg wildcard "*.$domain" \
        '{hostnames: [$d, $wildcard], requested_validity: 5475, request_type: "origin-rsa", csr: $csr}')

    _yellow "调用 Cloudflare Origin CA API 签发 15 年证书..."
    if [[ $token == v1.0* ]]; then
        resp=$(curl -s --noproxy '*' -X POST "https://api.cloudflare.com/client/v4/certificates" \
            -H "X-Auth-User-Service-Key: $token" \
            -H "Content-Type: application/json" \
            --data "$req_json")
    else
        resp=$(curl -s --noproxy '*' -X POST "https://api.cloudflare.com/client/v4/certificates" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            --data "$req_json")
    fi

    success=$(jq -r '.success // false' <<<"$resp" 2>/dev/null)
    if [[ $success != "true" ]]; then
        local err_msg
        err_msg=$(jq -r '.errors[0].message // .messages[0] // "请求失败"' <<<"$resp" 2>/dev/null)
        _red "Cloudflare 证书签发失败: $err_msg"
        rm -rf "$tmp_dir"
        return 1
    fi

    jq -r '.result.certificate' <<<"$resp" > "$tmp_dir/cert.pem"
    cert_install "$tmp_dir/cert.pem" "$tmp_dir/key.pem" "$domain"
    local rc=$?
    rm -rf "$tmp_dir"
    return $rc
}
