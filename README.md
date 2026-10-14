# WireGuard 一鍵安裝腳本

在 Ubuntu（核心 ≥ 5.6）伺服器上一鍵架設 WireGuard VPN，包含：安裝、設定、客戶端 import file、防火牆與 NAT 上網。

## 檔案

| 檔案 | 說明 |
|------|------|
| `wg.conf` | 統一設定檔：port、網段、endpoint、DNS、路徑（內建預設 < `wg.conf` < 環境變數） |
| `wg-install.sh` | 裝機：安裝、server 金鑰、`wg0`、`ip_forward`、防火牆/NAT（不管設備，可重跑） |
| `wg-manage.sh` | 設備管理：照 `devices.conf` 發 key、重建 `[Peer]`、產 `clients/*.conf` |
| `wg-status.sh` | 狀態查詢：握手、流量、online/stale、防火牆計數（唯讀） |
| `devices.conf` | 設備清單，一行一名，IP 自動配發（可寫 `<名稱> <IP>` 釘選） |
| `clients/` | 產出的 client `.conf`，一台一檔（勿進 git，含私鑰） |

## 使用方式

```bash
# 1. 裝機（一次即可，重跑安全，不會動 [Peer]）
sudo ./wg-install.sh

# 2. 改 wg.conf（endpoint、DNS 等，平時不用動）
# 3. 管設備：編輯 devices.conf（加減行），然後
sudo ./wg-manage.sh
# 不在名單的設備會一併刪除（peer/conf/key/IP），執行前會先印出新增/刪除清單

# 4. 查狀態
./wg-status.sh
```

## 可調參數

優先順序：內建預設 < `wg.conf` < 環境變數。平時改 `wg.conf` 即可，臨時覆寫用如 `WG_PORT=51820 ./wg-manage.sh`。

| 變數 | `wg.conf` 預設 | 說明 |
|------|---------------|------|
| `WG_CONF` | 與 script 同目錄的 `wg.conf` | 統一設定檔路徑 |
| `WG_PORT` | `30443` | 監聽 UDP 埠 |
| `WG_SUBNET` | `10.20.20.0/24` | VPN 內網網段 |
| `WG_SERVER_IP` | `10.20.20.1` | 伺服器隧道 IP |
| `WG_DEVICES` | `./devices.conf` | 設備清單檔路徑（一行一名，可加 IP 釘選） |
| `WG_MAP` | `/etc/wireguard/devices.map` | IP 配發記錄（主機狀態，不進版控） |
| `WG_OUT` | `./clients/` | client `.conf` 輸出目錄 |
| `WG_ENDPOINT` | `usvpn.bestsvip.vip` | 客戶端連線位址 |
| `WG_DNS` | `1.1.1.1` | 客戶端 DNS |
| `WG_ALLOWED_IPS` | `0.0.0.0/0` | 全流量走 VPN；只走內網可設如 `10.1.0.0/16` |
| `WG_OUT_IF` | 自動偵測 | 對外網卡（如 `enp0s6`），自動抓預設路由出口 |

## 腳本會做的事

1. **裝機**（`wg-install.sh`）：`apt-get install -y wireguard iptables iptables-persistent` → server 金鑰（已存在沿用）→ 寫 `wg0` `[Interface]`（保留既有 `[Peer]`）→ 啟動 + 開機自啟 → `ip_forward` → INPUT/FORWARD/NAT + 持久化
2. **管設備**（`wg-manage.sh + devices.conf`）：每台產生/沿用 key → 重建全部 `[Peer]` → `syncconf` 熱載入 → 產 `clients/<名稱>.conf`
3. **查狀態**（`wg-status.sh`）：握手、流量、online/stale、防火牆計數，唯讀

## 客戶端匯入（iPhone 官方 WireGuard App）

1. 下載設定檔：
```bash
scp ubuntu@usvpn.bestsvip.vip:/data/wireguard-installer/clients/<名稱>.conf .
```
2. 傳到 iPhone（AirDrop / Email / LINE）
3. 點開檔案 → 分享 → 用 WireGuard 開啟匯入
4. 打開開關連線

## 前置條件

- OCI Security List 的 Ingress 需放行 `UDP <port>`（來源 `0.0.0.0/0`）
- 連上後開 `ifconfig.me`，顯示伺服器公網 IP 即代表流量從伺服器出去

## 新增一台設備

```bash
# 1. devices.conf 加一行名字（IP 自動配）
echo "newpad" >> devices.conf

# 2. 生產設定檔（會顯示 + newpad 10.20.20.x）
sudo ./wg-manage.sh

# 3. 下載並匯入
scp ubuntu@usvpn.bestsvip.vip:/data/wireguard-installer/clients/newpad.conf .
```

## 移除一台設備

```bash
# 1. devices.conf 刪掉那行
# 2. 跑管理（會顯示 - <名稱>，peer/conf/key/IP 全刪）
sudo ./wg-manage.sh
```
注意：刪行後加回同名 = 全新設備（新 key），手機要重匯。

## 重要：一機一 key

同一個 `.conf` 不要同時給兩台上線，server 的 `endpoint` 會在兩個 IP 間跳、
握手無限重試（`wg-status.sh` 顯示 `stale`）。要多台用就照上面各發一台。

## 更換金鑰

金鑰外流、手機遺失、或定期輪換時使用。注意：換 key 後舊的手機設定立即失效，需重匯。

```bash
# 1. 刪除舊金鑰（server + 所有 client）
sudo rm -f /etc/wireguard/*.key /etc/wireguard/*.pub

# 2. 重跑裝機 + 設備管理（會產生全新金鑰並重載 wg0）
sudo ./wg-install.sh
sudo ./wg-manage.sh

# 3. 下載新的設定檔並重匯到手機
scp ubuntu@usvpn.bestsvip.vip:/data/wireguard-installer/clients/<名稱>.conf .
```

只換某台設備的 key（server 不動）：

```bash
sudo rm -f /etc/wireguard/<名稱>.key /etc/wireguard/<名稱>.pub
sudo ./wg-manage.sh
```

## 注意事項

- `.conf` 含私鑰，視同密碼，勿外流；傳完建議刪除家目錄副本
- 手機遺失時，從 `devices.conf` 刪掉那行後跑 `sudo ./wg-manage.sh`（peer/conf/key/IP 全刪）
- 與 IPsec 可並存（不同網段、不同埠）
