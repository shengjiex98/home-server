#!/usr/bin/env bash
set -euo pipefail

# Read-only status board for the restic backups: recent snapshots, true repo
# size on B2, recent local runs, next scheduled run, healthcheck state.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$STACK_DIR/.env"; set +a
export RESTIC_PASSWORD B2_ACCOUNT_ID B2_ACCOUNT_KEY

REPO="b2:${B2_BUCKET}:${RESTIC_B2_PATH}"

echo "── snapshots (last 8) ─ $REPO"
restic -r "$REPO" snapshots --compact | tail -n 11

echo
echo "── stored on B2 (deduplicated, all snapshots) ──"
restic -r "$REPO" stats --mode raw-data | grep -E 'Snapshots processed|Total Size'

echo
echo "── recent runs on this machine ──"
journalctl -u restic-backup.service --no-pager -n 500 2>/dev/null \
  | grep -E 'Starting restic|Backup complete|Failed with result' | tail -6 \
  || echo "(no journal entries readable)"
systemctl list-timers restic-backup.timer --no-pager 2>/dev/null | sed -n 2p

if [[ -n "${HC_CHECK_UUID:-}" && -n "${HC_API_KEY:-}" ]]; then
  echo
  echo "── healthchecks.io ──"
  # Direct lookup needs a regular API key; read-only keys can only list, and
  # their listings omit real UUIDs — in that case just show every check.
  hc_fmt='import json, sys
d = json.load(sys.stdin)
for c in (d["checks"] if "checks" in d else [d]):
    print("%s: %s   last ping: %s" % (c["name"], c["status"], c.get("last_ping") or "never"))'
  { curl -fsS -m 10 -H "X-Api-Key: $HC_API_KEY" \
      "https://healthchecks.io/api/v3/checks/$HC_CHECK_UUID" 2>/dev/null \
    || curl -fsS -m 10 -H "X-Api-Key: $HC_API_KEY" \
      "https://healthchecks.io/api/v3/checks/"; } \
    | python3 -c "$hc_fmt" || echo "(healthchecks query failed)"
fi
