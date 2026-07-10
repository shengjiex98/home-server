#!/usr/bin/env bash
set -euo pipefail

# Show how much space each Mac's Time Machine backup uses.
# Each Mac stores its backups as one <MacName>.sparsebundle directory.

TM_DIR=/srv/timemachine

shopt -s nullglob
bundles=("$TM_DIR"/*.sparsebundle)

if [[ ${#bundles[@]} -eq 0 ]]; then
  echo "No Time Machine backups yet in $TM_DIR"
else
  echo "Per-Mac Time Machine usage:"
  du -sh "${bundles[@]}"
fi

echo
echo "Filesystem holding $TM_DIR:"
df -h "$TM_DIR"
