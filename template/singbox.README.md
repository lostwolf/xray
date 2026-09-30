# sing-box 模板说明

## 目标版本

**sing-box v1.14.2**（2026-09-24 发布，当时最新 stable）。

## 格式依据

官方站点 `docs.sing-box.sagernet.org` 默认跟的是 dev 分支（1.15.0-alpha），
因此本项目对照的是 **v1.14.2 tag 下的文档源文件**。

- 迁移与废弃说明：https://sing-box.sagernet.org/migration/ · https://sing-box.sagernet.org/deprecated/
- DNS：https://sing-box.sagernet.org/configuration/dns/ · `/dns/server/` · `/dns/server/https/`
- 路由：https://sing-box.sagernet.org/configuration/route/ · `/route/rule_action/`
- TUN：https://sing-box.sagernet.org/configuration/inbound/tun/
- 规则集：https://sing-box.sagernet.org/configuration/rule-set/

## 五个必须知道的格式变化

1. **DNS server 老写法已移除。**
   `{"address":"https://1.1.1.1/dns-query"}` 在 **1.14.0 被彻底移除**，不是"仍兼容"。
   新写法：`{"type":"https","server":"1.1.1.1"}`（默认 `path=/dns-query`、`port=443`）。

2. **`detour` 语义变了 —— 这是最容易踩的坑。**
   新格式的 DNS server 默认等价于空 direct outbound，**走代理 DNS 必须显式写 `"detour":"proxy"`**。
   漏写 = DNS 全部直连泄漏。模板里的 `dns-proxy` 已显式指定。

3. **`route.rules` 统一走 `action`。**
   规则级 `outbound` 自 1.11 废弃。正确写法：
   `{"action":"route","outbound":"direct"}`、`{"action":"sniff"}`、
   `{"protocol":"dns","action":"hijack-dns"}`、`{"action":"resolve",...}`。

4. **`dns.strategy` 取值**：`prefer_ipv4` / `prefer_ipv6` / `ipv4_only` / `ipv6_only`。
   本模板用 **`ipv4_only`** 以避免 IPv6 泄漏。

5. **TUN**：`address`（数组）/ `auto_route` / `strict_route` / `stack` 在 1.14.2 均有效。
   ⚠️ **1.15.0 起 `stack` 字段废弃**（sing-tun 自研栈，直接删该字段）。
   升级到 1.15+ 时需去掉 `"stack": "mixed"`。

## 占位符契约（渲染器必须遵守，否则 sing-box 启动失败）

`route.final`、`dns.servers[dns-proxy].detour`、两个 `rule_set[].download_detour`
**全部指向 tag `proxy`**。因此注入片段必须满足：

### 正确做法：节点用唯一 tag，再用一个 selector 包成 `proxy`

```json
{
  "type": "vless", "tag": "node-1", ...
},
{
  "type": "vless", "tag": "node-2", ...
},
{
  "type": "selector",
  "tag": "proxy",
  "outbounds": ["node-1", "node-2"],
  "default": "node-1"
}
```

- 每个节点 tag 必须**唯一**（建议 `node-1` / `node-2` / … 或节点摘要）
- `proxy` 这个 tag **全片段只出现一次**，挂在 selector 或 urltest 上
- 多节点时也可以用 `{"type":"urltest","tag":"proxy","outbounds":[...],"url":"https://cp.cloudflare.com/generate_204","interval":"5m"}`

### 禁止做法

- ❌ 每个节点都叫 `proxy` → 重复 tag，sing-box 直接报错退出
- ❌ 片段自行定义 `direct` → 模板已有，会重复
- ❌ 片段以逗号结尾 → 模板占位符后已给逗号，会变成双逗号

### 位置

`{{OUTBOUNDS}}` 位于 `outbounds` 数组内，模板已在其后给了逗号，
注入 `{...},\n{...},\n{...}` 后可直接接上模板自带的 `{"type":"direct","tag":"direct"}`。

## 已知废弃项（后续升级要处理）

| 字段 | 状态 | 建议 |
|---|---|---|
| `dns.independent_cache` | 1.14.0 废弃，1.16.0 移除（缓存现按 transport 分键，该字段已无实际效果） | 保留仅因 1.14.2 接受；后续删除 |
| `rule_set[].download_detour` | 1.14.0 废弃，1.16.0 移除 | 替代方案：顶层 `http_clients` + `route.default_http_client` |
| `inbounds[].stack` | 1.15.0 起废弃 | 升级到 1.15+ 时删除该字段 |

## 未实机验证的部分

本模板的验证只到 **JSON 结构 + 官方文档** 层面，环境内没有 sing-box 二进制，
**未跑过 `sing-box check`**。首次部署时请务必：

```bash
sing-box check -c /path/to/generated.json
```

另需注意两点：

1. `stack: "mixed"` 依赖 gVisor 构建标签。官方 release 二进制带 `with_gvisor` 可用；
   精简包 / 部分 OpenWrt 构建可能不可用 —— 那种情况下改用 `"stack": "system"`。
2. `dns.rules` 引用 `geosite-cn`（域名型规则集）理论合规，但未核对 `.srs` 内是否混入
   `ip_cidr` 条目。若启动报错，把该 DNS 规则换成显式 `domain_suffix` 列表。
