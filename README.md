# DPM 採集程式 — 安裝說明

在現場閘道器（Ubuntu）上讀取 DPM 電表，透過 MQTT 上傳；斷網時資料會先存本機，連上後自動補送。

---

## 安裝前準備

- Ubuntu 20.04 以上（64-bit 完整支援；ARMv7/armhf 使用 SQLite-only 相容模式）
- 板載 RS-485 已接到電表（BL118：485A-1/485B-1 → `/dev/ttyS1`；安裝時會列出板載序列埠讓你選）
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
腳本會自動安裝 Node.js、InfluxDB（本機 7 天備份）並啟動服務。
ARMv7/armhf 上會安裝 Node.js 22 並略過不支援 32-bit ARM 的 InfluxDB 2；
未送達 MQTT 的資料仍由 SQLite 佇列保存，但不提供 Influx 7 天歷史。

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
