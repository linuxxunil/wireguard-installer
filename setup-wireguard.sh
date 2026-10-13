#!/bin/bash
#
# setup-wireguard.sh — WireGuard 一鍵安裝腳本
#   a. 安裝 wireguard
#   b. 設定 (金鑰 + wg0.conf + 啟動 + 開機自啟)
#   c. 產生 client import file (.conf, 無 QR code)
#   d. 防火牆 + NAT 上網
#
# 用法:
#   sudo ./setup-wireguard.sh [client名稱]
#
# 可用環境變數覆寫預設值:
#   WG_PORT        監聽 UDP 埠          (預設 30443)
#   WG_SUBNET      VPN 網段              (預設 10.20.20.0/24)
#   WG_SERVER_IP   伺服器隧道 IP         (預設 10.20.20.1)
#   WG_CLIENT_IP   客戶端隧道 IP         (預設 10.20.20.2)
#   WG_ENDPOINT    客戶端連線位址        (預設 example.com)
#   WG_DNS         客戶端 DNS            (預設 8.8.8.8)
#   WG_ALLOWED_IPS 客戶端路由 (full tunnel 0.0.0.0/0, split tunnel 如 10.1.0.0/16)
#                                            (預設 0.0.0.0/0)
#   WG_OUT_IF    對外網卡 (預設自動偵測預設路由出口,如 enp0s6)
#   WG_OUT         檔輸出目錄            (預設與 script 相同目錄)
#
# 特性: 冪等設計,重跑不會產生重複規則;已存在的金鑰會沿用,不會覆蓋。
#
set -euo pipefail

# ---------------- 參數 ----------------
CLIENT_NAME="${1:-iphone}"
WG_PORT="${WG_PORT:-30443}"
WG_SUBNET="${WG_SUBNET:-10.20.20.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.20.20.1}"
WG_CLIENT_IP="${WG_CLIENT_IP:-10.20.20.2}"
WG_ENDPOINT="${WG_ENDPOINT:-example.com}"
WG_DNS="${WG_DNS:-1.1.1.1}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WG_OUT="${WG_OUT:-$SCRIPT_DIR}"
WG_DIR="/etc/wireguard"

# 對外網卡:可用 WG_OUT_IF 指定,否則自動偵測預設路由出口
OUT_IF="${WG_OUT_IF:-$(ip route show default 2>/dev/null | awk '{print $5; exit}')}"
if [ -z "$OUT_IF" ]; then
  echo "錯誤:找不到預設路由出口網卡" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "請用 sudo 執行: sudo $0 [client名稱]" >&2
  exit 1
fi

echo "=== WireGuard 安裝設定 ==="
echo "client : $CLIENT_NAME"
echo "port   : udp/$WG_PORT"
echo "subnet : $WG_SUBNET (server $WG_SERVER_IP, client $WG_CLIENT_IP)"
echo "out-if : $OUT_IF"
echo ""

# ---------------- a. 安裝 ----------------
echo "--- [a] 安裝 wireguard ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables iptables-persistent
command -v wg >/dev/null || { echo "wg 安裝失敗" >&2; exit 1; }
command -v iptables >/dev/null || { echo "iptables 安裝失敗" >&2; exit 1; }
command -v netfilter-persistent >/dev/null || { echo "netfilter-persistent 安裝失敗" >&2; exit 1; }
echo "安裝完成: $(wg --version 2>&1 | head -1), $(iptables --version 2>&1 | head -1)"

# ---------------- b. 設定 ----------------
echo "--- [b] 設定 ---"
umask 077
mkdir -p "$WG_DIR"

# server 金鑰:已存在則沿用
if [ -f "$WG_DIR/server.key" ] && [ -f "$WG_DIR/server.pub" ]; then
  echo "沿用既有 server 金鑰"
else
  echo "產生 server 金鑰"
  wg genkey | tee "$WG_DIR/server.key" | wg pubkey > "$WG_DIR/server.pub"
  chmod 600 "$WG_DIR/server.key"
fi

# client 金鑰:已存在則沿用
if [ -f "$WG_DIR/${CLIENT_NAME}.key" ] && [ -f "$WG_DIR/${CLIENT_NAME}.pub" ]; then
  echo "沿用既有 client($CLIENT_NAME) 金鑰"
