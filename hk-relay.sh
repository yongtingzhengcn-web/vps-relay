#!/usr/bin/env bash
#==============================================================================
#  hk-relay.sh  —  香港 CN2 中转机 (入口 + 链式代理) 一键部署
#
#  角色：  客户端 --> (本机 香港) --> [越南落地] --> 互联网
#  协议：  入站 VLESS+TCP+REALITY+Vision / 出站 VLESS+TCP+REALITY+Vision
#  附带：  XanMod 内核 (BBRv3) + TCP 网络栈调优 + 落地连通性自检
#
#  用法：  先在越南机跑 vn-landing.sh，拿到 vless:// 链接，然后：
#          bash <(curl -fsSL <RAW_URL>/hk-relay.sh) -l 'vless://....'
#          不带 -l 会交互式提示粘贴
#==============================================================================
set -euo pipefail

#------------------------------- 可调参数 -------------------------------------
PORT=443                       # -p  本机对客户端监听的端口
SNI="www.microsoft.com"        # -s  本机 REALITY 伪装域名
VN_LINK=""                     # -l  越南落地机的 vless:// 链接
CN_DIRECT=0                    # --cn-direct  国内网站在香港直接出，不绕越南
DO_KERNEL=1                    # --no-kernel  跳过 XanMod 内核安装
AUTO_REBOOT=0                  # -y
TAG="HK-Relay-VN"
SOCKS_TEST_PORT=10808          # 仅监听 127.0.0.1，用于自检

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
info(){ echo "${CYN}[*]${RST} $*"; }
ok(){   echo "${GRN}[+]${RST} $*"; }
warn(){ echo "${YLW}[!]${RST} $*"; }
die(){  echo "${RED}[x]${RST} $*" >&2; exit 1; }
line(){ printf '%s\n' "------------------------------------------------------------"; }

usage(){
  cat <<EOF
用法: $0 -l 'vless://...' [选项]
  -l LINK        越南落地机输出的 vless:// 链接 (必填，记得用单引号包住)
  -p PORT        本机监听端口 (默认 443)
  -s SNI         本机 REALITY 伪装域名 (默认 www.microsoft.com)
  --cn-direct    命中 geosite:cn / geoip:cn 的流量在香港直接出，不绕越南
  -y             安装完 XanMod 内核后自动重启
  --no-kernel    不动内核，只装 Xray
  -h             显示帮助
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -l) VN_LINK="${2:?}"; shift 2 ;;
    -p) PORT="${2:?}"; shift 2 ;;
    -s) SNI="${2:?}"; shift 2 ;;
    --cn-direct) CN_DIRECT=1; shift ;;
    -y) AUTO_REBOOT=1; shift ;;
    --no-kernel) DO_KERNEL=0; shift ;;
    -h|--help) usage ;;
    *) die "未知参数: $1 (用 -h 看帮助)" ;;
  esac
done

#------------------------------- 前置检查 -------------------------------------
[ "$(id -u)" -eq 0 ] || die "请用 root 运行 (sudo -i 后再执行)"
command -v apt-get >/dev/null 2>&1 || die "此脚本仅支持 Debian / Ubuntu 系"
case "$PORT" in ''|*[!0-9]*) die "端口不合法: $PORT" ;; esac

if [ -z "$VN_LINK" ]; then
  echo "${BLD}请粘贴越南落地机输出的 vless:// 链接，然后回车：${RST}"
  read -r VN_LINK </dev/tty || true
fi
[ -n "$VN_LINK" ] || die "没有拿到落地机链接，先去越南机跑 vn-landing.sh"

#------------------------------- 解析落地链接 ---------------------------------
parse_link(){
  local url="$1"
  case "$url" in vless://*) ;; *) die "链接必须以 vless:// 开头，拿到的是: ${url:0:24}..." ;; esac
  url="${url#vless://}"
  url="${url%%#*}"                       # 去掉 #备注
  local userinfo="${url%%@*}"
  local rest="${url#*@}"
  local hostport="${rest%%\?*}"
  local query=""
  case "$rest" in *\?*) query="${rest#*\?}" ;; esac

  VN_UUID="$userinfo"
  case "$hostport" in
    \[*\]:*) VN_HOST="${hostport%%]*}"; VN_HOST="${VN_HOST#[}"; VN_PORT="${hostport##*]:}" ;;
    *)       VN_HOST="${hostport%%:*}";  VN_PORT="${hostport##*:}" ;;
  esac

  qval(){ tr '&' '\n' <<<"$query" | awk -F= -v k="$1" '$1==k{print $2; exit}'; }
  VN_SNI="$(qval sni)"
  VN_PBK="$(qval pbk)"
  VN_SID="$(qval sid)"
  VN_FP="$(qval fp)"; [ -n "$VN_FP" ] || VN_FP="chrome"

  [ -n "$VN_UUID" ] || die "链接里没解析出 UUID"
  [ -n "$VN_HOST" ] || die "链接里没解析出落地机地址"
  case "$VN_PORT" in ''|*[!0-9]*) die "链接里的端口不合法: $VN_PORT" ;; esac
  [ -n "$VN_SNI" ]  || die "链接里没有 sni= 参数"
  [ -n "$VN_PBK" ]  || die "链接里没有 pbk= 参数"
}
parse_link "$VN_LINK"

. /etc/os-release
info "系统: ${PRETTY_NAME:-unknown}  内核: $(uname -r)  架构: $(uname -m)"
info "落地机: ${VN_HOST}:${VN_PORT}  SNI=${VN_SNI}  ShortID=${VN_SID:-<空>}"

#------------------------------- 依赖 -----------------------------------------
info "安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl gnupg qrencode >/dev/null

#------------------------------- 网络栈调优 -----------------------------------
tune_sysctl(){
  info "写入 TCP 调优参数 /etc/sysctl.d/99-relay-tuning.conf ..."
  cat > /etc/sysctl.d/99-relay-tuning.conf <<'EOF'
# --- 由 vps-relay 脚本生成：面向高延迟长肥管道的 TCP 调优 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
fs.file-max = 1000000
EOF
  sysctl --system >/dev/null 2>&1 || true
  ok "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')  队列: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
}

#------------------------------- XanMod / BBRv3 -------------------------------
cpu_level(){
  awk '
  BEGIN {
    while (!/flags/) if (getline < "/proc/cpuinfo" != 1) { print 1; exit }
    if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) lv=1
    if (lv==1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) lv=2
    if (lv==2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) lv=3
    print (lv?lv:1)
  }'
}

KERNEL_INSTALLED=0
install_xanmod(){
  if uname -r | grep -qi xanmod; then
    ok "已经在跑 XanMod 内核 ($(uname -r))，BBRv3 已可用，跳过"
    return 0
  fi
  if [ "$(uname -m)" != "x86_64" ]; then
    warn "非 x86_64 架构，XanMod 不提供预编译包 —— 跳过，继续用内核自带 BBR(v1)"
    return 0
  fi
  local codename="${VERSION_CODENAME:-}"
  [ -n "$codename" ] || { warn "读不到发行版代号，跳过 XanMod"; return 0; }

  info "配置 XanMod 源 (suite=${codename}) ..."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://dl.xanmod.org/archive.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${codename} main" \
    > /etc/apt/sources.list.d/xanmod-release.list

  if ! apt-get update -qq; then
    warn "XanMod 源不可用 (${codename} 可能尚未支持)，已移除该源，保留内核自带 BBR"
    rm -f /etc/apt/sources.list.d/xanmod-release.list
    apt-get update -qq || true
    return 0
  fi

  local lvl pkg
  lvl="$(cpu_level)"
  case "$lvl" in
    3) pkg="linux-xanmod-x64v3" ;;
    2) pkg="linux-xanmod-x64v2" ;;
    *) pkg="linux-xanmod-lts-x64v1" ;;
  esac
  info "CPU 微架构等级: x86-64-v${lvl}  ->  安装 ${pkg}"

  if apt-cache policy "$pkg" 2>/dev/null | grep -q 'Candidate: (none)'; then
    warn "源里没有 ${pkg}，跳过内核升级"; return 0
  fi
  if apt-get install -y "$pkg"; then
    KERNEL_INSTALLED=1
    ok "XanMod 内核已安装 —— 重启后 'bbr' 即为 BBRv3"
  else
    warn "XanMod 安装失败，跳过（不影响 Xray 使用）"
  fi
}

#------------------------------- 安装 Xray ------------------------------------
install_xray(){
  info "安装 / 更新 Xray-core (XTLS 官方安装脚本)..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  command -v xray >/dev/null 2>&1 || die "Xray 安装失败"
  ok "Xray 版本: $(xray version | head -n1)"
  install -d -m 0755 /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1000000
EOF
  systemctl daemon-reload
}

#------------------------------- 生成本机凭据 ---------------------------------
gen_creds(){
  UUID="$(xray uuid)"
  SHORT_ID="$(openssl rand -hex 8)"
  local out; out="$(xray x25519)"
  PRIVATE_KEY="$(awk '/[Pp]rivate/{print $NF; exit}' <<<"$out")"
  PASSWORD="$(awk '/[Pp]assword/{print $NF; exit}' <<<"$out")"
  PUBLIC_KEY="$(awk '/[Pp]ublic/{print $NF; exit}' <<<"$out")"
  [ -n "$PRIVATE_KEY" ] || die "解析 x25519 私钥失败，原始输出：\n$out"

  # Xray v25 起客户端字段由 publicKey 改名为 password，按核心实际输出自适应
  if [ -n "$PASSWORD" ]; then
    AUTH_VALUE="$PASSWORD"; CLIENT_AUTH_FIELD="password"
  else
    AUTH_VALUE="$PUBLIC_KEY"; CLIENT_AUTH_FIELD="publicKey"
  fi
  [ -n "$AUTH_VALUE" ] || die "解析 x25519 公钥失败，原始输出：\n$out"
  info "本机核心使用的 REALITY 客户端字段名: ${CLIENT_AUTH_FIELD}"
}

#------------------------------- 写配置 ---------------------------------------
write_config(){
  install -d -m 0755 /usr/local/etc/xray
  if [ -f /usr/local/etc/xray/config.json ]; then
    cp -a /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.bak.$(date +%s)"
  fi

  local cn_rules=""
  if [ "$CN_DIRECT" -eq 1 ]; then
    cn_rules='
      { "type": "field", "domain": [ "geosite:cn" ], "outboundTag": "direct" },
      { "type": "field", "ip": [ "geoip:cn" ], "outboundTag": "direct" },'
  fi

  # 说明：routing.domainStrategy 固定为 AsIs —— 不在香港做 DNS 解析，
  # 域名原样带到越南落地机再解析，既省一次 RTT，也保证 CDN 给的是越南就近节点。
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
        },
        "sockopt": { "tcpFastOpen": true, "tcpNoDelay": true }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": false
      }
    },
    {
      "tag": "socks-selftest",
      "listen": "127.0.0.1",
      "port": ${SOCKS_TEST_PORT},
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    }
  ],
  "outbounds": [
    {
      "tag": "to-landing",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${VN_HOST}",
            "port": ${VN_PORT},
            "users": [
              { "id": "${VN_UUID}", "encryption": "none", "flow": "xtls-rprx-vision" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${VN_SNI}",
          "fingerprint": "${VN_FP}",
          "${CLIENT_AUTH_FIELD}": "${VN_PBK}",
          "shortId": "${VN_SID}",
          "spiderX": "/"
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 15,
          "tcpcongestion": "bbr"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIP" }
    },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" },${cn_rules}
      { "type": "field", "network": "tcp,udp", "outboundTag": "to-landing" }
    ]
  }
}
EOF

  xray -test -config /usr/local/etc/xray/config.json >/dev/null \
    || die "生成的配置未通过 xray -test，请把上面的报错贴出来"
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || { journalctl -u xray -n 30 --no-pager; die "Xray 启动失败"; }
  ok "Xray 已启动，对外监听 :${PORT}，出站指向 ${VN_HOST}:${VN_PORT}"
}

