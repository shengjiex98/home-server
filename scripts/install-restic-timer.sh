#!/usr/bin/env bash
set -euo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo $0)"; exit 1; fi

# Render the service with the correct absolute path to the backup script
sed "s|__BACKUP_SCRIPT__|$STACK_DIR/scripts/restic-backup.sh|g" \
  "$STACK_DIR/scripts/systemd/restic-backup.service" > /etc/systemd/system/restic-backup.service
cp "$STACK_DIR/scripts/systemd/restic-backup.timer" /etc/systemd/system/restic-backup.timer

systemctl daemon-reload
systemctl enable --now restic-backup.timer
echo "Installed. Check with: systemctl list-timers restic-backup.timer"
