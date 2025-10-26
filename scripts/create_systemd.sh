#!/usr/bin/env bash
set -euo pipefail

# ====== USER CONFIG (edit if your paths differ) ======
USER_NAME="${USER}"                      # e.g. rpi
REPO_DIR="${HOME}/gits/LeanFrame"        # your existing repo
VENV_BIN="${REPO_DIR}/.venv/bin"
PHOTO_DIR="${HOME}/DrivePhotos"          # local photo cache (for sync)
RCLONE_REMOTE="gdrive"
DRIVE_PATH=""                   # or a folder ID in quotes

# ====== Sanity checks ======
if [ ! -d "${REPO_DIR}" ]; then
  echo "Repo not found at ${REPO_DIR}"; exit 1
fi
if [ ! -x "${VENV_BIN}/python" ]; then
  echo "Existing venv not found at ${VENV_BIN}. Expected ${VENV_BIN}/python"
  echo "Create it first (python3 -m venv .venv && pip install -r requirements.txt)."
  exit 1
fi

# ====== Ensure photo dir exists ======
mkdir -p "${PHOTO_DIR}"

# ====== Global env for systemd units ======
sudo tee /etc/leanframe.env >/dev/null <<EOF
PHOTO_DIR=${PHOTO_DIR}
RCLONE_REMOTE=${RCLONE_REMOTE}
DRIVE_PATH="${DRIVE_PATH}"
EOF

# ====== Render systemd units from templates ======
sudo tee /etc/systemd/system/leanframe.service >/dev/null <<EOF
[Unit]
Description=LeanFrame digital photo frame
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${REPO_DIR}
EnvironmentFile=/etc/leanframe.env
Environment=PYTHONUNBUFFERED=1
# Uncomment one if you need SDL/FB/GUI:
# Environment=SDL_VIDEODRIVER=fbcon
# Environment=DISPLAY=:0

ExecStart=${VENV_BIN}/python -m photoframe
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/leanframe-sync.service >/dev/null <<'EOF'
[Unit]
Description=LeanFrame: rclone sync Drive -> local photo cache
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=%i
EnvironmentFile=/etc/leanframe.env
ExecStartPre=/usr/bin/mkdir -p "${PHOTO_DIR}"
ExecStart=/usr/bin/rclone sync "${RCLONE_REMOTE}:${DRIVE_PATH}" "${PHOTO_DIR}" \
  --fast-list --transfers 4 --checkers 8 --create-empty-src-dirs=false
EOF

sudo tee /etc/systemd/system/leanframe-sync@.service >/dev/null <<'EOF'
[Unit]
Description=LeanFrame: rclone sync Drive -> local photo cache (templated)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=%i
EnvironmentFile=/etc/leanframe.env
ExecStartPre=/usr/bin/mkdir -p "${PHOTO_DIR}"
ExecStart=/usr/bin/rclone sync "${RCLONE_REMOTE}:${DRIVE_PATH}" "${PHOTO_DIR}" \
  --fast-list --transfers 4 --checkers 8 --create-empty-src-dirs=false
EOF

sudo tee /etc/systemd/system/leanframe-sync.timer >/dev/null <<EOF
[Unit]
Description=Run LeanFrame sync periodically (10 mins)

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Unit=leanframe-sync.service

[Install]
WantedBy=timers.target
EOF

# ====== Enable & start ======
sudo systemctl daemon-reload
# Use the non-templated service bound to your current user:
sudo systemctl enable --now leanframe-sync.timer
sudo systemctl start        leanframe-sync.service || true   # warm sync
sudo systemctl enable --now leanframe.service

echo "Done.
- leanframe.service (app) using ${VENV_BIN}/python in ${REPO_DIR}
- leanframe-sync.timer every 10 min -> ${PHOTO_DIR}
Edit /etc/leanframe.env to change PHOTO_DIR or rclone settings.
"