#!/usr/bin/env bash
set -euo pipefail

# Manage encrypted secrets for a multi-server stack.
#
# Layout:
#   .env.sops              shared secrets (same on every server)
#   hosts/<host>.sops.env  per-server settings (hostname, restic path, healthchecks)
#   .env                   generated plaintext = shared + host  (gitignored)
#
# Usage:
#   secrets.sh decrypt <host>   build .env for this server (remembers host in .host)
#   secrets.sh decrypt          rebuild .env using the remembered host
#   secrets.sh edit             edit shared .env.sops in $EDITOR
#   secrets.sh edit <host>      edit hosts/<host>.sops.env (created if missing)
#
# After any edit, run `secrets.sh decrypt` again, then `docker compose up -d`.
# Requires sops + age, and the age private key at ~/.config/sops/age/keys.txt.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"
S=(sops --input-type dotenv --output-type dotenv)

case "${1:-}" in
  edit)
    if [[ -n "${2:-}" ]]; then
      mkdir -p hosts
      "${S[@]}" "hosts/$2.sops.env"
    else
      "${S[@]}" .env.sops
    fi
    echo "Remember to run: $0 decrypt   (so the running stack picks up the change)"
    ;;
  decrypt)
    host="${2:-$(cat .host 2>/dev/null || true)}"
    if [[ -z "$host" ]]; then
      echo "Usage: $0 decrypt <host>   (available: $(ls hosts 2>/dev/null | sed 's/\.sops\.env//' | tr '\n' ' '))" >&2
      exit 1
    fi
    if [[ ! -f "hosts/$host.sops.env" ]]; then
      echo "No hosts/$host.sops.env — create it with: $0 edit $host" >&2
      exit 1
    fi
    {
      "${S[@]}" -d .env.sops
      echo
      "${S[@]}" -d "hosts/$host.sops.env"
    } > .env
    chmod 600 .env
    echo "$host" > .host
    echo "Decrypted .env.sops + hosts/$host.sops.env -> .env"
    ;;
  *)
    echo "Usage: $0 {decrypt [host]|edit [host]}" >&2
    exit 1
    ;;
esac
