#!/usr/bin/env bash
#==============================================================================
#  bench.sh  —  分段测速，定位中转链路的瓶颈到底在哪一段
#
#  两台机器上都跑一遍，然后对比结果：
#    落地机(越南) 直连下载慢      -> 越南机本身的国际带宽就不行，换机器或换线路
#    中转机(香港) 直连下载快      -> 香港侧没问题
#    香港经链路下载慢             -> 瓶颈在 香港->越南 这一跳
#
#  关键区分：单流 vs 4 并发
#    单流慢、并发快  -> 丢包/高延迟导致的单流受限，不是带宽不够
#    单流慢、并发也慢 -> 真的是带宽上限或线路拥塞
#==============================================================================
set -uo pipefail

CONFIG=/usr/local/etc/xray/config.json
SOCKS=10808
BYTES=${BYTES:-50000000}      # 每流下载字节数，默认 50MB
URL="https://speed.cloudflare.com/__down?bytes=${BYTES}"
IPERF_PORT=${IPERF_PORT:-5201}
MODE=""                       # --server / --peer
PEER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --server) MODE=server; shift ;;
    --peer)   MODE=peer; PEER="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
info(){ echo "${CYN}[*]${RST} $*"; }
line(){ printf '%s\n' "------------------------------------------------------------"; }

mbps(){ awk -v b="$1" 'BEGIN{printf "%.1f", b*8/1000000}'; }

dl_one(){ # 单流，回显 字节/秒
  curl -o /dev/null -s --max-time 30 -w '%{speed_download}' "$1" ${2:+-x "$2"} 2>/dev/null || echo 0
}

dl_par(){ # 4 并发，回显合计 字节/秒
  local url="$1" proxy="${2:-}" d i total=0 s
  d="$(mktemp -d)"
  for i in 1 2 3 4; do
    ( curl -o /dev/null -s --max-time 30 -w '%{speed_download}' "$url" ${proxy:+-x "$proxy"} 2>/dev/null > "$d/$i" || echo 0 > "$d/$i" ) &
  done
  wait
  for i in 1 2 3 4; do s="$(cat "$d/$i" 2>/dev/null || echo 0)"; total="$(awk -v a="$total" -v b="${s:-0}" 'BEGIN{print a+b}')"; done
  rm -rf "$d"
  echo "$total"
}

pub_ip(){
  local ip=""
  for u in "https://api.ipify.org" "https://ipv4.icanhazip.com"; do
    ip="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')" || true
    if [ -n "$ip" ]; then echo "$ip"; return; fi
  done
  ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}'
}

# ---- 两机直连对测：ping 只能证明延迟和丢包，证明不了吞吐，必须实测 ----
if [ "$MODE" = "server" ]; then
  command -v iperf3 >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get update -qq; apt-get install -y -qq iperf3 >/dev/null; }
  # 云厂商安全组常常只放行了 443。443 是唯一已知一定能通的端口（中转链路正在用），
  # 所以允许临时借用它：停掉 xray -> 测速 -> 退出时自动恢复。
  if ss -lnt 2>/dev/null | grep -q ":${IPERF_PORT} "; then
    if [ "$IPERF_PORT" = "443" ] && systemctl is-active --quiet xray 2>/dev/null; then
      echo "${YLW}[!]${RST} 临时停止 xray 以借用 443 端口测速，脚本退出时会自动恢复"
      systemctl stop xray
      trap 'systemctl start xray >/dev/null 2>&1; echo; echo "${GRN}[+]${RST} xray 已自动恢复"' EXIT INT TERM
    else
      echo "${RED}[x]${RST} 端口 ${IPERF_PORT} 已被占用，换一个：IPERF_PORT=5202 bash \$0 --server"; exit 1
    fi
  fi
  line
  echo "${BLD}iperf3 服务端已启动，端口 ${IPERF_PORT}（测完按 Ctrl+C）${RST}"
  echo "在${BLD}中转机${RST}上执行："
  echo "  ${GRN}bash <(curl -fsSL https://raw.githubusercontent.com/yongtingzhengcn-web/vps-relay/main/bench.sh) --peer $(pub_ip):${IPERF_PORT}${RST}"
  echo
  echo "若中转机连不上，说明本机安全组没放行 ${IPERF_PORT}；改用 443 重跑："
  echo "  IPERF_PORT=443 bash <(curl -fsSL .../bench.sh) --server"
  line
  iperf3 -s -p "$IPERF_PORT"   # 不能用 exec，否则退出时的 trap 不会执行
fi

