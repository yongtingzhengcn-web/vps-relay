#!/usr/bin/env bash
#==============================================================================
#  fix.sh  —  修复已部署的 vps-relay（不重新生成密钥，两台机器无需重新配对）
#
#  修三件事：
#    1. REALITY 伪装站(dest)从本机实测挑选  ← 连不通的主因
#       写死 www.microsoft.com 时，若落地机到该站的 TLS 握手不正常，
#       参数全对也连不上，症状就是「TCP 通、但代理没反应」
#    2. 配置目录/文件权限（Xray 以 nobody 运行，0700 会让它重启后起不来）
#    3. 去掉 sockopt 里的 tcpcongestion / tcpFastOpen
#       setsockopt(TCP_CONGESTION) 一旦失败，Xray 会让整个连接失败；
#       系统级 sysctl 已经把默认拥塞控制设成 bbr，这里再设一遍纯属多余
#
#  用法：
#    落地机(越南)先跑：  bash <(curl -fsSL <RAW_URL>/fix.sh)
#    它会打印中转机该跑的命令，形如：
#    中转机(香港)再跑：  bash <(curl -fsSL <RAW_URL>/fix.sh) -l <落地机SNI>
#==============================================================================
set -euo pipefail

CONFIG=/usr/local/etc/xray/config.json
INFO=/usr/local/etc/xray/relay-info.txt
LANDING_SNI=""      # -l  落地机正在用的 SNI（中转机必填）
MY_SNI=""           # -s  本机对外的伪装域名，留空=自动探测
SOCKS_TEST_PORT=10808

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
info(){ echo "${CYN}[*]${RST} $*"; }
ok(){   echo "${GRN}[+]${RST} $*"; }
warn(){ echo "${YLW}[!]${RST} $*"; }
die(){  echo "${RED}[x]${RST} $*" >&2; exit 1; }
line(){ printf '%s\n' "------------------------------------------------------------"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -l) LANDING_SNI="${2:?}"; shift 2 ;;
    -s) MY_SNI="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
[ -f "$CONFIG" ] || die "找不到 $CONFIG —— 这台机器还没部署过，请先跑 vn-landing.sh 或 hk-relay.sh"
command -v xray >/dev/null 2>&1 || die "找不到 xray"

export DEBIAN_FRONTEND=noninteractive
if ! command -v python3 >/dev/null 2>&1; then
  info "安装 python3（用于安全地改写 JSON 配置）..."
  apt-get update -qq && apt-get install -y -qq python3 >/dev/null
fi
command -v openssl >/dev/null 2>&1 || apt-get install -y -qq openssl >/dev/null

#------------------------------- 角色识别 -------------------------------------
ROLE="$(python3 - "$CONFIG" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for o in d.get('outbounds',[]):
    if (o.get('streamSettings') or {}).get('realitySettings'):
        print('relay'); break
else:
    print('landing')
PY
)"
if [ "$ROLE" = "relay" ]; then
  info "识别为：${BLD}香港中转机${RST}（有一个 REALITY 出站指向落地机）"
else
  info "识别为：${BLD}越南落地机${RST}（只有直连出站）"
fi

#------------------------------- 伪装站探测 -----------------------------------
# 候选顺序 = 全球可达性 + TLS1.3/H2 稳定性；刻意不含 microsoft.com（本次故障源）
DEST_CANDIDATES="gateway.icloud.com www.apple.com addons.mozilla.org www.cloudflare.com dl.google.com www.samsung.com one-piece.com www.lovelive-anime.jp"

probe_dest(){ # $1=域名；同时满足 TLS1.3 + ALPN h2 + X25519 系密钥交换才算合格
  local h="$1" out kex
  out="$(printf 'HEAD / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$h" \
        | timeout 12 openssl s_client -connect "$h:443" -servername "$h" -alpn h2 -tls1_3 2>/dev/null)" || return 1
  grep -q 'ALPN protocol: h2' <<<"$out" || return 1
  grep -qE 'Protocol *: *TLSv1\.3' <<<"$out" || return 1
  kex="$(grep -oE '(Server Temp Key|Negotiated TLS1\.3 group): *[A-Za-z0-9_+-]+' <<<"$out" | head -1 | sed -E 's/.*: *//')"
  case "${kex:-}" in X25519*) return 0 ;; *) return 1 ;; esac
}

CUR_SNI="$(python3 - "$CONFIG" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for i in d.get('inbounds',[]):
    rs=(i.get('streamSettings') or {}).get('realitySettings')
    if rs: print((rs.get('serverNames') or [''])[0]); break
