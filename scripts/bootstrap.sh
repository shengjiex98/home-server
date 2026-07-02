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
# code-server + samba run as uid 1000; make sure it owns its data
chown -R 1000:1000 /srv/code-server /srv/timemachine /srv/shares 2>/dev/null || true

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

# --- SELinux note (Fedora) ---
if [[ "$FAMILY" == "fedora" ]]; then
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    log "SELinux is Enforcing — the ':Z' bind-mount flags in docker-compose.yml handle labeling."
  fi
fi

log "Bootstrap complete."
log "Next: cp .env.example .env && edit it, then: docker compose up -d"
