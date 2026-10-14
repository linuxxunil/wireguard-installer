#!/bin/bash
#
# wg-manage.sh — WireGuard 設備管理（以 devices.conf 為唯一真相）
#   - devices.conf 一行一台，只寫名稱；IP 由本腳本自動配發
#     （也可寫 "<名稱> <隧道IP>" 手動釘選，自動配發會避開）
#   - 配發記錄在 /etc/wireguard/devices.map，同名重跑拿回同 IP
#   - 從 devices.conf 消失的設備：peer、clients/<名稱>.conf、
#     /etc/wireguard/<名稱>.key/.pub、IP 一併刪除（server.* 永遠不動）
#   - 沒被管過的孤兒 key 只列出提醒，不自動刪
#
# 用法:
#   sudo ./wg-manage.sh
#
# 可用環境變數覆寫預設值（優先順序：內建預設 < wg.conf < 環境變數）:
#   WG_CONF      統一設定檔          (預設與 script 同目錄的 wg.conf)
#   WG_DEVICES   設備清單檔          (預設 ./devices.conf，相對於 script 目錄)
#   WG_MAP       IP 配發記錄         (預設 /etc/wireguard/devices.map)
#   WG_PORT      監聽 UDP 埠          (預設 30443；已有 wg0.conf 時沿用檔內值)
#   WG_SUBNET    VPN 網段              (預設 10.20.20.0/24)
#   WG_SERVER_IP 伺服器隧道 IP         (預設 10.20.20.1；已有 wg0.conf 時沿用檔內值)
#   WG_ENDPOINT  客戶端連線位址        (預設 example.com)
#   WG_DNS       客戶端 DNS            (預設 1.1.1.1)
#   WG_ALLOWED_IPS 客戶端路由          (預設 0.0.0.0/0)
#   WG_OUT       client .conf 輸出目錄 (預設 ./clients/，統一管理)
#
# 特性: 冪等，重跑安全。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WG_CONF="${WG_CONF:-$SCRIPT_DIR/wg.conf}"
if [ -f "$WG_CONF" ]; then
  # shellcheck disable=SC1090
  . "$WG_CONF"
fi

