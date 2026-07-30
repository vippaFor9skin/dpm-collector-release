#!/usr/bin/env bash
# =============================================================================
# install.sh — DPM-DA530（DPM-DA510）Modbus RTU Collector 一鍵安裝／更新（BL118）
#
# 目標平台：僅限 BLIIOT BL118 工業閘道器（ARMv7），搭配 DPM-DA530（DPM-DA510）電表，
# 現場實測 Pin 1 / Pin 2 對應 /dev/ttyAS4。
# 執行方式：sudo ./install.sh（須 root，用於 apt、systemd、chown）。
#
# 安裝來源（自動偵測 SOURCE_DIR）：
#   - 客戶 repo 根目錄（git clone 的 dpm-collector/）
#   - 開發 repo 的 scripts/ 或含 dist/ 的舊布局
#
# 主要流程（初次安裝）：
#   環境檢查 → 同步檔案 → Node.js + npm install → 互動建立 .env
#   （GATEWAY_ID、Modbus、MQTT）→ systemd → 權限 → 啟動服務
#
# 本地持久化：SQLite 7 天備援（已送標記、逾期刪除；斷網未送列恢復後補送）。
#
# 更新模式（is_update_mode）：已有 .env 且 systemd 單元存在時，
#   保留 .env，僅同步程式、npm install、驗證、重啟。
# =============================================================================
set -euo pipefail

# --- 可覆寫的安裝參數（環境變數） ---
INSTALL_DIR="${INSTALL_DIR:-/opt/dpm-collector}"
SERVICE_NAME="${SERVICE_NAME:-dpm-collector}"
SERVICE_USER="${SERVICE_USER:-dpm}"
NODE_MIN_MAJOR="${NODE_MIN_MAJOR:-24}"
NODE_ARMV7_MAJOR="${NODE_ARMV7_MAJOR:-22}"
CLIENT_GIT_REPO_URL="${CLIENT_GIT_REPO_URL:-https://github.com/vippaFor9skin/dpm-collector-release.git}"
DEFAULT_MQTT_URL="${DEFAULT_MQTT_URL:-mqtt://124.219.96.34:1883}"
DEFAULT_MQTT_USERNAME="${DEFAULT_MQTT_USERNAME:-dpm_user}"
DEFAULT_MQTT_PASSWORD="${DEFAULT_MQTT_PASSWORD:-}"
DEFAULT_POLL_INTERVAL_MS="${DEFAULT_POLL_INTERVAL_MS:-60000}"
DEFAULT_SQLITE_RETENTION_HOURS="${DEFAULT_SQLITE_RETENTION_HOURS:-168}"
DEFAULT_MONITOR_ONLY="${DEFAULT_MONITOR_ONLY:-0}"
DEFAULT_SERIAL_PORT="${DEFAULT_SERIAL_PORT:-/dev/ttyAS4}"
MAX_MODBUS_DEVICES="${MAX_MODBUS_DEVICES:-5}"

# 判斷「腳本所在目錄」對應的套件根目錄（支援就地 git clone 安裝）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/index.js" ]]; then
  SOURCE_DIR="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/dist/index.js" ]]; then
  SOURCE_DIR="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../index.js" ]]; then
  SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [[ -f "$SCRIPT_DIR/../dist/index.js" ]]; then
  SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  echo "❌ 找不到 index.js，請在 clone 或解壓後的套件根目錄執行 install.sh"
  exit 1
fi

# --- 終端輸出（僅 install 流程使用；不影響服務日誌） ---
# log_section / log_highlight 在非 TTY（例如 CI）時會降級為純文字。
log() { echo "$*" >&2; }
die() { echo "❌ $*" >&2; exit 1; }

log_section() {
  if [[ -t 2 ]]; then
    printf '\n\033[96m【%s】\033[0m\n' "$1" >&2
  else
    printf '\n【%s】\n' "$1" >&2
  fi
}

log_highlight() {
  if [[ -t 2 ]]; then
    printf '\033[96m%s\033[0m\n' "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

countdown_progress_bar() {
  local total="${1:-5}"
  local width=40
  local i j n
  if [[ ! -t 2 ]]; then
    sleep "$total"
    return
  fi
  for ((i=1; i<=total; i++)); do
    n=$((i * width / total))
    printf '\r[' >&2
    for ((j=0; j<width; j++)); do
      if ((j < n)); then printf '█' >&2; else printf '░' >&2; fi
    done
    printf '] %d/%ds' "$i" "$total" >&2
    sleep 1
  done
  echo >&2
}

# --- 檔案複製與舊版目錄布局遷移 ---
resolve_path() {
  readlink -f "$1" 2>/dev/null || realpath "$1"
}

safe_cp() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 0
  local src_real dst_real
  src_real="$(resolve_path "$src")"
  dst_real="$(resolve_path "$dst")"
  if [[ "$src_real" == "$dst_real" ]]; then
    return 0
  fi
  cp -f "$src" "$dst"
}

# 複製本身不做字元轉碼；以 iconv 驗證中文設定檔仍是合法 UTF-8。
validate_utf8_file() {
  local file="$1"
  [[ -f "$file" ]] || die "找不到 UTF-8 檢查目標：$file"
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1 || \
      die "$file 不是合法 UTF-8，已停止以免中文備註寫成亂碼"
  fi
}

