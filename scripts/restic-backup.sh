#!/usr/bin/env bash
set -euo pipefail

# Load env
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$STACK_DIR/.env"; set +a

export RESTIC_PASSWORD B2_ACCOUNT_ID B2_ACCOUNT_KEY

# healthchecks.io dead-man's switch (no-op if HC_PING_URL is unset)
hc() {
  [[ -n "${HC_PING_URL:-}" ]] && curl -fsS -m 10 --retry 3 "${HC_PING_URL}$1" >/dev/null 2>&1 || true
}
trap 'hc /fail' ERR
hc /start

BACKUP_PATHS=(/srv /opt/stacks)
# Excluded:
# - /srv/timemachine: already a backup of the Macs, huge, churns constantly.
# - /srv/tailscale, /srv/ts-*: MACHINE IDENTITY (node keys). Restoring these
#   onto another machine makes two servers fight over the same tailnet nodes.
EXCLUDES=(--exclude /srv/timemachine --exclude /srv/tailscale --exclude '/srv/ts-*')

RETENTION=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)

ensure_repo() {
  local repo="$1"; shift
  if ! restic -r "$repo" snapshots >/dev/null 2>&1; then
    echo "[restic] Initializing repo: $repo"
    restic -r "$repo" init
  fi
}

run_target() {
  local repo="$1"
  echo "[restic] Backing up to $repo"
  ensure_repo "$repo"
  restic -r "$repo" backup "${BACKUP_PATHS[@]}" "${EXCLUDES[@]}"
  echo "[restic] Pruning $repo"
  restic -r "$repo" forget "${RETENTION[@]}" --prune
}

# --- B2 (offsite, always) ---
B2_REPO="b2:${B2_BUCKET}:${RESTIC_B2_PATH}"
run_target "$B2_REPO"

# --- Local repo (optional, faster restores) ---
if [[ -n "${RESTIC_LOCAL_REPO:-}" ]]; then
  run_target "$RESTIC_LOCAL_REPO"
fi

hc ""
echo "[restic] Backup complete."
