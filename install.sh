#!/usr/bin/env bash
# =============================================================================
# install.sh — DPM-DA510/530 Modbus RTU Collector 一鍵安裝／更新
#
# 目標平台：BL118 等 Ubuntu 20.04+ 邊緣閘道器。
# 執行方式：sudo ./install.sh（須 root，用於 apt、systemd、chown）。
#
# 安裝來源（自動偵測 SOURCE_DIR）：
#   - 客戶 repo 根目錄（git clone / USB 的 dpm-collector/）
#   - 開發 repo 的 scripts/ 或含 dist/ 的舊布局
#
# 主要流程（初次安裝）：
#   環境檢查 → 同步檔案 → Node.js + npm ci → 互動建立 .env
#   → InfluxDB 2（本地 7 天緩存）→ systemd → 權限 → 啟動服務
#
# 更新模式（is_update_mode）：已有 .env 且 systemd 單元存在時，
#   保留 .env，僅同步程式、npm ci、驗證、重啟。
# =============================================================================
set -euo pipefail

# --- 可覆寫的安裝參數（環境變數） ---
INSTALL_DIR="${INSTALL_DIR:-/opt/dpm-collector}"
SERVICE_NAME="${SERVICE_NAME:-dpm-collector}"
SERVICE_USER="${SERVICE_USER:-dpm}"
NODE_MIN_MAJOR="${NODE_MIN_MAJOR:-24}"
INFLUX_RETENTION_HOURS="${INFLUX_RETENTION_HOURS:-168}"
CLIENT_GIT_REPO_URL="${CLIENT_GIT_REPO_URL:-https://github.com/vippaFor9skin/dpm-collector-release.git}"
DEFAULT_MQTT_URL="${DEFAULT_MQTT_URL:-mqtt://124.219.96.34:1883}"
DEFAULT_MQTT_USERNAME="${DEFAULT_MQTT_USERNAME:-dpm_user}"
DEFAULT_MQTT_PASSWORD="${DEFAULT_MQTT_PASSWORD:-}"
DEFAULT_POLL_INTERVAL_MS="${DEFAULT_POLL_INTERVAL_MS:-5000}"
DEFAULT_MONITOR_ONLY="${DEFAULT_MONITOR_ONLY:-0}"

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

# --- Node.js（採集程式執行環境，預設 24+） ---
node_major() {
  if ! command -v node >/dev/null 2>&1; then
    echo 0
    return
  fi
  node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1
}

install_nodejs() {
  log "安裝 Node.js ${NODE_MIN_MAJOR}+ …"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MIN_MAJOR}.x" | bash -
    apt-get install -y nodejs
  else
    die "不支援的套件管理器，請手動安裝 Node.js ${NODE_MIN_MAJOR}+"
  fi
  log "Node.js 版本：$(node -v)"
}

ensure_nodejs() {
  local major
  major="$(node_major)"
  if [[ "$major" -lt "$NODE_MIN_MAJOR" ]]; then
    install_nodejs
  else
    log "Node.js 已安裝：$(node -v)"
  fi
}

# --- InfluxDB 2（本地時序緩存，斷網期間仍保存採樣） ---
# INFLUX_HOST：influx CLI 與 curl 共用；勿用 influx --host（部分版本不支援）。
# 健康檢查優先 curl /health，避免 sudo 下 PATH 缺 curl 導致誤判。
install_influxdb_apt() {
  log "安裝 InfluxDB 2（apt）…"
  apt-get update -qq
  apt-get install -y wget gpg ca-certificates
  local key_file
  key_file="$(mktemp)"
  wget -qO "$key_file" https://repos.influxdata.com/influxdata-archive.key
  gpg --show-keys --with-fingerprint --with-colons "$key_file" 2>&1 \
    | grep -qE ':24C975CBA61A024EE1B631787C3D57159FC2F927:' \
    || die "InfluxData GPG 指紋驗證失敗"
  gpg --dearmor < "$key_file" > /etc/apt/trusted.gpg.d/influxdata-archive.gpg
  rm -f "$key_file"
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" \
    > /etc/apt/sources.list.d/influxdata.list
  apt-get update -qq
  apt-get install -y influxdb2
  systemctl enable --now influxdb
  log "InfluxDB 服務已啟動"
}

INFLUX_HOST="${INFLUX_HOST:-http://127.0.0.1:8086}"

find_http_client() {
  local name="$1"
  local c
  for c in "/usr/bin/$name" "/bin/$name"; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  command -v "$name" 2>/dev/null || true
}

ensure_influx_http_client() {
  find_http_client curl >/dev/null && return 0
  find_http_client wget >/dev/null && return 0
  apt-get update -qq
  apt-get install -y curl
}

influx_cli() {
  INFLUX_HOST="$INFLUX_HOST" influx "$@"
}

influx_http_healthy() {
  local curl_bin wget_bin body
  curl_bin="$(find_http_client curl)"
  if [[ -n "$curl_bin" ]]; then
    body="$("$curl_bin" -sf "${INFLUX_HOST}/health" 2>/dev/null || true)"
    if [[ -n "$body" ]] && echo "$body" | grep -q '"pass"'; then
      return 0
    fi
  fi
  wget_bin="$(find_http_client wget)"
  if [[ -n "$wget_bin" ]]; then
    body="$("$wget_bin" -qO- "${INFLUX_HOST}/health" 2>/dev/null || true)"
    if [[ -n "$body" ]] && echo "$body" | grep -q '"pass"'; then
      return 0
    fi
  fi
  return 1
}

influx_reachable() {
  if influx_http_healthy; then
    return 0
  fi
  INFLUX_HOST="$INFLUX_HOST" influx ping >/dev/null 2>&1
}

