#!/usr/bin/env bash
set -euo pipefail

# ===== User-configurable paths =====
USER_NAME="${USER}"                                # e.g. rpi
HOME_DIR="${HOME}"
REPO_DIR="${HOME_DIR}/gits/LeanFrame"              # your repo
VENV_BIN="${REPO_DIR}/.venv/bin"                   # existing venv bin
PHOTO_DIR="${HOME_DIR}/DrivePhotos"                # local photo cache (for sync)
RCLONE_REMOTE="gdrive"                             # rclone remote name
DRIVE_PATH=""                             # Drive folder name OR ID (keep quotes for ID)

# ===== Sanity checks =====
if [ ! -d "${REPO_DIR}" ]; then
  echo "ERROR: Repo not found at ${REPO_DIR}"; exit 1
fi
if [ ! -x "${VENV_BIN}/python" ]; then
  echo "ERROR: venv python not found at ${VENV_BIN}/python"
  echo "Create it first:  python3 -m venv ${REPO_DIR}/.venv && source ${REPO_DIR}/.venv/bin/activate && pip install -r ${REPO_DIR}/requirements.txt"
  exit 1
fi

# ===== Ensure photo dir and global env exist =====
mkdir -p "${PHOTO_DIR}"
sudo tee /etc/leanframe.env >/dev/null <<EOF
PHOTO_DIR=${PHOTO_DIR}
RCLONE_REMOTE=${RCLONE_REMOTE}
DRIVE_PATH="${DRIVE_PATH}"
EOF

# ===== Create user units (~/.config/systemd/user) =====
USER_UNIT_DIR="${HOME_DIR}/.config/systemd/user"
mkdir -p "${USER_UNIT_DIR}"

# leanframe.service (Wayland user service with socket wait)
cat > "${USER_UNIT_DIR}/leanframe.service" <<'EOF'
[Unit]
Description=LeanFrame (Wayland user service; waits for compositor)
Wants=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
WorkingDirectory=/home/rpi/gits/LeanFrame
EnvironmentFile=/etc/leanframe.env
Environment=PYTHONUNBUFFERED=1
Environment=SDL_VIDEODRIVER=wayland
# Wait up to ~15s for Wayland socket to avoid race at login
ExecStartPre=/bin/sh -lc 'for i in $(seq 1 15); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && exit 0; sleep 1; done; echo "wayland-0 not ready"; exit 1'
ExecStart=/home/rpi/gits/LeanFrame/.venv/bin/python -m photoframe
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
# Patch username in the unit paths
sed -i "s|/home/rpi|${HOME_DIR}|g" "${USER_UNIT_DIR}/leanframe.service"

# Path unit to start LeanFrame when Wayland socket appears
cat > "${USER_UNIT_DIR}/leanframe-wayland.path" <<'EOF'
[Unit]
Description=Start LeanFrame when Wayland socket appears

[Path]
PathExists=%t/wayland-0
Unit=leanframe.service

[Install]
WantedBy=default.target
EOF

# ===== Make the user manager survive boot (do once) =====
sudo loginctl enable-linger "${USER_NAME}"

# ===== Disable and remove any old system service (optional cleanup) =====
if systemctl list-unit-files | grep -q '^leanframe.service'; then
  sudo systemctl disable --now leanframe.service || true
  sudo rm -f /etc/systemd/system/leanframe.service || true
  sudo systemctl daemon-reload || true
fi

# ===== Enable & start user units =====
systemctl --user daemon-reload
systemctl --user enable --now leanframe.service
systemctl --user enable --now leanframe-wayland.path

echo "-------------------------------------------------------------"
echo "Installed user units:"
echo "  ${USER_UNIT_DIR}/leanframe.service"
echo "  ${USER_UNIT_DIR}/leanframe-wayland.path"
echo
echo "Global env: /etc/leanframe.env"
echo "  PHOTO_DIR=${PHOTO_DIR}"
echo "  RCLONE_REMOTE=${RCLONE_REMOTE}"
echo "  DRIVE_PATH=\"${DRIVE_PATH}\""
echo
echo "User-service logs (no sudo):"
echo "  journalctl --user -u leanframe -f"
echo
echo "If you use the system sync timer, manage it separately:"
echo "  sudo systemctl status leanframe-sync.timer"
echo "-------------------------------------------------------------"