#------------------------------- 自检 -----------------------------------------
self_test(){
  info "自检：香港 -> 越南 链路连通性 & 出口 IP ..."
  local rtt exit_ip code
  rtt="$(ping -c 3 -W 2 "$VN_HOST" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.1f", $5}')" || true
  if [ -n "${rtt:-}" ]; then
    ok "香港 -> 越南 ICMP 延迟: ${rtt} ms"
  else
    warn "落地机没回应 ICMP（多数 VPS 默认封 ping，不影响使用）"
  fi

  code="$(curl -x "socks5h://127.0.0.1:${SOCKS_TEST_PORT}" -s -o /dev/null -w '%{http_code}' \
          --max-time 15 https://www.gstatic.com/generate_204 2>/dev/null || echo 000)"
  if [ "$code" = "204" ] || [ "$code" = "200" ]; then
    ok "链路打通（HTTP ${code}）"
  else
    warn "经落地机访问外网失败 (HTTP ${code})"
    warn "常见原因：越南机防火墙用 -a 限制了别的 IP / 端口没放行 / 链接复制不完整"
  fi

  exit_ip="$(curl -x "socks5h://127.0.0.1:${SOCKS_TEST_PORT}" -s --max-time 15 https://api.ipify.org 2>/dev/null || true)"
  if [ -n "$exit_ip" ]; then
    if [ "$exit_ip" = "$VN_HOST" ]; then
      ok "出口 IP = ${exit_ip}  ✅ 正是越南落地机，中转链路成立"
    else
      warn "出口 IP = ${exit_ip}（与落地机 ${VN_HOST} 不同，若落地机有多个出口 IP 属正常）"
    fi
  fi
}

pub_ip(){
  local ip=""
  for u in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')" || true
    if [ -n "$ip" ]; then echo "$ip"; return; fi
  done
  ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}'
}

#------------------------------- 主流程 ---------------------------------------
line
echo "${BLD}香港中转机部署 — VLESS+REALITY 入口，链式出站到越南${RST}"
line
tune_sysctl
install_xray
gen_creds
write_config
self_test
if [ "$DO_KERNEL" -eq 1 ]; then install_xanmod; fi

IP="$(pub_ip)"
[ -n "$IP" ] || IP="<你的香港VPS_IP>"

LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${AUTH_VALUE}&sid=${SHORT_ID}&type=tcp&headerType=none&spx=%2F#${TAG}"

cat > /usr/local/etc/xray/relay-info.txt <<EOF
# 香港中转机 (入口) — 生成于 $(date -Is)
ROLE=relay
IP=${IP}
PORT=${PORT}
UUID=${UUID}
SNI=${SNI}
SHORT_ID=${SHORT_ID}
PUBLIC_KEY_OR_PASSWORD=${AUTH_VALUE}
RAW_PUBLIC_KEY=${PUBLIC_KEY}
LANDING=${VN_HOST}:${VN_PORT}
LINK=${LINK}
EOF
chmod 600 /usr/local/etc/xray/relay-info.txt

cat > /usr/local/bin/relay-info <<'EOF'
#!/usr/bin/env bash
cat /usr/local/etc/xray/relay-info.txt
EOF
chmod +x /usr/local/bin/relay-info

echo
line
ok "${BLD}香港中转机部署完成${RST}"
line
echo "  链路      : 你 --> ${IP}:${PORT} (香港CN2) --> ${VN_HOST}:${VN_PORT} (越南) --> 互联网"
echo "  UUID      : ${UUID}"
echo "  SNI       : ${SNI}"
echo "  ShortID   : ${SHORT_ID}"
echo "  公钥/密码 : ${AUTH_VALUE}"
line
echo "${BLD}${YLW}客户端订阅链接（导入 v2rayN / Shadowrocket / Clash-Meta）：${RST}"
echo
echo "${GRN}${LINK}${RST}"
echo
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 "$LINK" || true
fi
line
if [ -n "$PUBLIC_KEY" ] && [ "$PUBLIC_KEY" != "$AUTH_VALUE" ]; then
  echo "若客户端版本较老连不上，把链接里的 ${BLD}pbk=${RST} 换成原始公钥再试： ${PUBLIC_KEY}"
fi
echo "随时用 ${BLD}relay-info${RST} 命令重新查看以上信息。"

if [ "$KERNEL_INSTALLED" -eq 1 ]; then
  echo
  warn "XanMod 内核已装好，${BLD}必须重启一次${RST}才会生效 (重启后 bbr 即 BBRv3)"
  if [ "$AUTO_REBOOT" -eq 1 ]; then
    warn "5 秒后自动重启... (Ctrl+C 取消)"; sleep 5; reboot
  else
    echo "     手动重启:  reboot"
    echo "     重启后校验: uname -r && sysctl net.ipv4.tcp_congestion_control"
  fi
fi
