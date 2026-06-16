#!/usr/bin/env bash
# =============================================================================
# dpm-ctl.sh — DPM Collector 現場維運工具
#
# 安裝後位於 /opt/dpm-collector/dpm-ctl.sh，由 systemd 以外的工程師手動呼叫。
# 多數指令需 root（或 sudo）才能操作 systemd / 讀取 .env。
#
# 典型用法：
#   sudo ./dpm-ctl.sh status
#   sudo ./dpm-ctl.sh logs -n 50
#   sudo ./dpm-ctl.sh update          # git pull + install.sh（更新模式）
#   sudo ./dpm-ctl.sh test-mqtt
# =============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/dpm-collector}"
SERVICE_NAME="${SERVICE_NAME:-dpm-collector}"

die() { echo "❌ $*" >&2; exit 1; }

usage() {
  cat <<EOF
用法: $(basename "$0") <command>

  status          檢查 systemd 狀態 + 最近 20 行日誌
  logs [-n N]     即時查看日誌（預設 -n 100）
  restart         重啟服務
  start           啟動服務
  stop            停止服務
  update          git pull 後重新執行 install.sh（更新模式）
  enable          設定開機自啟
  disable         取消開機自啟
  check-config    檢查 .env 設定完整性
  test-influx     測試 InfluxDB 連線
  test-mqtt       測試 MQTT 連線
  test-modbus     測試 Modbus 讀取（單次）
EOF
}

require_install_dir() {
  [[ -d "$INSTALL_DIR" ]] || die "找不到安裝目錄 $INSTALL_DIR"
}

# journalctl 預設會加上「Jun 15 … dpm-collector[pid]:」前綴；
# -o cat 只輸出應用程式自己印的內容（與程式內台北時間戳一致）。
journal_app_logs() {
  journalctl -u "$SERVICE_NAME" -o cat "$@"
}

cmd_status() {
  systemctl status "$SERVICE_NAME" --no-pager || true
  echo "--- 最近 20 行日誌 ---"
  journal_app_logs -n 20 --no-pager
}

cmd_logs() {
  local lines=100
  if [[ "${1:-}" == "-n" && -n "${2:-}" ]]; then
    lines="$2"
    shift 2
  fi
  journal_app_logs -f -n "$lines"
}

# sudo 與 clone 擁有者不同時，root 執行 git 可能觸發 safe.directory 錯誤。
ensure_git_safe_directory() {
  local dir
  dir="$(readlink -f "$INSTALL_DIR" 2>/dev/null || realpath "$INSTALL_DIR")"
  [[ -d "$dir/.git" ]] || return 0
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  if git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$dir"; then
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    git config --global --add safe.directory "$dir"
  else
    sudo git config --global --add safe.directory "$dir"
  fi
}

# 更新流程：pull → install.sh（偵測為更新模式，保留 .env，重裝依賴與重啟服務）。
cmd_update() {
  require_install_dir
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    ensure_git_safe_directory
    # 目錄擁有者為工程師時可直接 pull；否則 fallback sudo。
    if [[ -w "$INSTALL_DIR" ]] && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
      git -C "$INSTALL_DIR" pull
    elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      git -C "$INSTALL_DIR" pull
    else
      sudo git -C "$INSTALL_DIR" pull
    fi
  else
    die "$INSTALL_DIR 不是 git 倉庫；請 git clone 客戶公開倉庫，或使用 USB 離線包安裝"
  fi
  if [[ -f "$INSTALL_DIR/install.sh" ]]; then
    sudo "$INSTALL_DIR/install.sh"
  elif [[ -f "$INSTALL_DIR/scripts/install.sh" ]]; then
    sudo "$INSTALL_DIR/scripts/install.sh"
  else
    die "找不到 install.sh"
  fi
}

# 逐項檢查 .env 必填欄位與 device-identities.json、influxdb 服務狀態。
cmd_check_config() {
  require_install_dir
  local env_file="$INSTALL_DIR/.env"
  [[ -f "$env_file" ]] || die "缺少 $env_file"

  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a

  local ok=1
  check_nonempty() {
    local name="$1"
    local val="${!name:-}"
    if [[ -z "$val" ]]; then
      echo "❌ $name 未設定"
      ok=0
    else
      echo "✅ $name"
    fi
  }

  check_nonempty SERIAL_PORT
  check_nonempty MODBUS_SLAVE_IDS
  check_nonempty GATEWAY_ID
  check_nonempty INFLUX_URL
  check_nonempty INFLUX_TOKEN
  check_nonempty INFLUX_ORG
  check_nonempty INFLUX_BUCKET

  if systemctl is-active --quiet influxdb 2>/dev/null; then
    echo "✅ influxdb 服務運行中"
  else
    echo "❌ influxdb 服務未運行（本地緩存必填）"
    ok=0
  fi

  if [[ "${MONITOR_ONLY:-0}" != "1" ]]; then
    check_nonempty MQTT_URL
    check_nonempty MQTT_DATA_TOPIC
    check_nonempty MQTT_BOOT_TOPIC
  else
    echo "ℹ️  MONITOR_ONLY=1，略過 MQTT 必填檢查"
  fi

  local ident="$INSTALL_DIR/config/device-identities.json"
  if [[ -f "$ident" ]]; then
    echo "✅ device-identities.json 存在"
  else
    echo "❌ 缺少 $ident"
    ok=0
  fi

  [[ "$ok" -eq 1 ]] && echo "✅ 設定檢查通過" || die "設定檢查未通過"
}