abs_path() { # 相對路徑以 script 目錄為基準
  local p="${1#./}"
  p="${p%/}"
  case "$p" in
    /*) printf '%s' "$p" ;;
    *) printf '%s' "$SCRIPT_DIR/$p" ;;
  esac
}

if [ -n "${1:-}" ]; then
  echo "用法: sudo $0" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "請用 sudo 執行: sudo $0" >&2
  exit 1
fi

DEVICES_FILE="$(abs_path "${WG_DEVICES:-./devices.conf}")"
WG_DIR="/etc/wireguard"
MAP_FILE="${WG_MAP:-$WG_DIR/devices.map}"
WG_OUT="$(abs_path "${WG_OUT:-./clients/}")"
WG_PORT="${WG_PORT:-30443}"
WG_SUBNET="${WG_SUBNET:-10.20.20.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.20.20.1}"
WG_ENDPOINT="${WG_ENDPOINT:-example.com}"
WG_DNS="${WG_DNS:-1.1.1.1}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0}"

if [ ! -f "$DEVICES_FILE" ]; then
  echo "錯誤:找不到設備清單 $DEVICES_FILE" >&2
  exit 1
fi
if [ ! -f "$WG_DIR/server.key" ] || [ ! -f "$WG_DIR/server.pub" ]; then
  echo "錯誤:找不到 server 金鑰，請先跑 sudo ./wg-install.sh" >&2
  exit 1
fi
command -v wg >/dev/null || { echo "錯誤:找不到 wg，請先跑 sudo ./wg-install.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "錯誤:需要 python3 做 IP 配發" >&2; exit 1; }

# 若 wg0.conf 已有 [Interface]，沿用其 Address/ListenPort（裝機值優先於環境變數）
if [ -f "$WG_DIR/wg0.conf" ]; then
  EXIST_ADDR="$(awk -F'=' '/^Address/{gsub(/[ \t]/,"",$2); print $2; exit}' "$WG_DIR/wg0.conf" || true)"
  EXIST_PORT="$(awk -F'=' '/^ListenPort/{gsub(/[ \t]/,"",$2); print $2; exit}' "$WG_DIR/wg0.conf" || true)"
  [ -n "${EXIST_ADDR:-}" ] && WG_SERVER_IP="${EXIST_ADDR%%/*}"
  [ -n "${EXIST_PORT:-}" ] && WG_PORT="$EXIST_PORT"
fi

# ---------------- 解析 devices.conf（名稱 [+ 釘選IP]） ----------------
NAMES=()
PINNED=()   # 與 NAMES 對應，無釘選則為空字串
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(echo "$line" | awk '{$1=$1};1')"
  [ -z "$line" ] && continue
  name="$(echo "$line" | awk '{print $1}')"
  ip="$(echo "$line" | awk '{print $2}')"
  extra="$(echo "$line" | awk '{print $3}')"
  if [ -z "$name" ] || [ -n "$extra" ]; then
    echo "錯誤:devices.conf 格式錯誤（一行: <名稱> [隧道IP]）: $line" >&2
    exit 1
  fi
  if ! [[ "$name" =~ ^[a-z0-9_-]+$ ]]; then
    echo "錯誤:設備名稱只允許 [a-z0-9_-]: $name" >&2
    exit 1
  fi
  if [ -n "$ip" ] && ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "錯誤:IP 格式錯誤: $name $ip" >&2
    exit 1
  fi
  if [ -n "$ip" ] && [ "$ip" = "$WG_SERVER_IP" ]; then
    echo "錯誤:$name 的 IP 跟 server 相同: $ip" >&2
    exit 1
  fi
  NAMES+=("$name")
  PINNED+=("$ip")
done < "$DEVICES_FILE"

if [ "$(printf '%s\n' "${NAMES[@]}" | sort -u | wc -l)" -ne "${#NAMES[@]}" ]; then
  echo "錯誤:devices.conf 有重複的設備名稱" >&2
  exit 1
fi

# ---------------- 讀取配發記錄 ----------------
declare -A OLD_MAP=()   # 名稱 -> IP（上次配的）
if [ -f "$MAP_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(echo "$line" | awk '{$1=$1};1')"
    [ -z "$line" ] && continue
    OLD_MAP["$(echo "$line" | awk '{print $1}')"]="$(echo "$line" | awk '{print $2}')"
  done < "$MAP_FILE"
fi

# ---------------- 配發 IP ----------------
IPS=()
TAKEN=()   # 已佔用 IP（含釘選與已配發）
take() { TAKEN+=("$1"); }
is_taken() {
  local x="$1" t
  for t in "${TAKEN[@]:-}"; do [ "$t" = "$x" ] && return 0; done
  return 1
}

# 1) 釘選 IP 先佔位，並檢查合法性
for i in "${!NAMES[@]}"; do
  if [ -n "${PINNED[$i]}" ]; then
    if is_taken "${PINNED[$i]}"; then
      echo "錯誤:IP ${PINNED[$i]} 重複（${NAMES[$i]}）" >&2
      exit 1
    fi
    take "${PINNED[$i]}"
  fi
done

export SUBNET="$WG_SUBNET" SERVER_IP="$WG_SERVER_IP"
check_in_subnet() { # check_in_subnet <ip>，在網段內回 0
  SUBNET="$WG_SUBNET" IP="$1" python3 -c "
import ipaddress, os, sys
sys.exit(0 if ipaddress.ip_address(os.environ['IP']) in ipaddress.ip_network(os.environ['SUBNET']) else 1)
"
}
for i in "${!NAMES[@]}"; do
  if [ -n "${PINNED[$i]}" ] && ! check_in_subnet "${PINNED[$i]}"; then
    echo "錯誤:${PINNED[$i]} 不在 $WG_SUBNET 內" >&2
    exit 1
  fi
done

pick_free_ip() { # 輸出子網內最小空閒 host（排除 server 與已佔用），無則回 non-zero
  SUBNET="$WG_SUBNET" SERVER_IP="$WG_SERVER_IP" TAKEN_STR="${TAKEN[*]}" python3 -c "
import ipaddress, os, sys
net = ipaddress.ip_network(os.environ['SUBNET'])
taken = set(os.environ['TAKEN_STR'].split()) | {os.environ['SERVER_IP']}
for h in net.hosts():
    if str(h) not in taken:
        print(str(h)); sys.exit(0)
print('錯誤:網段內已無可用 IP', file=sys.stderr); sys.exit(1)
"
}

# 2) 非釘選：沿用舊配發，否則取最小空閒
for i in "${!NAMES[@]}"; do
  if [ -n "${PINNED[$i]}" ]; then
    IPS+=("${PINNED[$i]}")
    continue
  fi
  old="${OLD_MAP[${NAMES[$i]}]:-}"
  if [ -n "$old" ] && ! is_taken "$old" && check_in_subnet "$old" && [ "$old" != "$WG_SERVER_IP" ]; then
    IPS+=("$old")
    take "$old"
  else
    new_ip="$(pick_free_ip)"
    IPS+=("$new_ip")
    take "$new_ip"
  fi
done

# ---------------- 刪除清單（上次有、這次無） ----------------
GONE=()
for old_name in "${!OLD_MAP[@]}"; do
  keep=0
  for name in "${NAMES[@]}"; do
    if [ "$old_name" = "$name" ]; then keep=1; break; fi
  done
  if [ "$keep" -eq 0 ]; then GONE+=("$old_name"); fi
done

# ---------------- 預覽 ----------------
echo "=== 設備 (${#NAMES[@]} 台) ==="
for i in "${!NAMES[@]}"; do
  if [ -z "${OLD_MAP[${NAMES[$i]}]:-}" ]; then
    echo "  + ${NAMES[$i]}  ${IPS[$i]}  (新增)"
  else
    echo "    ${NAMES[$i]}  ${IPS[$i]}"
  fi
done
for g in ${GONE[@]:-}; do
  echo "  - $g  ${OLD_MAP[$g]}  (刪除:peer/conf/key/IP)"
done
echo ""

umask 077
mkdir -p "$WG_DIR" "$WG_OUT"

# ---------------- 執行刪除 ----------------
for g in ${GONE[@]:-}; do
  [ -z "$g" ] && continue
  rm -f "$WG_DIR/${g}.key" "$WG_DIR/${g}.pub"
  rm -f "${WG_OUT}/${g}.conf"
  echo "已刪除: $g (peer/conf/key/IP)"
done

# clients/ 下不在名單的殘留 .conf 也清掉（統一管理目錄）
for f in "$WG_OUT"/*.conf; do
  [ -e "$f" ] || continue
  base="$(basename "$f" .conf)"
  keep=0
  for name in "${NAMES[@]}"; do
    if [ "$base" = "$name" ]; then keep=1; break; fi
  done
  if [ "$keep" -eq 0 ]; then
    rm -f "$f"
    echo "已刪除殘留: $f"
  fi
done

# ---------------- 金鑰 ----------------
for name in "${NAMES[@]}"; do
  if [ -f "$WG_DIR/${name}.key" ] && [ -f "$WG_DIR/${name}.pub" ]; then
    echo "沿用既有 client($name) 金鑰"
  else
    echo "產生 client($name) 金鑰"
    wg genkey | tee "$WG_DIR/${name}.key" | wg pubkey > "$WG_DIR/${name}.pub"
    chmod 600 "$WG_DIR/${name}.key"
  fi
done

# ---------------- 重建 wg0.conf ----------------
SERVER_KEY="$(cat "$WG_DIR/server.key")"
SERVER_PUB="$(cat "$WG_DIR/server.pub")"
{
  echo "[Interface]"
  echo "Address = ${WG_SERVER_IP}/24"
  echo "ListenPort = ${WG_PORT}"
  echo "PrivateKey = ${SERVER_KEY}"
  echo "SaveConfig = false"
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    ip="${IPS[$i]}"
    pub="$(cat "$WG_DIR/${name}.pub")"
    echo ""
    echo "[Peer]"
    echo "# ${name}"
    echo "PublicKey = ${pub}"
    echo "AllowedIPs = ${ip}/32"
  done
} > "$WG_DIR/wg0.conf"
chmod 600 "$WG_DIR/wg0.conf"
echo "已寫入 $WG_DIR/wg0.conf（共 ${#NAMES[@]} 個 peer）"

if ip link show wg0 >/dev/null 2>&1; then
  echo "wg0 已存在,熱載入設定"
  wg syncconf wg0 <(wg-quick strip wg0)
else
  wg-quick up wg0
fi
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true

# ---------------- 產生 client conf ----------------
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  ip="${IPS[$i]}"
  ckey="$(cat "$WG_DIR/${name}.key")"
  {
    echo "[Interface]"
    echo "PrivateKey = ${ckey}"
    echo "Address = ${ip}/24"
    echo "DNS = ${WG_DNS}"
    echo ""
    echo "[Peer]"
    echo "PublicKey = ${SERVER_PUB}"
    echo "Endpoint = ${WG_ENDPOINT}:${WG_PORT}"
    echo "AllowedIPs = ${WG_ALLOWED_IPS}"
    echo "PersistentKeepalive = 25"
  } > "${WG_OUT}/${name}.conf"
  chmod 600 "${WG_OUT}/${name}.conf"
  echo "已產生: ${WG_OUT}/${name}.conf"
done

if id ubuntu >/dev/null 2>&1; then
  chown -R ubuntu:ubuntu "$WG_OUT"
  chmod 700 "$WG_OUT"
fi

# ---------------- 寫回配發記錄 ----------------
{
  for i in "${!NAMES[@]}"; do
    echo "${NAMES[$i]} ${IPS[$i]}"
  done
} > "$MAP_FILE"
chmod 600 "$MAP_FILE"

# ---------------- 孤兒 key 提醒（沒管過的不自動刪） ----------------
for kf in "$WG_DIR"/*.key; do
  [ -e "$kf" ] || continue
  base="$(basename "$kf" .key)"
  [ "$base" = "server" ] && continue
  known=0
  for name in "${NAMES[@]}"; do
    if [ "$base" = "$name" ]; then known=1; break; fi
  done
  if [ "$known" -eq 0 ]; then
    echo "提醒:孤兒 key 未處理: $kf（非 wg-manage.sh 配發；確認無用後手動刪除：sudo rm -f $kf ${kf%.key}.pub）"
  fi
done

echo ""
echo "=== 完成：${#NAMES[@]} 台 ==="
for i in "${!NAMES[@]}"; do
  echo "  ${NAMES[$i]}  ${IPS[$i]}  -> ${WG_OUT}/${NAMES[$i]}.conf"
done
