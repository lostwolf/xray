# xctl

> 生产级 Xray 运维与增强工具，专注于 **Cloudflare CDN 回源自动化** 与 **全协议客户端订阅托管**。

---

## 🌟 核心特性

- **🖥 现代化交互管理面板**
  - 直接运行 `xray` 进入终端面板：顶部实时汇总 Xray / Caddy 运行态、节点数、CDN 站点明细、订阅状态与 BBR。
  - CDN 回源、订阅管理、doctor 自检等 xctl 全部能力收录进菜单，不再需要背命令。
  - 每个动作执行完自动重载面板，状态永远最新；空目录、无 CDN 站点等场景有友好引导。

- **🛡️ 纯回环源站安全架构**
  - 有域名时 inbound 自动强制绑定 `127.0.0.1`，回源端口绝不向公网暴露，避免端口扫描与真实 IP 暴露。
  - 支持 `--cf-only` Caddy 回源白名单，仅放行 Cloudflare 官方 IP。

- **🔐 证书多维度自动化**
  - **Cloudflare API 全自动签发**：无需登录控制台手动点击，提供 API Token 或 Origin CA Key 即可全自动生成私钥/CSR、调用 API 签发并安装 **15 年超长有效期 Origin Certificate**。
  - **手工证书安装校验**：支持导入自定义 PEM 证书并由 `openssl` 自动执行私钥配对校验与 SAN 域名覆盖检查。
  - **免配置自签模式**：内置 `--tls internal` 零门槛测试模式，秒级启动。

- **📦 完整客户端订阅托管（静态化）**
  - 代理流量与订阅拉取共用 **Caddy 统一站点的不同 handle**，订阅天然继承 Cloudflare 边缘 TLS 加速与源站 IP 隐藏。
  - **Clash Meta (mihomo)**：全自动化渲染完整 Profile，预置国内直连、广告拦截、AI 平台分流与自动测速选择；支持 WS / gRPC / **XHTTP** 传输。
  - **sing-box 1.14+**：适配最新 rule_set 远程规则集与 DNS `detour: "proxy"` 显式防泄漏机制，内置 TUN 路由接管。
  - **标准订阅与落地页**：自动生成 `default.txt` (base64) 与友好的 Web 订阅导航落地页。
  - 注意：官方 sing-box 尚未支持 XHTTP 传输（仅第三方 fork 支持），XHTTP 节点会渲染进 Clash 订阅与 base64 分享链接，sing-box Profile 自动跳过该节点。

- **🧪 严格的 E2E 自动化测试**
  - 内置基于沙箱的端到端测试套件，在无 root / 无宿主干扰的隔离环境中对真实的 Xray、Caddy、sing-box、mihomo 链路执行 48 项全覆盖验证。

---

## 🚀 快速上手

### 1. 一键安装（推荐）