# 先 influx ping，再以官方 JS client 打 API（與採集程式相同依賴）。
cmd_test_influx() {
  require_install_dir
  if ! systemctl is-active --quiet influxdb 2>/dev/null; then
    die "influxdb 服務未運行"
  fi
  if ! command -v influx >/dev/null 2>&1; then
    die "找不到 influx CLI"
  fi
  INFLUX_HOST="${INFLUX_URL:-http://127.0.0.1:8086}" influx ping \
    || die "influx ping 失敗（可試：INFLUX_HOST=http://127.0.0.1:8086 influx ping）"
  cd "$INSTALL_DIR"
  node -e "
require('dotenv').config({ path: '.env' });
const { InfluxDB } = require('@influxdata/influxdb-client');
const url = process.env.INFLUX_URL || '';
const token = process.env.INFLUX_TOKEN || '';
const org = process.env.INFLUX_ORG || '';
const bucket = process.env.INFLUX_BUCKET || '';
if (!url || !token || !org || !bucket) {
  console.error('❌ INFLUX 四項未齊全');
  process.exit(1);
}
const client = new InfluxDB({ url, token });
const pingApi = client.getPingAPI();
pingApi.getPing().then(() => {
  console.log('✅ InfluxDB API 可連線:', url, 'bucket=' + bucket);
  process.exit(0);
}).catch((e) => {
  console.error('❌ InfluxDB API 錯誤:', e.message);
  process.exit(1);
});
"
}

# 單次連線測試，不發布資料；clientId 加 -test 後綴避免與正式服務衝突。
cmd_test_mqtt() {
  require_install_dir
  cd "$INSTALL_DIR"
  node -e "
require('dotenv').config({ path: '.env' });
const mqtt = require('mqtt');
const url = process.env.MQTT_URL || '';
const gatewayId = (process.env.GATEWAY_ID || process.env.MQTT_CLIENT_ID || '').trim();
const clientId = (process.env.MQTT_CLIENT_ID || gatewayId || 'dpm-test').trim();
if (!url) { console.error('MQTT_URL 未設定'); process.exit(1); }
if (!gatewayId && process.env.MONITOR_ONLY !== '1') { console.error('GATEWAY_ID 未設定'); process.exit(1); }
const opts = { clientId: clientId + '-test', connectTimeout: 10000, reconnectPeriod: 0 };
if (process.env.MQTT_USERNAME) opts.username = process.env.MQTT_USERNAME;
if (process.env.MQTT_PASSWORD) opts.password = process.env.MQTT_PASSWORD;
const c = mqtt.connect(url, opts);
c.on('connect', () => { console.log('✅ MQTT 連線成功:', url); c.end(true, () => process.exit(0)); });
c.on('error', (e) => { console.error('❌ MQTT 錯誤:', e.message); process.exit(1); });
setTimeout(() => { console.error('❌ MQTT 連線逾時'); process.exit(1); }, 15000);
"
}

# 讀取第一個 MODBUS_SLAVE_IDS 的 holding register 40001（2 words）做連線抽測。
cmd_test_modbus() {
  require_install_dir
  cd "$INSTALL_DIR"
  node -e "
require('dotenv').config({ path: '.env' });
const ModbusRTU = require('modbus-serial');
const port = process.env.SERIAL_PORT || '/dev/ttyUSB0';
const baud = parseInt(process.env.MODBUS_BAUD_RATE || '9600', 10);
const slaveRaw = (process.env.MODBUS_SLAVE_IDS || '1').split(',')[0].trim();
const slaveId = parseInt(slaveRaw, 10);
const client = new ModbusRTU();
(async () => {
  try {
    await client.connectRTUBuffered(port, { baudRate: baud, dataBits: 8, stopBits: 2, parity: 'none' });
    client.setID(slaveId);
    client.setTimeout(parseInt(process.env.MODBUS_TIMEOUT_MS || '1000', 10));
    const data = await client.readHoldingRegisters(40001, 2);
    console.log('✅ Modbus 讀取成功 slave=' + slaveId + ' port=' + port + ' regs=' + JSON.stringify(data.data));
    await client.close();
    process.exit(0);
  } catch (e) {
    console.error('❌ Modbus 錯誤:', e.message);
    try { await client.close(); } catch (_) {}
    process.exit(1);
  }
})();
"
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    status)       cmd_status ;;
    logs)         cmd_logs "$@" ;;
    restart)      systemctl restart "$SERVICE_NAME" ;;
    start)        systemctl start "$SERVICE_NAME" ;;
    stop)         systemctl stop "$SERVICE_NAME" ;;
    update)       cmd_update ;;
    enable)       systemctl enable "$SERVICE_NAME" ;;
    disable)      systemctl disable "$SERVICE_NAME" ;;
    check-config) cmd_check_config ;;
    test-influx)  cmd_test_influx ;;
    test-mqtt)    cmd_test_mqtt ;;
    test-modbus)  cmd_test_modbus ;;
    ""|-h|--help) usage ;;
    *)            die "未知指令：$cmd（執行 $(basename "$0") --help 查看）" ;;
  esac
}

main "$@"
