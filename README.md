# DPM 採集程式 — 安裝說明（BL118）

在鋇錸 **BL118** 閘道上讀取 **DPM-DA530（DPM-DA510）**，透過 MQTT 上傳；採樣先寫本機 SQLite（預設保留 7 天），已送過的不重送，逾期刪除。斷網時未送筆會在連上後自動補送。

---

## 建議：筆電部署精靈（不必用終端機）

1. 取得 **DPM 設定精靈**
   - **Windows（建議）**：`dpm-setup-wizard-win.zip`（內含 `.exe`，不必裝 Node）
   - **Linux／macOS**（或 Windows 備援）：`dpm-setup-wizard` zip／客戶倉（需 Node 18+）
2. 筆電設 `192.168.3.x`，網線接 BL118 **LAN**
3. Windows：雙擊 `dpm-setup-wizard.exe`；其他：執行 `start.cmd`／`./start.sh`
4. 瀏覽器依 **Step 1 → Step 2** 填 GATEWAY_ID、MQTT 密碼、站號與 GUID，按部署

SSH 僅由精靈在背景使用，現場不必手動 `vi` 或下指令。連線帳密預設已內建；若需修改，在畫面操作即可（本次有效，不寫本機設定檔）。

---

## 備援：終端機安裝

### 安裝前準備

- BL118（Ubuntu 20.04 以上）
- 板載 RS-485 已接到電表（現場實測 Pin 1／Pin 2 → `/dev/ttyAS4`）
- 向後台取得：**Gateway ID**、**MQTT 密碼**、各台設備 **GUID**

### 安裝

```bash
sudo git clone https://github.com/vippaFor9skin/dpm-collector-release.git /opt/dpm-collector
cd /opt/dpm-collector
# 請先編輯 config/device-identities.json（可複製 .example）
sudo ./install.sh
```

依畫面輸入 Gateway ID、序列埠、Modbus 站號、MQTT 密碼即可。  
腳本會自動安裝 Node.js、依賴，並以 systemd 啟動服務。

若設定檔已由部署精靈寫好，亦可非互動安裝：

```bash
sudo DPM_NONINTERACTIVE=1 ./install.sh
```

安裝成功後，若 `install.sh` 是從其他暫存目錄執行，該來源專案會自動刪除；直接在 `/opt/dpm-collector` 就地安裝則會保留正式安裝目錄。腳本結束後請依提示執行：

```bash
cd /opt/dpm-collector
```

Shell 不允許子腳本直接更改呼叫端的目前目錄，因此無法由 `install.sh` 自動完成這個 `cd`。

---

## 日常操作

```bash
cd /opt/dpm-collector

sudo ./dpm-ctl.sh status      # 看狀態與最近日誌
sudo ./dpm-ctl.sh logs        # 即時日誌（Ctrl+C 離開）
sudo ./dpm-ctl.sh restart     # 重啟
sudo ./dpm-ctl.sh update      # 拉新版本並更新
```

改過 `.env` 或 `config/device-identities.json` 後，請執行 `restart`。

### 遠端更新（MQTT）

閘道連上 MQTT 後會訂閱 `gw/cmd/{GATEWAY_ID}`。辦公室可用維運帳對該 topic 下發
`{"message_kind":"cmd","command":"update","request_id":"…"}`，閘道會自行
`git pull` 並重跑安裝更新（與上方 `dpm-ctl update` 相同）。結果回報在
`gw/status/{GATEWAY_ID}`。關閉：`.env` 設 `MQTT_REMOTE_UPDATE=0` 後重啟服務。

---

## 常見問題

| 狀況 | 怎麼查 |
|------|--------|
| 服務起不來 | `sudo ./dpm-ctl.sh check-config` |
| MQTT 連不上 | 確認 `.env` 的 `MQTT_USERNAME`／`MQTT_PASSWORD`（後台站點 MQTT 帳）；`sudo ./dpm-ctl.sh test-mqtt` |
| Modbus 讀不到 | 確認板載 485A/B 接線與站號；`sudo ./dpm-ctl.sh test-modbus` |

---

## 需要協助時

請提供：

```bash
cat /opt/dpm-collector/VERSION
sudo /opt/dpm-collector/dpm-ctl.sh status
```
