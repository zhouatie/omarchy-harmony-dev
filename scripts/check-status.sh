#!/usr/bin/env bash
# ==============================================================================
# HarmonyOS Dev Plugin - Environment & Status Checker
# ==============================================================================

set -o pipefail

CONFIG_FILE="$HOME/.config/harmony/config.json"
MAC_HOST=""
PROJECT_PATH=""
DEVICE_IP=""

if [ -f "$CONFIG_FILE" ]; then
  MAC_HOST=$(jq -r '.macHost // empty' "$CONFIG_FILE" 2>/dev/null || true)
  PROJECT_PATH=$(jq -r '.projectPath // empty' "$CONFIG_FILE" 2>/dev/null || true)
  DEVICE_IP=$(jq -r '.deviceIp // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      MAC_HOST="$2"
      shift 2
      ;;
    --path)
      PROJECT_PATH="$2"
      shift 2
      ;;
    --device-ip)
      DEVICE_IP="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

MAC_HOST="${MAC_HOST:-chenbolun@10.221.68.124}"

# 1. Check SSH to Mac
SSH_OK=false
if ssh -o BatchMode=yes -o ConnectTimeout=2 "$MAC_HOST" "echo ok" >/dev/null 2>&1; then
  SSH_OK=true
fi

# 2. Check HDC Device
export PATH="$HOME/.local/harmonyos/command-line-tools/bin:$PATH"
DEVICE_NAME=""
DEVICE_ONLINE=false
IS_WIRELESS=false

if command -v hdc >/dev/null 2>&1; then
  hdc start >/dev/null 2>&1 </dev/null || true
  HDC_OUT=$(timeout 3 hdc list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Client\]' | grep -v '^$' || true)
  
  # 若未检测到在线设备且配置了设备无线 IP，尝试静默自动连接
  if { [ -z "$HDC_OUT" ] || echo "$HDC_OUT" | grep -qi "Empty"; } && [ -n "$DEVICE_IP" ]; then
    TARGET_IP="$DEVICE_IP"
    [[ "$TARGET_IP" != *:* ]] && TARGET_IP="${TARGET_IP}:5555"
    timeout 2 hdc tconn "$TARGET_IP" >/dev/null 2>&1 || true
    HDC_OUT=$(timeout 3 hdc list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Client\]' | grep -v '^$' || true)
  fi

  if [ -n "$HDC_OUT" ] && ! echo "$HDC_OUT" | grep -qi "Empty"; then
    DEV_ID=$(echo "$HDC_OUT" | head -n 1 | awk '{print $1}' | tr -d '\r\n')
    if [ -n "$DEV_ID" ]; then
      [[ "$DEV_ID" == *:* ]] && IS_WIRELESS=true
      MODEL=$(timeout 2 hdc -t "$DEV_ID" shell param get const.product.model 2>/dev/null | tr -d '\r\n ' || true)
      if [ -n "$MODEL" ] && ! echo "$MODEL" | grep -qi -E "fail|error"; then
        DEVICE_NAME="$DEV_ID ($MODEL)"
      else
        DEVICE_NAME="$DEV_ID"
      fi
      DEVICE_ONLINE=true
    fi
  fi
fi

# 3. Detect Project
find_project() {
  local dir="$1"
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -f "$dir/build-profile.json5" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

DETECTED_PROJECT=""
if [ -n "$PROJECT_PATH" ] && [ -f "$PROJECT_PATH/build-profile.json5" ]; then
  DETECTED_PROJECT="$PROJECT_PATH"
else
  # Try active terminal directory if available
  if command -v omarchy-cmd-terminal-cwd >/dev/null 2>&1; then
    TERM_CWD=$(omarchy-cmd-terminal-cwd 2>/dev/null || true)
    if [ -n "$TERM_CWD" ]; then
      DETECTED_PROJECT=$(find_project "$TERM_CWD" || true)
    fi
  fi
  # If still not found, check common locations
  if [ -z "$DETECTED_PROJECT" ]; then
    for candidate in "$HOME/Work/harmony/"* "$HOME/Dev/harmony/"*; do
      if [ -d "$candidate" ] && [ -f "$candidate/build-profile.json5" ]; then
        DETECTED_PROJECT="$candidate"
        break
      fi
    done
  fi
fi

PROJECT_OK=false
PROJECT_NAME=""
BUNDLE_NAME=""
if [ -n "$DETECTED_PROJECT" ] && [ -f "$DETECTED_PROJECT/build-profile.json5" ]; then
  PROJECT_OK=true
  PROJECT_NAME=$(basename "$DETECTED_PROJECT")
  if [ -f "$DETECTED_PROJECT/AppScope/app.json5" ]; then
    BUNDLE_NAME=$(grep -o '"bundleName"[[:space:]]*:[[:space:]]*"[^"]*"' "$DETECTED_PROJECT/AppScope/app.json5" | cut -d'"' -f4 | tr -d '\r\n' || true)
  fi
fi

# Output guaranteed valid JSON using jq
jq -n \
  --argjson ssh_ok "$SSH_OK" \
  --arg mac_host "$MAC_HOST" \
  --argjson device_online "$DEVICE_ONLINE" \
  --arg device_name "${DEVICE_NAME:-离线}" \
  --argjson is_wireless "$IS_WIRELESS" \
  --arg device_ip "${DEVICE_IP:-}" \
  --argjson project_ok "$PROJECT_OK" \
  --arg project_path "${DETECTED_PROJECT:-}" \
  --arg project_name "${PROJECT_NAME:-}" \
  --arg bundle_name "${BUNDLE_NAME:-}" \
  '{
    ssh_ok: $ssh_ok,
    mac_host: $mac_host,
    device_online: $device_online,
    device_name: $device_name,
    is_wireless: $is_wireless,
    device_ip: $device_ip,
    project_ok: $project_ok,
    project_path: $project_path,
    project_name: $project_name,
    bundle_name: $bundle_name
  }'
