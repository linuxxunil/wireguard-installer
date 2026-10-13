# WireGuard 一鍵安裝腳本

在 Ubuntu（核心 ≥ 5.6）伺服器上一鍵架設 WireGuard VPN，包含：安裝、設定、客戶端 import file、防火牆與 NAT 上網。

## 檔案

| 檔案 | 說明 |
|------|------|
| `setup-wireguard.sh` | 主腳本（冪等，重跑安全） |

## 使用方式

```bash
sudo ./setup-wireguard.sh [client名稱]
```

範例：

```bash
sudo ./setup-wireguard.sh               # client 名稱為 iphone
sudo ./setup-wireguard.sh iphone2       # 第二台設備
sudo WG_PORT=51820 ./setup-wireguard.sh # 換埠
```

## 可調參數（環境變數）

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `WG_PORT` | `30443` | 監聽 UDP 埠 |
| `WG_SUBNET` | `10.20.20.0/24` | VPN 內網網段 |
| `WG_SERVER_IP` | `10.20.20.1` | 伺服器隧道 IP |
| `WG_CLIENT_IP` | `10.20.20.2` | 客戶端隧道 IP |
| `WG_ENDPOINT` | `example.com` | 客戶端連線位址 |
| `WG_DNS` | `1.1.1.1` | 客戶端 DNS |
| `WG_ALLOWED_IPS` | `0.0.0.0/0` | 全流量走 VPN；只走內網可設如 `10.1.0.0/16` |
| `WG_OUT_IF` | 自動偵測 | 對外網卡（如 `enp0s6`），自動抓預設路由出口 |
| `WG_OUT` | `/home/ubuntu` | client `.conf` 輸出目錄 |

## 腳本會做的事

1. **安裝**：`apt-get install -y wireguard iptables iptables-persistent`（缺一不可，裝完會逐一檢查指令是否存在）
2. **設定**：產生 server/client 金鑰（已存在則沿用）→ 寫 `/etc/wireguard/wg0.conf` → 啟動 `wg0` → 開機自啟 → 啟用 `ip_forward`
3. **Import file**：產生 `/home/ubuntu/<client>.conf`，下載後匯入手機 App
4. **防火牆/NAT**：INPUT 放行 UDP 埠、FORWARD 放行 VPN 網段、POSTROUTING MASQUERADE、`netfilter-persistent save` 持久化

## 客戶端匯入（iPhone 官方 WireGuard App）

1. 下載設定檔：
```bash
scp ubuntu@example.com:/home/ubuntu/wireguard-installer/iphone.conf .
```
2. 傳到 iPhone（AirDrop / Email / LINE）
3. 點開檔案 → 分享 → 用 WireGuard 開啟匯入
4. 打開開關連線

## 前置條件

- OCI Security List 的 Ingress 需放行 `UDP <port>`（來源 `0.0.0.0/0`）
- 連上後開 `ifconfig.me`，顯示伺服器公網 IP 即代表流量從伺服器出去

## 更換金鑰

金鑰外流、手機遺失、或定期輪換時使用。注意：換 key 後舊的手機設定立即失效，需重匯。

```bash
# 1. 刪除舊金鑰（server + 所有 client）
sudo rm -f /etc/wireguard/*.key /etc/wireguard/*.pub

# 2. 重跑腳本（會產生全新金鑰並重載 wg0）
sudo ./setup-wireguard.sh

# 3. 下載新的設定檔並重匯到手機
scp ubuntu@example.com:/home/ubuntu/wireguard-installer/iphone.conf .
```

只換某台設備的 key（server 不動）：

```bash
sudo rm -f /etc/wireguard/iphone.key /etc/wireguard/iphone.pub
sudo ./setup-wireguard.sh iphone
```

## 注意事項

- `.conf` 含私鑰，視同密碼，勿外流；傳完建議刪除家目錄副本
- 手機遺失時，從伺服器 `/etc/wireguard/wg0.conf` 刪除對應 `[Peer]` 並 `wg syncconf`（或重跑腳本前先刪該 client 的 key）
- 與 IPsec 可並存（不同網段、不同埠）
