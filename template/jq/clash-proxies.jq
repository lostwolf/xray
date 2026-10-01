# ============================================================================
# xctl: 节点描述符 -> Clash Meta (mihomo) proxy 对象
#
# 描述符字段见 src/sub.sh::sub_node_desc
# 输出: JSON 数组 (渲染器再转成 YAML 块序列中的 flow mapping)
# ============================================================================

def clash_proxy:
  . as $n
  # mihomo 的 ss 类型名是 "ss"; 其余协议名与 xctl 一致
  | { name: $n.name, type: (if $n.protocol == "shadowsocks" then "ss" else $n.protocol end),
      server: $n.server, port: $n.port, udp: ($n.udp // true) }
  | if $n.protocol == "shadowsocks" then
      . + { cipher: $n.cipher, password: $n.password }
    elif $n.protocol == "trojan" then
      . + { password: $n.password, "skip-cert-verify": false,
            "client-fingerprint": ($n.fingerprint // "chrome") }
      + (if ($n.sni // "") != "" then { sni: $n.sni } else {} end)
    else
      . + { uuid: $n.uuid, alterId: ($n.alterId // 0), tls: ($n.tls // false),
            "skip-cert-verify": false, "client-fingerprint": ($n.fingerprint // "chrome") }
      + (if $n.protocol == "vmess" then { cipher: "auto" } else {} end)
      + (if ($n.sni // "") != "" then { servername: $n.sni } else {} end)
    end
  # reality / vision: flow 只在 reality 场景设置 (WS 下带 flow 会被 mihomo 拒绝)
  | (if ($n.reality // false) then
       . + { "reality-opts": { "public-key": $n.publicKey, "short-id": ($n.shortId // "") },
             flow: ($n.flow // "xtls-rprx-vision") }
     elif ($n.flow // "") != "" and ($n.network // "tcp") == "tcp" then
       . + { flow: $n.flow }
     else . end)
  # 传输层
  | (if $n.network == "ws" then
       . + { network: "ws",
             "ws-opts": ( { path: ($n.path // "/") }
                          + (if ($n.host // "") != "" then { headers: { Host: $n.host } } else {} end) ) }
     elif $n.network == "grpc" then
       . + { network: "grpc", "grpc-opts": { "grpc-service-name": ($n.serviceName // $n.path // "") } }
     elif $n.network == "xhttp" then
       # 过 CDN 场景用兼容性最高的 packet-up; host 与 TLS servername 是不同字段
       . + { network: "xhttp",
             "xhttp-opts": ( { path: ($n.path // "/"), mode: ($n.xhttpMode // "packet-up") }
                          + (if ($n.host // "") != "" then { host: $n.host } else {} end) ) }
     elif $n.network == "tcp" and ($n.headerType // "none") == "http" then
       # VMess-TCP http 伪装 -> mihomo network: http (CF 可当普通 HTTP 回源, 也能套 CDN)
       . + { network: "http",
             "http-opts": ( { path: [ ($n.path // "/") ] }
                          + (if ($n.host // "") != "" then { headers: { Host: [ $n.host ] } } else {} end) ) }
     else
       # reality 属于 TLS 层而非传输层: mihomo 只认 network tcp (默认)
       . + { network: (if ($n.network // "tcp") == "reality" then "tcp" else ($n.network // "tcp") end) }
     end)
  | with_entries(select(.value != null));

map(clash_proxy)