else
  echo "產生 client($CLIENT_NAME) 金鑰"
  wg genkey | tee "$WG_DIR/${CLIENT_NAME}.key" | wg pubkey > "$WG_DIR/${CLIENT_NAME}.pub"
  chmod 600 "$WG_DIR/${CLIENT_NAME}.key"
fi

SERVER_KEY="$(cat "$WG_DIR/server.key")"
CLIENT_PUB="$(cat "$WG_DIR/${CLIENT_NAME}.pub")"

# 啟用 IP 轉發 (持久化)
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# wg0.conf
cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_KEY}
SaveConfig = false

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF
chmod 600 "$WG_DIR/wg0.conf"
echo "已寫入 $WG_DIR/wg0.conf"

# 啟動介面 (已存在則熱載入)
if ip link show wg0 >/dev/null 2>&1; then
  echo "wg0 已存在,熱載入設定"
  wg syncconf wg0 <(wg-quick strip wg0)
else
  wg-quick up wg0
fi
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
echo "wg0 運行中:"
wg show wg0 | sed 's/private key.*/private key: (hidden)/'

# ---------------- c. import file ----------------
echo "--- [c] 產生 import file ---"
CLIENT_KEY="$(cat "$WG_DIR/${CLIENT_NAME}.key")"
SERVER_PUB="$(cat "$WG_DIR/server.pub")"
CLIENT_CONF="${WG_OUT}/${CLIENT_NAME}.conf"

cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${CLIENT_KEY}
Address = ${WG_CLIENT_IP}/24
DNS = ${WG_DNS}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${WG_ENDPOINT}:${WG_PORT}
AllowedIPs = ${WG_ALLOWED_IPS}
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF"
# 讓 ubuntu 使用者可用 scp 下載
if id ubuntu >/dev/null 2>&1; then
  chown ubuntu:ubuntu "$CLIENT_CONF"
fi
echo "已產生: $CLIENT_CONF"

# ---------------- d. 防火牆 + NAT ----------------
echo "--- [d] 防火牆 + NAT ---"

add_rule() {
  # add_rule <table> <chain> <rule...>: 不存在才加
  local table="$1"; shift
  local chain="$1"; shift
  if ! iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    iptables -t "$table" -A "$chain" "$@"
    echo "加入: -t $table $chain $*"
  else
    echo "已存在,略過: -t $table $chain $*"
  fi
}

# INPUT 放行前先確認 REJECT 位置:把 ACCEPT 插在 REJECT 之前。
# 作法:若 REJECT 存在,先記下行號,逐條插入;簡化做法:直接 -I 到 REJECT 之前。
insert_before_reject() {
  # insert_before_reject <chain> <rule...>
  local chain="$1"; shift
  if iptables -C "$chain" "$@" 2>/dev/null; then
    echo "已存在,略過: $chain $*"
    return 0
  fi
  local rline
  rline="$(iptables -L "$chain" --line-numbers -n 2>/dev/null | awk '$2=="REJECT"{print $1; exit}')"
  if [ -n "$rline" ]; then
    iptables -I "$chain" "$rline" "$@"
  else
    iptables -A "$chain" "$@"
  fi
  echo "加入: $chain $*"
}

insert_before_reject INPUT -p udp --dport "$WG_PORT" -j ACCEPT
insert_before_reject FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
insert_before_reject FORWARD -s "$WG_SUBNET" -j ACCEPT
insert_before_reject FORWARD -d "$WG_SUBNET" -j ACCEPT
add_rule nat POSTROUTING -s "$WG_SUBNET" -o "$OUT_IF" -j MASQUERADE

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
  echo "防火牆規則已持久化"
else
  echo "注意:未安裝 iptables-persistent,重開機後規則會遺失" >&2
fi

# ---------------- 完成 ----------------
echo ""
echo "=== 完成 ==="
echo "伺服器: ${WG_SERVER_IP} 監聽 udp/${WG_PORT}, peer ${CLIENT_NAME} (${WG_CLIENT_IP})"
echo "下載設定檔:"
echo "  scp -P 3822 ubuntu@${WG_ENDPOINT}:${CLIENT_CONF} ."
echo "匯入方式: WireGuard App → + → Create from file or archive"
