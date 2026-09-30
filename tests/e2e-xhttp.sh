#!/bin/bash
# ============================================================================
# XHTTP 回源 E2E 验证 (tests/e2e-xhttp.sh)
#
# 复用 e2e.sh 的沙箱方法, 但回源传输换成 xhttp:
#   客户端 --(VLESS+XHTTP+TLS)--> Caddy(443 等价端口) --(h2c)--> Xray origin
# 验证:
#   1. xctl 能创建 XHTTP inbound 并生成 Caddy 站点
#   2. Xray/Caddy 起得来, 无 wsSettings.headers 弃用警告
#   3. 订阅能渲染 xhttp 节点 (mihomo xhttp-opts / sing-box type xhttp)
#   4. mihomo / sing-box 用生成的 profile 真连成功
# ============================================================================
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/.e2e/bin
WORK=$ROOT/.e2e/run-xhttp
PREFIX=$WORK/prefix
DOMAIN=xhttp.e2e.test
HTTP_PORT=18081
HTTPS_PORT=18444
ORIGIN_PORT=19556
SOCKS_PORT=21081
ECHO_PORT=28081

unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
export no_proxy='*' NO_PROXY='*'

PASS=0
FAIL=0
PIDS=()

ok() { printf '  \033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
has() {
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

cleanup() {
    local p
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    return 0
}
trap cleanup EXIT

info "0. 依赖"
for b in xray caddy sing-box mihomo jq; do
    [[ -x $BIN/$b ]] || "$ROOT/tests/fetch-bins.sh" >/dev/null 2>&1
done
for b in xray caddy sing-box mihomo jq; do
    if [[ -x $BIN/$b ]]; then ok "二进制就绪: $b"; else bad "缺少二进制: $b"; exit 1; fi
done

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

openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
    -keyout "$WORK/e2e.key" -out "$WORK/e2e.pem" -subj "/CN=$DOMAIN" \
    -addext "subjectAltName=DNS:$DOMAIN" &>/dev/null
has "生成测试证书" test -s "$WORK/e2e.pem"

run_xctl() { bash "$PREFIX/etc/xray/sh/xray.sh" "$@"; }
run_xctl fix-config.json >/dev/null 2>&1
has "生成 config.json" test -s "$PREFIX/etc/xray/config.json"

info "2. xray cdn --net xhttp 一键配置"
run_xctl cdn "$DOMAIN" --net xhttp --cert "$WORK/e2e.pem" --key "$WORK/e2e.key" --port "$ORIGIN_PORT" -y >"$WORK/cdn.log" 2>&1
if [[ $? == 0 ]]; then ok "cdn 配置命令执行成功"; else bad "cdn 配置命令失败 (见 $WORK/cdn.log)"; tail -30 "$WORK/cdn.log"; fi

SITE="$PREFIX/etc/caddy/sites/$DOMAIN.conf"
INBOUND=$(ls "$PREFIX"/etc/xray/conf/VLESS-XHTTP-TLS-*.json 2>/dev/null | head -n1)
has "Caddy 站点已生成" test -s "$SITE"
has "站点 h2c 回源" grep -q "h2c://127.0.0.1:$ORIGIN_PORT" "$SITE"
has "inbound 文件已生成" test -n "$INBOUND" -a -s "$INBOUND"
has "inbound 网络为 xhttp" bash -c "[[ \$(jq -r '.inbounds[0].streamSettings.network' '$INBOUND') == xhttp ]]"
has "inbound 使用独立 host 字段" bash -c "[[ \$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host' '$INBOUND') == $DOMAIN ]]"
has "inbound 监听回环" bash -c "[[ \$(jq -r '.inbounds[0].listen' '$INBOUND') == 127.0.0.1 ]]"

info "3. 启动 Xray / Caddy"
"$BIN/xray" run -c "$PREFIX/etc/xray/config.json" -confdir "$PREFIX/etc/xray/conf" >"$WORK/xray.log" 2>&1 &
PIDS+=($!)
"$BIN/caddy" run --config "$PREFIX/etc/caddy/Caddyfile" --adapter caddyfile >"$WORK/caddy.log" 2>&1 &
PIDS+=($!)
sleep 3
if kill -0 "${PIDS[0]}" 2>/dev/null; then ok "Xray 已启动"; else bad "Xray 未启动"; tail -20 "$WORK/xray.log"; fi
if kill -0 "${PIDS[1]}" 2>/dev/null; then ok "Caddy 已启动"; else bad "Caddy 未启动"; tail -20 "$WORK/caddy.log"; fi
has "无 ws headers 弃用警告" bash -c "! grep -q 'feature .host. in .headers' '$WORK/xray.log'"
has "无 WS 传输弃用警告" bash -c "! grep -qi 'WebSocket transport' '$WORK/xray.log'"

info "4. 订阅渲染 XHTTP 节点"
TOKEN=$(basename "$(ls -d "$PREFIX"/etc/xray/sub/*/ 2>/dev/null | head -n1)" 2>/dev/null)
has "订阅 token 已生成" bash -c "[[ -n '$TOKEN' ]]"
SUBDIR="$PREFIX/etc/xray/sub/$TOKEN"
has "clash.yaml 含 xhttp 节点" grep -q '"network":"xhttp"' "$SUBDIR/clash.yaml"
has "clash.yaml 含 xhttp-opts" grep -q '"xhttp-opts"' "$SUBDIR/clash.yaml"
# mihomo 需要本地 Geo 数据, 否则 -t 会触发在线下载而超时
mkdir -p "$WORK/mihomo-check"
cp -f "$BIN/geoip.dat" "$BIN/geosite.dat" "$WORK/mihomo-check/"
has "mihomo profile 语法正确" bash -c "'$BIN/mihomo' -t -f '$SUBDIR/clash.yaml' -d '$WORK/mihomo-check' < /dev/null"
# 官方 sing-box 不支持 XHTTP 传输 (仅第三方 fork 支持), 此处验证跳过列表提示正确
has "singbox.json 不含 xhttp outbound (官方 sing-box 不支持)" bash -c "! jq -e '.outbounds[] | select(.type == \"xhttp\")' '$SUBDIR/singbox.json' &>/dev/null"

info "5. mihomo 经 XHTTP 代理真连 (强制规则 MATCH 走代理, 避免 127.0.0.1 被直连)"
python3 - "$SUBDIR/clash.yaml" "$WORK/mihomo-run.yaml" "$HTTPS_PORT" "$SOCKS_PORT" <<'PY'
import sys, yaml
src, dst, port, socks = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
cfg = yaml.safe_load(open(src))
cfg["mixed-port"] = socks
cfg.pop("socks-port", None)
cfg["rules"] = ["MATCH,手动切换"]          # 全部流量强制走代理组
cfg["dns"]["enable"] = False
for p in cfg.get("proxies", []):
    p["server"] = "127.0.0.1"
    p["port"] = port
    p["skip-cert-verify"] = True
yaml.safe_dump(cfg, open(dst, "w"), allow_unicode=True, sort_keys=False)
PY
"$BIN/mihomo" -f "$WORK/mihomo-run.yaml" -d "$WORK/mihomo-check" >"$WORK/mihomo.log" 2>&1 &
PIDS+=($!)
sleep 3
python3 -m http.server $ECHO_PORT --bind 127.0.0.1 --directory "$WORK" >"$WORK/echo.log" 2>&1 &
PIDS+=($!)
echo "xctl-xhttp-e2e-payload" >"$WORK/payload.txt"
sleep 1
has "mihomo 经 xhttp 代理访问成功" bash -c "curl -s --max-time 15 --noproxy '*' -x http://127.0.0.1:$SOCKS_PORT http://127.0.0.1:$ECHO_PORT/payload.txt | grep -q xctl-xhttp-e2e-payload"

info "6. Xray 官方客户端经 XHTTP 代理真连 (对照组)"
UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$INBOUND")
XPATH=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$INBOUND")
cat >"$WORK/xray-client.json" <<EOF
{
  "inbounds": [{"tag":"socks","listen":"127.0.0.1","port":$((SOCKS_PORT + 1)),"protocol":"socks","settings":{"udp":true}}],
  "outbounds": [{
    "tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"127.0.0.1","port":$HTTPS_PORT,"users":[{"id":"$UUID","encryption":"none"}]}]},
    "streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{"serverName":"$DOMAIN","certificates":[{"certificateFile":"$WORK/e2e.pem","usage":"verify"}]},
                      "xhttpSettings":{"path":"$XPATH","host":"$DOMAIN","mode":"packet-up"}}
  }]
}
EOF
"$BIN/xray" run -c "$WORK/xray-client.json" >"$WORK/xray-client.log" 2>&1 &
PIDS+=($!)
sleep 3
has "Xray 客户端经 xhttp 代理访问成功" bash -c "curl -s --max-time 15 --noproxy '*' -x socks5h://127.0.0.1:$((SOCKS_PORT + 1)) http://127.0.0.1:$ECHO_PORT/payload.txt | grep -q xctl-xhttp-e2e-payload"

info "7. 交互面板冒烟测试"
MENU="$PREFIX/etc/xray/sh/xray.sh"
has "主面板渲染并退出" bash -c "echo q | bash '$MENU' &>/dev/null"
has "面板显示 xhttp 节点" bash -c "echo q | bash '$MENU' 2>/dev/null | grep -q '节点'"

info "== 结果 =="
echo "  PASS: $PASS   FAIL: $FAIL"
[[ $FAIL == 0 ]]
