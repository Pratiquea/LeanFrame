#!/usr/bin/env bash
set -euo pipefail

BACKEND_BASE="${BACKEND_BASE:-http://rpi.local:8000}"      # pairing backend on the Pi
DISPLAY_URL_BASE="${DISPLAY_URL_BASE:-http://rpi.local:8000}"
ENV_FILE="/etc/leanframe.env"
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
REMOTE_NAME="${RCLONE_REMOTE:-gdrive}"
POLL_SECONDS="${POLL_SECONDS:-2}"
POLL_MAX_TRIES="${POLL_MAX_TRIES:-450}"                     # ~15 min

mkdir -p "$(dirname "$RCLONE_CONF")"

# Load env if present (defines RCLONE_REMOTE / DRIVE_PATH optionally)
if [ -f "$ENV_FILE" ]; then . "$ENV_FILE"; fi

PAIR_URL="${DISPLAY_URL_BASE}/pair"

echo "============================================"
echo " LeanFrame setup"
echo " 1) On your phone: ${PAIR_URL}"
echo " 2) Follow Google steps at google.com/device"
echo " 3) Paste your Drive folder link/ID, then return here."
echo "============================================"

echo "Waiting for authorization + folder selection..."
TRIES=0
while [ $TRIES -lt "$POLL_MAX_TRIES" ]; do
  RESP="$(curl -fsS "$BACKEND_BASE/v1/pair" 2>/dev/null || true)"
  STATUS="$(echo "$RESP" | jq -r '.status // empty')"
  if [ "$STATUS" = "ready" ]; then
    TOKEN_JSON="$(echo "$RESP" | jq -c '.token')"
    FOLDER_ID="$(echo "$RESP" | jq -r '.folder_id')"
    if [ -n "$FOLDER_ID" ] && [ "$FOLDER_ID" != "null" ]; then
      echo "Received folder_id=$FOLDER_ID"

      # Persist DRIVE_PATH
      if grep -q '^DRIVE_PATH=' "$ENV_FILE" 2>/dev/null; then
        sudo sed -i "s|^DRIVE_PATH=.*$|DRIVE_PATH=\"$FOLDER_ID\"|" "$ENV_FILE" || true
      else
        echo "DRIVE_PATH=\"$FOLDER_ID\"" | sudo tee -a "$ENV_FILE" >/dev/null
      fi

      # Configure rclone (user-local; no browser)
      rclone config create "$REMOTE_NAME" drive \
        scope=drive.readonly \
        root_folder_id="$FOLDER_ID" \
        token="$TOKEN_JSON" \
        config_is_local=true >/dev/null
      chmod 600 "$RCLONE_CONF" || true

      # Validate
      if rclone lsd "${REMOTE_NAME}:${FOLDER_ID}" >/dev/null 2>&1; then
        echo "rclone configured successfully."
      else
        echo "ERROR: rclone cannot access the folder. Check scopes/sharing."
        exit 1
      fi

      # Kick steady-state services
      sudo systemctl enable --now leanframe-sync.timer || true
      systemctl --user daemon-reload || true
      systemctl --user enable --now leanframe.service || true
      echo "Onboarding complete."
      exit 0
    fi
  fi
  TRIES=$((TRIES+1))
  sleep "$POLL_SECONDS"
done

echo "Setup timed out. Open ${PAIR_URL} again to finish."
exit 1
