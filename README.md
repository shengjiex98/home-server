# Home Server Stack

This repository defines a distro-independent, container-based home server stack with Tailscale as the private front door, code-server for browser-based development, and Samba shares including a macOS Time Machine target. Configuration, Compose definitions, and operational scripts live in git at `/opt/stacks`; all container-written data lives in visible bind mounts under `/srv`, keeping backup, inspection, and migration independent of the host distribution.

## Prerequisites

You need:

- A cloud VM or home PC running Ubuntu/Debian or Fedora.
- A Tailscale account and an auth key from the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys).
- A Backblaze B2 bucket and application key.
- `git` for cloning the repository.
- `restic` for backup and restore. Install it with `apt install restic` on Ubuntu/Debian or `dnf install restic` on Fedora.

## First run on the cloud VM

Replace `<repo-url>` with this repository's URL:

```bash
git clone <repo-url> /opt/stacks
cd /opt/stacks
sudo ./scripts/bootstrap.sh
cp .env.example .env && nano .env      # fill in all secrets
chmod 600 .env
docker compose up -d
docker exec tailscale tailscale status  # approve node in admin console
sudo apt install restic || sudo dnf install restic
./scripts/restic-backup.sh              # first backup + repo init
sudo ./scripts/install-restic-timer.sh  # automate daily
```

The bootstrap script creates the `/srv` data tree, installs Docker when needed, configures the host firewall, and disables host SMB and Avahi services that would conflict with the Samba container. It is safe to run again.

## Accessing services

Publish code-server through the Tailscale node. The `tailscale` and `code-server`
containers are separate on the Docker network (no shared network namespace), so the
serve target must name the `code-server` service rather than `127.0.0.1`/a bare port:

```bash
docker exec tailscale tailscale serve --bg http://code-server:8080
```

Then open `https://<tailscale-name>` (no port — `tailscale serve` publishes HTTPS on
443 by default) from a device on the same tailnet. The Compose port itself is bound
only to host loopback and is not publicly exposed.

Connect to the file shares from macOS Finder with:

```text
smb://<tailscale-name>
```

Authenticate as `jerry` with the `SMB_PASSWORD` from `.env`. To configure Time Machine, connect to the server in Finder first, then open **System Settings → General → Time Machine → Add Backup Disk** and select `TimeMachine`. If it does not appear immediately, choose the mounted `TimeMachine` share through **Set Up Disk**.

## Claude Code and Codex in code-server

Use code-server's Extensions view to install available Claude Code or Codex extensions from the Open VSX registry. Extension availability can differ from Microsoft's VS Code Marketplace.

Claude Code also works from code-server's integrated terminal regardless of extension availability:

```bash
npm i -g @anthropic-ai/claude-code
claude
```

For Codex, install its Open VSX extension when available or use the Codex CLI from the integrated terminal according to its installation instructions.

## Migrate to the home PC (Fedora)

The same repository and data paths move unchanged. Back up the cloud VM first, then run these commands on the Fedora host:

```bash
git clone <repo-url> /opt/stacks
cd /opt/stacks
sudo ./scripts/bootstrap.sh            # same script, auto-detects Fedora
cp .env.example .env && nano .env      # regenerate TS_AUTHKEY; reuse B2/restic creds
chmod 600 .env
sudo ./scripts/restic-restore.sh       # pulls /srv data down from B2
docker compose up -d
```

The commands are the same on both hosts. Secrets are the only values that must be entered again: generate a fresh `TS_AUTHKEY`, and reuse the B2 credentials and `RESTIC_PASSWORD` needed to decrypt the existing backup.

> [!CAUTION]
> **CRITICAL WARNINGS**
>
> - Store `RESTIC_PASSWORD` somewhere off the server, such as a password manager. If it is lost, the encrypted B2 backups are unrecoverable.
> - Never commit `.env`.
> - Never expose code-server to the public internet. Access it through Tailscale only.
> - Test a restore once before trusting the backups:
>
>   ```bash
>   ./scripts/restic-restore.sh latest /tmp/restore-test
>   ```
>
>   Verify that the expected files appear under `/tmp/restore-test`.

## Backblaze B2 egress

Restoring all of `/srv` downloads all backed-up data. B2 egress is inexpensive but still scales with data volume, so keep the cloud phase lean and do not park a large photo archive there unless you have accounted for its restore cost and time.

## Extending the stack

Add a service block to `docker-compose.yml` and bind-mount its persistent data under `/srv/<service>` with the SELinux-compatible `:Z` suffix:

```yaml
services:
  example:
    image: example/service:latest
    volumes:
      - /srv/example:/var/lib/example:Z
```

Because `/srv` is already included in the restic backup, the new service data is covered automatically. Once the stack grows substantially, split related services into multiple Compose files or projects while retaining the same `/srv` data convention.
