#!/usr/bin/env bash
#==============================================================================
#  vn-landing.sh  —  越南落地机 (出口) 一键部署
#
#  角色：  客户端 --> [香港中转] --> (本机 越南) --> 互联网
#  协议：  VLESS + TCP + REALITY + XTLS-Vision
#  附带：  XanMod 内核 (BBRv3) + TCP 网络栈调优
#
#  用法：  bash <(curl -fsSL <RAW_URL>/vn-landing.sh)
#          bash <(curl -fsSL <RAW_URL>/vn-landing.sh) -p 443 -a <香港机IP>
#
#  跑完会打印一条 vless:// 链接，把它复制下来喂给香港中转机的 hk-relay.sh
#==============================================================================
set -euo pipefail

#------------------------------- 可调参数 -------------------------------------
PORT=443                       # -p  本机监听端口
SNI=""                         # -s  REALITY 伪装域名；留空=从本机实测自动挑选
ALLOW_IP=""                    # -a  只允许该 IP (香港中转机) 连本端口，留空=不限制
DO_KERNEL=1                    # --no-kernel  跳过 XanMod 内核安装
AUTO_REBOOT=0                  # -y  装完内核自动重启
TAG="VN-Landing"

#------------------------------- 输出helper -----------------------------------
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
info(){ echo "${CYN}[*]${RST} $*"; }
ok(){   echo "${GRN}[+]${RST} $*"; }
warn(){ echo "${YLW}[!]${RST} $*"; }
die(){  echo "${RED}[x]${RST} $*" >&2; exit 1; }
line(){ printf '%s\n' "------------------------------------------------------------"; }

usage(){
  cat <<EOF
用法: $0 [选项]
  -p PORT        监听端口 (默认 443)
  -s SNI         REALITY 伪装域名；默认从本机实测自动挑选
  -a IP          只允许该 IP 访问本端口 (填香港中转机 IP，强烈建议)
  -y             安装完 XanMod 内核后自动重启
  --no-kernel    不动内核，只装 Xray
  -h             显示帮助
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p) PORT="${2:?}"; shift 2 ;;
    -s) SNI="${2:?}"; shift 2 ;;
    -a) ALLOW_IP="${2:?}"; shift 2 ;;
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

. /etc/os-release
info "系统: ${PRETTY_NAME:-unknown}  内核: $(uname -r)  架构: $(uname -m)"

#------------------------------- 依赖 -----------------------------------------
info "安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates openssl gnupg qrencode >/dev/null

#------------------------------- 伪装站探测 -----------------------------------
# 血泪教训：写死一个 dest（比如 www.microsoft.com）是这套方案最大的坑。
# 若本机到该站的 TLS 握手不正常，即使 UUID/公钥/shortId 全对，客户端也连不上，
# 症状是「TCP 通、但代理毫无反应」，极难排查。所以一律现场实测后再选。
DEST_CANDIDATES="gateway.icloud.com www.apple.com addons.mozilla.org www.cloudflare.com dl.google.com www.samsung.com one-piece.com www.lovelive-anime.jp"

probe_dest(){ # 快速预筛：TLS1.3 + ALPN h2 + X25519。只能排除明显不可用的，不足以定生死
  local h="$1" out kex
  out="$(printf 'HEAD / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$h" \
        | timeout 12 openssl s_client -connect "$h:443" -servername "$h" -alpn h2 -tls1_3 2>/dev/null)" || return 1
  grep -q 'ALPN protocol: h2' <<<"$out" || return 1
  grep -qE 'Protocol *: *TLSv1\.3' <<<"$out" || return 1
  kex="$(grep -oE '(Server Temp Key|Negotiated TLS1\.3 group): *[A-Za-z0-9_+-]+' <<<"$out" | head -1 | sed -E 's/.*: *//')"
  case "${kex:-}" in X25519*) return 0 ;; *) return 1 ;; esac
}

# 唯一可靠的判据：在本机起一对临时 REALITY 服务端/客户端，用候选域名真跑一遍握手。
# 为什么必须这样测：www.microsoft.com 的 TLS1.3/h2/X25519 全部合格，但它的证书链有
# 8273 字节，超出 REALITY 中转握手能容纳的大小，握手必定失败 —— 只查特性根本发现不了。
TEST_URL=""
pick_test_url(){
  local u code
  for u in https://www.gstatic.com/generate_204 https://cp.cloudflare.com/generate_204 https://api.ipify.org; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || echo 000)"
    case "$code" in 200|204) TEST_URL="$u"; return 0 ;; esac
  done
  return 1
}

free_port(){
  local p i
  for i in 1 2 3 4 5 6 7 8; do
    p=$(( (RANDOM % 20000) + 30000 ))
    ss -lnt 2>/dev/null | grep -q ":${p} " || { echo "$p"; return 0; }
  done
  echo "$(( (RANDOM % 20000) + 30000 ))"
}