在干净的 VPS（Debian 10+ / Ubuntu 20.04+ / CentOS 8+ / Alpine）上，直接以 root 身份执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lostwolf/xray/main/install.sh)
```

或使用 `wget`：

```bash
wget -qO- https://raw.githubusercontent.com/lostwolf/xray/main/install.sh | bash
```

> **自动完成**：系统依赖、最新官方 Xray Core、Caddy 二进制下载、GeoIP/GeoSite 路由库、systemd 守护进程注册及基础环境初始化。

安装完成后，直接运行：

```bash
xray
```

即可进入交互管理面板（无参数时的默认行为）；也可以继续使用下面的命令行方式。

### 2. 方式 A：通过 Cloudflare API 一键全自动配置（推荐）

只需准备好你的域名（例如 `cdn.example.com`）和 Cloudflare API Token（或 Origin CA Key）：

```bash
xray cdn cdn.example.com --cf-token "YOUR_CLOUDFLARE_TOKEN_OR_KEY"
```

> 脚本将自动在本地生成私钥与 CSR、请求 Cloudflare API 签发 15 年 Origin Certificate、配置回环 VLESS-WS 节点、生成 Caddy 站点与订阅 Profile。

**迁移到 XHTTP（官方推荐，替代已弃用的 WS）**：加 `--net xhttp` 即可，回源走 h2c，客户端用兼容性最高的 packet-up 模式过 CDN：

```bash
xray cdn cdn.example.com --net xhttp --cf-token "YOUR_CLOUDFLARE_TOKEN_OR_KEY"
```

> XHTTP 迁移注意：① Cloudflare 控制台需开启 **gRPC**（Network → gRPC）；② 间歇断流时可把 profile 里 `xhttp-opts.mode` 换成 `auto`；③ 官方 sing-box 暂不支持 XHTTP，Clash Meta (mihomo) 与 Xray 官方客户端可正常使用。

### 3. 方式 B：使用已在 CF 控制台下载的证书

若已在 Cloudflare 面板下载好源站证书（`cert.pem` 与 `key.pem`）：

```bash
xray cdn cdn.example.com --cert /root/cert.pem --key /root/key.pem
```

### 4. 方式 C：零证书极速体验（调试用）

```bash
xray cdn cdn.example.com --tls internal
```
*(注意：此模式 Cloudflare 控制台 SSL 模式需设置为 Full 而非 Full strict)*

---

## ⚙️ Cloudflare 控制台配套设置

完成服务器配置后，在 Cloudflare 仪表盘确认以下 4 点：

1. **DNS**：添加 `A` 记录指向 VPS IP，开启 **橙色云朵 (Proxied)**。
2. **SSL/TLS**：加密模式切换为 **Full (strict)**（如使用 `--tls internal` 则选 **Full**）。
3. **Network (网络)**：确保 **WebSockets** 处于开启状态。
4. **Cache Rules (缓存规则)**：对 `/<wspath>*` 及 `/sub/*` 路径配置 **Bypass Cache (绕过缓存)**。

---

## 📲 客户端订阅获取

运行以下命令即可查看当前的专属订阅地址与 Token：

```bash
xray sub
```

输出示例：
```text
订阅 token: 65118107d1572ed206a3d1c26e76423f
产物目录  : /etc/xray/sub/65118107d1572ed206a3d1c26e76423f
订阅地址 (cdn.example.com):
  Clash Meta : https://cdn.example.com/sub/65118107d1572ed206a3d1c26e76423f/clash.yaml
  sing-box   : https://cdn.example.com/sub/65118107d1572ed206a3d1c26e76423f/singbox.json
  base64     : https://cdn.example.com/sub/65118107d1572ed206a3d1c26e76423f/default.txt
```

直接将对应的链接填入 Clash Verge Rev、Mihomo Party、sing-box GUI 或 Shadowrocket 即可一键更新使用。

---

## 🛠️ CLI 命令速查

```text
xctl 扩展命令:
  cdn [domain] [options]        配置 Cloudflare CDN 回源 (WS + 源站证书 + Caddy)
  cdn info [domain]             查看当前 CDN 配置与 Cloudflare 清单
  cdn doctor [domain]           自检源站端口、证书、反代、订阅与 CF 解析状态
  cdn sync [domain]             重新同步生成 Caddy 站点配置与客户端订阅
  cdn remove [domain]           安全移除 CDN 站点反代 (保留 inbound 节点)
  
  sub [gen]                     手动重新生成全部订阅产物
  sub info                      查看订阅地址与当前 Token
  sub token new                 重置订阅 Token（旧链接立即失效）
  sub off                       关闭订阅分发

  cert cf <domain> <key>        调用 Cloudflare API 自动签发并下载 15 年 Origin 证书
  cert info <domain>            查看已安装源站证书详细信息与有效期
  cert self <domain>            为域名生成自签证书 (调试用)
```

上游所有原有指令（如 `xray add`, `xray change`, `xray del`, `xray status`, `xray bbr` 等）均完整保留且无缝兼容。

---

## 🏗️ 架构说明与深度文档

详细架构决策、协议映射陷阱与生产部署细节，请参阅：
- [ARCHITECTURE.md](./ARCHITECTURE.md) —— 整体架构设计方案
- [doc/DEPLOY.md](./doc/DEPLOY.md) —— 生产环境完整部署运维指南
- [template/singbox.README.md](./template/singbox.README.md) —— sing-box 1.14+ 路由配置解析

---

## 🧪 自动化测试

本项目配有端到端测试套件，可以在非 root 环境直接运行：

```bash
bash tests/e2e.sh         # WS 回源全链路 (48 项)
bash tests/e2e-xhttp.sh   # XHTTP 回源全链路 (26 项)
```

---

## 📄 开源许可

- 本项目遵循 GPL-3.0 协议开源。
