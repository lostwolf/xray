#!/bin/bash
# ============================================================================
# xctl 端到端验证 (tests/e2e.sh)
#
# 目标: 在完全隔离的沙箱里跑通真实链路, 不需要 root, 不碰 /etc 与 systemd:
#
#   客户端 --(SOCKS)--> Xray client --(VLESS+WS+TLS)--> Caddy(源站 443 等价端口)
#                                                          |
#                                                          +--> 127.0.0.1:<回源端口> Xray server
#   客户端 --(HTTPS)--> Caddy /sub/<token>/(clash.yaml | singbox.json | default.txt)
#
# 所有产物都在 $WORK 下, 结束时只杀后台进程 (保留目录便于排查).
# 用法: bash tests/e2e.sh
# ============================================================================
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/.e2e/bin
WORK=$ROOT/.e2e/run
PREFIX=$WORK/prefix
DOMAIN=e2e.test
HTTP_PORT=18080
HTTPS_PORT=18443
ORIGIN_PORT=19555
API_PORT=19090
SOCKS_PORT=21080
ECHO_PORT=28080

unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
export no_proxy='*' NO_PROXY='*'

PASS=0
FAIL=0
XRAY_PID=
CADDY_PID=
ECHO_PID=

ok() { printf '  \033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
has() { # 描述, 命令...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

cleanup() {
    [[ $ECHO_PID ]] && kill $ECHO_PID 2>/dev/null
    [[ $XRAY_PID ]] && kill $XRAY_PID 2>/dev/null
    [[ $CADDY_PID ]] && kill $CADDY_PID 2>/dev/null
    wait 2>/dev/null
    return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
info "0. 依赖"
for b in xray caddy sing-box mihomo jq; do
    [[ -x $BIN/$b ]] || "$ROOT/tests/fetch-bins.sh" >/dev/null 2>&1
done
for b in xray caddy sing-box mihomo jq; do
    if [[ -x $BIN/$b ]]; then ok "二进制就绪: $b"; else bad "缺少二进制: $b (先跑 tests/fetch-bins.sh)"; exit 1; fi
done

# ---------------------------------------------------------------------------
info "1. 搭建沙箱前缀"
rm -rf "$WORK"
mkdir -p "$PREFIX/etc/xray/bin" "$PREFIX/etc/xray/conf" "$PREFIX/etc/caddy/xctl" \
         "$PREFIX/etc/caddy/sites" "$PREFIX/etc/caddy/storage" "$PREFIX/var/log/xray" \
         "$PREFIX/usr/local/bin" "$PREFIX/var/www" "$PREFIX/tmp" "$PREFIX/etc/xray/sh/tools"
cp -f "$BIN/xray" "$PREFIX/etc/xray/bin/xray"
cp -f "$BIN/caddy" "$PREFIX/usr/local/bin/caddy"
cp -f "$ROOT/xray.sh" "$PREFIX/etc/xray/sh/xray.sh"
cp -rf "$ROOT/src" "$ROOT/template" "$PREFIX/etc/xray/sh/"
cp -f "$ROOT/tools/jq" "$PREFIX/etc/xray/sh/tools/jq"
# Xray 需要 geoip.dat / geosite.dat (安装时也放在 bin 目录)
cp -f "$BIN/geoip.dat" "$BIN/geosite.dat" "$PREFIX/etc/xray/bin/"
export XRAY_LOCATION_ASSET=$PREFIX/etc/xray/bin
export XCTL_PREFIX=$PREFIX
export XCTL_ASSUME_CADDY=1
export XCTL_NO_RESTART=1
export PATH=$BIN:$PATH
ok "沙箱前缀: $PREFIX"

cat >"$PREFIX/etc/caddy/Caddyfile" <<EOF
{
	admin off
	http_port $HTTP_PORT
	https_port $HTTPS_PORT
	default_bind 127.0.0.1
	auto_https disable_redirects
	storage file_system $PREFIX/etc/caddy/storage
}
import $PREFIX/etc/caddy/xctl/*.conf
import $PREFIX/etc/caddy/sites/*.conf
EOF

# 自签源站证书 (在这个测试里扮演 Cloudflare Origin Certificate 的角色)
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
    -keyout "$WORK/e2e.key" -out "$WORK/e2e.pem" -subj "/CN=$DOMAIN" \
    -addext "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN" &>/dev/null
has "生成测试证书" test -s "$WORK/e2e.pem"

run_xctl() { bash "$PREFIX/etc/xray/sh/xray.sh" "$@"; }
run_xctl fix-config.json >/dev/null 2>&1
has "生成 config.json" test -s "$PREFIX/etc/xray/config.json"

# ---------------------------------------------------------------------------
info "2. xray cdn 一键配置"
run_xctl cdn "$DOMAIN" --cert "$WORK/e2e.pem" --key "$WORK/e2e.key" --port "$ORIGIN_PORT" -y >"$WORK/cdn.log" 2>&1
CDN_RC=$?
if [[ $CDN_RC == 0 ]]; then ok "cdn 配置命令执行成功"; else bad "cdn 配置命令失败 (见 $WORK/cdn.log)"; tail -30 "$WORK/cdn.log"; fi

SITE="$PREFIX/etc/caddy/sites/$DOMAIN.conf"
INBOUND=$PREFIX/etc/xray/conf/VLESS-WS-TLS-$DOMAIN.json
has "Caddy 站点已生成" test -s "$SITE"
has "站点使用 Origin 证书" grep -qE "tls .*e2e(\.test)?\.pem" "$SITE"
has "站点包含反代 handle" grep -q "reverse_proxy 127.0.0.1:$ORIGIN_PORT" "$SITE"
has "站点包含订阅 handle" grep -qE "handle(_path)? /sub/" "$SITE"
has "站点包含兜底 file_server" grep -q "file_server" "$SITE"
has "inbound 文件已生成" test -s "$INBOUND"
has "inbound 只监听回环" bash -c "[[ \$(jq -r '.inbounds[0].listen' '$INBOUND') == 127.0.0.1 ]]"
has "inbound 端口正确" bash -c "[[ \$(jq -r '.inbounds[0].port' '$INBOUND') == $ORIGIN_PORT ]]"
has "inbound 网络为 ws" bash -c "[[ \$(jq -r '.inbounds[0].streamSettings.network' '$INBOUND') == ws ]]"
has "inbound 域名正确" bash -c "[[ \$(jq -r '.inbounds[0].streamSettings.wsSettings.host // .inbounds[0].streamSettings.wsSettings.headers.Host' '$INBOUND') == $DOMAIN ]]"

TOKEN=$(basename "$(ls -d "$PREFIX"/etc/xray/sub/*/ 2>/dev/null | head -n1)" 2>/dev/null)
has "订阅 token 已生成" bash -c "[[ -n '$TOKEN' ]]"
SUBDIR="$PREFIX/etc/xray/sub/$TOKEN"
for f in default.txt clash.yaml singbox.json; do
    has "订阅产物 $f 非空" test -s "$SUBDIR/$f"
done
has "Caddy 配置语法正确" "$BIN/caddy" validate --config "$PREFIX/etc/caddy/Caddyfile" --adapter caddyfile
has "sing-box profile 语法正确 (含 TUN)" "$BIN/sing-box" -c "$SUBDIR/singbox.json" check
has "mihomo profile 语法正确" bash -c "mkdir -p '$WORK/mihomo-check' && '$BIN/mihomo' -t -f '$SUBDIR/clash.yaml' -d '$WORK/mihomo-check'"

# ---------------------------------------------------------------------------
info "3. 启动 Xray / Caddy, 验证订阅分发"
"$BIN/xray" run -c "$PREFIX/etc/xray/config.json" -confdir "$PREFIX/etc/xray/conf" >"$WORK/xray.log" 2>&1 &
XRAY_PID=$!
"$BIN/caddy" run --config "$PREFIX/etc/caddy/Caddyfile" --adapter caddyfile >"$WORK/caddy.log" 2>&1 &
CADDY_PID=$!
sleep 3
if kill -0 $XRAY_PID 2>/dev/null; then ok "Xray 已启动"; else bad "Xray 未启动"; tail -20 "$WORK/xray.log"; fi
if kill -0 $CADDY_PID 2>/dev/null; then ok "Caddy 已启动"; else bad "Caddy 未启动"; tail -20 "$WORK/caddy.log"; fi

SUBBASE="https://$DOMAIN:$HTTPS_PORT/sub/$TOKEN"
has "订阅 clash.yaml 可下载" bash -c "curl -sk --noproxy '*' --resolve $DOMAIN:$HTTPS_PORT:127.0.0.1 '$SUBBASE/clash.yaml' | grep -q 'proxy-groups'"
has "订阅 singbox.json 可下载并校验" bash -c "curl -sk --noproxy '*' --resolve $DOMAIN:$HTTPS_PORT:127.0.0.1 '$SUBBASE/singbox.json' > '$WORK/dl-singbox.json' && '$BIN/sing-box' -c '$WORK/dl-singbox.json' check"
has "订阅 default.txt 可解码出节点" bash -c "curl -sk --noproxy '*' --resolve $DOMAIN:$HTTPS_PORT:127.0.0.1 '$SUBBASE/default.txt' | base64 -d | grep -qE '^(vless|vmess)://'"
has "订阅 index.html 可访问" bash -c "curl -sk --noproxy '*' --resolve $DOMAIN:$HTTPS_PORT:127.0.0.1 '$SUBBASE/' | grep -qi '<html'"
has "兜底伪装站可访问" bash -c "curl -sk --noproxy '*' --resolve $DOMAIN:$HTTPS_PORT:127.0.0.1 'https://$DOMAIN:$HTTPS_PORT/' | grep -qi 'It works'"
has "未定义路径返回 404" bash -c "[[ \$(curl -sk --noproxy '*' --resolve $DOMAIN:$HTTPS_PORT:127.0.0.1 -o /dev/null -w '%{http_code}' 'https://$DOMAIN:$HTTPS_PORT/nope.txt') == 404 ]]"
has "回源端口未监听在公网地址" bash -c "! ss -ltn | awk '{print \$4}' | grep -qE '^(0[.]0[.]0[.]0|\\[::\\]):$ORIGIN_PORT\$'"

# ---------------------------------------------------------------------------
info "4. 真实代理流量 (VLESS+WS+TLS 经 Caddy 到 Xray)"
UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$INBOUND")
WSPATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$INBOUND")
cat >"$WORK/client.json" <<EOF
{
  "inbounds": [{"tag":"socks","listen":"127.0.0.1","port":$SOCKS_PORT,"protocol":"socks","settings":{"udp":true}}],
  "outbounds": [{
    "tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"127.0.0.1","port":$HTTPS_PORT,"users":[{"id":"$UUID","encryption":"none"}]}]},
    "streamSettings":{"network":"ws","security":"tls","tlsSettings":{"serverName":"$DOMAIN","certificates":[{"certificateFile":"$WORK/e2e.pem","usage":"verify"}]},
                      "wsSettings":{"path":"$WSPATH","host":"$DOMAIN"}}
  }]
}
EOF
"$BIN/xray" run -c "$WORK/client.json" >"$WORK/xray-client.log" 2>&1 &
CLIENT_PID=$!
python3 -m http.server $ECHO_PORT --bind 127.0.0.1 --directory "$WORK" >"$WORK/echo.log" 2>&1 &
ECHO_PID=$!
echo "xctl-e2e-payload" >"$WORK/payload.txt"
sleep 2
if kill -0 $CLIENT_PID 2>/dev/null; then ok "Xray 客户端已启动"; else bad "Xray 客户端未启动"; tail -20 "$WORK/xray-client.log"; fi
has "经代理访问真实 HTTP 服务" bash -c "curl -s --noproxy '*' --max-time 10 -x socks5h://127.0.0.1:$SOCKS_PORT http://127.0.0.1:$ECHO_PORT/payload.txt | grep -q xctl-e2e-payload"
kill $CLIENT_PID 2>/dev/null

# ---------------------------------------------------------------------------
info "5. 用生成的客户端 profile 真连"
IS_SUB_NO_TUN=true run_xctl sub gen >/dev/null 2>&1
has "关闭 TUN 后 profile 仍合法" "$BIN/sing-box" -c "$SUBDIR/singbox.json" check
python3 - "$SUBDIR/singbox.json" "$WORK/singbox-run.json" "$HTTPS_PORT" "$SOCKS_PORT" <<'PY'
import json, sys
src, dst, port, socks = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
cfg = json.load(open(src))
cfg["inbounds"] = [i for i in cfg["inbounds"] if i.get("type") == "mixed"]
for i in cfg["inbounds"]:
    i["listen"], i["listen_port"] = "127.0.0.1", socks
for o in cfg["outbounds"]:
    if o.get("type") in ("vless", "vmess", "trojan", "shadowsocks") and o.get("server"):
        o["server"] = "127.0.0.1"
        o["server_port"] = port
        o.setdefault("tls", {})["insecure"] = True
json.dump(cfg, open(dst, "w"), indent=2, ensure_ascii=False)
PY
has "sing-box 校验改造后的 profile" "$BIN/sing-box" -c "$WORK/singbox-run.json" check
"$BIN/sing-box" run -c "$WORK/singbox-run.json" >"$WORK/singbox.log" 2>&1 &
SB_PID=$!
sleep 3
has "sing-box 经生成 profile 代理成功" bash -c "curl -s --noproxy '*' --max-time 10 -x socks5h://127.0.0.1:$SOCKS_PORT http://127.0.0.1:$ECHO_PORT/payload.txt | grep -q xctl-e2e-payload"
kill $SB_PID 2>/dev/null

python3 - "$SUBDIR/clash.yaml" "$WORK/clash-run.yaml" "$HTTPS_PORT" <<'PY'
import sys, yaml
src, dst, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = yaml.safe_load(open(src))
cfg["mixed-port"] = 21081
cfg.pop("socks-port", None)
cfg.setdefault("dns", {})["hosts"] = {"e2e.test": "127.0.0.1"}
for p in cfg.get("proxies", []):
    p["server"] = "127.0.0.1"
    p["port"] = port
    p["skip-cert-verify"] = True
yaml.safe_dump(cfg, open(dst, "w"), allow_unicode=True, sort_keys=False)
PY
"$BIN/mihomo" -f "$WORK/clash-run.yaml" -d "$WORK/mihomo-run" >"$WORK/mihomo.log" 2>&1 &
MH_PID=$!
sleep 5
has "mihomo 经生成 profile 代理成功" bash -c "curl -s --noproxy '*' --max-time 12 -x socks5h://127.0.0.1:21081 http://127.0.0.1:$ECHO_PORT/payload.txt | grep -q xctl-e2e-payload"
kill $MH_PID 2>/dev/null

# ---------------------------------------------------------------------------
info "6. doctor 与负向用例"
run_xctl cdn doctor "$DOMAIN" >"$WORK/doctor.log" 2>&1
if [[ $? == 0 ]]; then ok "cdn doctor 全部通过"; else bad "cdn doctor 有失败项"; grep -E 'FAIL|WARN' "$WORK/doctor.log"; fi

openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -nodes -keyout "$WORK/other.key" -out "$WORK/other.pem" -subj "/CN=other.test" &>/dev/null
if run_xctl cdn cert "$WORK/e2e.pem" "$WORK/other.key" "$DOMAIN" >/dev/null 2>&1; then
    bad "证书/私钥不匹配时应拒绝 (实际通过了)"
else
    ok "证书/私钥不匹配时被拒绝"
fi
if run_xctl cdn cert "$WORK/other.pem" "$WORK/other.key" bad.test >/dev/null 2>&1; then
    ok "SAN 不覆盖时仅告警, 证书仍安装 (预期行为)"
else
    bad "SAN 不匹配时不应直接失败 (应只告警)"
fi
has "SAN 不覆盖的证书已落盘" test -s "$PREFIX/etc/xray/cert/bad.test.pem"

run_xctl cdn "$DOMAIN" --cf-only -y >/dev/null 2>&1
has "cf-only 模式 Caddyfile 仍然合法" bash -c "'$BIN/caddy' validate --config '$PREFIX/etc/caddy/Caddyfile' --adapter caddyfile && grep -q 'xctl_not_cf' '$SITE'"

run_xctl cdn remove "$DOMAIN" >/dev/null 2>&1
has "remove 之后站点文件已删除" bash -c "[[ ! -f '$SITE' ]]"
has "remove 之后 Caddyfile 仍然合法" "$BIN/caddy" validate --config "$PREFIX/etc/caddy/Caddyfile" --adapter caddyfile

# ---------------------------------------------------------------------------
info "7. 交互面板冒烟测试"
MENU="$PREFIX/etc/xray/sh/xray.sh"
has "主面板渲染并含状态总览" bash -c "echo q | bash '$MENU' 2>/dev/null | grep -q '服务管理面板'"
has "面板显示订阅状态" bash -c "echo q | bash '$MENU' 2>/dev/null | grep -q '已启用'"
has "面板 EOF 安全退出" bash -c "bash '$MENU' </dev/null &>/dev/null"
has "面板选项 3 查看配置 (含 exec 重载链)" bash -c "printf '3\n\nq\n' | bash '$MENU' 2>/dev/null | grep -q '协议'"
has "面板选项 8 订阅地址" bash -c "printf '8\n' | bash '$MENU' 2>/dev/null | grep -q '订阅 token'"
has "无效选项友好提示" bash -c "printf '99\n\nq\n' | bash '$MENU' 2>/dev/null | grep -q '无效的选项'"

# ---------------------------------------------------------------------------
info "结果"
printf '  PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
[[ $FAIL == 0 ]] || exit 1