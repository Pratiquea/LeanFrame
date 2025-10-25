#!/usr/bin/env bash
set -euo pipefail
sudo apt-get update
sudo apt-get install -y python3-venv python3-dev libjpeg-dev zlib1g-dev \
    ffmpeg mpv libSDL2-dev libsdl2-image-2.0-0 rclone
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt