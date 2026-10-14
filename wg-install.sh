#!/bin/bash
#
# wg-install.sh — WireGuard 裝機（只管主機，不管設備）
#   a. 安裝 wireguard / iptables
#   b. server 金鑰 + wg0 [Interface] + 啟動 + 開機自啟 + ip_forward
#   c. 防火牆 + NAT（INPUT 放行 UDP、FORWARD 放行 VPN 網段、POSTROUTING MASQUERADE）
#
# 用法:
#   sudo ./wg-install.sh
#
# 可用環境變數覆寫預設值:
#   WG_CONF      統一設定檔          (預設與 script 同目錄的 wg.conf)
#   WG_PORT      監聽 UDP 埠        (預設 30443)
#   WG_SUBNET    VPN 網段            (預設 10.20.20.0/24)
#   WG_SERVER_IP 伺服器隧道 IP       (預設 10.20.20.1)
#   WG_OUT_IF    對外網卡 (預設自動偵測預設路由出口)
#
# 變數優先順序:內建預設 < wg.conf < 環境變數。
#
# 設備管理請用 wg-manage.sh + devices.conf，本腳本不會動任何 [Peer]。
# 特性: 冪等，重跑安全；已存在的金鑰與 [Peer] 會沿用。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WG_CONF="${WG_CONF:-$SCRIPT_DIR/wg.conf}"
if [ -f "$WG_CONF" ]; then
  # shellcheck disable=SC1090
  . "$WG_CONF"
fi

WG_PORT="${WG_PORT:-30443}"
WG_SUBNET="${WG_SUBNET:-10.20.20.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.20.20.1}"
WG_DIR="/etc/wireguard"

OUT_IF="${WG_OUT_IF:-$(ip route show default 2>/dev/null | awk '{print $5; exit}')}"
if [ -z "$OUT_IF" ]; then
  echo "錯誤:找不到預設路由出口網卡，可用 WG_OUT_IF 指定" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "請用 sudo 執行: sudo $0" >&2
  exit 1
fi

echo "=== WireGuard 裝機 ==="
echo "port   : udp/$WG_PORT"
echo "subnet : $WG_SUBNET (server $WG_SERVER_IP)"
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

# ---------------- b. 主機設定 ----------------
echo "--- [b] 主機設定 ---"
umask 077
mkdir -p "$WG_DIR"

if [ -f "$WG_DIR/server.key" ] && [ -f "$WG_DIR/server.pub" ]; then
  echo "沿用既有 server 金鑰"
else
  echo "產生 server 金鑰"
  wg genkey | tee "$WG_DIR/server.key" | wg pubkey > "$WG_DIR/server.pub"
  chmod 600 "$WG_DIR/server.key"
fi

SERVER_KEY="$(cat "$WG_DIR/server.key")"

# 啟用 IP 轉發 (持久化)
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# 重寫 [Interface]，但保留既有 [Peer]（裝機不應踢掉設備）
PEERS_TMP="$(mktemp)"
if [ -f "$WG_DIR/wg0.conf" ]; then
  awk 'BEGIN{p=0} /^\[Peer\]/{p=1} p{print}' "$WG_DIR/wg0.conf" > "$PEERS_TMP" || true
fi
{
  echo "[Interface]"
  echo "Address = ${WG_SERVER_IP}/24"
  echo "ListenPort = ${WG_PORT}"
  echo "PrivateKey = ${SERVER_KEY}"
  echo "SaveConfig = false"
  echo ""
  if [ -s "$PEERS_TMP" ]; then
    cat "$PEERS_TMP"
  fi
} > "$WG_DIR/wg0.conf"
rm -f "$PEERS_TMP"
chmod 600 "$WG_DIR/wg0.conf"
echo "已寫入 $WG_DIR/wg0.conf（[Peer] 已保留）"

if ip link show wg0 >/dev/null 2>&1; then
  echo "wg0 已存在,熱載入設定"
  wg syncconf wg0 <(wg-quick strip wg0)
else
  wg-quick up wg0
fi
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
echo "wg0 運行中:"
wg show wg0 | sed 's/private key.*/private key: (hidden)/'

# ---------------- c. 防火牆 + NAT ----------------
echo "--- [c] 防火牆 + NAT ---"

add_rule() {
  local table="$1"; shift
  local chain="$1"; shift
  if ! iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
    iptables -t "$table" -A "$chain" "$@"
    echo "加入: -t $table $chain $*"
  else
    echo "已存在,略過: -t $table $chain $*"
  fi
}

insert_before_reject() {
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

echo ""
echo "=== 完成 ==="
echo "下一步:編輯 devices.conf 後跑  sudo ./wg-manage.sh  來發 client 設定檔"