else: print('')
PY
)"

if [ -z "$MY_SNI" ]; then
  info "从本机实测挑选 REALITY 伪装站（这是本次连不通的主因，必须现场验证）..."
  if [ -n "$CUR_SNI" ]; then
    if probe_dest "$CUR_SNI"; then
      ok "当前的 ${CUR_SNI} 实测合格，保持不变"
      MY_SNI="$CUR_SNI"
    else
      warn "当前的 ${CUR_SNI} 从本机握手不合格 —— 这就是连不通的原因，换掉它"
    fi
  fi
  if [ -z "$MY_SNI" ]; then
    for h in $DEST_CANDIDATES; do
      printf '    测试 %-24s' "$h"
      if probe_dest "$h"; then echo "${GRN}合格${RST}"; MY_SNI="$h"; break; else echo "${YLW}不合格${RST}"; fi
    done
  fi
  [ -n "$MY_SNI" ] || die "候选伪装站全部不合格，本机网络可能有问题。可用 -s 手动指定一个"
else
  info "使用手动指定的伪装站 ${MY_SNI}，实测验证中..."
  probe_dest "$MY_SNI" || warn "${MY_SNI} 实测不合格，仍按你的要求写入（可能连不通）"
fi
ok "本机伪装站(SNI) = ${BLD}${MY_SNI}${RST}"

if [ "$ROLE" = "relay" ]; then
  [ -n "$LANDING_SNI" ] || die "中转机必须用 -l 指定落地机的 SNI（先在落地机上跑一次本脚本，它会打印出来）"
  info "出站将使用落地机的 SNI = ${LANDING_SNI}"
fi

#------------------------------- 权限 -----------------------------------------
info "修正权限（Xray 以 nobody 运行，读不到配置就会 exit 23）..."
chmod 0755 /usr/local/etc/xray
chmod 0644 "$CONFIG"
ok "目录 $(stat -c '%A' /usr/local/etc/xray)  配置 $(stat -c '%A' "$CONFIG")"

#------------------------------- 改配置 ---------------------------------------
cp -a "$CONFIG" "${CONFIG}.bak.$(date +%s)"
info "改写配置：伪装站 + 去掉危险的 sockopt ..."
python3 - "$CONFIG" "$MY_SNI" "$LANDING_SNI" <<'PY'
import json,sys
p,my_sni,landing_sni = sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(p))

def clean_sockopt(ss):
    so=ss.get('sockopt')
    if isinstance(so,dict):
        # setsockopt(TCP_CONGESTION) 失败会让 Xray 直接判连接失败；
        # TFO 在部分国际线路上 SYN 带数据会被中间设备丢弃。两者都是净负担。
        so.pop('tcpcongestion',None)
        so.pop('tcpFastOpen',None)
        if not so: ss.pop('sockopt',None)

for ib in d.get('inbounds',[]):
    ss=ib.get('streamSettings') or {}
    rs=ss.get('realitySettings')
    if isinstance(rs,dict):
        rs['dest']=my_sni+':443'
        rs['serverNames']=[my_sni]
    clean_sockopt(ss)

for ob in d.get('outbounds',[]):
    ss=ob.get('streamSettings') or {}
    rs=ss.get('realitySettings')
    if isinstance(rs,dict) and landing_sni:
        rs['serverName']=landing_sni
    clean_sockopt(ss)

json.dump(d,open(p,'w'),indent=2)
PY

xray -test -config "$CONFIG" >/dev/null || die "改写后的配置未通过 xray -test，已备份为 ${CONFIG}.bak.*"
ok "配置校验通过"

systemctl restart xray
sleep 1
systemctl is-active --quiet xray || { journalctl -u xray -n 20 --no-pager; die "Xray 重启失败"; }

#------------------------------- 读回凭据 -------------------------------------
read -r PORT UUID SHORT_ID PRIV <<EOF
$(python3 - "$CONFIG" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for i in d.get('inbounds',[]):
    rs=(i.get('streamSettings') or {}).get('realitySettings')
    if rs:
        cl=(i.get('settings') or {}).get('clients') or [{}]
        print(i.get('port'), cl[0].get('id',''), (rs.get('shortIds') or [''])[0], rs.get('privateKey',''))
        break
PY
)
EOF
[ -n "${UUID:-}" ] || die "从配置里读不出 UUID"

