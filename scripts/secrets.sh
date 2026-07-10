#!/usr/bin/env bash
set -euo pipefail

# Manage the encrypted secrets file (.env.sops <-> .env).
#
#   secrets.sh encrypt   .env       -> .env.sops   (run after editing .env)
#   secrets.sh decrypt   .env.sops  -> .env        (run after cloning)
#   secrets.sh edit      edit .env.sops in $EDITOR, re-encrypting on save
#
# Requires sops + age, and the age private key at ~/.config/sops/age/keys.txt.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR"

case "${1:-}" in
  encrypt)
    sops --input-type dotenv --output-type dotenv -e .env > .env.sops
    echo "Encrypted .env -> .env.sops (commit .env.sops; .env itself stays untracked)"
    ;;
  decrypt)
    sops --input-type dotenv --output-type dotenv -d .env.sops > .env
    chmod 600 .env
    echo "Decrypted .env.sops -> .env"
    ;;
  edit)
    sops --input-type dotenv --output-type dotenv .env.sops
    echo "Remember to run: $0 decrypt   (so the running stack picks up the change)"
    ;;
  *)
    echo "Usage: $0 {encrypt|decrypt|edit}" >&2
    exit 1
    ;;
esac
