#!/usr/bin/env bash
# =============================================================================
# dpm-remote-update.sh — 閘道端 MQTT 遠端維運入口（僅白名單子命令）
#
# 【角色】跑在現場 BL118，開發倉此檔為原始碼；
#         install.sh 會複製到 /opt/dpm-collector/dpm-remote-update.sh，
#         並安裝為 /usr/local/sbin/dpm-remote-update + sudoers。
#
# 【誰呼叫】採集程式（User=dpm）收到 MQTT gw/cmd/{gatewayId} 後執行：
#           sudo -n /usr/local/sbin/dpm-remote-update <command>
#
# 【子命令】
#   update         — 等同 dpm-ctl.sh update（git pull + install.sh，保留 .env）
#   restart        — systemctl restart dpm-collector
#   set_env        — 自 data/remote-pending-content 寫入 .env 後 restart
#   set_identities — 自 data/remote-pending-content 寫入 device-identities.json 後 restart
#   get_logs       — journalctl 尾端輸出至 stdout（行數讀 data/remote-log-lines）
#
# 【安全】
#   - 必須 root（經限縮 sudoers，禁止任意 shell）
#   - 參數僅允許單一白名單子命令
#   - flock 防止連收兩則指令重入（get_logs 除外，只讀）
#
# 【對照】辦公室／後台觸發：npm run remote 或後台閘道遠端管理
# =============================================================================

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/dpm-collector}"
SERVICE_NAME="${SERVICE_NAME:-dpm-collector}"
SERVICE_USER="${SERVICE_USER:-dpm}"
LOCK_FILE="${DPM_REMOTE_LOCK:-/run/dpm-remote-update.lock}"
REQUEST_ID_FILE="${DPM_REMOTE_REQUEST_ID_FILE:-$INSTALL_DIR/data/remote-request-id}"
PENDING_CONTENT_FILE="${DPM_REMOTE_PENDING_CONTENT:-$INSTALL_DIR/data/remote-pending-content}"
LOG_LINES_FILE="${DPM_REMOTE_LOG_LINES_FILE:-$INSTALL_DIR/data/remote-log-lines}"
REQUEST_ID="${DPM_REMOTE_REQUEST_ID:-}"
MAX_CONTENT_BYTES="${DPM_REMOTE_MAX_CONTENT_BYTES:-262144}"
DEFAULT_LOG_LINES=200
MAX_LOG_LINES=500

die() { echo "❌ dpm-remote-update: $*" >&2; exit 1; }

usage() {
  cat <<EOF
用法: $(basename "$0") <update|restart|set_env|set_identities|get_logs>
  request_id：優先讀 $INSTALL_DIR/data/remote-request-id，其次環境變數 DPM_REMOTE_REQUEST_ID。
  set_*：內容來自 $INSTALL_DIR/data/remote-pending-content
  get_logs：行數來自 $INSTALL_DIR/data/remote-log-lines（預設 ${DEFAULT_LOG_LINES}）
EOF
}

load_request_id() {
  if [[ -z "$REQUEST_ID" && -f "$REQUEST_ID_FILE" ]]; then
    REQUEST_ID="$(tr -d '\r\n' <"$REQUEST_ID_FILE" | head -c 128 || true)"
  fi
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "請以 root 執行（經 sudoers）"
}

# ---------------------------------------------------------------------------
# 盡力把執行階段回報到 gw/status/{gatewayId}
# ---------------------------------------------------------------------------
publish_status() {
  local phase="$1"
  local detail="$2"
  local env_file="$INSTALL_DIR/.env"
  [[ -f "$env_file" ]] || return 0
  command -v mosquitto_pub >/dev/null 2>&1 || return 0

  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a

  local gid="${GATEWAY_ID:-}"
  [[ -n "$gid" ]] || return 0
  local url="${MQTT_URL:-}"
  [[ -n "$url" ]] || return 0

  local host port
  host="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z0-9+.-]+://([^:/]+).*#\1#')"
  port="$(printf '%s' "$url" | sed -nE 's#^[a-zA-Z0-9+.-]+://[^:/]+:([0-9]+).*#\1#p')"
  [[ -n "$port" ]] || port=1883
  [[ -n "$host" ]] || return 0

  local topic_tpl="${MQTT_STATUS_TOPIC:-gw/status/{gatewayId}}"
  local topic="${topic_tpl//\{gatewayId\}/$gid}"
  topic="${topic//\{channelId\}/$gid}"

  local version=""
  [[ -f "$INSTALL_DIR/VERSION" ]] && version="$(head -n1 "$INSTALL_DIR/VERSION" | tr -d '\r')"

  local cmd_name="${REMOTE_COMMAND:-update}"
  local rid="${REQUEST_ID:-}"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"

  local payload
  payload="$(
    node -e '
const [phase, detail, gid, cmd, rid, ver, now] = process.argv.slice(1);
const obj = {
  message_kind: "status",
  phase,
  detail,
  gateway_id: gid,
  command: cmd,
  published_at: now,
};
if (rid) obj.request_id = rid;
if (ver) obj.version = ver;
process.stdout.write(JSON.stringify(obj));
' "$phase" "$detail" "$gid" "$cmd_name" "$rid" "$version" "$now" 2>/dev/null || true
  )"
  [[ -n "$payload" ]] || return 0

  local -a args=(-h "$host" -p "$port" -t "$topic" -q 1 -m "$payload")
  [[ -n "${MQTT_USERNAME:-}" ]] && args+=(-u "$MQTT_USERNAME")
  [[ -n "${MQTT_PASSWORD:-}" ]] && args+=(-P "$MQTT_PASSWORD")
  mosquitto_pub "${args[@]}" >/dev/null 2>&1 || true
}

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "已有遠端更新在執行（$LOCK_FILE）"
  else
    if [[ -e "$LOCK_FILE" ]]; then
      die "已有遠端更新在執行（$LOCK_FILE）"
    fi
    echo "$$" >"$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
  fi
}

