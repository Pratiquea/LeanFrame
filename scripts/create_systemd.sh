#!/usr/bin/env bash
set -euo pipefail
sudo useradd -r -s /usr/sbin/nologin leanframe || true
sudo mkdir -p /opt/leanframe
sudo rsync -a --delete ./ /opt/leanframe/
cd /opt/leanframe
./scripts/install_deps.sh
sudo cp systemd/leanframe.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable leanframe
sudo systemctl start leanframe