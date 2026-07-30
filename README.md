# DPM 採集程式 — 安裝說明（BL118）

在鋇錸 **BL118** 閘道上讀取 **DPM-DA530（DPM-DA510）**，透過 MQTT 上傳；採樣先寫本機 SQLite（預設保留 7 天），已送過的不重送，逾期刪除。斷網時未送筆會在連上後自動補送。

---

## 安裝前準備

- BL118（Ubuntu 20.04 以上）
- 板載 RS-485 已接到電表（現場實測 Pin 1／Pin 2 → `/dev/ttyAS4`）
- 向後台取得：**Gateway ID**、**MQTT 密碼**
- 編輯 `config/device-identities.json`（可先複製 `.example`），填入各台設備的 GUID

---

## 安裝

```bash
sudo git clone https://github.com/vippaFor9skin/dpm-collector-release.git /opt/dpm-collector
cd /opt/dpm-collector
sudo ./install.sh
```

依畫面輸入 Gateway ID、序列埠、Modbus 站號、MQTT 密碼即可。  
腳本會自動安裝 Node.js、依賴，並以 systemd 啟動服務。本機 SQLite 預設保留 7 天；已成功上報 MQTT 的資料只留作備援、不會重送。

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

---

## 常見問題

| 狀況 | 怎麼查 |
|------|--------|
| 服務起不來 | `sudo ./dpm-ctl.sh check-config` |
| MQTT 連不上 | 確認 `.env` 的 `MQTT_PASSWORD`；`sudo ./dpm-ctl.sh test-mqtt` |
| Modbus 讀不到 | 確認板載 485A/B 接線與站號；`sudo ./dpm-ctl.sh test-modbus` |

---

## 需要協助時

請提供：

```bash
cat /opt/dpm-collector/VERSION
sudo /opt/dpm-collector/dpm-ctl.sh status
```