log_influx_reachability_debug() {
  local curl_bin body ping_out
  curl_bin="$(find_http_client curl)"
  log "除錯：INFLUX_HOST=$INFLUX_HOST PATH=$PATH"
  log "除錯：curl=${curl_bin:-（找不到，請 apt install curl）}"
  if [[ -n "$curl_bin" ]]; then
    body="$("$curl_bin" -sf "${INFLUX_HOST}/health" 2>&1 || true)"
    log "除錯：GET ${INFLUX_HOST}/health → ${body:-（空）}"
  fi
  ping_out="$(INFLUX_HOST="$INFLUX_HOST" influx ping 2>&1 | head -c 160 || true)"
  log "除錯：INFLUX_HOST=$INFLUX_HOST influx ping → ${ping_out:-（空）}"
}

influx_is_initialized() {
  influx_cli ping >/dev/null 2>&1 && influx_cli org list >/dev/null 2>&1
}

fetch_influx_setup_status() {
  local curl_bin wget_bin body=""
  curl_bin="$(find_http_client curl)"
  if [[ -n "$curl_bin" ]]; then
    body="$("$curl_bin" -sf "${INFLUX_HOST}/api/v2/setup" 2>/dev/null || true)"
  else
    wget_bin="$(find_http_client wget)"
    [[ -n "$wget_bin" ]] && body="$("$wget_bin" -qO- "${INFLUX_HOST}/api/v2/setup" 2>/dev/null || true)"
  fi
  printf '%s' "$body"
}

influx_server_needs_setup() {
  ensure_influx_http_client
  local body
  body="$(fetch_influx_setup_status)"
  if [[ -n "$body" ]]; then
    if echo "$body" | grep -qE '"allowed"[[:space:]]*:[[:space:]]*true'; then
      return 0
    fi
    return 1
  fi
  # Influx 已在跑但讀不到 setup API：視為已初始化，不要 rerun setup
  if influx_reachable; then
    log "InfluxDB 已在運行，略過 setup（改為建立 API Token）"
    return 1
  fi
  return 0
}

wait_for_influx_ping() {
  ensure_influx_http_client
  local i
  for i in $(seq 1 20); do
    if influx_reachable; then
      return 0
    fi
    sleep 1
  done
  log_influx_reachability_debug
  return 1
}

resolve_influx_credentials() {
  local _var="$1"
  local created="$2"
  local admin_file="/root/dpm-collector-influx-admin.txt"
  local influx_org influx_bucket influx_token

  if [[ -n "$created" ]]; then
    IFS='|' read -r influx_org influx_bucket influx_token <<< "$created"
    printf -v "$_var" '%s|%s|%s' "$influx_org" "$influx_bucket" "$influx_token"
    return 0
  fi

  [[ -f "$admin_file" ]] || return 1
  influx_token="$(trim_value "$(sed -n 's/^Token:[[:space:]]*//p' "$admin_file" | head -n1)")"
  influx_org="$(sed -n 's/^Org:[[:space:]]*//p' "$admin_file" | head -n1)"
  influx_bucket="$(sed -n 's/^Bucket:[[:space:]]*//p' "$admin_file" | head -n1)"
  [[ -n "$influx_token" ]] || return 1
  [[ -n "$influx_org" ]] || influx_org="${INFLUX_ORG:-nineskin}"
  [[ -n "$influx_bucket" ]] || influx_bucket="${INFLUX_BUCKET:-9998-6_dpm}"
  log "沿用 $admin_file 內 Token"
  printf -v "$_var" '%s|%s|%s' "$influx_org" "$influx_bucket" "$influx_token"
}

# Influx 已初始化時，sudo 執行者（SUDO_USER）的 influx CLI 常有有效 token，
# 但 root 自己沒有 ~/.influxdbv2/configs；以下函式以 SUDO_USER 身份跑 influx。
influx_sudo_user() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    printf '%s' "$SUDO_USER"
  fi
}

influx_invoke_as_user() {
  local user="$1"
  shift
  if [[ -n "$user" ]]; then
    sudo -u "$user" env INFLUX_HOST="$INFLUX_HOST" "$@"
  else
    env INFLUX_HOST="$INFLUX_HOST" "$@"
  fi
}

influx_cli_user_can_list_orgs() {
  local user="$1"
  influx_invoke_as_user "$user" influx org list --hide-headers >/dev/null 2>&1
}

influx_token_can_list_orgs() {
  local token="$1"
  [[ -n "$token" ]] || return 1
  INFLUX_HOST="$INFLUX_HOST" INFLUX_TOKEN="$token" influx org list --hide-headers >/dev/null 2>&1
}

extract_active_token_from_influx_config_json() {
  node -e "
let s='';
process.stdin.on('data',(d)=>s+=d);
process.stdin.on('end',()=>{
  try {
    const j=JSON.parse(s);
    const list=Array.isArray(j)
      ? j
      : (j.configs
        ? Object.entries(j.configs).map(([name, c]) => ({ name, ...c }))
        : Object.entries(j).filter(([, c]) => c && typeof c === 'object').map(([name, c]) => ({ name, ...c })));
    const active=list.find((c)=>c.active===true||c.active==='true')||list[0];
    if(active&&active.token) process.stdout.write(String(active.token));
  } catch {}
});
"
}

get_influx_cli_token_for_user() {
  local user="$1" raw
  raw="$(influx_invoke_as_user "$user" influx config list --json 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 1
  trim_value "$(printf '%s' "$raw" | extract_active_token_from_influx_config_json)"
}

detect_influx_org_with_cli_user() {
  local user="$1"
  local preferred="$2"
  local detected
  detected="$(influx_invoke_as_user "$user" influx org list --hide-headers --json 2>/dev/null | node -e "
let s='';
process.stdin.on('data',(d)=>s+=d);
process.stdin.on('end',()=>{
  try {
    const arr=JSON.parse(s);
    const names=(Array.isArray(arr)?arr:[]).map((o)=>o.name).filter(Boolean);
    const pref=process.argv[1];
    if(names.includes(pref)){ process.stdout.write(pref); return; }
    if(names[0]) process.stdout.write(names[0]);
  } catch {}
});
" "$preferred" 2>/dev/null || true)"
  detected="$(trim_value "$detected")"
  [[ -n "$detected" ]] && printf '%s' "$detected" || printf '%s' "$preferred"
}

