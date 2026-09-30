# ============================================================================
# Clash Meta (mihomo) 客户端配置 — 由 `xray sub` 生成, 请勿手工编辑
#
# 生成时间: {{UPDATED_AT}}
# 节点数量: {{NODE_COUNT}}
#
# 这里的默认值都是有意为之, 针对实践中反复出现的故障:
#   ① ipv6: false          TUN 未接管 IPv6 时 IPv6 会绕过隧道直连, 泄漏真实 IP
#   ② allow-lan: false     避免在公共 Wi-Fi 上变成开放代理 (7890/9090 被白嫖)
#   ③ 控制口 secret        external-controller 裸奔等于把节点送人
#   ④ 兜底组首选代理       兜底若默认 DIRECT, 未命中规则的国际流量会直接泄漏
#   ⑤ 代理规则排在前面     否则 google 等域名会被后面的 CN 规则抢先匹配成直连
#   ⑥ MATCH 显式兜底       不依赖任何隐式行为
#   ⑦ 节点不带 multiplex   WS 下 mux.cool 未开 XUDP 会让 UDP 失效 → WebRTC/QUIC 泄漏
#   ⑧ DNS 分流             国内域名走国内 DoH, 其余走远端 DoH, 避免 DNS 污染与泄漏
# ============================================================================

mixed-port: 7890
socks-port: 7891
allow-lan: false            # ② 不对外暴露
bind-address: 127.0.0.1     # ② 只监听回环
mode: rule
log-level: info
ipv6: false                 # ① 全局关闭 IPv6

external-controller: 127.0.0.1:9090
secret: "{{SECRET}}"        # ③ 控制口带密码, 不能裸奔

unified-delay: true
tcp-concurrent: true
find-process-mode: strict
global-client-fingerprint: chrome
keep-alive-interval: 30

profile:
  store-selected: true
  store-fake-ip: true

geodata-mode: true
geo-auto-update: true
geo-update-interval: 24
geox-url:
  geoip: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb"

sniffer:
  enable: true
  override-destination: false
  sniff:
    HTTP:
      ports: [80, 8080-8880]
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]

dns:
  enable: true
  ipv6: false               # ① DNS 也不返回 AAAA
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.localhost"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "localhost.ptlogin2.qq.com"
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  # 解析节点域名必须用直连 DNS, 否则会绕回代理自身造成引导死循环
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
  nameserver-policy:        # ⑧ 国内域名走国内 DoH
    "geosite:cn,private":
      - https://doh.pub/dns-query
      - https://dns.alidns.com/dns-query

proxies:
{{PROXIES}}

proxy-groups:
  - name: 手动切换
    type: select
    proxies:
      - 自动选择
      - DIRECT
{{NODE_GROUP_ENTRIES}}

  - name: 自动选择
    type: url-test
    url: https://cp.cloudflare.com/generate_204
    interval: 300
    tolerance: 50
    lazy: false
    proxies:
{{NODE_GROUP_ENTRIES}}

  # ④ 兜底组第一项是「手动切换」而非 DIRECT:
  #    未命中规则的流量会跟随用户在主组里的选择走代理
  - name: 漏网之鱼
    type: select
    proxies:
      - 手动切换
      - 自动选择
      - DIRECT

rules:
  # ---- ⑤ 代理类: 必须排在 CN 直连规则之前 ----
  - GEOSITE,google,手动切换,no-resolve
  - GEOSITE,youtube,手动切换,no-resolve
  - GEOSITE,telegram,手动切换,no-resolve
  - GEOSITE,twitter,手动切换,no-resolve
  - GEOSITE,facebook,手动切换,no-resolve
  - GEOSITE,instagram,手动切换,no-resolve
  - GEOSITE,openai,手动切换,no-resolve
  - GEOSITE,anthropic,手动切换,no-resolve
  - GEOSITE,github,手动切换,no-resolve
  - GEOSITE,netflix,手动切换,no-resolve
  - GEOSITE,disney,手动切换,no-resolve
  - GEOSITE,spotify,手动切换,no-resolve
  - GEOSITE,bing,手动切换,no-resolve
  - GEOSITE,geolocation-!cn,手动切换,no-resolve

  # ---- 直连 / 拦截类 ----
  - GEOSITE,private,DIRECT,no-resolve
  - GEOIP,private,DIRECT,no-resolve
  - GEOSITE,category-ads-all,REJECT
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT

  # ⑥ 显式兜底: 未命中任何规则 → 走代理, 绝不依赖隐式行为
  - MATCH,漏网之鱼
