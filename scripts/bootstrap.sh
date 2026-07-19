#!/usr/bin/env bash
set -euo pipefail

# Bootstrap host for the homeserver stack. Idempotent. Run with sudo or as root.
# Handles both Fedora (dnf/firewalld/SELinux) and Ubuntu/Debian (apt/ufw).

log() { printf '\033[1;32m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo $0)"; exit 1
fi

# --- Detect distro family ---
. /etc/os-release
FAMILY="unknown"
case "${ID}${ID_LIKE:-}" in
  *fedora*|*rhel*|*centos*) FAMILY="fedora" ;;
  *debian*|*ubuntu*)        FAMILY="debian" ;;
esac
log "Detected distro family: $FAMILY ($PRETTY_NAME)"

# --- Directory trees ---
log "Creating /opt/stacks and /srv trees"
mkdir -p /srv/{timemachine,shares,tailscale}
mkdir -p /srv/code-server/{config,projects}
mkdir -p /srv/filebrowser/{database,config}
# code-server, samba and filebrowser run as uid 1000; make sure it owns their data
chown -R 1000:1000 /srv/code-server /srv/timemachine /srv/shares /srv/filebrowser 2>/dev/null || true

# --- Install Docker if absent ---
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  if [[ "$FAMILY" == "fedora" ]]; then
    dnf -y install dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  elif [[ "$FAMILY" == "debian" ]]; then
    apt-get update
    apt-get -y install ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  else
    warn "Unknown distro — install Docker manually."
  fi
  systemctl enable --now docker
else
  log "Docker already present: $(docker --version)"
fi

# --- Disable host avahi + smb so the Samba container can own mDNS/SMB ---
log "Disabling host avahi and smb/nmb (Samba container owns these)"
systemctl disable --now avahi-daemon.socket avahi-daemon.service 2>/dev/null || true
systemctl disable --now smb nmb smbd nmbd 2>/dev/null || true

# --- Firewall ---
# Only needed for LAN access to SMB. If everything is over Tailscale, these are optional.
log "Configuring firewall (SMB + mDNS + wsdd)"
if [[ "$FAMILY" == "fedora" ]] && command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-service=samba || true
  firewall-cmd --permanent --add-port=5353/udp || true
  firewall-cmd --permanent --add-port=3702/udp || true
  firewall-cmd --reload || true
elif [[ "$FAMILY" == "debian" ]] && command -v ufw >/dev/null 2>&1; then
  ufw allow 445/tcp || true
  ufw allow 139/tcp || true
  ufw allow 5353/udp || true
  ufw allow 3702/udp || true
else
  warn "No recognized firewall tool active; skipping (fine if using Tailscale only)."
fi

# --- Secrets tooling: age + sops ---
if ! command -v age-keygen >/dev/null 2>&1; then
  log "Installing age"
  if [[ "$FAMILY" == "fedora" ]]; then dnf -y install age; else apt-get -y install age; fi
fi
if ! command -v sops >/dev/null 2>&1; then
  SOPS_VER=v3.13.2
  log "Installing sops $SOPS_VER"
  ARCH=$(uname -m); case "$ARCH" in x86_64) SOPS_ARCH=amd64 ;; aarch64) SOPS_ARCH=arm64 ;; *) SOPS_ARCH=$ARCH ;; esac
  curl -sL -o /usr/local/bin/sops \
    "https://github.com/getsops/sops/releases/download/${SOPS_VER}/sops-${SOPS_VER}.linux.${SOPS_ARCH}"
  chmod +x /usr/local/bin/sops
fi
if [[ ! -f /root/.config/sops/age/keys.txt ]]; then
  warn "No age key at /root/.config/sops/age/keys.txt."
  warn "  Migrating?   Restore the key from your password manager to that path."
  warn "  First setup? Run: mkdir -p /root/.config/sops/age && age-keygen -o /root/.config/sops/age/keys.txt"
  warn "  Then BACK THE KEY UP and put its public key in .sops.yaml."
fi

# --- SELinux note (Fedora) ---
if [[ "$FAMILY" == "fedora" ]]; then
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    log "SELinux is Enforcing — the ':Z' bind-mount flags in docker-compose.yml handle labeling."
  fi
fi

log "Bootstrap complete."
log "Next: ./scripts/secrets.sh decrypt   (or create .env from .env.example on first setup)"
log "Then: docker compose up -d"
