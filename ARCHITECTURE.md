# xctl 架构设计文档

本文档详细描述 **xctl** 的整体架构设计、模块边界、关键技术决策与系统实现。

---

## 1. 目标与非目标

### 目标

在原生 Xray 协议平台之上构建生产级基础设施增强，重点解决两块核心需求：

1. **Cloudflare CDN 回源全自动化**：解决回源 TLS 证书（Origin Certificate）自动签发与安装、Caddy 前端反代配置，以及源站端口强制本地回环隔离（防止扫描探测）。
2. **客户端订阅生成与静态托管**：提供生产级标准客户端 Profile（Clash Meta / sing-box 1.14+ / base64），与代理共用边缘通道分发，杜绝信息泄漏。

### 非目标

- 不重复实现复杂的底层协议加解密（全部委托给 Xray Core 负责）。
- 不引入重型 Web 框架或动态数据库（订阅与站点服务采用全静态文件 + Caddy 高性能托管）。
- 不做重量级 Panel / GUI 后台，保持轻量高效的 CLI 运维体验。

---

## 2. 系统拓扑与流量链路

```text
┌─────────────────────────────────────────────────────────────┐
│                        客户端                                 │
│   Clash Meta / sing-box / v2rayN                            │
│         │                                    │              │
│         │ ① 代理流量 (VLESS+WS+TLS)           │ ② 订阅拉取    │
└─────────┼────────────────────────────────────┼──────────────┘
          ▼                                    ▼
┌─────────────────────────────────────────────────────────────┐
│                    Cloudflare CDN (橙云 Proxied)              │
│   · 隐藏源站真实 IP      · 边缘 TLS 终止                     │
│   · SSL 模式 = Full (strict) → 通过 15年 Origin Cert 回源    │
└─────────┬────────────────────────────────────┬──────────────┘
          ▼                                    ▼
┌─────────────────────────────────────────────────────────────┐
│                      源站 VPS : 443 (Caddy)                   │
│                                                              │
│   handle /<wspath>/*   ──reverse_proxy──▶ 127.0.0.1:<port>   │
│                                           ┌──────────────┐  │
│                                           │  Xray Core   │  │
│                                           └──────────────┘  │
│   handle_path /sub/*   ──file_server──▶ /etc/xray/sub/      │
│   handle /*            ──file_server──▶ /var/www/<domain>   │
└─────────────────────────────────────────────────────────────┘
```

### 核心设计洞察

- **单站点多 Handle 共享**：代理回源流量与客户端订阅拉取走 **同一域名同一 443 站点的不同 Handle**。订阅分发天然继承 Cloudflare 的边缘加速、DDoS 防护、TLS 终结与源站 IP 隐藏，不需要为订阅额外开放新端口或申请额外证书。
- **强制仅监听回环**：当配置绑定域名时，Inbound 严格限定监听在 `127.0.0.1`，公网不可直连该端口，彻底阻断 GFW / 探针扫源站真实 IP 的隐患。

---

## 3. 核心子系统设计

### 3.1 CDN 回源自动化 (`src/cdn.sh`)

- **功能**：一键生成回源节点、配置证书、生成 Caddy 站点并打印 Cloudflare 设置清单。
- **Inbound 隔离**：调用底层配置生成器，生成 `network=ws`、`security=none`、`listen=127.0.0.1` 的 VLESS Inbound。
- **站点自动写入**：向 `/etc/caddy/sites/<domain>.conf` 输出配置，并使用 `handle_path` 精准剥离前缀提供订阅文件，末尾配置静态伪装站兜底。
- **健康自检 (`xray cdn doctor`)**：自动核验端口占用、本地回环绑定、证书有效性、Caddy 语法及解析连通性。

### 3.2 证书管理与自动签发 (`src/cert.sh`)

- **Cloudflare API 自动签发**：
  - 本地生成 2048 位 RSA 密钥与包含主域名及泛域名的 CSR。
  - 调用 Cloudflare Origin CA API (`/client/v4/certificates`) 签发并自动下载 15 年长效源站证书。
- **自定义证书导入**：
  - 自动运行 `openssl` 校验私钥与公钥的模数哈希是否匹配（`cert_check_pair`）。
  - 自动检查 Subject Alternative Name (SAN) 是否覆盖目标域名（`cert_covers_domain`）。
- **极速自签模式**：
  - 支持 `--tls internal`，由 Caddy 本地生成自签证书用于快速调试。

### 3.3 客户端订阅子系统 (`src/sub.sh`)

- **Token 隔离与鉴权**：生成 16 字节安全随机字符串作为 URL Token，实现零后端的高性能静态分发。
- **多端 Profile 自动渲染**：
  - `default.txt`：标准 Base64 编码的分享链接集合。
  - `clash.yaml`：Clash Meta / mihomo 完整配置，预置 GEO 分流策略组与兜底代理规则。
  - `singbox.json`：适配 sing-box 1.14+ 现代规则集（`rule_set`）与 DNS Detour 显式指定。
  - `index.html`：美观现代的静态 Web 导航落地页。
- **自动同步钩子 (`xctl_hook`)**：在节点增删或修改端口后，触发订阅 Profile 异步重新渲染，确保客户端获取的内容始终最新。

---

## 4. 目录与文件布局

```text
xctl/
├── README.md                # 项目介绍与快速上手
├── ARCHITECTURE.md          # 架构设计与技术决策
├── doc/
│   └── DEPLOY.md            # 生产环境完整部署运维指南
├── xray.sh                  # 主 CLI 入口
├── src/
│   ├── init.sh              # 全局初始化与环境变量
│   ├── core.sh              # 核心配置分发与状态管理
│   ├── cdn.sh               # CDN 回源自动化
│   ├── cert.sh              # 证书管理与 CF API 签发
│   ├── sub.sh               # 订阅生成与模板组装
│   ├── caddy.sh             # Caddy 站点管理
│   ├── help.sh              # CLI 帮助与关于信息
│   └── ...
├── template/
│   ├── clash.yaml.tpl       # Clash Meta 模板
│   ├── singbox.json         # sing-box 基础配置文件
│   ├── sub-index.html.tpl   # 订阅静态落地页模板
│   ├── site.index.html      # 伪装站点默认页面
│   └── jq/                  # 模板 JSON/YAML 转换规则
└── tests/
    ├── e2e.sh               # 48 项全覆盖沙箱 E2E 测试套件
    └── fetch-bins.sh        # 测试辅助二进制获取脚本
```

---

## 5. 关键安全考量

1. **防 DNS 泄漏**：在 sing-box 1.14+ 模板中，直连 DNS 显式指向国内权威 DNS（223.5.5.5），代理 DNS 显式绑定 `detour: "proxy"`，防止客户端发起 DNS 解析时泄露访问目标。
2. **防 IPv6 泄漏**：在 TUN 路由接管配置中，禁用未经由代理封装的 IPv6 直连通道。
3. **节点 Multiplex 策略**：默认关闭 `mux.cool`，避免在 CDN + WebSocket 场景下因 UDP 映射失败导致 WebRTC / QUIC 直连穿透。
4. **回源端口零外露**：所有走 CDN 的节点仅侦听 `127.0.0.1`，公网端口只放行 443 与 80，彻底免除端口探测封锁。