# 客戶 repo 已改為根目錄 index.js + lib/；此函式相容舊 dist/ 與根目錄 package.json。
migrate_legacy_dist_layout() {
  local root="$1"
  if [[ -f "$root/dist/index.js" ]] && [[ ! -f "$root/index.js" ]]; then
    log "偵測舊版 dist/ 布局，搬移主程式至根目錄 …"
    safe_cp "$root/dist/index.js" "$root/index.js"
    [[ -f "$root/dist/VERSION" ]] && safe_cp "$root/dist/VERSION" "$root/VERSION"
  fi
  if [[ -f "$root/package.json" ]] && [[ ! -f "$root/lib/package.json" ]]; then
    log "偵測舊版根目錄 package.json，搬移至 lib/ …"
    mkdir -p "$root/lib"
    safe_cp "$root/package.json" "$root/lib/package.json"
    safe_cp "$root/package-lock.json" "$root/lib/package-lock.json"
    [[ -f "$root/dpm-collector.service" ]] && \
      safe_cp "$root/dpm-collector.service" "$root/lib/dpm-collector.service"
  fi
}

# --- 系統前置檢查 ---
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "請以 root 執行：sudo $0"
  fi
}

detect_system() {
  log "系統：$(uname -s) $(uname -m)"
  if [[ -r /proc/meminfo ]]; then
    local mem_kb
    mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    log "記憶體：$(( mem_kb / 1024 )) MB"
  fi
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    log "發行版：${PRETTY_NAME:-unknown}"
  fi
}

# --- 平台能力 ---
is_armv7() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  [[ "$arch" == "armhf" || "$arch" == "armv7l" ]]
}

# --- Node.js（一般平台 24+；ARMv7 使用仍提供官方 binary 的 22.x） ---
node_major() {
  if ! command -v node >/dev/null 2>&1; then
    echo 0
    return
  fi
  node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1
}

required_node_major() {
  if is_armv7; then
    echo "$NODE_ARMV7_MAJOR"
  else
    echo "$NODE_MIN_MAJOR"
  fi
}

install_nodejs_armv7() {
  local major="$NODE_ARMV7_MAJOR"
  local base_url="https://nodejs.org/dist/latest-v${major}.x"
  local tmp_dir sums_file archive archive_path install_root version_dir

  log "ARMv7 不受 NodeSource 支援，改裝 Node.js 官方 ${major}.x ARMv7 binary …"
  apt-get install -y ca-certificates curl xz-utils
  tmp_dir="$(mktemp -d)"
  sums_file="$tmp_dir/SHASUMS256.txt"
  curl -fsSL "$base_url/SHASUMS256.txt" -o "$sums_file"
  archive="$(awk -v major="$major" \
    '$2 ~ ("^node-v" major "\\.[0-9]+\\.[0-9]+-linux-armv7l\\.tar\\.xz$") { print $2; exit }' \
    "$sums_file")"
  [[ -n "$archive" ]] || {
    rm -rf "$tmp_dir"
    die "Node.js ${major}.x 官方下載區找不到 ARMv7 binary"
  }
  archive_path="$tmp_dir/$archive"
  curl -fL "$base_url/$archive" -o "$archive_path"
  (cd "$tmp_dir" && grep "  $archive\$" SHASUMS256.txt | sha256sum -c -)

  install_root="/usr/local/lib/nodejs"
  version_dir="${archive%.tar.xz}"
  mkdir -p "$install_root"
  rm -rf "$install_root/$version_dir"
  tar -xJf "$archive_path" -C "$install_root"
  ln -sfn "$install_root/$version_dir/bin/node" /usr/local/bin/node
  ln -sfn "$install_root/$version_dir/bin/npm" /usr/local/bin/npm
  ln -sfn "$install_root/$version_dir/bin/npx" /usr/local/bin/npx
  [[ -e "$install_root/$version_dir/bin/corepack" ]] && \
    ln -sfn "$install_root/$version_dir/bin/corepack" /usr/local/bin/corepack
  rm -rf "$tmp_dir"
  hash -r
}

install_nodejs() {
  local required_major
  required_major="$(required_node_major)"
  log "安裝 Node.js ${required_major}+ …"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg
    if is_armv7; then
      install_nodejs_armv7
    else
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_MIN_MAJOR}.x" | bash -
      apt-get install -y nodejs
    fi
  else
    die "不支援的套件管理器，請手動安裝 Node.js ${required_major}+"
  fi
  log "Node.js 版本：$(node -v)"
}

ensure_nodejs() {
  local major required_major
  major="$(node_major)"
  required_major="$(required_node_major)"
  if [[ "$major" -lt "$required_major" ]]; then
    install_nodejs
  else
    log "Node.js 已安裝：$(node -v)"
  fi
}

log_mqtt_defaults() {
  local mqtt_url="$1"
  local mqtt_user="$2"
  local monitor_only="$3"
  local poll_ms="$4"
  log "MQTT_URL=$mqtt_url"
  log "MQTT_USERNAME=$mqtt_user"
  log "MONITOR_ONLY=$monitor_only"
  log "POLL_INTERVAL_MS=$poll_ms"
}

# --- 互動式輸入與 .env 值格式化 ---
prompt() {
  local msg="$1"
  local default="${2:-}"
  local var
  if [[ -n "$default" ]]; then
    read -rp "? $msg （預設 ${default}）: " var
    echo "${var:-$default}"
  else
    read -rp "? $msg: " var
    echo "$var"
  fi
}

prompt_secret() {
  local msg="$1"
  local var=""
  read -rsp "? $msg: " var >&2
  echo >&2
  printf '%s' "$var"
}

