# DPM 採集程式 — 安裝說明（BL118）

在鋇錸 **BL118** 閘道上讀取電表（**DPM-DA530／DPM-DA510** 或 **CPM-12D**，安裝時選擇；同一閘道不可混接），透過 MQTT 上傳；採樣先寫本機 SQLite（預設保留 7 天），已送過的不重送，逾期刪除。斷網時未送筆會在連上後自動補送。

---

## 建議：筆電部署精靈（不必用終端機）

1. 取得 **DPM 設定精靈**
   - **Windows（建議）**：`dpm-setup-wizard-win.zip`（內含 `.exe`，不必裝 Node）
   - **Linux／macOS**（或 Windows 備援）：`dpm-setup-wizard` zip／客戶倉（需 Node 18+）
2. 筆電設 `192.168.3.x`，網線接 BL118 **LAN**
3. Windows：雙擊 `dpm-setup-wizard.exe`；其他：執行 `start.cmd`／`./start.sh`
4. 瀏覽器依 **Step 1 → Step 2** 填 GATEWAY_ID、MQTT 密碼、**電表型號（DPM／CPM 二選一）**、站號與 GUID，按部署

SSH 僅由精靈在背景使用，現場不必手動 `vi` 或下指令。連線帳密預設已內建；若需修改，在畫面操作即可（本次有效，不寫本機設定檔）。

### 精靈連不上時：手動經 Node-RED 設 SSH 密碼

畫面「經 Node-RED 設密」失敗時，可手動在閘道 Node-RED 把系統 SSH 密碼設回約定值，再回精靈連線。

| 用途 | 常見出廠帳密 |
|------|----------------|
| Node-RED 編輯器 | `root`／`123456` |
| 系統 SSH（精靈用） | 下方會設成 `root`／`bl118rentec` |

1. 瀏覽器開 `http://閘道IP:1880`（例：`http://192.168.3.1:1880`），用編輯器帳密登入
2. 新增 **inject**（時間戳）→ **exec**，exec 指令：

   ```bash
   echo "root:bl118rentec" | chpasswd
   ```

3. inject 勾「立即執行於」**0.1** 秒、重複「無」→ 部署
4. 回精靈，密碼填 `bl118rentec` →「儲存並連線」
5. 成功後可刪該暫時 flow；部署完成後建議改成專用 SSH 密碼

詳見設定精靈包內 `README.md` 同名章節。

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

依畫面輸入 Gateway ID、**電表型號**、序列埠、Modbus 站號、MQTT 密碼即可。  
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
