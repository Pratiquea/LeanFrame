#!/usr/bin/env bash
set -euo pipefail
sudo cp systemd/leanframe-sync.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable leanframe-sync.timer
sudo systemctl start leanframe-sync.timer