# 公钥不存在于配置里，用私钥现场推导，避免依赖 relay-info.txt
KP="$(xray x25519 -i "$PRIV")"
AUTH_VALUE="$(awk '/[Pp]assword/{print $NF; exit}' <<<"$KP")"
[ -n "$AUTH_VALUE" ] || AUTH_VALUE="$(awk '/[Pp]ublic/{print $NF; exit}' <<<"$KP")"
[ -n "$AUTH_VALUE" ] || die "从私钥推导公钥失败"

pub_ip(){
  local ip=""
  for u in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')" || true
    if [ -n "$ip" ]; then echo "$ip"; return; fi
  done
  ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}'
}
IP="$(pub_ip)"

if command -v ss >/dev/null 2>&1 && ! ss -lnt 2>/dev/null | grep -q ":${PORT} "; then
  warn "服务在跑但没看到 :${PORT} 监听"
else
  ok "Xray 正常监听 :${PORT}"
fi

#------------------------------- 收尾 -----------------------------------------
echo
line
if [ "$ROLE" = "landing" ]; then
  ok "${BLD}落地机修复完成${RST}"
  line
  echo "  伪装站(SNI): ${BLD}${MY_SNI}${RST}   监听: ${IP}:${PORT}"
  line
  echo "${BLD}${YLW}接下来在香港中转机上执行这一条：${RST}"
  echo
  echo "${GRN}bash <(curl -fsSL https://raw.githubusercontent.com/yongtingzhengcn-web/vps-relay/main/fix.sh) -l ${MY_SNI}${RST}"
  echo
  line
else
  LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MY_SNI}&fp=chrome&pbk=${AUTH_VALUE}&sid=${SHORT_ID}&type=tcp&headerType=none&spx=%2F#HK-Relay-VN"
  LOON_LINE="HK-Relay-VN = VLESS,${IP},${PORT},\"${UUID}\",transport=tcp,over-tls=true,sni=${MY_SNI},flow=xtls-rprx-vision,public-key=\"${AUTH_VALUE}\",short-id=${SHORT_ID},udp=true,skip-cert-verify=true"

  info "端到端自检..."
  VN="$(python3 - "$CONFIG" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for o in d.get('outbounds',[]):
    rs=(o.get('streamSettings') or {}).get('realitySettings')
    if rs:
        v=(o.get('settings') or {}).get('vnext') or [{}]
        print(v[0].get('address',''), v[0].get('port',''))
        break
PY
)"
  set -- $VN; VN_HOST="${1:-}"; VN_PORT="${2:-443}"
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${VN_HOST}/${VN_PORT}" 2>/dev/null; then
    ok "TCP 可达落地机 ${VN_HOST}:${VN_PORT}"
  else
    warn "TCP 连不上落地机 ${VN_HOST}:${VN_PORT}"
  fi

  EXIT_IP="$(curl -x "socks5h://127.0.0.1:${SOCKS_TEST_PORT}" -s --max-time 20 https://api.ipify.org 2>/dev/null || true)"
  echo
  line
  if [ -n "$EXIT_IP" ]; then
    ok "${BLD}中转链路已打通${RST}   出口 IP = ${BLD}${EXIT_IP}${RST}"
    [ "$EXIT_IP" = "$VN_HOST" ] && ok "确认就是越南落地机的 IP ✅"
  else
    warn "${BLD}链路仍然不通${RST}"
    echo "    落地机上请确认已经跑过一次本脚本，且它报出的 SNI 与这里的 -l 参数一致："
    echo "      本机 -l 传入的落地机 SNI = ${LANDING_SNI}"
    echo "    若仍不通，在落地机上打开调试日志再抓一次："
    echo "      sed -i -e 's/\"show\": false/\"show\": true/' -e 's/\"loglevel\": \"warning\"/\"loglevel\": \"debug\"/' $CONFIG"
    echo "      xray -test -config $CONFIG >/dev/null && systemctl restart xray"
    echo "      journalctl -u xray -f     # 然后在香港重跑一次自检"
  fi
  line
  echo "${BLD}客户端链接：${RST}"
  echo "${GRN}${LINK}${RST}"
  echo
  echo "${BLD}Loon 原生配置（扫码常丢参数，建议直接粘这行）：${RST}"
  echo "${CYN}${LOON_LINE}${RST}"
  line

  if [ -f "$INFO" ]; then
    sed -i -e "s|^SNI=.*|SNI=${MY_SNI}|" -e "s|^LINK=.*|LINK=${LINK}|" "$INFO"
    grep -q '^LOON=' "$INFO" && sed -i "s|^LOON=.*|LOON=${LOON_LINE}|" "$INFO" || echo "LOON=${LOON_LINE}" >> "$INFO"
  fi
fi
echo "备份的旧配置：${CONFIG}.bak.*"
