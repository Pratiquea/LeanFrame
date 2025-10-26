#!/usr/bin/env bash
set -euo pipefail

# Base packages only; keep your existing venv intact.
sudo apt-get update
sudo apt-get install -y \
  python3-venv python3-dev libjpeg-dev zlib1g-dev \
  ffmpeg mpv libsdl2-dev libsdl2-image-2.0-0 rclone

# Do NOT touch the existing venv. If you want optional guard rails:
REPO_DIR="${HOME}/gits/LeanFrame"
VENV_BIN="${REPO_DIR}/.venv/bin"

if [ ! -x "${VENV_BIN}/python" ]; then
  echo "[Notice] No venv found at ${VENV_BIN}."
  echo "Create one manually if needed: python3 -m venv ${REPO_DIR}/.venv && source ${REPO_DIR}/.venv/bin/activate && pip install -r ${REPO_DIR}/requirements.txt"
else
  echo "Existing venv detected at ${VENV_BIN}; skipping pip install."
fi