reality_handshake_ok(){ # $1=候选 dest
  local DEST="$1" sd sp cp2 kp priv pub uuid sid code S C i
  [ -n "$TEST_URL" ] || return 1
  sd="$(mktemp -d)"; sp="$(free_port)"; cp2="$(free_port)"
  kp="$(xray x25519)"
  priv="$(awk '/[Pp]rivate/{print $NF; exit}' <<<"$kp")"
  pub="$(awk '/[Pp]assword/{print $NF; exit}' <<<"$kp")"
  [ -n "$pub" ] || pub="$(awk '/[Pp]ublic/{print $NF; exit}' <<<"$kp")"
  uuid="$(xray uuid)"; sid="$(openssl rand -hex 8)"
  cat > "$sd/s.json" <<EOF
{ "log":{"loglevel":"warning"},
  "inbounds":[{"listen":"127.0.0.1","port":${sp},"protocol":"vless",
    "settings":{"clients":[{"id":"${uuid}","flow":"xtls-rprx-vision"}],"decryption":"none"},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
      "show":false,"dest":"${DEST}:443","xver":0,"serverNames":["${DEST}"],
      "privateKey":"${priv}","shortIds":["${sid}"]}}}],
  "outbounds":[{"protocol":"freedom","settings":{"domainStrategy":"UseIP"}}] }
EOF
  cat > "$sd/c.json" <<EOF
{ "log":{"loglevel":"warning"},
  "inbounds":[{"listen":"127.0.0.1","port":${cp2},"protocol":"socks","settings":{"auth":"noauth"}}],
  "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":${sp},
      "users":[{"id":"${uuid}","encryption":"none","flow":"xtls-rprx-vision"}]}]},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
      "serverName":"${DEST}","fingerprint":"chrome","password":"${pub}","shortId":"${sid}","spiderX":"/"}}}] }
EOF
  xray run -c "$sd/s.json" >"$sd/s.log" 2>&1 & S=$!
  xray run -c "$sd/c.json" >"$sd/c.log" 2>&1 & C=$!
  for i in $(seq 1 24); do
    ss -lnt 2>/dev/null | grep -q ":${cp2} " && break
    sleep 0.25
  done
  code="$(curl -x "socks5h://127.0.0.1:${cp2}" -s -o /dev/null -w '%{http_code}' --max-time 12 "$TEST_URL" 2>/dev/null || echo 000)"
  kill "$S" "$C" 2>/dev/null || true
  wait "$S" 2>/dev/null || true; wait "$C" 2>/dev/null || true
  rm -rf "$sd"
  case "$code" in 200|204) return 0 ;; *) return 1 ;; esac
}

dest_ok(){ probe_dest "$1" && reality_handshake_ok "$1"; }

select_sni(){
  pick_test_url || die "本机连不上任何测试地址，无法验证伪装站；请先检查这台机器的出网"
  if [ -n "$SNI" ]; then
    info "验证手动指定的伪装站 ${SNI}（真实握手测试）..."
    if dest_ok "$SNI"; then ok "${SNI} 握手成功"
    else warn "${SNI} 握手失败，仍按你的要求写入（很可能连不通）"; fi
    return 0
  fi
  info "实测挑选 REALITY 伪装站（每个候选真跑一遍握手，约几秒一个）..."
  local h
  for h in $DEST_CANDIDATES; do
    printf '    %-24s' "$h"
    if dest_ok "$h"; then echo "${GRN}握手成功${RST}"; SNI="$h"; break; else echo "${YLW}不可用${RST}"; fi
  done
  [ -n "$SNI" ] || die "候选伪装站全部不可用，本机网络可能有问题；可用 -s 手动指定"
  ok "选定伪装站: ${BLD}${SNI}${RST}"
}

#------------------------------- 网络栈调优 -----------------------------------
tune_sysctl(){
  info "写入 TCP 调优参数 /etc/sysctl.d/99-relay-tuning.conf ..."
  cat > /etc/sysctl.d/99-relay-tuning.conf <<'EOF'
# --- 由 vps-relay 脚本生成：面向高延迟长肥管道的 TCP 调优 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 收发缓冲区放大，跑满跨境带宽的前提
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# 空闲后不回落慢启动，避免每次停顿都重新爬窗口
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384

# 连接数与回收
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
fs.file-max = 1000000
EOF
  sysctl --system >/dev/null 2>&1 || true
  local cc; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  ok "当前拥塞控制: ${cc}  队列: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
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
  if [ -z "$codename" ]; then
    warn "读不到发行版代号，跳过 XanMod"
    return 0
  fi

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
    warn "源里没有 ${pkg}，跳过内核升级"
    return 0
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

#------------------------------- 生成凭据 -------------------------------------
gen_creds(){
  UUID="$(xray uuid)"
  SHORT_ID="$(openssl rand -hex 8)"
  local out; out="$(xray x25519)"
  PRIVATE_KEY="$(awk '/[Pp]rivate/{print $NF; exit}' <<<"$out")"
  PASSWORD="$(awk '/[Pp]assword/{print $NF; exit}' <<<"$out")"
  PUBLIC_KEY="$(awk '/[Pp]ublic/{print $NF; exit}' <<<"$out")"
  [ -n "$PRIVATE_KEY" ] || die "解析 x25519 私钥失败，原始输出：\n$out"

  # Xray v25 起客户端字段由 publicKey 改名为 password，这里按核心实际输出自适应
  if [ -n "$PASSWORD" ]; then
    AUTH_VALUE="$PASSWORD"
  else
    AUTH_VALUE="$PUBLIC_KEY"
  fi
  [ -n "$AUTH_VALUE" ] || die "解析 x25519 公钥失败，原始输出：\n$out"
}

#------------------------------- 写配置 ---------------------------------------
write_config(){
  install -d -m 0755 /usr/local/etc/xray
  if [ -f /usr/local/etc/xray/config.json ]; then
    cp -a /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.bak.$(date +%s)"
  fi

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
        "sockopt": { "tcpNoDelay": true }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
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
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }
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
  ok "Xray 已启动并监听 :${PORT}"
}