trim_value() {
  local v="$1"
  v="${v//$'\r'/}"
  v="${v//$'\n'/}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# .env 含特殊字元時加雙引號並跳脫，避免 systemd EnvironmentFile 解析錯誤。
format_dotenv_value() {
  local v="$1"
  [[ -n "$v" ]] || return 0
  if [[ "$v" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    printf '%s' "$v"
    return
  fi
  local escaped="${v//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '"%s"' "$escaped"
}

prompt_yes_no() {
  local msg="$1"
  local default="${2:-Y}"
  local hint="Y/n"
  [[ "$default" == "n" || "$default" == "N" ]] && hint="y/N"
  local ans
  read -rp "? $msg ($hint): " ans
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

# 先問串接電表台數（1~MAX_MODBUS_DEVICES），再問站號與序列埠。
prompt_device_count() {
  local raw count
  while true; do
    raw="$(prompt "串接電表台數（1~${MAX_MODBUS_DEVICES}）" "1")"
    raw="$(trim_value "$raw")"
    if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
      count=$((raw))
      if (( count >= 1 && count <= MAX_MODBUS_DEVICES )); then
        echo "$count"
        return 0
      fi
    fi
    log "⚠️  請輸入 1~${MAX_MODBUS_DEVICES} 的整數"
  done
}

# 依台數產生預設站號（1,2,…,N），並驗證數量一致、無重複。
prompt_slave_ids() {
  local count="$1"
  local i default="" raw cleaned
  local -a ids=()
  local -a parts=()
  local -a uniq=()
  for ((i = 1; i <= count; i++)); do
    [[ -n "$default" ]] && default+=","
    default+="$i"
  done
  while true; do
    raw="$(prompt "Modbus Slave IDs（逗號分隔，須剛好 ${count} 個，且與 config/device-identities.json 一致）" "$default")"
    raw="${raw//[\[\]]/}"
    raw="$(trim_value "$raw")"
    ids=()
    IFS=',' read -ra parts <<< "$raw"
    for part in "${parts[@]}"; do
      part="$(trim_value "$part")"
      [[ -z "$part" ]] && continue
      if [[ ! "$part" =~ ^[1-9][0-9]*$ ]] || (( part < 1 || part > 247 )); then
        ids=()
        break
      fi
      ids+=("$part")
    done
    if ((${#ids[@]} != count)); then
      log "⚠️  站號數量須為 ${count} 個（目前 ${#ids[@]}）"
      continue
    fi
    cleaned="$(printf '%s\n' "${ids[@]}" | awk '!a[$0]++' | paste -sd, -)"
    IFS=',' read -ra uniq <<< "$cleaned"
    if ((${#uniq[@]} != count)); then
      log "⚠️  Slave ID 不可重複"
      continue
    fi
    echo "$cleaned"
    return 0
  done
}

# --- Modbus 序列埠偵測（BL118 板載 RS-485，僅 /dev/ttyS*／ttyWCH* 等硬體節點） ---
# 本案 BL118 現場實測：Pin 1 / Pin 2 → /dev/ttyAS4。
serial_port_usable() {
  local dev="$1"
  local baud="${2:-9600}"
  [[ -c "$dev" ]] || return 1
  command -v stty >/dev/null 2>&1 || return 1
  stty -F "$dev" "$baud" cs8 -parenb cstopb >/dev/null 2>&1
}

validate_serial_port_or_die() {
  local dev="$1"
  local baud="${2:-9600}"
  local error
  [[ -c "$dev" ]] || die "RS-485 序列埠不存在或不是字元裝置：$dev"
  command -v stty >/dev/null 2>&1 || die "找不到 stty，無法驗證 RS-485 序列埠"
  if ! error="$(stty -F "$dev" "$baud" cs8 -parenb cstopb 2>&1)"; then
    log "RS-485 序列埠驗證失敗：$dev（${baud} baud, 8N2）"
    [[ -n "$error" ]] && log "$error"
    die "核心驅動無法設定 $dev；請確認 BL118 實體 RS-485 通道對應的 /dev/ttyS*"
  fi
  log "✅ RS-485 序列埠可用：$dev（${baud} baud, 8N2）"
}

detect_serial_ports() {
  local p n
  # 列出核心可成功設定 9600 8N2 的 UART；預設選 /dev/ttyAS4。
  for n in 1 2 3 4 5 6 7 8 9 0; do
    p="/dev/ttyS${n}"
    [[ -e "$p" && -c "$p" ]] || continue
    if serial_port_usable "$p"; then
      printf '%s\n' "$p"
    else
      log "略過 $p：核心驅動無法設定 9600 baud"
    fi
  done
  for p in /dev/ttyWCH* /dev/ttyAS* /dev/ttyRS485*; do
    [[ -e "$p" && -c "$p" ]] || continue
    if serial_port_usable "$p"; then
      printf '%s\n' "$p"
    else
      log "略過 $p：核心驅動無法設定 9600 baud"
    fi
  done
}

serial_port_desc() {
  local dev="$1" base
  base="$(basename "$dev")"
  case "$base" in
    ttyAS4) printf '%s' "BL118 Pin 1 / Pin 2（現場實測）" ;;
    ttyS1) printf '%s' "板載 RS485（依機型）" ;;
    ttyS2) printf '%s' "板載 RS485-2（485A-2 / 485B-2）" ;;
    ttyS3) printf '%s' "板載 RS485-3" ;;
    ttyS4) printf '%s' "板載 RS485-4" ;;
    ttyS5) printf '%s' "板載 RS485-3／擴充通道（視 X 板）" ;;
    ttyS0) printf '%s' "板載 UART／RS485（視機型）" ;;
    ttyWCH*) printf '%s' "擴充板 RS485（Y 板）" ;;
    ttyAS*|ttyRS485*) printf '%s' "板載 RS485" ;;
    *) printf '%s' "硬體序列埠" ;;
  esac
}

