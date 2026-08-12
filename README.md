# vps-relay — 香港 CN2 中转 + 越南落地（VLESS + REALITY 链式代理）

两个脚本，分别粘到两台 VPS 上跑完就能用。

```
        中国大陆                香港 CN2 GIA               越南 VPS
  ┌──────────────┐   优质回国线路   ┌──────────┐  国际线路   ┌──────────┐
  │ v2rayN /     │ ─────────────→ │  中转机   │ ────────→ │  落地机   │ → 互联网
  │ Shadowrocket │  VLESS+REALITY  │ hk-relay │ VLESS+RE  │vn-landing│   (越南 IP)
  └──────────────┘   +XTLS-Vision  └──────────┘  ALITY    └──────────┘
```

为什么快：客户端到香港走 CN2 优质线路（低延迟、不拥堵），香港到越南走机房间国际骨干，
比"大陆直连越南"少了最容易拥塞的那一跳。两段都是 VLESS + REALITY + XTLS-Vision，
无需域名和证书，抗封锁能力强，Vision 流控让大文件传输接近裸速。

---

## 一、部署顺序（必须先越南、后香港）

### 第 1 步：越南落地机

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yongtingzhengcn-web/vps-relay/main/vn-landing.sh)
```

跑完会打印一条 `vless://...` 链接，**整行复制下来**。

建议加上 `-a` 参数，只放行香港中转机的 IP，落地机就不会被扫描到：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yongtingzhengcn-web/vps-relay/main/vn-landing.sh) -a 香港机IP
```

### 第 2 步：香港中转机

把上一步的链接用**单引号**包起来传进去（链接里有 `&`，不加引号会被 shell 截断）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yongtingzhengcn-web/vps-relay/main/hk-relay.sh) -l 'vless://粘贴这里'
```

不带 `-l` 会交互式提示你粘贴。

跑完会打印**客户端订阅链接 + 二维码**，导入 v2rayN / Shadowrocket / Clash-Meta 即可。
脚本还会自动自检：测香港→越南的延迟、走一遍完整链路取出口 IP，确认确实是越南的 IP 才算成功。

### 第 3 步：重启两台机器

两台都装了 XanMod 内核（BBRv3），**必须各重启一次**才生效：

```bash
reboot
```

重启后校验：

```bash
uname -r && sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

看到内核名里带 `xanmod`、拥塞控制是 `bbr`、队列是 `fq` 就对了。
XanMod 内核里的 `bbr` **就是 BBRv3**（上游 BBRv3 补丁已合入，sysctl 名称仍沿用 `bbr`，
不存在 `bbr3` 这个值 —— 网上让你 `sysctl net.ipv4.tcp_congestion_control=bbr3` 的教程是错的）。

---

## 二、参数

两个脚本共用的：

| 参数 | 说明 |
|---|---|
| `-p PORT` | 监听端口，默认 `443` |
| `-s SNI` | REALITY 伪装域名，默认 `www.microsoft.com`（须支持 TLS1.3 + H2） |
| `-y` | 装完内核自动重启 |
| `--no-kernel` | 不动内核，只装 Xray |

`vn-landing.sh` 额外：

| 参数 | 说明 |
|---|---|
| `-a IP` | 只允许该 IP 访问代理端口（填香港机 IP）。用 nftables 独立 table 实现，chain policy 为 `accept`，**只对代理端口生效，不会影响 SSH** |

`hk-relay.sh` 额外：

| 参数 | 说明 |
|---|---|
| `-l LINK` | 越南落地机输出的 `vless://` 链接（必填） |
| `--cn-direct` | 命中 `geosite:cn` / `geoip:cn` 的流量在香港直接出，不绕越南 |

---

## 三、脚本都做了什么

1. **Xray-core**：用 XTLS 官方 `install-release.sh` 安装，systemd 托管，`LimitNOFILE=1000000`
2. **REALITY 凭据**：UUID、x25519 密钥对、shortId 全部本机随机生成，不写死在仓库里
3. **TCP 调优**（`/etc/sysctl.d/99-relay-tuning.conf`）：`fq` + `bbr`、收发缓冲区放大到 32MB、
   关闭 `tcp_slow_start_after_idle`（避免每次空闲后重新爬窗口）、开 TFO 与 MTU 探测
4. **XanMod 内核**：自动探测 CPU 微架构等级选包（v3 → `linux-xanmod-x64v3`，v2 → `x64v2`，
   更老 → `linux-xanmod-lts-x64v1`；主线分支没有 v4 包），源不可用时自动移除并回退，不会把系统搞坏
5. **香港侧路由**：`domainStrategy` 固定 `AsIs` —— 不在香港解析 DNS，域名原样带到越南再解析。
   省一次 RTT，且保证 CDN 返回的是**越南**就近节点（否则你会拿到香港的 CDN 节点，落地就白绕了）

配置文件在 `/usr/local/etc/xray/config.json`，覆盖前会自动备份为 `.bak.<时间戳>`。
凭据存在 `/usr/local/etc/xray/relay-info.txt`（0600），随时用 `relay-info` 命令查看。

---

## 四、排错

```bash
relay-info                      # 重新查看节点信息和链接
systemctl status xray           # 服务状态
journalctl -u xray -n 50        # 最近日志
xray -test -config /usr/local/etc/xray/config.json   # 校验配置
```

**香港自检显示链路不通**，按这个顺序查：

1. 越南机跑 `-a` 时填错了 IP → 在越南机上 `nft list table inet relayfw` 看放行的是不是香港机的公网 IP
2. 越南机的云厂商安全组没放行该端口
3. 链接复制不完整（没加单引号，`&` 后面被吃掉了）
4. 两台机器的 Xray 版本差太多 → 都重跑一遍脚本升到最新

**客户端连不上但香港自检是通的**：多半是客户端版本太老。
Xray v25 起 REALITY 客户端字段从 `publicKey` 改名为 `password`，脚本会按核心实际输出自适应，
但老客户端可能只认原始公钥 —— `relay-info` 里的 `RAW_PUBLIC_KEY` 就是备用值，替换链接里的 `pbk=` 再试。

---

## 五、卸载

```bash
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
rm -f /etc/sysctl.d/99-relay-tuning.conf /usr/local/bin/relay-info
sysctl --system
# 如果用过 -a：
nft delete table inet relayfw && nft list ruleset > /etc/nftables.conf
```

回退内核：`apt remove linux-xanmod-*` 后重启（Debian 会自动落回原内核）。

---

## 六、注意

- 仅适用于 **Debian / Ubuntu**；XanMod 内核仅 **x86_64**，其他架构脚本会自动跳过内核部分并提示
- 脚本会替换内核并需要重启，请在**能进救援模式/VNC 的机器**上操作
- 落地机不要再往上叠 Socks5 等无鉴权节点
