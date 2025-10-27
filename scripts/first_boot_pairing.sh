#!/usr/bin/env bash
set -euo pipefail

# --------- configurable ----------
BACKEND_BASE="${BACKEND_BASE:-http://rpi.local:8000}"      # pairing backend base
DISPLAY_URL_BASE="${DISPLAY_URL_BASE:-http://rpi.local:8000}"
ENV_FILE="/etc/leanframe.env"                               # read-only (we'll sudo-append later)
PAIR_FILE="$HOME/.config/leanframe/pair"                    # USER-SPACE (no sudo)
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
REMOTE_NAME="${RCLONE_REMOTE:-gdrive}"
POLL_SECONDS="${POLL_SECONDS:-2}"
POLL_MAX_TRIES="${POLL_MAX_TRIES:-450}"                     # ~15 min
# ----------------------------------

mkdir -p "$(dirname "$RCLONE_CONF")" "$(dirname "$PAIR_FILE")"

# Load env if present (defines RCLONE_REMOTE / DRIVE_PATH optionally)
if [ -f "$ENV_FILE" ]; then . "$ENV_FILE"; fi

# Helper: random code like ABCD-1234
gen_code() {
  local a b
  a="$(tr -dc 'A-Z0-9' </dev/urandom | head -c4)"
  b="$(tr -dc 'A-Z0-9' </dev/urandom | head -c4)"
  printf '%s-%s' "$a" "$b"
}

# Create/read pairing code (USER-SPACE; no sudo)
if [ -f "$PAIR_FILE" ]; then
  CODE="$(cat "$PAIR_FILE")"
else
  CODE="$(gen_code)"
  echo "$CODE" > "$PAIR_FILE"
  chmod 600 "$PAIR_FILE"
fi

PAIR_URL="${DISPLAY_URL_BASE}/pair?code=${CODE}"

echo "============================================"
echo " LeanFrame pairing needed"
echo " 1) On your phone: ${PAIR_URL}"
echo " 2) Enter code:    ${CODE}"
echo " 3) Sign into Google, pick the photo folder."
echo "============================================"

# Optional QR (safe to skip if not installed)
if command -v qrencode >/dev/null 2>&1; then
  echo "(QR):"
  qrencode -t ANSIUTF8 "$PAIR_URL" || true
fi

# Register with backend (idempotent; never fail the script)
DEVICE_ID="$(cat /etc/machine-id 2>/dev/null || hostname)"
curl -fsS -X POST "$BACKEND_BASE/v1/pair/init" \
  -H "Content-Type: application/json" \
  -d "{\"code\":\"$CODE\",\"device_id\":\"$DEVICE_ID\"}" >/dev/null 2>&1 || true

echo "Waiting for authorization + folder selection from phone..."
TRIES=0
while [ $TRIES -lt "$POLL_MAX_TRIES" ]; do
  RESP="$(curl -fsS "$BACKEND_BASE/v1/pair/${CODE}" 2>/dev/null || true)"
  if echo "$RESP" | grep -q '"status":"ready"'; then
    TOKEN_JSON="$(echo "$RESP" | jq -c '.token')"
    FOLDER_ID="$(echo "$RESP" | jq -r '.folder_id')"
    if [ -n "${FOLDER_ID:-}" ] && [ "$FOLDER_ID" != "null" ]; then
      echo "Received folder_id=$FOLDER_ID"

      # Persist DRIVE_PATH in /etc/leanframe.env (needs sudo once; we do it *after* printing)
      if [ -w "$ENV_FILE" ]; then
        sed -i "s|^DRIVE_PATH=.*$|DRIVE_PATH=\"$FOLDER_ID\"|" "$ENV_FILE" || true
      else
        echo "Updating $ENV_FILE with DRIVE_PATH requires sudo..."
        echo "DRIVE_PATH=\"$FOLDER_ID\"" | sudo tee -a "$ENV_FILE" >/dev/null
      fi

      # Configure rclone (user-local; no sudo)
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
      sudo systemctl enable --now leanframe-sync.timer || true     # system timer
      systemctl --user daemon-reload || true
      systemctl --user enable --now leanframe.service || true      # user GUI
      echo "Onboarding complete."
      exit 0
    fi
  fi
  TRIES=$((TRIES+1))
  sleep "$POLL_SECONDS"
done

echo "Pairing timed out. Open ${PAIR_URL} again to finish."
exit 1
