#!/usr/bin/env bash
set -euo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo $0)"; exit 1; fi

install -m 0755 "$STACK_DIR/scripts/net-sleep-inhibit" /usr/local/bin/net-sleep-inhibit
cp "$STACK_DIR/scripts/systemd/net-sleep-inhibit.service" /etc/systemd/system/net-sleep-inhibit.service

systemctl daemon-reload
systemctl enable --now net-sleep-inhibit.service
echo "Installed. While an SSH/SMB session is open, verify with: systemd-inhibit --list"