prompt_serial_port() {
  local -a ports=()
  local line i choice desc manual_idx default_choice default_manual="$DEFAULT_SERIAL_PORT"

  while IFS= read -r line; do
    [[ -n "$line" ]] && ports+=("$line")
  done < <(detect_serial_ports)

  manual_idx=$((${#ports[@]} + 1))

  echo "請選擇 Modbus 序列埠（僅列出已通過 9600 baud 核心測試的板載 RS-485）：" >&2
  if [[ ${#ports[@]} -eq 0 ]]; then
    echo "  （未找到可設定 9600 baud 的板載 RS-485；可手動輸入其他裝置節點驗證）" >&2
  else
    for i in "${!ports[@]}"; do
      desc="$(serial_port_desc "${ports[$i]}")"
      if [[ -n "$desc" ]]; then
        printf '  %d) %s  (%s)\n' "$((i + 1))" "${ports[$i]}" "$desc" >&2
      else
        printf '  %d) %s\n' "$((i + 1))" "${ports[$i]}" >&2
      fi
    done
  fi
  printf '  %d) 手動輸入路徑（預設 %s）\n' "$manual_idx" "$default_manual" >&2

  if [[ ${#ports[@]} -gt 0 ]]; then
    default_choice=1
  else
    default_choice="$manual_idx"
  fi

  read -rp "? 請選擇 （預設 ${default_choice}）: " choice >&2
  choice="${choice:-$default_choice}"

  if [[ "$choice" == "$manual_idx" ]]; then
    prompt "請輸入序列埠路徑" "${ports[0]:-$default_manual}"
    return
  fi

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ports[@]} )); then
    printf '%s' "${ports[$((choice - 1))]}"
    return
  fi

  if [[ -c "$choice" ]]; then
    printf '%s' "$choice"
    return
  fi

  if [[ ${#ports[@]} -gt 0 ]]; then
    log "無效選擇，使用 ${ports[0]}"
    printf '%s' "${ports[0]}"
  else
    prompt "請輸入序列埠路徑" "$default_manual"
  fi
}

ensure_serial_port_config() {
  local env_file="$1"
  local configured baud selected
  [[ -f "$env_file" ]] || return

  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
  configured="${SERIAL_PORT:-$DEFAULT_SERIAL_PORT}"
  baud="${MODBUS_BAUD_RATE:-9600}"
  if serial_port_usable "$configured" "$baud"; then
    log "RS-485 序列埠已驗證：$configured（${baud} baud）"
    return
  fi

  log "⚠️  既有 SERIAL_PORT=$configured 無法由核心設定 ${baud} baud，請重新選擇板載 RS-485"
  selected="$(prompt_serial_port)"
  validate_serial_port_or_die "$selected" "$baud"
  if grep -q '^SERIAL_PORT=' "$env_file"; then
    sed -i "s|^SERIAL_PORT=.*|SERIAL_PORT=$selected|" "$env_file"
  else
    printf '\nSERIAL_PORT=%s\n' "$selected" >> "$env_file"
  fi
  SERIAL_PORT="$selected"
  export SERIAL_PORT
  log "✅ 已更新 $env_file：SERIAL_PORT=$selected"
}

# 寫入含中文備註的 .env（欄位說明對照開發倉 .env.example）。
write_env_file_content() {
  local env_file="$1"
  local serial_port="$2"
  local slave_ids="$3"
  local monitor_only="$4"
  local poll_ms="$5"
  local mqtt_url="$6"
  local mqtt_user="$7"
  local mqtt_pass="$8"
  local gateway_id="$9"

  local env_tmp="${env_file}.tmp.$$"
  cat > "$env_tmp" <<EOF
# ---------------------------------------------------------------------------
# 本檔由 install.sh 產生（$(date -Iseconds)）
# 修改後請執行：sudo systemctl restart dpm-collector
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 序列埠（BL118 現場實測：Pin 1 / Pin 2 → /dev/ttyAS4）
# ---------------------------------------------------------------------------
SERIAL_PORT=$serial_port
MODBUS_BAUD_RATE=9600
MODBUS_DATA_BITS=8
MODBUS_STOP_BITS=2
MODBUS_PARITY=none
# 多設備輪詢（最多 5 台，逗號分隔；同一 SERIAL_PORT 串接；須與 config/device-identities.json 的 key 一致）
MODBUS_SLAVE_IDS=$slave_ids
MODBUS_TIMEOUT_MS=1000

# ---------------------------------------------------------------------------
# 時區：影響 sampled_at 時間標記
# ---------------------------------------------------------------------------
TIMEZONE=Asia/Taipei

# ---------------------------------------------------------------------------
# 僅本機檢測：1 時不連 MQTT，仍寫入 SQLite 本地備援；改回 0 重啟後可補送未送筆
# ---------------------------------------------------------------------------
MONITOR_ONLY=$monitor_only

# ---------------------------------------------------------------------------
# Float 讀值異常時可改 MODBUS_FLOAT_SWAP_WORDS=1 試交換 word 順序
# ---------------------------------------------------------------------------
MODBUS_FLOAT_SWAP_WORDS=0

# 設備身分對照（JSON；key 為 slave_id）；請先編輯再 install
DEVICE_IDENTITIES_FILE=config/device-identities.json
# 輪詢間隔（毫秒）；BL118 建議 ≥60000（5 台約可撐 7 天本地備援）
POLL_INTERVAL_MS=$poll_ms

# ---------------------------------------------------------------------------
# 本地 SQLite 備援：保留 7 天；已 MQTT 成功標記後不重送；逾期刪除
# ---------------------------------------------------------------------------
SQLITE_OUTBOX_PATH=data/dpm.db
SQLITE_RETENTION_HOURS=${DEFAULT_SQLITE_RETENTION_HOURS}
OUTBOX_FLUSH_BATCH=200

# ---------------------------------------------------------------------------
# MQTT（MONITOR_ONLY=0 時必填）
# 每筆為 UTF-8 JSON：guid, parameters, sampled_at
# ---------------------------------------------------------------------------
MQTT_URL=$mqtt_url
# 週期資料 topic；佔位僅支援 {gatewayId}
MQTT_DATA_TOPIC=gw/data/{gatewayId}
# 啟動設備清單 topic（必填）
MQTT_BOOT_TOPIC=gw/boot/{gatewayId}

# 與後台 Gateway 主檔 gateway_id 一致（topic 佔位用，非 MQTT clientId）
GATEWAY_ID=$gateway_id

# Broker 連線 clientId；留白時以 GATEWAY_ID 帶入
MQTT_CLIENT_ID=

# Broker 帳密（若 MQTT_URL 未內嵌帳密時使用）
MQTT_USERNAME=$mqtt_user
MQTT_PASSWORD=$(format_dotenv_value "$mqtt_pass")

# 發布 QoS：0 / 1 / 2
MQTT_QOS=1
MQTT_CONNECT_TIMEOUT_MS=30000

# mqtts:// 自簽憑證測試用；正式環境請保持 0
MQTT_TLS_INSECURE=0
EOF
  validate_utf8_file "$env_tmp"
  mv -f "$env_tmp" "$env_file"
  validate_utf8_file "$env_file"
}

# 互動建立 .env：GATEWAY_ID → Modbus → MQTT。
# log_section 標題僅影響終端顯示，不寫入 .env。
write_env_file() {
  local env_file="$1"
  log_section "設定檔"
  log "建立 $env_file …"

  local gateway_id serial_port slave_ids device_count
  local mqtt_url="$DEFAULT_MQTT_URL"
  local mqtt_user="$DEFAULT_MQTT_USERNAME"
  local mqtt_pass="$DEFAULT_MQTT_PASSWORD"
  local poll_ms="$DEFAULT_POLL_INTERVAL_MS"
  local monitor_only="$DEFAULT_MONITOR_ONLY"

  gateway_id="$(prompt "請輸入 GATEWAY_ID（後台 Gateway 主檔的識別碼）")"
  [[ -n "$gateway_id" ]] || die "GATEWAY_ID 不可為空"

  log_section "Modbus"
  log "電表採 RS-485 串接：同一 SERIAL_PORT 輪詢多站號（最多 ${MAX_MODBUS_DEVICES} 台）"
  device_count="$(prompt_device_count)"
  slave_ids="$(prompt_slave_ids "$device_count")"
  serial_port="$(prompt_serial_port)"
  validate_serial_port_or_die "$serial_port" 9600

  log_section "MQTT"
  log_mqtt_defaults "$mqtt_url" "$mqtt_user" "$monitor_only" "$poll_ms"
  mqtt_pass="$(prompt_secret "請輸入 MQTT_PASSWORD（Broker 密碼；直接 Enter 表示空密碼）")"
  if [[ -z "$mqtt_pass" && -z "${DEFAULT_MQTT_PASSWORD:-}" ]]; then
    log "⚠️  MQTT_PASSWORD 為空；若 Broker 回 Not authorized，請編輯 .env 補上密碼後重啟服務"
  fi

  write_env_file_content "$env_file" \
    "$serial_port" "$slave_ids" "$monitor_only" "$poll_ms" \
    "$mqtt_url" "$mqtt_user" "$mqtt_pass" "$gateway_id"
  chmod 600 "$env_file"
  log "✅ 已建立 $env_file（含 MQTT、Modbus 與本地儲存設定）"
}

env_file_is_complete() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 1
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
  [[ -n "${GATEWAY_ID:-}" ]] || return 1
  [[ -n "${MODBUS_SLAVE_IDS:-}" ]] || return 1
  [[ -n "${SERIAL_PORT:-}" ]] || return 1
  return 0
}

# 已有 .env 時：完整則保留；否則整份重建。
ensure_env_file() {
  local env_file="$1"
  if [[ ! -f "$env_file" ]]; then
    write_env_file "$env_file"
    return
  fi

  if env_file_is_complete "$env_file"; then
    log "保留既有 .env"
    return
  fi

  log "⚠️  既有 .env 不完整，重新建立 …"
  write_env_file "$env_file"
}

# 將 SOURCE_DIR 白名單檔案複製到 INSTALL_DIR；就地安裝時 safe_cp 會跳過同路徑。
sync_app_files() {
  local dest="$1"
  migrate_legacy_dist_layout "$dest"
  log "同步程式檔案到 $dest …"
  mkdir -p "$dest/config" "$dest/data" "$dest/lib"
  if [[ -f "$SOURCE_DIR/index.js" ]]; then
    safe_cp "$SOURCE_DIR/index.js" "$dest/index.js"
    [[ -f "$SOURCE_DIR/VERSION" ]] && safe_cp "$SOURCE_DIR/VERSION" "$dest/VERSION"
  elif [[ -f "$SOURCE_DIR/dist/index.js" ]]; then
    safe_cp "$SOURCE_DIR/dist/index.js" "$dest/index.js"
    [[ -f "$SOURCE_DIR/dist/VERSION" ]] && safe_cp "$SOURCE_DIR/dist/VERSION" "$dest/VERSION"
  fi
  if [[ -f "$SOURCE_DIR/lib/package.json" ]]; then
    safe_cp "$SOURCE_DIR/lib/package.json" "$dest/lib/package.json"
    safe_cp "$SOURCE_DIR/lib/package-lock.json" "$dest/lib/package-lock.json"
    [[ -f "$SOURCE_DIR/lib/dpm-collector.service" ]] && \
      safe_cp "$SOURCE_DIR/lib/dpm-collector.service" "$dest/lib/dpm-collector.service"
  elif [[ -f "$SOURCE_DIR/package.json" ]]; then
    # 相容舊版客戶 repo 根目錄 layout
    safe_cp "$SOURCE_DIR/package.json" "$dest/lib/package.json"
    safe_cp "$SOURCE_DIR/package-lock.json" "$dest/lib/package-lock.json"
    [[ -f "$SOURCE_DIR/dpm-collector.service" ]] && \
      safe_cp "$SOURCE_DIR/dpm-collector.service" "$dest/lib/dpm-collector.service"
  fi
  [[ -f "$SOURCE_DIR/.env.example" ]] && safe_cp "$SOURCE_DIR/.env.example" "$dest/.env.example"
  # device-identities.json.example 僅供參考，始終同步
  if [[ -f "$SOURCE_DIR/config/device-identities.json.example" ]]; then
    safe_cp "$SOURCE_DIR/config/device-identities.json.example" "$dest/config/device-identities.json.example"
  fi
  # 從來源同步 device-identities.json（優先取正式檔，無則從 .example 建立）
  local dest_json="$dest/config/device-identities.json"
  if [[ -f "$SOURCE_DIR/config/device-identities.json" ]]; then
    local src_json_size
    src_json_size=$(wc -c < "$SOURCE_DIR/config/device-identities.json" 2>/dev/null || echo 0)
    if [[ "$src_json_size" -gt 3 ]]; then
      # 來源有正式內容的 device-identities.json
      if [[ ! -f "$dest_json" ]]; then
        # 目標不存在 → 直接複製
        safe_cp "$SOURCE_DIR/config/device-identities.json" "$dest_json"
        log "已從來源同步 config/device-identities.json"
      elif cmp -s "$SOURCE_DIR/config/device-identities.json" "$dest_json" 2>/dev/null; then
        : # 內容相同，無需動作
      else
        # 目標已存在且內容不同 → 詢問使用者
        if [[ -t 0 ]] && prompt_yes_no "來源 config/device-identities.json 與安裝目錄不同，是否覆寫？" "n"; then
          safe_cp "$SOURCE_DIR/config/device-identities.json" "$dest_json"
          log "已覆寫 config/device-identities.json"
        else
          log "保留安裝目錄原有的 config/device-identities.json（與來源不同）"
        fi
      fi
    fi
  elif [[ ! -f "$dest_json" ]] && [[ -f "$SOURCE_DIR/config/device-identities.json.example" ]]; then
    # 來源無正式檔，但目標也不存在 → 從 .example 建立
    safe_cp "$SOURCE_DIR/config/device-identities.json.example" "$dest_json"
    log "已從範本建立 config/device-identities.json（請依現場修改）"
  fi
  if [[ -f "$SOURCE_DIR/dpm-ctl.sh" ]]; then
    safe_cp "$SOURCE_DIR/dpm-ctl.sh" "$dest/dpm-ctl.sh"
    chmod +x "$dest/dpm-ctl.sh"
  elif [[ -f "$SOURCE_DIR/scripts/dpm-ctl.sh" ]]; then
    safe_cp "$SOURCE_DIR/scripts/dpm-ctl.sh" "$dest/dpm-ctl.sh"
    chmod +x "$dest/dpm-ctl.sh"
  fi

  local src_real dest_real
  src_real="$(resolve_path "$SOURCE_DIR")"
  dest_real="$(resolve_path "$dest")"
  if [[ "$src_real" == "$dest_real" ]]; then
    log "來源與安裝目錄相同（git clone 就地安裝），略過重複複製"
  fi
}

ensure_git_safe_directory() {
  local dir
  dir="$(readlink -f "$1" 2>/dev/null || realpath "$1")"
  [[ -d "$dir/.git" ]] || return 0
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  if git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$dir"; then
    return 0
  fi
  git config --global --add safe.directory "$dir"
  log "已將 $dir 加入 git safe.directory（sudo 與 clone 擁有者不同時才可 pull）"
}

link_git_from_source() {
  local dest="$1"
  if [[ -d "$SOURCE_DIR/.git" ]] && [[ ! -d "$dest/.git" ]]; then
    log "複製 Git 中繼資料（與公開倉庫同版，上線後可 git pull）…"
    cp -a "$SOURCE_DIR/.git" "$dest/.git"
  fi

  local manifest=""
  for candidate in \
    "$SOURCE_DIR/MANIFEST.json" \
    "$SOURCE_DIR/../MANIFEST.json" \
    "$(dirname "$SOURCE_DIR")/MANIFEST.json"; do
    if [[ -f "$candidate" ]]; then
      manifest="$candidate"
      break
    fi
  done

  if [[ -n "$manifest" ]]; then
    cp -f "$manifest" "$dest/MANIFEST.json"
  fi

  if [[ -d "$dest/.git" ]]; then
    ensure_git_safe_directory "$dest"
    local remote_url=""
    if [[ -n "$manifest" ]]; then
      remote_url="$(node -e "
const fs = require('fs');
const p = process.argv[1];
try {
  const j = JSON.parse(fs.readFileSync(p, 'utf8'));
  process.stdout.write(j.git_remote || '');
} catch { process.stdout.write(''); }
" "$manifest" 2>/dev/null || true)"
    fi
    if [[ -n "$remote_url" ]]; then
      if git -C "$dest" remote get-url origin >/dev/null 2>&1; then
        git -C "$dest" remote set-url origin "$remote_url"
      else
        git -C "$dest" remote add origin "$remote_url"
      fi
      log "Git remote：$remote_url"
    elif ! git -C "$dest" remote get-url origin >/dev/null 2>&1; then
      git -C "$dest" remote add origin "$CLIENT_GIT_REPO_URL"
      log "Git remote：$CLIENT_GIT_REPO_URL（預設）"
    else
      log "Git remote：$(git -C "$dest" remote get-url origin)"
    fi
  fi
}

# npm install 在 lib/ 執行，完成後將 node_modules 移至安裝根目錄（與 index.js 並列）。
# 來源目錄若已含 node_modules（離線包）則直接複製，跳過 npm。
install_dependencies() {
  local dest="$1"
  if [[ -d "$SOURCE_DIR/node_modules" ]] && [[ ! -d "$dest/node_modules" ]]; then
    log "偵測到離線 node_modules，直接複製 …"
    cp -a "$SOURCE_DIR/node_modules" "$dest/node_modules"
    return
  fi
  if [[ ! -f "$dest/lib/package.json" ]]; then
    die "找不到 $dest/lib/package.json（請確認為新版客戶 repo 或重新 release:client）"
  fi
  log "執行 npm install --omit=dev（lib/）…"
  (
    cd "$dest/lib"
    npm install --omit=dev --no-audit --no-fund \
      --fetch-retries=5 \
      --fetch-retry-mintimeout=10000 \
      --fetch-retry-maxtimeout=120000
  )
  rm -rf "$dest/node_modules"
  mv "$dest/lib/node_modules" "$dest/node_modules"
}

ensure_service_user() {
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    log "建立系統使用者 $SERVICE_USER …"
    useradd --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  if getent group dialout >/dev/null 2>&1; then
    usermod -aG dialout "$SERVICE_USER" 2>/dev/null || true
  fi
}

install_systemd_unit() {
  local unit_src="$SOURCE_DIR/lib/dpm-collector.service"
  [[ -f "$unit_src" ]] || unit_src="$SOURCE_DIR/dpm-collector.service"
  [[ -f "$unit_src" ]] || unit_src="$SOURCE_DIR/scripts/dpm-collector.service"
  [[ -f "$unit_src" ]] || die "找不到 dpm-collector.service（lib/ 或舊版根目錄）"

  local node_bin
  node_bin="$(command -v node || true)"
  [[ -n "$node_bin" ]] || die "找不到 node 執行檔"

  sed -e "s|/opt/dpm-collector|$INSTALL_DIR|g" \
      -e "s|/usr/bin/node|$node_bin|g" \
    "$unit_src" > "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

# 權限模型：安裝者（SUDO_USER）擁有檔案、dpm 群組可讀；data/ 僅 dpm 可寫。
# 目的：工程師可 git pull / 編輯 config，服務帳號仍可讀 .env 與程式。
fix_permissions() {
  local install_owner="${SUDO_USER:-root}"
  local data_dir="$INSTALL_DIR/data"

  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    usermod -aG "$SERVICE_USER" "$SUDO_USER" 2>/dev/null || true
  fi

  mkdir -p "$data_dir"

  # 安裝者持有檔案、dpm 群組可讀 → 工程師可 git pull／編輯 config，服務仍可讀取
  chown -R "$install_owner:$SERVICE_USER" "$INSTALL_DIR"
  chown "$SERVICE_USER:$SERVICE_USER" "$data_dir"

  find "$INSTALL_DIR" -type d ! -path "$data_dir" -exec chmod 2775 {} \;
  chmod 2775 "$data_dir"
  find "$INSTALL_DIR" -type f ! -path "$data_dir/*" -exec chmod 664 {} \;
  find "$data_dir" -type f -exec chmod 660 {} \; 2>/dev/null || true

  chmod 775 "$INSTALL_DIR/dpm-ctl.sh" "$INSTALL_DIR/install.sh" 2>/dev/null || true
  [[ -f "$INSTALL_DIR/.env" ]] && chmod 640 "$INSTALL_DIR/.env"

  # 根目錄允許 ls / cd；寫入仍限擁有者（與群組成員）
  chmod 755 "$INSTALL_DIR"

  log "目錄權限：${install_owner} 可編輯與 git pull；服務帳號 ${SERVICE_USER} 經群組讀取設定"
}

# 是否為「更新」：有 .env、systemd 單元、/etc 內 unit 檔皆存在。
is_update_mode() {
  [[ -f "$INSTALL_DIR/.env" ]] && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    && [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]
}

# 啟動服務前以 Node 腳本驗證：slave id 與 device-identities 一致。
validate_runtime_config() {
  local dest="$1"
  local serial_port baud_rate
  [[ -f "$dest/index.js" ]] || die "找不到 $dest/index.js"
  [[ -f "$dest/.env" ]] || die "找不到 $dest/.env"
  [[ -f "$dest/config/device-identities.json" ]] || \
    die "找不到 $dest/config/device-identities.json（請依現場 SLAVE_ID 填寫 guid）"

  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$dest/.env"
  set +a
  serial_port="${SERIAL_PORT:-$DEFAULT_SERIAL_PORT}"
  baud_rate="${MODBUS_BAUD_RATE:-9600}"
  validate_serial_port_or_die "$serial_port" "$baud_rate"

  if ! (
    cd "$dest"
    node <<'NODE'
require('dotenv').config({ path: '.env' });
const fs = require('fs');
const slaveIds = String(process.env.MODBUS_SLAVE_IDS || '')
  .split(',')
  .map((s) => parseInt(s.trim(), 10))
  .filter((n) => Number.isInteger(n) && n >= 1 && n <= 247);
let ident = {};
try {
  ident = JSON.parse(fs.readFileSync('config/device-identities.json', 'utf8'));
} catch (e) {
  console.error('❌ 無法讀取 config/device-identities.json:', e.message);
  process.exit(1);
}
const missing = slaveIds.filter((id) => {
  const row = ident[String(id)];
  return !row || !row.guid;
});
if (missing.length) {
  console.error(
    '❌ MODBUS_SLAVE_IDS 與 device-identities.json 不一致，缺少 SLAVE_ID:',
    missing.join(',')
  );
  console.error('   請編輯 config/device-identities.json，或改 .env 的 MODBUS_SLAVE_IDS');
  process.exit(1);
}
NODE
  ); then
    die "設定檢查未通過（見上方訊息）"
  fi
}

# 重啟 systemd 服務；失敗時印出最近 journal 供除錯。
start_service() {
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "✅ 服務 ${SERVICE_NAME} 運行中"
    if [[ -f "$INSTALL_DIR/VERSION" ]]; then
      log "版本：$(head -n1 "$INSTALL_DIR/VERSION")"
    fi
  else
    echo "--- 最近 30 行日誌 ---" >&2
    journalctl -u "$SERVICE_NAME" -o cat -n 30 --no-pager >&2 || true
    die "服務啟動失敗（常見：MODBUS_SLAVE_IDS 與 device-identities 不符、序列埠不存在、MQTT 設定缺漏）"
  fi
}

# 安裝成功後清除安裝來源；就地安裝時來源就是正式安裝目錄，必須保留。
SOURCE_WAS_REMOVED=0
cleanup_source_after_success() {
  local source_real install_real
  source_real="$(resolve_path "$SOURCE_DIR")"
  install_real="$(resolve_path "$INSTALL_DIR")"

  if [[ "$source_real" == "$install_real" ]]; then
    log "來源即正式安裝目錄，保留 $install_real"
    return
  fi

  # 不允許刪除正式安裝目錄的上層，避免自訂 INSTALL_DIR 時連安裝成果一起移除。
  if [[ "$install_real/" == "$source_real/"* ]]; then
    die "拒絕清除來源 $source_real：它包含正式安裝目錄 $install_real"
  fi

  # 僅刪除可辨識的 DPM 套件目錄，避免 SOURCE_DIR 判斷異常時誤刪廣泛路徑。
  if [[ ! -f "$source_real/index.js" && ! -f "$source_real/dist/index.js" ]] || \
     [[ ! -f "$source_real/install.sh" && ! -f "$source_real/scripts/install.sh" ]]; then
    die "拒絕清除無法辨識的安裝來源：$source_real"
  fi

  cd "$install_real"
  log "清除原始安裝專案：$source_real …"
  rm -rf -- "$source_real"
  [[ ! -e "$source_real" ]] || die "無法完整清除原始安裝專案：$source_real"
  SOURCE_WAS_REMOVED=1
  log "✅ 已清除原始安裝專案：$source_real"
}

# 安裝成功後：提示 → 5 秒進度條 → clear → 即時日誌 → status（日誌可 Ctrl+C 離開）。
finish_install_success() {
  local mode="${1:-install}"
  echo
  if [[ "$mode" == "update" ]]; then
    log "✅ 更新完成"
  else
    log "✅ 安裝完成"
    echo "   安裝目錄：$INSTALL_DIR"
    echo "   管理工具：$INSTALL_DIR/dpm-ctl.sh status"
    echo "   查看日誌：$INSTALL_DIR/dpm-ctl.sh logs"
  fi
  echo
  log_highlight "接下來顯示即時日誌，可按 Ctrl+C 離開（不影響服務運行）"
  countdown_progress_bar 5
  if [[ -t 1 ]]; then
    clear
  fi
  "$INSTALL_DIR/dpm-ctl.sh" logs -n 30 || true
  "$INSTALL_DIR/dpm-ctl.sh" status || true
  echo
  if [[ "$SOURCE_WAS_REMOVED" -eq 1 ]]; then
    log "✅ 原始安裝專案已刪除"
  fi
  log_highlight "install.sh 無法切換呼叫端 Shell 的目錄，請執行："
  printf '   cd %q\n' "$INSTALL_DIR"
}

# --- 主流程 ---
main() {
  require_root
  validate_utf8_file "$0"
  log_section "環境"
  detect_system
  log_section "安裝目標"
  log_highlight "程式將安裝至：$INSTALL_DIR"
  if [[ "$SOURCE_DIR" != "$INSTALL_DIR" ]]; then
    log "安裝成功後將刪除來源：$SOURCE_DIR"
  else
    log "目前為就地安裝，將保留正式安裝目錄"
  fi
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  if is_update_mode; then
    log_section "更新"
    log "偵測到既有安裝，進入更新模式 …"
    log_section "程式檔案"
    sync_app_files "$INSTALL_DIR"
    link_git_from_source "$INSTALL_DIR"
    log_section "Node.js"
    ensure_nodejs
    install_dependencies "$INSTALL_DIR"
    ensure_serial_port_config "$INSTALL_DIR/.env"
    validate_runtime_config "$INSTALL_DIR"
    fix_permissions
    log_section "服務"
    start_service
    cleanup_source_after_success
    finish_install_success update
    exit 0
  fi

  log "初次安裝到 $INSTALL_DIR …"
  mkdir -p "$INSTALL_DIR"
  log_section "程式檔案"
  sync_app_files "$INSTALL_DIR"
  link_git_from_source "$INSTALL_DIR"
  log_section "Node.js"
  ensure_nodejs
  install_dependencies "$INSTALL_DIR"

  ensure_env_file "$INSTALL_DIR/.env"

  log_section "systemd"
  ensure_service_user
  install_systemd_unit
  validate_runtime_config "$INSTALL_DIR"
  fix_permissions
  log_section "服務"
  start_service
  cleanup_source_after_success
  finish_install_success install
}

main "$@"
