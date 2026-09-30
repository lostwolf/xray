# xctl 部署与使用指南

本文档介绍如何在真实生产 VPS 上使用 **xctl** 部署基于 Cloudflare CDN 回源与全自动客户端订阅的 Xray 代理节点。

---

## 1. 架构与准备工作

### 1.1 流量链路

```text
客户端 (Clash Meta / sing-box / v2rayN)
  │
  │ (1) 代理流量 (VLESS-WS-TLS)       (2) 订阅分发 (/sub/<token>/...)
  ▼                                    ▼
Cloudflare CDN (橙云 Proxied，隐藏源站真实 IP)
  │ (Full strict TLS 回源)
  ▼
源站 VPS (Caddy: 443 + Origin Certificate)
  ├── handle /<wspath>/*  ──▶ 反向代理 127.0.0.1:<local_port> (Xray VLESS-WS)
  ├── handle_path /sub/*  ──▶ 静态文件托管 /etc/xray/sub/<token>/*
  └── handle (其他路径)   ──▶ 伪装静态站 /var/www/<domain>
```

### 1.2 准备事项

1. **VPS 一台**：Debian 11/12 或 Ubuntu 22.04/24.04 (推荐)，开放 80 与 443 端口。
2. **域名一个**：已托管在 Cloudflare DNS。
3. **Cloudflare Origin Certificate** (源站证书)：
   - 登录 Cloudflare 控制台 -> 选择域名 -> **SSL/TLS** -> **Origin Server (源服务器)**。
   - 点击 **Create Certificate (创建证书)**。
   - 保持默认（RSA 2048、覆盖 `example.com` 与 `*.example.com`、15年有效期）。
   - 点击 **Create**，将生成的 **Origin Certificate** 保存为 `cert.pem`，**Private Key** 保存为 `key.pem` 并上传至 VPS。

---

## 2. 安装与一键配置

### 2.1 安装 xctl

将代码克隆到服务器或解压到 `/etc/xray/sh`，执行软链接使 `xray` 命令全局可用：

```bash
# 赋予执行权限并建立命令软链接
chmod +x /etc/xray/sh/xray.sh
ln -sf /etc/xray/sh/xray.sh /usr/local/bin/xray
```

### 2.2 一键配置 CDN 回源

假设您的域名为 `cdn.example.com`，证书文件已存放在 `/root/cert.pem` 与 `/root/key.pem`：

```bash
xray cdn cdn.example.com --cert /root/cert.pem --key /root/key.pem
```

脚本将自动执行以下操作：
1. 校验证书有效性及与私钥的配对情况，安装至 `/etc/xray/cert/cdn.example.com.{pem,key}`。
2. 自动创建仅监听在 `127.0.0.1` 本地回环的 VLESS-WS inbound（绝不向公网暴露回源端口）。
3. 自动生成订阅 Token，并预渲染好客户端 Profiles（Clash Meta、sing-box 1.14+、base64 分享链接）。
4. 部署伪装站静态资源，并配置 Caddy 站点 `/etc/caddy/sites/cdn.example.com.conf`。
5. 校验 Caddy 配置并热重载服务。
6. 打印 Cloudflare 需配合开启的配置清单。

> **提示**：若未提前准备源站证书，可添加 `--tls internal` 临时使用 Caddy 自签证书调试（此时 Cloudflare SSL 模式需选择 Full 而非 Full strict）。

---

## 3. Cloudflare 面板设置

在 Cloudflare 面板完成以下 5 项配置：

1. **DNS 记录**：
   - 类型：`A`
   - 名称：`cdn` (即 `cdn.example.com`)
   - 内容：VPS 真实公网 IP
   - 代理状态：**已代理 (橙色云朵 ☁️ Proxied)**
2. **SSL/TLS 加密模式**：
   - 切换为 **Full (strict)**（严格加密）。
3. **WebSockets 支持**：
   - 进入 **Network (网络)** -> 确保 **WebSockets** 处于 **开启 (On)** 状态。
4. **缓存规避规则 (Cache Rules)**：
   - 进入 **Caching (缓存)** -> **Cache Rules** -> 创建规则：
   - 当 URI 路径匹配 `/<wspath>*` 或 `/sub/*` 时，设置为 **Bypass Cache (绕过缓存)**。
5. **防火墙保护 (可选推荐)**：
   - 源站仅需放行 443/TCP（和 80/TCP 用于跳转）；回源端口由 Xray 自动绑定为 127.0.0.1，公网不可探针扫描。
   - 可在执行 `xray cdn` 时指定 `--cf-only`，在 Caddy 层只接受 Cloudflare 回源 IP 白名单。

---

## 4. 客户端订阅使用

执行 `xray sub` 或 `xray cdn info` 可查看生成的专属订阅地址：

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

### 客户端接入说明：

- **Clash Verge Rev / Mihomo Party / Flclash**：
  - 复制 `clash.yaml` 链接，在客户端中添加为远程订阅，更新即可。
  - 内置精选分流策略（OpenAI、Anthropic、YouTube、Google、Telegram、GitHub 等走代理，国内直连，广告拦截）。
- **sing-box (GUI / SFI / SFA / CLI)**：
  - 复制 `singbox.json` 链接导入客户端。
  - 已适配 sing-box 1.12+ / 1.14+ 路由与 DNS 规则结构，内置 TUN 自动路由接管，DNS 配置带显式 `"detour": "proxy"` 防泄漏。
  - 若客户端环境无需 TUN（如纯 SOCKS/HTTP 本地混合代理），可设置 `IS_SUB_NO_TUN=true xray sub gen` 重新生成无 TUN 的配置。
- **v2rayN / Shadowrocket / v2rayNG**：
  - 复制 `default.txt` 订阅链接，或使用生成的 URL 导入。

---

## 5. 日常运维命令速查

| 操作 | 命令 | 说明 |
|---|---|---|
| **自检诊断** | `xray cdn doctor [domain]` | 全自动检查端口、证书、反代、订阅与 CF 解析配置 |
| **查看配置** | `xray cdn info [domain]` | 查看当前域名回源信息与订阅 URL |
| **重置 Token** | `xray sub token new` | 撤销旧订阅 Token 并生成全新链接（旧链接即刻失效） |
| **重新渲染** | `xray sub gen` | 节点或规则变动后手动重新渲染订阅产物 |
| **证书重装** | `xray cdn cert <cert> <key> [domain]` | 证书到期时快速更新并比对公私钥 |
| **重建站点** | `xray cdn sync [domain]` | 重新同步 Caddyfile 与订阅配置 |
| **移除 CDN** | `xray cdn remove [domain]` | 下线该域名的 CDN 站点（保留 inbound 节点及证书） |
