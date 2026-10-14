#!/bin/bash
#
# wg-status.sh — WireGuard 連線狀態查詢（唯讀，不改任何設定）
#   - 介面/監聽埠/公網 IP
#   - 每台設備（對照 devices.conf）：tunnel IP、endpoint、最後握手、收發量、online/stale
#   - 防火牆/NAT 計數、ip_forward
#
# 用法:
#   ./wg-status.sh            # 讀 wg/iptables 需要 sudo，會自動 sudo
#   sudo ./wg-status.sh
#
# 設定來自 wg.conf（WG_MAP 指定配發記錄位置），環境變數可覆寫。
#
# online 判定:最後握手在 180 秒內；超過為 stale；0 為從未握手。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WG_CONF="${WG_CONF:-$SCRIPT_DIR/wg.conf}"
if [ -f "$WG_CONF" ]; then
  # shellcheck disable=SC1090
  . "$WG_CONF"
fi
DEVICES_FILE="${WG_DEVICES:-$SCRIPT_DIR/devices.conf}"
DEVICES_FILE="${DEVICES_FILE#./}"; DEVICES_FILE="${DEVICES_FILE%/}"
case "$DEVICES_FILE" in /*) ;; *) DEVICES_FILE="$SCRIPT_DIR/$DEVICES_FILE" ;; esac
WG_PORT_DEFAULT="${WG_PORT:-30443}"
ONLINE_SECS=180

# 需要特權的指令：已是 root 直接跑，否則 sudo（可能要輸密碼）
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "=== WireGuard 狀態 ==="

# ---- 介面 ----
if ! $SUDO wg show wg0 >/dev/null 2>&1; then
  echo "wg0 未運行"
  if [ -f /etc/wireguard/wg0.conf ]; then
    echo "（/etc/wireguard/wg0.conf 存在但介面沒起來，可跑 sudo wg-quick up wg0）"
  fi
  exit 1
fi

LISTEN_PORT="$($SUDO wg show wg0 listen-port 2>/dev/null || echo "?")"
PUB_IP="$(curl -m5 -s ifconfig.me 2>/dev/null || echo "?")"
echo "interface : wg0 (listen udp/${LISTEN_PORT})"
echo "public-ip : ${PUB_IP}"
echo "forward   : $(sysctl -n net.ipv4.ip_forward 2>/dev/null || $SUDO sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
echo ""

# ---- devices.map / devices.conf 對照表（tunnelIP -> 名稱） ----
declare -A IP2NAME=()
MAP_FILE="${WG_MAP:-/etc/wireguard/devices.map}"
load_mapping() { # load_mapping <file>：讀「名稱 IP」對照
  local f="$1" line n ip
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | awk '{$1=$1};1')"
    [ -z "$line" ] && continue
    n="$(echo "$line" | awk '{print $1}')"
    ip="$(echo "$line" | awk '{print $2}')"
    [ -n "$n" ] && [ -n "$ip" ] && IP2NAME["$ip"]="$n"
  done < "$f"
}
if $SUDO test -r "$MAP_FILE" 2>/dev/null && [ -n "$($SUDO cat "$MAP_FILE" 2>/dev/null | head -1)" ]; then
  tmp="$(mktemp)"; $SUDO cat "$MAP_FILE" > "$tmp"; load_mapping "$tmp"; rm -f "$tmp"
elif [ -f "$DEVICES_FILE" ]; then
  load_mapping "$DEVICES_FILE"   # 退回：devices.conf 內的釘選 IP
fi

# ---- peers ----
printf '%-12s %-13s %-22s %-16s %-24s %s\n' "NAME" "TUNNEL-IP" "ENDPOINT" "HANDSHAKE" "TRANSFER(RX/TX)" "STATE"
NOW="$(date +%s)"
$SUDO wg show wg0 dump 2>/dev/null | tail -n +2 | while IFS="$(printf '\t')" read -r pub _psk endpoint allowed stamp rx tx _ka; do
  tunip="${allowed%%/*}"
  tunip="${tunip%%,*}"                       # 取第一個 allowed IP
  name="${IP2NAME[$tunip]:-?}"
  [ -z "$endpoint" ] || [ "$endpoint" = "(none)" ] && endpoint="-"
  if [ "$stamp" = "0" ]; then
    hs="never"; state="never"
  else
    age=$((NOW - stamp))
    if [ "$age" -lt 60 ]; then hs="${age}s ago"
    elif [ "$age" -lt 3600 ]; then hs="$((age/60))m$((age%60))s ago"
    else hs="$((age/3600))h$(((age%3600)/60))m ago"
    fi
    if [ "$age" -le "$ONLINE_SECS" ]; then state="online"; else state="stale"; fi
  fi
  # bytes 轉可讀
  human() {
    local b=$1
    if [ "$b" -ge 1073741824 ]; then awk "BEGIN{printf \"%.2fGiB\", $b/1073741824}"
    elif [ "$b" -ge 1048576 ]; then awk "BEGIN{printf \"%.2fMiB\", $b/1048576}"
    elif [ "$b" -ge 1024 ]; then awk "BEGIN{printf \"%.1fKiB\", $b/1024}"
    else echo "${b}B"; fi
  }
  printf '%-12s %-13s %-22s %-16s %-24s %s\n' "$name" "$tunip" "$endpoint" "$hs" "$(human "$rx")/$(human "$tx")" "$state"
done
echo ""
echo "(online = ${ONLINE_SECS}s 內有握手；stale = 有 endpoint 但握手逾時，多為同 key 雙上線搶線或回包被擋)"
echo ""

# ---- 防火牆計數 ----
echo "--- 防火牆 ---"
$SUDO iptables -L INPUT -n -v --line-numbers 2>/dev/null | grep -E "dpt:${LISTEN_PORT:-$WG_PORT_DEFAULT}|^Chain" || echo "INPUT 無 udp/${LISTEN_PORT:-$WG_PORT_DEFAULT} 規則"
$SUDO iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -E "MASQUERADE|^Chain" || echo "nat 無 MASQUERADE 規則"