detect_influx_bucket_with_cli_user() {
  local user="$1"
  local org="$2"
  local preferred="$3"
  local detected
  detected="$(influx_invoke_as_user "$user" influx bucket list --org "$org" --hide-headers --json 2>/dev/null | node -e "
let s='';
process.stdin.on('data',(d)=>s+=d);
process.stdin.on('end',()=>{
  try {
    const arr=JSON.parse(s);
    const names=(Array.isArray(arr)?arr:[]).map((b)=>b.name).filter(Boolean);
    const pref=process.argv[1];
    if(names.includes(pref)){ process.stdout.write(pref); return; }
    if(names[0]) process.stdout.write(names[0]);
  } catch {}
});
" "$preferred" 2>/dev/null || true)"
  detected="$(trim_value "$detected")"
  [[ -n "$detected" ]] && printf '%s' "$detected" || printf '%s' "$preferred"
}

collect_influx_tokens_from_configs_file() {
  local configs_file="$1"
  [[ -f "$configs_file" ]] || return 0
  node - "$configs_file" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
try {
  const j = JSON.parse(fs.readFileSync(path, 'utf8'));
  const configs = j.configs || j;
  const list = Array.isArray(configs)
    ? configs
    : Object.entries(configs).map(([name, c]) => ({ name, ...c }));
  for (const c of list) {
    if (c && c.token) process.stdout.write(String(c.token) + '\n');
  }
} catch {}
NODE
}

collect_influx_tokens_from_user() {
  local user="$1" home cf
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
  [[ -n "$home" ]] || return 0
  for cf in "$home/.influxdbv2/configs" "$home/.config/influxdb/influx-configs"; do
    collect_influx_tokens_from_configs_file "$cf"
  done
}

collect_all_influx_config_tokens() {
  local raw token sudo_user
  sudo_user="$(influx_sudo_user || true)"

  raw="$(influx config list --json 2>/dev/null || true)"
  if [[ -n "$raw" ]]; then
    token="$(printf '%s' "$raw" | extract_active_token_from_influx_config_json || true)"
    [[ -n "$token" ]] && printf '%s\n' "$token"
    printf '%s' "$raw" | node -e "
let s='';
process.stdin.on('data',(d)=>s+=d);
process.stdin.on('end',()=>{
  try {
    const j=JSON.parse(s);
    const list=Array.isArray(j)?j:(j.configs?Object.entries(j.configs).map(([n,c])=>({name:n,...c})):[]);
    for (const c of list) { if(c&&c.token) process.stdout.write(String(c.token)+'\n'); }
  } catch {}
});
"
  fi

  if [[ -n "$sudo_user" ]]; then
    token="$(get_influx_cli_token_for_user "$sudo_user" || true)"
    [[ -n "$token" ]] && printf '%s\n' "$token"
    collect_influx_tokens_from_user "$sudo_user"
  fi
}

find_influx_operator_token() {
  local token sudo_user
  sudo_user="$(influx_sudo_user || true)"

  if [[ -n "$sudo_user" ]] && influx_cli_user_can_list_orgs "$sudo_user"; then
    token="$(get_influx_cli_token_for_user "$sudo_user" || true)"
    if [[ -n "$token" ]] && influx_token_can_list_orgs "$token"; then
      printf '%s' "$token"
      return 0
    fi
  fi

  while IFS= read -r token; do
    token="$(trim_value "$token")"
    [[ -n "$token" ]] || continue
    if influx_token_can_list_orgs "$token"; then
      printf '%s' "$token"
      return 0
    fi
  done < <(collect_all_influx_config_tokens | sort -u)
  return 1
}

detect_influx_org_with_token() {
  local op_token="$1"
  local preferred="$2"
  local detected
  detected="$(INFLUX_HOST="$INFLUX_HOST" INFLUX_TOKEN="$op_token" influx org list --hide-headers --json 2>/dev/null | node -e "
let s='';
process.stdin.on('data',(d)=>s+=d);
process.stdin.on('end',()=>{
  try {
    const arr=JSON.parse(s);
    const names=(Array.isArray(arr)?arr:[]).map((o)=>o.name).filter(Boolean);
    const pref=process.argv[1];
    if(names.includes(pref)){ process.stdout.write(pref); return; }
    if(names[0]) process.stdout.write(names[0]);
  } catch {}
});
" "$preferred" 2>/dev/null || true)"
  detected="$(trim_value "$detected")"
  [[ -n "$detected" ]] && printf '%s' "$detected" || printf '%s' "$preferred"
}

detect_influx_bucket_with_token() {
  local op_token="$1"
  local org="$2"
  local preferred="$3"
  local detected
  detected="$(INFLUX_HOST="$INFLUX_HOST" INFLUX_TOKEN="$op_token" influx bucket list --org "$org" --hide-headers --json 2>/dev/null | node -e "
let s='';
process.stdin.on('data',(d)=>s+=d);
process.stdin.on('end',()=>{
  try {
    const arr=JSON.parse(s);
    const names=(Array.isArray(arr)?arr:[]).map((b)=>b.name).filter(Boolean);
    const pref=process.argv[1];
    if(names.includes(pref)){ process.stdout.write(pref); return; }
    if(names[0]) process.stdout.write(names[0]);
  } catch {}
});
" "$preferred" 2>/dev/null || true)"
  detected="$(trim_value "$detected")"
  [[ -n "$detected" ]] && printf '%s' "$detected" || printf '%s' "$preferred"
}

get_active_influx_token() {
  local raw
  raw="$(influx config list --json 2>/dev/null | node -e "
let s='';
process.stdin.on('data',(d)=>s+=d);
process.stdin.on('end',()=>{
  try {
    const j=JSON.parse(s);
    const list=Array.isArray(j)?j:(j.configs?Object.entries(j.configs).map(([n,c])=>({name:n,...c})):[]);
    const active=list.find((c)=>c.active===true||c.active==='true')||list[0];
    if(active&&active.token) process.stdout.write(String(active.token));
  } catch {}
});
" 2>/dev/null || true)"
  trim_value "$raw"
}