#------------------------------- 防火墙 ---------------------------------------
lock_down(){
  [ -n "$ALLOW_IP" ] || { warn "未指定 -a，本端口对全网开放（REALITY 本身有密钥保护，但建议只放行香港机 IP）"; return 0; }
  apt-get install -y -qq nftables >/dev/null
  if [ -f /etc/nftables.conf ]; then
    cp -a /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%s)"
  fi
  # 只针对本端口收紧，chain policy 为 accept，绝不影响 SSH
  nft list table inet relayfw >/dev/null 2>&1 || nft add table inet relayfw
  nft list chain inet relayfw input >/dev/null 2>&1 \
    || nft add chain inet relayfw input '{ type filter hook input priority 0 ; policy accept ; }'
  nft flush chain inet relayfw input
  nft add rule inet relayfw input tcp dport "$PORT" ip saddr "$ALLOW_IP" accept
  nft add rule inet relayfw input tcp dport "$PORT" ct state established,related accept
  nft add rule inet relayfw input tcp dport "$PORT" drop
  nft list ruleset > /etc/nftables.conf
  systemctl enable nftables >/dev/null 2>&1 || true
  ok "已限制 :${PORT} 仅允许 ${ALLOW_IP} 接入 (SSH 不受影响)"
}

#------------------------------- 出口信息 -------------------------------------
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
echo "${BLD}越南落地机部署 — VLESS + REALITY 出口${RST}"
line
tune_sysctl
install_xray
select_sni          # 必须在 install_xray 之后：真实握手测试要用 xray 起临时收发端
gen_creds
write_config
lock_down
if [ "$DO_KERNEL" -eq 1 ]; then install_xanmod; fi

IP="$(pub_ip)"
[ -n "$IP" ] || IP="<你的越南VPS_IP>"

LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${AUTH_VALUE}&sid=${SHORT_ID}&type=tcp&headerType=none&spx=%2F#${TAG}"

# 注意：不要收紧 /usr/local/etc/xray 目录权限。
# Xray 以 nobody 身份运行，目录一旦变成 0700，重启后就读不到 config.json（exit 23）。
cat > /usr/local/etc/xray/relay-info.txt <<EOF
# 越南落地机 (出口) — 生成于 $(date -Is)
ROLE=landing
IP=${IP}
PORT=${PORT}
UUID=${UUID}
SNI=${SNI}
SHORT_ID=${SHORT_ID}
PUBLIC_KEY_OR_PASSWORD=${AUTH_VALUE}
RAW_PUBLIC_KEY=${PUBLIC_KEY}
LINK=${LINK}
EOF
chmod 600 /usr/local/etc/xray/relay-info.txt

cat > /usr/local/bin/relay-info <<'EOF'
#!/usr/bin/env bash
cat /usr/local/etc/xray/relay-info.txt
EOF
chmod +x /usr/local/bin/relay-info

# 收尾复核：所有文件写完之后再重启一次，确认 xray 能以 nobody 身份真正拉起来。
# 之前踩过的坑：写凭据时把配置目录改成 0700，当时进程还活着看不出问题，重启后必挂 (exit 23)。
info "收尾复核：重启 Xray 并确认服务存活..."
chmod 0755 /usr/local/etc/xray
chmod 0644 /usr/local/etc/xray/config.json
systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
  if command -v ss >/dev/null 2>&1 && ! ss -lnt 2>/dev/null | grep -q ":${PORT} "; then
    warn "服务在跑，但没看到 :${PORT} 的监听，请手动检查 ss -lntp"
  else
    ok "Xray 重启后正常监听 :${PORT}"
  fi
else
  journalctl -u xray -n 20 --no-pager
  die "Xray 重启后启动失败（上面是日志）"
fi

echo
line
ok "${BLD}越南落地机部署完成${RST}"
line
echo "  IP        : ${IP}"
echo "  端口      : ${PORT}"
echo "  UUID      : ${UUID}"
echo "  SNI       : ${SNI}"
echo "  ShortID   : ${SHORT_ID}"
echo "  公钥/密码 : ${AUTH_VALUE}"
line
echo "${BLD}${YLW}把下面这一整行复制走，等下喂给香港中转机：${RST}"
echo
echo "${GRN}${LINK}${RST}"
echo
line
echo "接着在${BLD}香港${RST}机器上执行（把链接用单引号包起来）："
echo "  bash <(curl -fsSL RAW_URL_HK) -l '${LINK}'"
line
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