if [ "$MODE" = "peer" ]; then
  command -v iperf3 >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get update -qq; apt-get install -y -qq iperf3 >/dev/null; }
  PH="${PEER%%:*}"; PP="${PEER##*:}"; [ "$PP" = "$PH" ] && PP="$IPERF_PORT"
  line
  echo "${BLD}中转机 <-> 落地机 裸 TCP 吞吐（不经 Xray，纯网络能力）${RST}"
  line
  echo "→ 上行 4 并发："
  iperf3 -c "$PH" -p "$PP" -t 10 -P 4 2>&1 | tail -4
  echo "← 下行 4 并发："
  iperf3 -c "$PH" -p "$PP" -t 10 -P 4 -R 2>&1 | tail -4
  line
  echo "把这个数字和「经完整中转链路」的速度对比："
  echo "  两者接近      -> 瓶颈是这条国际线路本身，Xray 已经跑满了它，调参数无用"
  echo "  裸 TCP 明显更快 -> 瓶颈在 Xray/CPU，值得优化"
  line
  exit 0
fi

line
echo "${BLD}分段测速${RST}   每流 $((BYTES/1000000))MB"
line

# ---- 基础环境 ----
echo "内核      : $(uname -r)"
echo "拥塞控制  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)  队列: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo "CPU       : $(nproc) 核  $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
echo "接收缓冲  : $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}') 字节"
line

# ---- 角色 ----
ROLE=landing
if [ -f "$CONFIG" ] && command -v python3 >/dev/null 2>&1; then
  ROLE="$(python3 - "$CONFIG" <<'PY' 2>/dev/null || echo landing
import json,sys
d=json.load(open(sys.argv[1]))
print('relay' if any((o.get('streamSettings') or {}).get('realitySettings') for o in d.get('outbounds',[])) else 'landing')
PY
)"
fi
echo "本机角色  : ${BLD}${ROLE}${RST}"
line

# ---- 本机直连测速 ----
info "① 本机直连下载（不经过任何代理）..."
S1="$(dl_one "$URL")";  echo "   单流   : ${BLD}$(mbps "$S1") Mbps${RST}"
P1="$(dl_par "$URL")";  echo "   4 并发 : ${BLD}$(mbps "$P1") Mbps${RST}"
line

if [ "$ROLE" = "relay" ]; then
  VN="$(python3 - "$CONFIG" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
for o in d.get('outbounds',[]):
    if (o.get('streamSettings') or {}).get('realitySettings'):
        v=(o.get('settings') or {}).get('vnext') or [{}]
        print(v[0].get('address','')); break
PY
)"
  if [ -n "${VN:-}" ]; then
    info "② 香港 -> 越南 链路质量（延迟与丢包，丢包才是单流慢的元凶）..."
    ping -c 20 -i 0.2 -W 2 "$VN" 2>/dev/null | tail -3 || echo "   落地机不回应 ICMP"
    line
  fi
  info "③ 经完整中转链路下载（香港 -> 越南 -> 互联网）..."
  S2="$(dl_one "$URL" "socks5h://127.0.0.1:${SOCKS}")"; echo "   单流   : ${BLD}$(mbps "$S2") Mbps${RST}"
  P2="$(dl_par "$URL" "socks5h://127.0.0.1:${SOCKS}")"; echo "   4 并发 : ${BLD}$(mbps "$P2") Mbps${RST}"
  line
  echo "${BLD}判读${RST}"
  R_ONE="$(awk -v a="$S2" -v b="$S1" 'BEGIN{printf "%.0f", (b>0? a*100/b : 0)}')"
  R_PAR="$(awk -v a="$P2" -v b="$P1" 'BEGIN{printf "%.0f", (b>0? a*100/b : 0)}')"
  echo "   中转后单流保留了本机直连的 ${R_ONE}%，并发保留了 ${R_PAR}%"
  if [ "${R_PAR:-0}" -lt 40 ] 2>/dev/null; then
    echo "   ${RED}并发也掉得厉害${RST} -> 瓶颈在 香港->越南 这一跳（国际线路拥塞或越南机带宽小）"
    echo "     这一段换不了协议来解决，只能换落地机机房 / 换更好的中转线路"
  elif [ "${R_ONE:-0}" -lt 40 ]; then
    echo "   ${YLW}单流掉得厉害但并发还行${RST} -> 丢包/高延迟导致的单流受限，不是带宽不够"
    echo "     客户端开多路复用或多线程下载能明显改善；上面 ping 的丢包率是关键证据"
  else
    echo "   ${GRN}中转损耗正常${RST} -> 瓶颈更可能在 你->香港 这一段（本地宽带或回国线路）"
    echo "     在本地对香港机做一次 speedtest 对比即可确认"
  fi
  line
fi
echo "提示：想测更久更准，用 BYTES=200000000 bash bench.sh"
