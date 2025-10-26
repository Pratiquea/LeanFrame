#!/usr/bin/env bash
set -euo pipefail

sudo systemctl daemon-reload
sudo systemctl enable --now leanframe-sync.timer
sudo systemctl start        leanframe-sync.service || true

echo "leanframe-sync.timer enabled and started."