detect_influx_org() {
  local preferred="$1"
  local detected
  detected="$(influx_cli org list --hide-headers --json 2>/dev/null | node -e "
let s='';
process.stdin.on('data',(d)=>s+=d);
process.stdin.on('end',()=>{
  try {
    const arr=JSON.parse(s);
    const names=(Array.isArray(arr)?arr:[]).map((o)=>o.name).filter(Boolean);
    const pref=process.argv[1];
    if(names.includes(pref)){ process.stdout.write(pref); return; }
    if(names[0]) process.stdout.write(names[0]);
  } catch {}
});
" "$preferred" 2>/dev/null || true)"
  detected="$(trim_value "$detected")"
  [[ -n "$detected" ]] && printf '%s' "$detected" || printf '%s' "$preferred"
}

detect_influx_bucket() {
  local org="$1"
  local preferred="$2"
  local detected
  detected="$(influx_cli bucket list --org "$org" --hide-headers --json 2>/dev/null | node -e "
let s='';
process.stdin.on('data',(d)=>s+=d);
process.stdin.on('end',()=>{
  try {
    const arr=JSON.parse(s);
    const names=(Array.isArray(arr)?arr:[]).map((b)=>b.name).filter(Boolean);
    const pref=process.argv[1];
    if(names.includes(pref)){ process.stdout.write(pref); return; }
    if(names[0]) process.stdout.write(names[0]);
  } catch {}
});
" "$preferred" 2>/dev/null || true)"
  detected="$(trim_value "$detected")"
  [[ -n "$detected" ]] && printf '%s' "$detected" || printf '%s' "$preferred"
}

save_influx_admin_token() {
  local admin_file="$1"
  local org="$2"
  local bucket="$3"
  local token="$4"
  if [[ -f "$admin_file" ]]; then
    if grep -q '^Token:' "$admin_file"; then
      sed -i "s|^Token:.*|Token: $token|" "$admin_file"
    else
      printf '\nToken: %s\n' "$token" >> "$admin_file"
    fi
    if grep -q '^Org:' "$admin_file"; then
      sed -i "s|^Org:.*|Org: $org|" "$admin_file"
    fi
    if grep -q '^Bucket:' "$admin_file"; then
      sed -i "s|^Bucket:.*|Bucket: $bucket|" "$admin_file"
    fi
  else
    cat > "$admin_file" <<EOF
InfluxDB 管理資訊（請妥善保存，勿提交 git）
Org: $org
Bucket: $bucket
Token: $token
Retention: ${INFLUX_RETENTION_HOURS}h
EOF
  fi
  chmod 600 "$admin_file"
}

influx_auth_create_token() {
  local org="$1"
  local bucket="$2"
  local token="$3"
  local desc="$4"
  local op_token="${5:-}"
  local err_log rc sudo_user

  err_log="$(mktemp)"
  sudo_user="$(influx_sudo_user || true)"
  [[ -n "$op_token" ]] || op_token="$(find_influx_operator_token || true)"

  if [[ -n "$sudo_user" ]] && influx_cli_user_can_list_orgs "$sudo_user"; then
    if influx_invoke_as_user "$sudo_user" influx auth create \
      --org "$org" \
      --token "$token" \
      --description "$desc" \
      --read-bucket "$bucket" \
      --write-bucket "$bucket" 2>"$err_log"; then
      rm -f "$err_log"
      return 0
    fi
    log "以 $sudo_user 建立 Token 失敗：$(tr '\n' ' ' < "$err_log" | head -c 200)"
    : >"$err_log"
  fi

  if [[ -n "$op_token" ]]; then
    if INFLUX_HOST="$INFLUX_HOST" INFLUX_TOKEN="$op_token" influx auth create \
      --org "$org" \
      --token "$token" \
      --description "$desc" \
      --read-bucket "$bucket" \
      --write-bucket "$bucket" 2>"$err_log"; then
      rm -f "$err_log"
      return 0
    fi
  fi

  if influx_cli auth create \
    --org "$org" \
    --token "$token" \
    --description "$desc" \
    --read-bucket "$bucket" \
    --write-bucket "$bucket" 2>"$err_log"; then
    rm -f "$err_log"
    return 0
  fi

  rc=$?
  log "influx auth create 失敗（exit $rc）：$(tr '\n' ' ' < "$err_log" | head -c 240)"
  rm -f "$err_log"
  return 1
}

influx_setup_force_rebind() {
  local username="$1"
  local password="$2"
  local org="$3"
  local bucket="$4"
  local token="$5"
  influx_cli setup \
    --username "$username" \
    --password "$password" \
    --org "$org" \
    --bucket "$bucket" \
    --retention "${INFLUX_RETENTION_HOURS}h" \
    --token "$token" \
    --force
}

