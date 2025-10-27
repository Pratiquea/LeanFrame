#!/usr/bin/env bash
set -euo pipefail

# --------- configurable ----------
BACKEND_BASE="${BACKEND_BASE:-https://api.leanframe.example}"  # your backend base URL
PAIR_FILE="/etc/leanframe.pair"                                 # stores the pairing code (root-readable)
ENV_FILE="/etc/leanframe.env"                                   # holds RCLONE_REMOTE + DRIVE_PATH vars
RCLONE_CONF="${HOME}/.config/rclone/rclone.conf"
REMOTE_NAME="${RCLONE_REMOTE:-gdrive}"                          # from env or default "gdrive"
DISPLAY_URL_BASE="${DISPLAY_URL_BASE:-https://pair.leanframe.example}"  # web page for entering code
POLL_SECONDS="${POLL_SECONDS:-2}"
POLL_MAX_TRIES="${POLL_MAX_TRIES:-450}"   # ~15 minutes
# ----------------------------------

mkdir -p "$(dirname "$RCLONE_CONF")"

# Load env if present (defines RCLONE_REMOTE and maybe DRIVE_PATH)
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

# Helper: random pairing code like ABCD-1234
gen_code() {
  tr -dc 'A-Z0-9' </dev/urandom | head -c4 && printf -- "-"; tr -dc 'A-Z0-9' </dev/urandom | head -c4
}

# 1) Create or read pairing code
if [ -f "$PAIR_FILE" ]; then
  CODE="$(cat "$PAIR_FILE")"
else
  CODE="$(gen_code)"
  echo "$CODE" | sudo tee "$PAIR_FILE" >/dev/null
  sudo chmod 600 "$PAIR_FILE"
fi

# 2) Register with backend (idempotent)
DEVICE_ID="$(cat /etc/machine-id 2>/dev/null || hostname)"
curl -fsS -X POST "$BACKEND_BASE/v1/pair/init" \
  -H "Content-Type: application/json" \
  -d "{\"code\":\"$CODE\",\"device_id\":\"$DEVICE_ID\"}" >/dev/null || true

# 3) Show instructions (console log). Optional: QR if qrencode is installed.
PAIR_URL="${DISPLAY_URL_BASE}/?code=${CODE}"
echo "============================================"
echo " LeanFrame pairing needed"
echo " 1) On your phone: ${PAIR_URL}"
echo " 2) Enter code:    ${CODE}"
echo " 3) Sign into Google, pick the photo folder."
echo "============================================"
if command -v qrencode >/dev/null 2>&1; then
  echo "(Optional) QR below:"
  qrencode -t ANSIUTF8 "$PAIR_URL" || true
fi

# 4) Poll backend until ready
echo "Waiting for authorization + folder selection..."
TRIES=0
while [ $TRIES -lt "$POLL_MAX_TRIES" ]; do
  RESP="$(curl -fsS "$BACKEND_BASE/v1/pair/${CODE}" || true)"
  if echo "$RESP" | grep -q '"status":"ready"'; then
    TOKEN_JSON="$(echo "$RESP" | jq -c '.token')"
    FOLDER_ID="$(echo "$RESP" | jq -r '.folder_id')"
    if [ -z "$FOLDER_ID" ] || [ "$FOLDER_ID" = "null" ]; then
      echo "Backend returned no folder_id; still waiting..."
    else
      echo "Received token + folder_id=$FOLDER_ID"
      # 5) Persist DRIVE_PATH as folder ID
      if grep -q '^DRIVE_PATH=' "$ENV_FILE" 2>/dev/null; then
        sudo sed -i "s|^DRIVE_PATH=.*$|DRIVE_PATH=\"$FOLDER_ID\"|" "$ENV_FILE"
      else
        echo "DRIVE_PATH=\"$FOLDER_ID\"" | sudo tee -a "$ENV_FILE" >/dev/null
      fi
      # 6) Create/update rclone remote non-interactively (no browser)
      rclone config create "$REMOTE_NAME" drive \
        scope=drive.readonly \
        root_folder_id="$FOLDER_ID" \
        token="$TOKEN_JSON" \
        config_is_local=true >/dev/null
      chmod 600 "$RCLONE_CONF" || true

      # 7) Validate access
      if rclone lsd "${REMOTE_NAME}:${FOLDER_ID}" >/dev/null 2>&1; then
        echo "rclone configured successfully."
      else
        echo "rclone cannot access the folder. Check backend scopes and sharing."
        exit 1
      fi

      # 8) Kick the steady-state services
      #   - system timer (already installed in your setup): leanframe-sync.timer
      #   - user GUI service: leanframe.service
      sudo systemctl enable --now leanframe-sync.timer || true        # system timer
      systemctl --user daemon-reload || true
      systemctl --user enable --now leanframe.service || true         # user GUI
      echo "Onboarding complete."
      exit 0
    fi
  fi
  TRIES=$((TRIES+1))
  sleep "$POLL_SECONDS"
done

echo "Pairing timed out. Re-run the onboarding or open ${PAIR_URL} again."
exit 1
