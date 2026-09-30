<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>xctl 订阅</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: ui-sans-serif, system-ui, "Segoe UI", sans-serif; max-width: 720px;
         margin: 0 auto; padding: 2rem 1.25rem; line-height: 1.7; }
  code, a { word-break: break-all; }
  .card { border: 1px solid #8884; border-radius: 12px; padding: 1rem 1.25rem; margin: 1rem 0; }
  .muted { opacity: .7; font-size: .9rem; }
  ul { padding-left: 1.1rem; }
</style>
</head>
<body>
<h1>xctl 订阅</h1>
<p class="muted">节点数：{{NODE_COUNT}} · 更新时间：{{UPDATED_AT}} · token：<code>{{TOKEN}}</code></p>

<div class="card">
  <h2>订阅地址</h2>
  <ul>
    <li><a href="/sub/{{TOKEN}}/clash.yaml">Clash Meta / mihomo (clash.yaml)</a></li>
    <li><a href="/sub/{{TOKEN}}/singbox.json">sing-box 1.14+ (singbox.json)</a></li>
    <li><a href="/sub/{{TOKEN}}/default.txt">base64 分享链接 (default.txt)</a></li>
  </ul>
  <p class="muted">请把上面的 https 地址填进客户端。地址里的 token 就是密码，不要在公开场合分享。</p>
</div>

<div class="card">
  <h2>部署域名</h2>
  <ul>
{{DOMAIN_LIST}}
  </ul>
  <p class="muted">未列出的域名表示当前没有配置 CDN 站点，只有已配置的域名才能提供订阅。</p>
</div>

<div class="card">
  <h2>说明</h2>
  <ul>
    <li>订阅内容是静态文件，只通过 HTTPS 提供，不需要额外的动态后端。</li>
    <li>Clash / sing-box 里的规则顺序：代理类在前、CN 直连在后、显式兜底，DNS 已按分流配置，IPv6 默认关闭以避免泄漏。</li>
    <li>节点变化后订阅会自动重新生成；如未生效，可在服务端执行 <code>xray sub</code>。</li>
  </ul>
</div>
</body>
</html>