# 在已初始化的 Influx 上建立採集專用 token；失敗時嘗試沿用 SUDO_USER 的 CLI token。
create_collector_influx_token() {
  local org="$1"
  local bucket="$2"
  local token desc admin_file op_token sudo_user
  admin_file="/root/dpm-collector-influx-admin.txt"
  token="$(openssl rand -hex 32)"
  desc="dpm-collector-$(date +%Y%m%d%H%M%S)"
  sudo_user="$(influx_sudo_user || true)"

  if [[ -n "$sudo_user" ]] && influx_cli_user_can_list_orgs "$sudo_user"; then
    org="$(detect_influx_org_with_cli_user "$sudo_user" "$org")"
    bucket="$(detect_influx_bucket_with_cli_user "$sudo_user" "$org" "$bucket")"
    log "Influx 已存在：org=$org bucket=$bucket（自 $sudo_user 的 influx CLI 偵測）"
    if influx_auth_create_token "$org" "$bucket" "$token" "$desc"; then
      save_influx_admin_token "$admin_file" "$org" "$bucket" "$token"
      printf '%s|%s|%s' "$org" "$bucket" "$token"
      return 0
    fi
    op_token="$(get_influx_cli_token_for_user "$sudo_user" || true)"
    if [[ -n "$op_token" ]] && influx_token_can_list_orgs "$op_token"; then
      log "⚠️  無法建立獨立 Token，沿用 $sudo_user 的 Influx CLI Token"
      save_influx_admin_token "$admin_file" "$org" "$bucket" "$op_token"
      printf '%s|%s|%s' "$org" "$bucket" "$op_token"
      return 0
    fi
  fi

  op_token="$(find_influx_operator_token || true)"
  if [[ -n "$op_token" ]]; then
    org="$(detect_influx_org_with_token "$op_token" "$org")"
    bucket="$(detect_influx_bucket_with_token "$op_token" "$org" "$bucket")"
    log "Influx 已存在：org=$org bucket=$bucket（自本機 influx CLI 偵測）"
    if influx_auth_create_token "$org" "$bucket" "$token" "$desc" "$op_token"; then
      save_influx_admin_token "$admin_file" "$org" "$bucket" "$token"
      printf '%s|%s|%s' "$org" "$bucket" "$token"
      return 0
    fi
    log "⚠️  無法建立獨立 Token，沿用已驗證的 Influx CLI Token"
    save_influx_admin_token "$admin_file" "$org" "$bucket" "$op_token"
    printf '%s|%s|%s' "$org" "$bucket" "$op_token"
    return 0
  fi

  if [[ -f "$admin_file" ]]; then
    local admin_user admin_pass file_org file_bucket
    admin_user="$(sed -n 's/^Username:[[:space:]]*//p' "$admin_file" | head -n1)"
    admin_pass="$(sed -n 's/^Password:[[:space:]]*//p' "$admin_file" | head -n1)"
    file_org="$(sed -n 's/^Org:[[:space:]]*//p' "$admin_file" | head -n1)"
    file_bucket="$(sed -n 's/^Bucket:[[:space:]]*//p' "$admin_file" | head -n1)"
    [[ -n "$file_org" ]] && org="$file_org"
    [[ -n "$file_bucket" ]] && bucket="$file_bucket"
    if [[ -n "$admin_user" && -n "$admin_pass" ]]; then
      log "改用 influx setup --force 重新綁定 CLI 並建立 Token …"
      if influx_setup_force_rebind "$admin_user" "$admin_pass" "$org" "$bucket" "$token"; then
        save_influx_admin_token "$admin_file" "$org" "$bucket" "$token"
        printf '%s|%s|%s' "$org" "$bucket" "$token"
        return 0
      fi
    fi
  fi

  if [[ -f "$INSTALL_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/.env"
    set +a
    if [[ -n "${INFLUX_TOKEN:-}" ]] && influx_token_can_list_orgs "$(trim_value "$INFLUX_TOKEN")"; then
      org="$(detect_influx_org_with_token "$(trim_value "$INFLUX_TOKEN")" "${INFLUX_ORG:-$org}")"
      bucket="$(detect_influx_bucket_with_token "$(trim_value "$INFLUX_TOKEN")" "$org" "${INFLUX_BUCKET:-$bucket}")"
      log "沿用 $INSTALL_DIR/.env 內 Influx Token"
      save_influx_admin_token "$admin_file" "$org" "$bucket" "$(trim_value "$INFLUX_TOKEN")"
      printf '%s|%s|%s' "$org" "$bucket" "$(trim_value "$INFLUX_TOKEN")"
      return 0
    fi
  fi

  return 1
}

init_influxdb() {
  local username="${1:-dpmadmin}"
  local password="${2:-}"
  local org="${3:-nineskin}"
  local bucket="${4:-9998-6_dpm}"
  local token err_log
  token="$(openssl rand -hex 32)"
  err_log="$(mktemp)"

  log "初始化 InfluxDB（org=$org, bucket=$bucket, retention=${INFLUX_RETENTION_HOURS}h）…"
  if ! influx_cli setup \
    --username "$username" \
    --password "$password" \
    --org "$org" \
    --bucket "$bucket" \
    --retention "${INFLUX_RETENTION_HOURS}h" \
    --token "$token" \
    --force 2>"$err_log"; then
    log "influx setup 失敗：$(tr '\n' ' ' < "$err_log" | head -c 240)"
    rm -f "$err_log"
    return 1
  fi
  rm -f "$err_log"
  echo "$org|$bucket|$token"
  return 0
}

configure_influxdb_localhost() {
  local cfg
  for cfg in /etc/influxdb2/config.toml /etc/influxdb/config.toml; do
    [[ -f "$cfg" ]] || continue
    if grep -qE '^[[:space:]]*http-bind-address[[:space:]]*=[[:space:]]*"127\.0\.0\.1:8086"' "$cfg"; then
      log "InfluxDB 已綁定 127.0.0.1:8086"
      return 0
    fi
    if grep -qE '^[[:space:]]*#?[[:space:]]*http-bind-address' "$cfg"; then
      sed -i -E 's|^[[:space:]]*#?[[:space:]]*http-bind-address.*|http-bind-address = "127.0.0.1:8086"|' "$cfg"
    else
      printf '\nhttp-bind-address = "127.0.0.1:8086"\n' >> "$cfg"
    fi
    systemctl restart influxdb
    sleep 2
    log "InfluxDB 僅監聽本機 127.0.0.1:8086"
    return 0
  done
  log "⚠️  未找到 InfluxDB config.toml，請確認僅本機可連"
}

log_influx_credentials() {
  local org="$1"
  local bucket="$2"
  local token="$3"
  log "INFLUX_URL=${INFLUX_HOST}"
  log "INFLUX_ORG=$org"
  log "INFLUX_BUCKET=$bucket"
  log "INFLUX_TOKEN=$token"
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

# 回傳 org|bucket|token（InfluxDB 為必填，供本地 7 天緩存）
ensure_influxdb_for_install() {
  local influx_org="${INFLUX_ORG:-nineskin}"
  local influx_bucket="${INFLUX_BUCKET:-9998-6_dpm}"
  local influx_token=""
  local admin_file="/root/dpm-collector-influx-admin.txt"

  log "InfluxDB 2 為必填（本地 7 天緩存 + 斷網期間資料安全）…"

  if ! dpkg -l influxdb2 >/dev/null 2>&1; then
    install_influxdb_apt
  elif ! systemctl is-active --quiet influxdb 2>/dev/null; then
    systemctl enable --now influxdb || install_influxdb_apt
  fi

  configure_influxdb_localhost
  wait_for_influx_ping || die "InfluxDB 服務未就緒（${INFLUX_HOST}）"

  if influx_server_needs_setup; then
    local influx_pass setup_result created creds
    influx_pass="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
    if setup_result="$(init_influxdb "dpmadmin" "$influx_pass" "$influx_org" "$influx_bucket")"; then
      IFS='|' read -r influx_org influx_bucket influx_token <<< "$setup_result"
      cat > "$admin_file" <<EOF
InfluxDB 管理帳號（請妥善保存，勿提交 git）
Username: dpmadmin
Password: $influx_pass
Org: $influx_org
Bucket: $influx_bucket
Token: $influx_token
Retention: ${INFLUX_RETENTION_HOURS}h
EOF
      chmod 600 "$admin_file"
      log "InfluxDB 管理帳號已寫入 $admin_file"
    else
      log "InfluxDB 伺服器已初始化，改為建立採集程式 API Token …"
      created="$(create_collector_influx_token "$influx_org" "$influx_bucket" || true)"
      resolve_influx_credentials creds "$created" || \
        die "無法建立 InfluxDB Token。請確認 sudo 執行者（${SUDO_USER:-root}）曾 influx setup，或執行：sudo -u ${SUDO_USER:-$USER} influx org list"
      IFS='|' read -r influx_org influx_bucket influx_token <<< "$creds"
    fi
  elif [[ -f "$INSTALL_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$INSTALL_DIR/.env"
    influx_org="${INFLUX_ORG:-$influx_org}"
    influx_bucket="${INFLUX_BUCKET:-$influx_bucket}"
    influx_token="$(trim_value "${INFLUX_TOKEN:-}")"
    if [[ -z "$influx_token" ]]; then
      die "InfluxDB 已初始化但 .env 缺少 INFLUX_TOKEN，請手動填入或重建 token"
    fi
    log "沿用既有 InfluxDB 設定"
  else
    log "InfluxDB 已初始化，自動建立採集程式 API Token …"
    local created creds
    created="$(create_collector_influx_token "$influx_org" "$influx_bucket" || true)"
    resolve_influx_credentials creds "$created" || \
      die "無法建立 InfluxDB Token。請確認 sudo 執行者（${SUDO_USER:-root}）曾 influx setup，或執行：sudo -u ${SUDO_USER:-$USER} influx org list"
    IFS='|' read -r influx_org influx_bucket influx_token <<< "$creds"
  fi

  influx_token="$(trim_value "$influx_token")"
  [[ -n "$influx_token" ]] || die "INFLUX_TOKEN 不可為空"

  wait_for_influx_ping || die "InfluxDB 無法連線（${INFLUX_HOST}）"

  log_influx_credentials "$influx_org" "$influx_bucket" "$influx_token"
  echo "$influx_org|$influx_bucket|$influx_token"
}

verify_influxdb_ready() {
  if ! systemctl is-active --quiet influxdb 2>/dev/null; then
    die "InfluxDB 服務未運行（本地緩存必填）"
  fi
  if ! influx_reachable; then
    log_influx_reachability_debug
    die "InfluxDB 無法連線；請檢查 systemctl status influxdb 與 curl ${INFLUX_HOST}/health"
  fi
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

# --- Modbus 序列埠偵測（僅 ttyUSB* / ttyACM* / by-id；不含滑鼠鍵盤） ---
detect_serial_ports() {
  local p link real pattern
  {
    for link in /dev/serial/by-id/*; do
      [[ -e "$link" ]] || continue
      real="$(readlink -f "$link" 2>/dev/null || continue)"
      [[ -c "$real" ]] && printf '%s\n' "$real"
    done
    for pattern in /dev/ttyUSB* /dev/ttyACM*; do
      for p in $pattern; do
        [[ -e "$p" && -c "$p" ]] && printf '%s\n' "$p"
      done
    done
  } | sort -u
}

serial_port_desc() {
  local dev="$1" real link base props
  real="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"
  for link in /dev/serial/by-id/*; do
    [[ -e "$link" ]] || continue
    if [[ "$(readlink -f "$link" 2>/dev/null)" == "$real" ]]; then
      base="$(basename "$link")"
      printf '%s' "$base"
      return 0
    fi
  done
  if command -v udevadm >/dev/null 2>&1; then
    props="$(udevadm info -q property -n "$dev" 2>/dev/null \
      | awk -F= '/^ID_VENDOR=/ {v=$2} /^ID_MODEL=/ {m=$2} END {if (v||m) printf "%s %s", v, m}')"
    [[ -n "$props" ]] && printf '%s' "$props"
  fi
}

prompt_serial_port() {
  local -a ports=()
  local line i choice desc manual_idx default_choice default_manual="/dev/ttyUSB0"

  while IFS= read -r line; do
    [[ -n "$line" ]] && ports+=("$line")
  done < <(detect_serial_ports)

  manual_idx=$((${#ports[@]} + 1))

  echo "請選擇 Modbus 序列埠（RS-485／USB 轉串口；滑鼠、鍵盤、網卡不在此列）：" >&2
  if [[ ${#ports[@]} -eq 0 ]]; then
    echo "  （目前未偵測到 /dev/ttyUSB* 或 /dev/ttyACM*）" >&2
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

# 寫入含中文備註的 .env（欄位說明對照開發倉 .env.example）。
write_env_file_content() {
  local env_file="$1"
  local serial_port="$2"
  local slave_ids="$3"
  local monitor_only="$4"
  local poll_ms="$5"
  local influx_org="$6"
  local influx_bucket="$7"
  local influx_token="$8"
  local mqtt_url="$9"
  local mqtt_user="${10}"
  local mqtt_pass="${11}"
  local gateway_id="${12}"

  cat > "$env_file" <<EOF
# ---------------------------------------------------------------------------
# 本檔由 install.sh 產生（$(date -Iseconds)）
# 修改後請執行：sudo systemctl restart dpm-collector
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 序列埠（RS-485 轉 USB）
# Linux 常見為 /dev/ttyUSB0 或 /dev/ttyACM0
# ---------------------------------------------------------------------------
SERIAL_PORT=$serial_port
MODBUS_BAUD_RATE=9600
MODBUS_DATA_BITS=8
MODBUS_STOP_BITS=2
MODBUS_PARITY=none
# 多設備輪詢（最多 10 台，逗號分隔；須與 config/device-identities.json 的 key 一致）
MODBUS_SLAVE_IDS=$slave_ids
MODBUS_TIMEOUT_MS=1000

# ---------------------------------------------------------------------------
# 時區：影響 sampled_at 時間標記
# ---------------------------------------------------------------------------
TIMEZONE=Asia/Taipei

# ---------------------------------------------------------------------------
# 僅本機檢測：1 時不連 MQTT，仍寫 SQLite + Influx；改回 0 重啟後可補送佇列
# ---------------------------------------------------------------------------
MONITOR_ONLY=$monitor_only

# ---------------------------------------------------------------------------
# Float 讀值異常時可改 MODBUS_FLOAT_SWAP_WORDS=1 試交換 word 順序
# ---------------------------------------------------------------------------
MODBUS_FLOAT_SWAP_WORDS=0

# 設備身分對照（JSON；key 為 slave_id）；請先編輯再 install
DEVICE_IDENTITIES_FILE=config/device-identities.json
# 輪詢間隔（毫秒）；第一次讀取也在間隔後才執行
POLL_INTERVAL_MS=$poll_ms

# ---------------------------------------------------------------------------
# MQTT 永續佇列（SQLite）；斷網累積、恢復後補送
# ---------------------------------------------------------------------------
SQLITE_OUTBOX_PATH=data/dpm.db
OUTBOX_FLUSH_BATCH=200

# ---------------------------------------------------------------------------
# InfluxDB 2（必填）：本地 7 天緩存；僅監聽 127.0.0.1:8086
# Token 由 install.sh 建立；管理資訊備份見 /root/dpm-collector-influx-admin.txt
# ---------------------------------------------------------------------------
INFLUX_URL=http://127.0.0.1:8086
INFLUX_TOKEN=$influx_token
INFLUX_ORG=$influx_org
INFLUX_BUCKET=$influx_bucket
INFLUX_MEASUREMENT=dpm
INFLUX_WRITE_TIMEOUT_MS=20000
INFLUX_SOURCE_TAG=dpm

# ---------------------------------------------------------------------------
# MQTT（MONITOR_ONLY=0 時必填）
# 每筆為 UTF-8 JSON：component_type, guid, parameters, sampled_at
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
}

# 互動建立 .env：GATEWAY_ID → Modbus → MQTT → InfluxDB。
# log_section 標題僅影響終端顯示，不寫入 .env。
write_env_file() {
  local env_file="$1"
  log_section "設定檔"
  log "建立 $env_file …"

  local gateway_id serial_port slave_ids
  local influx_org influx_bucket influx_token setup_result
  local mqtt_url="$DEFAULT_MQTT_URL"
  local mqtt_user="$DEFAULT_MQTT_USERNAME"
  local mqtt_pass="$DEFAULT_MQTT_PASSWORD"
  local poll_ms="$DEFAULT_POLL_INTERVAL_MS"
  local monitor_only="$DEFAULT_MONITOR_ONLY"

  gateway_id="$(prompt "請輸入 GATEWAY_ID（後台 Gateway 主檔的識別碼）")"
  [[ -n "$gateway_id" ]] || die "GATEWAY_ID 不可為空"

  log_section "Modbus"
  serial_port="$(prompt_serial_port)"
  slave_ids="$(prompt "Modbus Slave IDs（逗號分隔，須與 config/device-identities.json 一致）" "1,2")"
  slave_ids="${slave_ids//[\[\]]/}"

  log_section "MQTT"
  log_mqtt_defaults "$mqtt_url" "$mqtt_user" "$monitor_only" "$poll_ms"
  mqtt_pass="$(prompt_secret "請輸入 MQTT_PASSWORD（Broker 密碼；直接 Enter 表示空密碼）")"
  if [[ -z "$mqtt_pass" && -z "${DEFAULT_MQTT_PASSWORD:-}" ]]; then
    log "⚠️  MQTT_PASSWORD 為空；若 Broker 回 Not authorized，請編輯 .env 補上密碼後重啟服務"
  fi

  log_section "InfluxDB"
  setup_result="$(ensure_influxdb_for_install)"
  IFS='|' read -r influx_org influx_bucket influx_token <<< "$setup_result"
  influx_org="$(trim_value "$influx_org")"
  influx_bucket="$(trim_value "$influx_bucket")"
  influx_token="$(trim_value "$influx_token")"
  [[ -n "$influx_org" && -n "$influx_bucket" && -n "$influx_token" ]] \
    || die "InfluxDB 設定不完整（org/bucket/token）"

  write_env_file_content "$env_file" \
    "$serial_port" "$slave_ids" "$monitor_only" "$poll_ms" \
    "$influx_org" "$influx_bucket" "$influx_token" \
    "$mqtt_url" "$mqtt_user" "$mqtt_pass" "$gateway_id"
  chmod 600 "$env_file"
  log "✅ 已建立 $env_file（含 MQTT、Modbus、InfluxDB 設定）"
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
  [[ -n "${INFLUX_URL:-}" && -n "${INFLUX_TOKEN:-}" && -n "${INFLUX_ORG:-}" && -n "${INFLUX_BUCKET:-}" ]] || return 1
  [[ -n "${MODBUS_SLAVE_IDS:-}" ]] || return 1
  [[ -n "${SERIAL_PORT:-}" ]] || return 1
  return 0
}

repair_env_influx() {
  local env_file="$1"
  local setup_result influx_org influx_bucket influx_token
  log_section "InfluxDB"
  log "補齊 $env_file 的 InfluxDB 設定 …"
  setup_result="$(ensure_influxdb_for_install)"
  IFS='|' read -r influx_org influx_bucket influx_token <<< "$setup_result"
  influx_org="$(trim_value "$influx_org")"
  influx_bucket="$(trim_value "$influx_bucket")"
  influx_token="$(trim_value "$influx_token")"
  [[ -n "$influx_org" && -n "$influx_bucket" && -n "$influx_token" ]] \
    || die "InfluxDB 設定不完整（org/bucket/token）"

  for key in INFLUX_URL INFLUX_TOKEN INFLUX_ORG INFLUX_BUCKET INFLUX_MEASUREMENT \
    INFLUX_WRITE_TIMEOUT_MS INFLUX_SOURCE_TAG; do
    sed -i "/^${key}=/d" "$env_file"
  done

  cat >> "$env_file" <<EOF

# ---------------------------------------------------------------------------
# InfluxDB 2（必填）：以下由 install.sh 補齊（$(date -Iseconds)）
# ---------------------------------------------------------------------------
INFLUX_URL=http://127.0.0.1:8086
INFLUX_TOKEN=$influx_token
INFLUX_ORG=$influx_org
INFLUX_BUCKET=$influx_bucket
INFLUX_MEASUREMENT=dpm
INFLUX_WRITE_TIMEOUT_MS=20000
INFLUX_SOURCE_TAG=dpm
EOF
  chmod 600 "$env_file"
  log "✅ 已更新 $env_file 的 InfluxDB 設定"
}

# 已有 .env 時：完整則保留；缺 Influx 則補齊；否則整份重建。
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

  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
  if [[ -n "${GATEWAY_ID:-}" && -n "${MODBUS_SLAVE_IDS:-}" && -n "${SERIAL_PORT:-}" ]] \
    && [[ -z "${INFLUX_TOKEN:-}" || -z "${INFLUX_ORG:-}" || -z "${INFLUX_BUCKET:-}" ]]; then
    log "⚠️  既有 .env 缺少 InfluxDB 設定，自動補齊 …"
    repair_env_influx "$env_file"
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
  if [[ -f "$SOURCE_DIR/config/device-identities.json.example" ]]; then
    safe_cp "$SOURCE_DIR/config/device-identities.json.example" "$dest/config/device-identities.json.example"
    if [[ ! -f "$dest/config/device-identities.json" ]]; then
      safe_cp "$SOURCE_DIR/config/device-identities.json.example" "$dest/config/device-identities.json"
      log "已從範本建立 config/device-identities.json（請依現場修改）"
    fi
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

# npm ci 在 lib/ 執行，完成後將 node_modules 移至安裝根目錄（與 index.js 並列）。
# USB / 離線包若已含 node_modules 則直接複製，跳過 npm。
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
  log "執行 npm ci --omit=dev（lib/）…"
  (cd "$dest/lib" && npm ci --omit=dev)
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

# 啟動服務前以 Node 腳本驗證：slave id 與 device-identities 一致、Influx 四項齊全。
validate_runtime_config() {
  local dest="$1"
  [[ -f "$dest/index.js" ]] || die "找不到 $dest/index.js"
  [[ -f "$dest/.env" ]] || die "找不到 $dest/.env"
  [[ -f "$dest/config/device-identities.json" ]] || \
    die "找不到 $dest/config/device-identities.json（請依現場 SLAVE_ID 填寫 guid / component_type）"

  if [[ ! -e "${SERIAL_PORT:-/dev/ttyUSB0}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$dest/.env"
    set +a
  fi
  if [[ ! -e "${SERIAL_PORT:-/dev/ttyUSB0}" ]]; then
    log "⚠️  序列埠 ${SERIAL_PORT:-/dev/ttyUSB0} 尚不存在（未接 RS-485 時服務可能無法啟動）"
  fi

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
  return !row || !row.guid || !row.component_type || !row.device_id;
});
if (missing.length) {
  console.error(
    '❌ MODBUS_SLAVE_IDS 與 device-identities.json 不一致，缺少 SLAVE_ID:',
    missing.join(',')
  );
  console.error('   請編輯 config/device-identities.json，或改 .env 的 MODBUS_SLAVE_IDS');
  process.exit(1);
}
const influxKeys = ['INFLUX_URL', 'INFLUX_TOKEN', 'INFLUX_ORG', 'INFLUX_BUCKET'];
const missingInflux = influxKeys.filter((k) => !String(process.env[k] || '').trim());
if (missingInflux.length) {
  console.error('❌ .env 缺少 InfluxDB 設定:', missingInflux.join(', '));
  console.error('   請重新執行 install.sh，或手動填入 INFLUX_TOKEN');
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
}

# --- 主流程 ---
main() {
  require_root
  log_section "環境"
  detect_system
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  if is_update_mode; then
    log_section "更新"
    log "偵測到既有安裝，進入更新模式 …"
    log_section "程式檔案"
    sync_app_files "$INSTALL_DIR"
    link_git_from_source "$INSTALL_DIR"
    log_section "Node.js"
    install_dependencies "$INSTALL_DIR"
    verify_influxdb_ready
    validate_runtime_config "$INSTALL_DIR"
    fix_permissions
    log_section "服務"
    start_service
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
  verify_influxdb_ready
  validate_runtime_config "$INSTALL_DIR"
  fix_permissions
  log_section "服務"
  start_service
  finish_install_success install
}

main "$@"
