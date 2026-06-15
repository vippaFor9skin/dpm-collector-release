# DPM-DA510/530 Modbus RTU 採集程式 — 客戶安裝說明

本套件主程式為根目錄 **`index.js`**（已打包，無 `src/`），來自公開倉庫 **`dpm-collector-release`**。  
`git pull` 後執行 `install.sh` 或 `dpm-ctl update` 即可；**不必**手動編輯 `lib/`（依賴鎖定與 systemd 範本由安裝腳本自動處理）。

---

## 系統需求

- Ubuntu 20.04+（64-bit）
- Node.js **24+**（安裝腳本可自動安裝）
- RS-485 USB 序列埠（如 `/dev/ttyUSB0`）
- InfluxDB 2（**必填**，`install.sh` 自動安裝；僅本機 127.0.0.1，保留 7 天）

---

## 一鍵安裝（Git 倉庫）

```bash
sudo mkdir -p /opt
sudo git clone https://github.com/vippaFor9skin/dpm-collector-release.git /opt/dpm-collector
cd /opt/dpm-collector
sudo ./install.sh
```

> 倉庫根目錄即為可執行程式；`node_modules` 由 `install.sh` 自動安裝，不在 Git 內。`lib/` 為內部檔，無需手動修改。

安裝腳本會：

1. 將程式部署到 `/opt/dpm-collector`
2. 安裝 Node.js 24+（若尚未安裝）
3. 執行 `npm ci` 安裝依賴
4. **互動式建立 `.env`**（GATEWAY_ID、**自動偵測 USB 序列埠選單**、Modbus Slave IDs；MQTT／輪詢等使用預設值）
5. **自動安裝並初始化 InfluxDB 2**（本地 7 天緩存，僅本機可連）
6. 建立 systemd 服務 `dpm-collector` 並啟動

### 斷網與資料安全

每筆採樣會**同時**寫入：

| 層 | 用途 |
|----|------|
| **SQLite 佇列**（`data/dpm.db`） | 尚未送達伺服器的 JSON；MQTT 成功後刪除 |
| **InfluxDB 2**（本機 7 天） | 本地時序備份；含 `mqtt_published` 標記 |

MQTT 暫時無法連線時，程式**不會停止**採集；恢復網路或重啟後會自動補送佇列至伺服器。

---

## 離線安裝（USB 隨身碟，與 Git 同版）

USB 內容由 `npm run release:usb` 產生（須先 `npm run release:client`），**與客戶 Git 倉庫同一 commit**；離線目錄額外含 `node_modules`（**僅在隨身碟，不在 Git 倉庫**）。

**隨身碟目錄（根目錄）：**

```
install-from-usb.sh
MANIFEST.json
dpm-collector.bundle
offline/dpm-collector/
```

**現場安裝（推薦）：**

```bash
cd /media/usb/          # 隨身碟掛載點
sudo ./install-from-usb.sh
```

或手動：

```bash
cd offline/dpm-collector
sudo ./install.sh
```

離線包已含 `node_modules` 與 `.git`，安裝時**不會**執行 `npm ci`（`node_modules` 僅適用打包時相同 CPU 架構）。

**恢復連線後更新**（與 Git 安裝相同）：

```bash
sudo /opt/dpm-collector/dpm-ctl.sh update
```

亦可從 bundle 離線 clone（備用）：

```bash
git clone /path/to/usb/dpm-collector.bundle dpm-collector
cd dpm-collector && sudo ./install.sh
```

---

## 更新版本

已用 Git 安裝時：

```bash
sudo /opt/dpm-collector/dpm-ctl.sh update
```

或手動：

```bash
cd /opt/dpm-collector   # 若為 git clone 目錄
git pull
sudo ./install.sh       # 更新模式：只更新 dist 並重啟
```

---

## 服務管理

安裝完成後，使用 `/opt/dpm-collector/dpm-ctl.sh`：

| 指令 | 說明 |
|------|------|
| `dpm-ctl.sh status` | 服務狀態 + 最近日誌 |
| `dpm-ctl.sh logs` | 即時日誌 |
| `dpm-ctl.sh restart` | 重啟 |
| `dpm-ctl.sh check-config` | 檢查 `.env` |
| `dpm-ctl.sh test-mqtt` | 測試 MQTT 連線 |
| `dpm-ctl.sh test-modbus` | 測試 Modbus 讀取 |

systemd 服務名稱：`dpm-collector`

```bash
sudo systemctl status dpm-collector
sudo journalctl -u dpm-collector -f
```

---

## 設定檔

| 檔案 | 說明 |
|------|------|
| `/opt/dpm-collector/.env` | 執行參數（MQTT、Modbus、Influx 等） |
| `/opt/dpm-collector/config/device-identities.json` | 設備身分對照（GUID、device_id） |
| `/opt/dpm-collector/data/dpm.db` | SQLite MQTT 佇列（自動建立） |

修改 `.env` 或 `device-identities.json` 後請重啟：

```bash
sudo /opt/dpm-collector/dpm-ctl.sh restart
```

`.env` 欄位說明請參考同目錄 `.env.example`。

---

## 版本查詢

```bash
cat /opt/dpm-collector/VERSION
```

---

## 疑難排解

**服務無法啟動**

```bash
sudo /opt/dpm-collector/dpm-ctl.sh check-config
sudo journalctl -u dpm-collector -n 50 --no-pager
```

**Modbus 讀不到**

- 確認序列埠：`ls -l /dev/ttyUSB*`
- 確認權限：`dpm` 使用者需能讀寫序列埠（通常需加入 `dialout` 群組）
- 測試：`sudo /opt/dpm-collector/dpm-ctl.sh test-modbus`

**MQTT 連不上**

- 測試：`sudo /opt/dpm-collector/dpm-ctl.sh test-mqtt`
- 確認 `GATEWAY_ID`、`MQTT_URL`、帳密

---

## 技術支援

回報問題時請附上：

```bash
cat /opt/dpm-collector/VERSION
sudo /opt/dpm-collector/dpm-ctl.sh status
uname -a
```
