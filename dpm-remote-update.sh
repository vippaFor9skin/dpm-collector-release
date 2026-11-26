#!/usr/bin/env bash
# =============================================================================
# dpm-remote-update.sh — 閘道端 MQTT 遠端維運入口（僅白名單子命令）
#
# 【角色】跑在現場 BL118，開發倉此檔為原始碼；
#         install.sh 會複製到 /opt/dpm-collector/dpm-remote-update.sh，
#         並安裝為 /usr/local/sbin/dpm-remote-update + sudoers。
#
# 【誰呼叫】採集程式（User=dpm）收到 MQTT gw/cmd/{gatewayId} 後執行：
#           sudo -n /usr/local/sbin/dpm-remote-update <update|restart>
#           （與 Node 行程分離，避免「更新自己殺到一半」）
#
# 【子命令】
#   update   — 等同 dpm-ctl.sh update（git pull + install.sh，保留 .env）
#   restart  — systemctl restart dpm-collector
#
# 【安全】
#   - 必須 root（經限縮 sudoers，禁止任意 shell）
#   - 參數僅允許單一子命令 update｜restart
#   - flock 防止連收兩則指令重入
#
# 【對照】辦公室觸發：npm run remote → scripts/remote/mqtt-remote.sh（只發 MQTT）
# =============================================================================

set -euo pipefail

# 正式安裝目錄與 systemd 服務名（可被環境變數覆寫，一般不必改）
INSTALL_DIR="${INSTALL_DIR:-/opt/dpm-collector}"
SERVICE_NAME="${SERVICE_NAME:-dpm-collector}"
# 互斥鎖：同一時間只允許一筆遠端更新
LOCK_FILE="${DPM_REMOTE_LOCK:-/run/dpm-remote-update.lock}"
# request_id：Node 寫入此檔後再 sudo（sudo 預設會清掉環境變數）
REQUEST_ID_FILE="${DPM_REMOTE_REQUEST_ID_FILE:-$INSTALL_DIR/data/remote-request-id}"
REQUEST_ID="${DPM_REMOTE_REQUEST_ID:-}"

die() { echo "❌ dpm-remote-update: $*" >&2; exit 1; }

usage() {
  cat <<EOF
用法: $(basename "$0") <update|restart>
  request_id：優先讀 $INSTALL_DIR/data/remote-request-id，其次環境變數 DPM_REMOTE_REQUEST_ID。
EOF
}

# 讀取辦公室下發的 request_id，供 status 回報對齊
load_request_id() {
  if [[ -z "$REQUEST_ID" && -f "$REQUEST_ID_FILE" ]]; then
    # 去掉換行、長度上限，避免異常內容
    REQUEST_ID="$(tr -d '\r\n' <"$REQUEST_ID_FILE" | head -c 128 || true)"
  fi
}

# 本腳本會動 git／systemd／install.sh，必須以 root 執行
require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "請以 root 執行（經 sudoers）"
}

# ---------------------------------------------------------------------------
# 盡力把執行階段回報到 gw/status/{gatewayId}
# - 讀安裝目錄 .env 的 MQTT 帳密與 GATEWAY_ID
# - 閘道若無 mosquitto_pub，或發送失敗：只略過，不中斷更新本體
# - phase：started｜ok｜error
# ---------------------------------------------------------------------------
publish_status() {
  local phase="$1"
  local detail="$2"
  local env_file="$INSTALL_DIR/.env"
  [[ -f "$env_file" ]] || return 0
  command -v mosquitto_pub >/dev/null 2>&1 || return 0

  # 匯入 .env 變數到目前 shell（供下方 MQTT_*／GATEWAY_ID 使用）
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a

  local gid="${GATEWAY_ID:-}"
  [[ -n "$gid" ]] || return 0
  local url="${MQTT_URL:-}"
  [[ -n "$url" ]] || return 0

  # 從 MQTT_URL 拆 host／port
  local host port
  host="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z0-9+.-]+://([^:/]+).*#\1#')"
  port="$(printf '%s' "$url" | sed -nE 's#^[a-zA-Z0-9+.-]+://[^:/]+:([0-9]+).*#\1#p')"
  [[ -n "$port" ]] || port=1883
  [[ -n "$host" ]] || return 0

  # status topic（預設 gw/status/{gatewayId}；相容舊 {channelId}）
  local topic_tpl="${MQTT_STATUS_TOPIC:-gw/status/{gatewayId}}"
  local topic="${topic_tpl//\{gatewayId\}/$gid}"
  topic="${topic//\{channelId\}/$gid}"

  # 附上目前 VERSION 第一行（若存在），方便辦公室確認版號
  local version=""
  [[ -f "$INSTALL_DIR/VERSION" ]] && version="$(head -n1 "$INSTALL_DIR/VERSION" | tr -d '\r')"

  local cmd_name="${REMOTE_COMMAND:-update}"
  local rid="${REQUEST_ID:-}"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"

  # 用 Node 組 JSON，失敗則整段略過回報
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
  # 發送失敗不影響 update／restart 本體
  mosquitto_pub "${args[@]}" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 互斥鎖：避免辦公室連發兩則 update 造成重入
# 優先 flock；無 flock 時退回簡易鎖檔
# ---------------------------------------------------------------------------
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    # -n：拿不到鎖立刻失敗（不要排隊）
    flock -n 9 || die "已有遠端更新在執行（$LOCK_FILE）"
  else
    if [[ -e "$LOCK_FILE" ]]; then
      die "已有遠端更新在執行（$LOCK_FILE）"
    fi
    echo "$$" >"$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
  fi
}

# ---------------------------------------------------------------------------
# update：與現場手動 sudo ./dpm-ctl.sh update 相同路徑
# DPM_NONINTERACTIVE=1 → install.sh 不倒數、不 follow 日誌（遠端才不會卡住）
# ---------------------------------------------------------------------------
cmd_update() {
  local ctl="$INSTALL_DIR/dpm-ctl.sh"
  [[ -x "$ctl" || -f "$ctl" ]] || die "找不到 $ctl"
  publish_status "started" "git pull + install.sh"
  if ! DPM_NONINTERACTIVE=1 bash "$ctl" update; then
    publish_status "error" "dpm-ctl update failed"
    die "dpm-ctl update 失敗"
  fi
  # install.sh 更新模式結束時服務通常已重啟；此 root 行程仍在，盡力回報 ok
  publish_status "ok" "update finished"
}

# ---------------------------------------------------------------------------
# restart：只重啟採集服務，不拉程式、不跑 install.sh
# ---------------------------------------------------------------------------
cmd_restart() {
  publish_status "started" "systemctl restart"
  systemctl restart "$SERVICE_NAME"
  publish_status "ok" "restart issued"
}

# ---------------------------------------------------------------------------
# 入口：僅接受一個參數（白名單子命令）
# ---------------------------------------------------------------------------
main() {
  require_root
  local cmd="${1:-}"
  if [[ $# -gt 1 ]]; then
    die "多餘參數（僅允許單一子命令 update｜restart）"
  fi

  load_request_id
  # 供 publish_status 組 payload 時帶上 command／request_id
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
    ""|-h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知指令：$cmd（僅允許 update｜restart）"
      ;;
  esac
}

main "$@"
