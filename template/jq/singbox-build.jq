# ============================================================================
# xctl: 节点描述符 -> sing-box outbound, 并按模板重组完整 profile
#
# 契约 (见 template/singbox.README.md):
#   · 每个节点使用唯一 tag (node-1 / node-2 / ...)
#   · 模板里的 route.final / dns.detour / download_detour 都指向 tag "proxy"
#   · 因此这里统一生成一个 selector "proxy" 包住所有节点
#   · 节点 server 若是域名, 通过 domain_resolver=dns-cn 直连解析, 避免
#     "DNS 走代理 -> 解析不了代理域名" 的引导死循环
# ============================================================================

def sb_tls:
  if (.tls // false) then
    { tls: (
        { enabled: true, server_name: (.sni // "") }
        + (if (.reality // false)
           # sing-box 要求 reality 客户端必须启用 uTLS
           then { utls: { enabled: true, fingerprint: (.fingerprint // "chrome") },
                  reality: { enabled: true, public_key: .publicKey, short_id: (.shortId // "") } }
           else { utls: { enabled: true, fingerprint: (.fingerprint // "chrome") } }
           end)
      ) }
  else {} end;

def sb_transport:
  if .network == "ws" then
    { transport: ({ type: "ws", path: (.path // "/") }
        + (if (.host // "") != "" then { headers: { Host: .host } } else {} end)) }
  elif .network == "grpc" then
    { transport: { type: "grpc", service_name: (.serviceName // .path // "") } }
  elif .network == "xhttp" then
    ({ transport: { type: "xhttp", path: (.path // "/"), mode: (.xhttpMode // "packet-up") } }
        + (if (.host // "") != "" then { host: .host } else {} end))
  elif .network == "reality" then
    # REALITY 只能走 TCP (无 transport); SNI/公钥在 sb_tls 的 reality 分支里
    {}
  elif .network == "tcp" and (.headerType // "none") == "http" then
    # VMess-TCP http 伪装 -> sing-box vmess.transport: http (可过普通 HTTP CDN 回源)
    { transport: ({ type: "http", path: (.path // "/") }
        + (if (.host // "") != "" then { headers: { Host: .host } } else {} end)) }
  else {} end;

def sb_outbound:
  . as $n
  | { type: $n.protocol, tag: $n.name, server: $n.server, server_port: $n.port,
      domain_resolver: "dns-cn" }
  + (if $n.protocol == "shadowsocks" then { method: $n.cipher, password: $n.password }
     elif $n.protocol == "trojan" then { password: $n.password }
     elif $n.protocol == "vmess" then { uuid: $n.uuid, security: "auto", alter_id: ($n.alterId // 0) }
     else { uuid: $n.uuid }
          # REALITY + vision: flow 必须带; 普通 TLS 直连 vision 场景也保留 (上游只在此处输出 flow)
          + (if ($n.flow // "") != "" then { flow: $n.flow } else {} end)
     end)
  + ($n | sb_tls)
  + ($n | sb_transport);

def sb_inbound($no_tun):
  if $no_tun then
    [ { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080 } ]
  else
    [ { type: "tun", tag: "tun-in", address: ["172.19.0.1/30"], mtu: 9000,
        auto_route: true, strict_route: true, stack: "mixed" },
      { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080 } ]
  end;

# 输入: 模板 profile (.), 参数: $nodes / $rule_sets / $proxy_rules / $no_tun
($nodes | map(.name)) as $tags
| ($tags + ["direct"]) as $sel_opts
| .inbounds = sb_inbound($no_tun)
| .outbounds = (($nodes | map(sb_outbound)) + [
    { type: "selector", tag: "proxy", outbounds: $sel_opts, default: ($tags[0] // "direct") },
    { type: "urltest", tag: "auto", outbounds: $tags,
      url: "https://cp.cloudflare.com/generate_204", interval: "5m", tolerance: 50 },
    { type: "direct", tag: "direct" }
  ])
| .route.rule_set = (($rule_sets + .route.rule_set) | unique_by(.tag))
| .route.rules = (.route.rules[0:2] + $proxy_rules + .route.rules[2:])
| .