read_pending_content() {
  [[ -f "$PENDING_CONTENT_FILE" ]] || die "找不到 pending content（$PENDING_CONTENT_FILE）"
  local size
  size="$(wc -c <"$PENDING_CONTENT_FILE" | tr -d ' ')"
  [[ "$size" -gt 0 ]] || die "pending content 為空"
  [[ "$size" -le "$MAX_CONTENT_BYTES" ]] || die "pending content 超過 ${MAX_CONTENT_BYTES} bytes"
  cat "$PENDING_CONTENT_FILE"
}

cmd_update() {
  local ctl="$INSTALL_DIR/dpm-ctl.sh"
  [[ -x "$ctl" || -f "$ctl" ]] || die "找不到 $ctl"
  publish_status "started" "git pull + install.sh"
  if ! DPM_NONINTERACTIVE=1 bash "$ctl" update; then
    publish_status "error" "dpm-ctl update failed"
    die "dpm-ctl update 失敗"
  fi
  publish_status "ok" "update finished"
}

cmd_restart() {
  publish_status "started" "systemctl restart"
  systemctl restart "$SERVICE_NAME"
  publish_status "ok" "restart issued"
}

cmd_set_env() {
  publish_status "started" "write .env + restart"
  local content
  content="$(read_pending_content)"
  if ! printf '%s\n' "$content" | grep -Eq '^GATEWAY_ID='; then
    publish_status "error" "invalid .env: GATEWAY_ID required"
    die "invalid .env: GATEWAY_ID required"
  fi
  local tmp
  tmp="$(mktemp "$INSTALL_DIR/.env.remote.XXXXXX")"
  printf '%s' "$content" >"$tmp"
  # 若結尾無換行補上，避免 EnvironmentFile 解析異常
  if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]]; then
    printf '\n' >>"$tmp"
  fi
  mv -f "$tmp" "$INSTALL_DIR/.env"
  chmod 640 "$INSTALL_DIR/.env"
  chown "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR/.env" 2>/dev/null || \
    chown "root:${SERVICE_USER}" "$INSTALL_DIR/.env" 2>/dev/null || true
  rm -f "$PENDING_CONTENT_FILE"
  systemctl restart "$SERVICE_NAME"
  publish_status "ok" "set_env + restart issued"
}

cmd_set_identities() {
  publish_status "started" "write device-identities.json + restart"
  local content
  content="$(read_pending_content)"
  if ! printf '%s' "$content" | node -e '
const fs = require("fs");
const raw = fs.readFileSync(0, "utf8");
let parsed;
try { parsed = JSON.parse(raw); } catch (e) { process.exit(2); }
if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) process.exit(3);
'; then
    publish_status "error" "invalid device-identities.json"
    die "invalid device-identities.json"
  fi
  mkdir -p "$INSTALL_DIR/config"
  local tmp
  tmp="$(mktemp "$INSTALL_DIR/config/device-identities.remote.XXXXXX")"
  printf '%s' "$content" >"$tmp"
  if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]]; then
    printf '\n' >>"$tmp"
  fi
  mv -f "$tmp" "$INSTALL_DIR/config/device-identities.json"
  chmod 640 "$INSTALL_DIR/config/device-identities.json"
  chown "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR/config/device-identities.json" 2>/dev/null || \
    chown "root:${SERVICE_USER}" "$INSTALL_DIR/config/device-identities.json" 2>/dev/null || true
  rm -f "$PENDING_CONTENT_FILE"
  systemctl restart "$SERVICE_NAME"
  publish_status "ok" "set_identities + restart issued"
}

cmd_get_logs() {
  local lines="$DEFAULT_LOG_LINES"
  if [[ -f "$LOG_LINES_FILE" ]]; then
    lines="$(tr -d '\r\n' <"$LOG_LINES_FILE" | head -c 8 || true)"
  fi
  if ! [[ "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -lt 1 ]]; then
    lines="$DEFAULT_LOG_LINES"
  fi
  if [[ "$lines" -gt "$MAX_LOG_LINES" ]]; then
    lines="$MAX_LOG_LINES"
  fi
  journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager 2>/dev/null || \
    die "journalctl 失敗（服務 $SERVICE_NAME）"
}

main() {
  require_root
  local cmd="${1:-}"
  if [[ $# -gt 1 ]]; then
    die "多餘參數（僅允許單一子命令）"
  fi

  load_request_id
  export REMOTE_COMMAND="$cmd"
  export DPM_REMOTE_REQUEST_ID="$REQUEST_ID"

  case "$cmd" in
    update)
      acquire_lock
      cmd_update
      ;;
    restart)
      acquire_lock
      cmd_restart
      ;;
    set_env)
      acquire_lock
      cmd_set_env
      ;;
    set_identities)
      acquire_lock
      cmd_set_identities
      ;;
    get_logs)
      cmd_get_logs
      ;;
    ""|-h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知指令：$cmd（僅允許 update｜restart｜set_env｜set_identities｜get_logs）"
      ;;
  esac
}

main "$@"
