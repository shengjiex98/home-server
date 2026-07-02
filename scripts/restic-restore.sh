#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$STACK_DIR/.env"; set +a
export RESTIC_PASSWORD B2_ACCOUNT_ID B2_ACCOUNT_KEY

B2_REPO="b2:${B2_BUCKET}:${RESTIC_B2_PATH}"
SNAPSHOT="${1:-latest}"
TARGET="${2:-/}"   # restore into place by default; pass /tmp/restore-test to dry-check

echo "[restic] Restoring snapshot '$SNAPSHOT' from $B2_REPO to '$TARGET'"
echo "[restic] (This overwrites files under the restored paths. Ctrl-C now to abort.)"
sleep 3
restic -r "$B2_REPO" restore "$SNAPSHOT" --target "$TARGET"
echo "[restic] Restore complete. Now: cd /opt/stacks && docker compose up -d"
