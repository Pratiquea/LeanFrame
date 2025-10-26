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
# ====== Sanity checks ======
if [ ! -d "${REPO_DIR}" ]; then
  echo "ERROR: Repo not found at ${REPO_DIR}"; exit 1
fi
if [ ! -x "${VENV_BIN}/python" ]; then
  echo "ERROR: Existing venv python not found at ${VENV_BIN}/python"
  echo "Create it first:  python3 -m venv ${REPO_DIR}/.venv && source ${REPO_DIR}/.venv/bin/activate && pip install -r ${REPO_DIR}/requirements.txt"
  exit 1
fi
if ! command -v rclone >/dev/null 2>&1; then
  echo "ERROR: rclone not found. Install it:  sudo apt-get update && sudo apt-get install -y rclone"
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
After=graphical.target network-online.target
Wants=graphical.target network-online.target

[Service]
Type=simple
User=rpi
WorkingDirectory=/home/rpi/gits/LeanFrame
EnvironmentFile=/etc/leanframe.env
Environment=PYTHONUNBUFFERED=1

# Tell SDL/pygame to use Wayland and the user's desktop session
Environment=SDL_VIDEODRIVER=wayland
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_RUNTIME_DIR=/run/user/1000

# Slight delay helps if the compositor/socket races at boot
ExecStartPre=/bin/sleep 3

ExecStart=/home/rpi/gits/LeanFrame/.venv/bin/python -m photoframe
Restart=always
RestartSec=2

[Install]
WantedBy=graphical.target
EOF


# Replace the bad unit with a correct one
sudo tee /etc/systemd/system/leanframe-sync.service >/dev/null <<'EOF'
[Unit]
Description=LeanFrame: rclone sync Drive -> local photo cache
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=rpi
EnvironmentFile=/etc/leanframe.env
ExecStartPre=/usr/bin/mkdir -p "${PHOTO_DIR}"
ExecStart=/usr/bin/rclone sync "${RCLONE_REMOTE}:${DRIVE_PATH}" "${PHOTO_DIR}" \
  --fast-list --transfers 4 --checkers 8 --create-empty-src-dirs=false
EOF
# Patch placeholder with actual user safely
sudo sed -i "s|rpi|${USER_NAME}|g" /etc/systemd/system/leanframe-sync.service


# Timer
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

# ====== Reload, enable, start ======
sudo systemctl daemon-reload
sudo systemctl enable --now leanframe-sync.timer
# Warm sync (non-fatal if it fails; check logs with journalctl -u leanframe-sync)
sudo systemctl start leanframe-sync.service || true

sudo systemctl enable --now leanframe.service

echo "-------------------------------------------------------------"
echo "Installed units:"
echo "  /etc/systemd/system/leanframe.service"
echo "  /etc/systemd/system/leanframe-sync.service"
echo "  /etc/systemd/system/leanframe-sync.timer"
echo
echo "Env file: /etc/leanframe.env"
echo "  PHOTO_DIR=${PHOTO_DIR}"
echo "  RCLONE_REMOTE=${RCLONE_REMOTE}"
echo "  DRIVE_PATH=\"${DRIVE_PATH}\""
echo
echo "Status:"
echo "  systemctl status leanframe"
echo "  systemctl status leanframe-sync.timer"
echo "  journalctl -u leanframe-sync -n 100 --no-pager"
echo "-------------------------------------------------------------"