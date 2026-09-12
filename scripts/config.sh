#!/usr/bin/env bash
set -eo pipefail

CONFIG_DIR="$HOME/.config/harmony"
CONFIG_FILE="$CONFIG_DIR/config.json"

mkdir -p "$CONFIG_DIR"

DEFAULT_HOST="chenbolun@10.221.68.124"
DEFAULT_REMOTE_DIR="~/Dev/harmony"
DEFAULT_PROJECT_PATH=""

action="${1:-get}"

case "$action" in
  get)
    if [ ! -f "$CONFIG_FILE" ]; then
      cat << EOF > "$CONFIG_FILE"
{
  "macHost": "$DEFAULT_HOST",
  "remoteDir": "$DEFAULT_REMOTE_DIR",
  "projectPath": "$DEFAULT_PROJECT_PATH",
  "autoInstall": true,
  "autoLaunch": true
}
EOF
    fi
    cat "$CONFIG_FILE"
    ;;
  set)
    payload="$2"
    if [ -z "$payload" ]; then
      echo "Error: missing json payload" >&2
      exit 1
    fi
    if [ -f "$CONFIG_FILE" ]; then
      merged=$(jq -s '.[0] * .[1]' "$CONFIG_FILE" <(echo "$payload") 2>/dev/null || echo "$payload")
    else
      merged="$payload"
    fi
    echo "$merged" | jq '.' > "$CONFIG_FILE"
    cat "$CONFIG_FILE"
    ;;
  *)
    echo "Usage: $0 {get|set '<json>'}" >&2
    exit 1
    ;;
esac
