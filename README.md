# Home Server Stack

A distro-independent, container-based server stack designed to run on **multiple servers at once** (e.g. a home PC and a cloud VM), each fully independent. Every server is one Tailscale node; all of its HTTP services live under that single hostname, path-routed by Caddy — no port numbers, no per-service tailnet nodes, HTTPS handled by `tailscale serve`. Compose definitions, service config, and operational scripts live in git at `/opt/stacks`; all container-written data lives in visible bind mounts under `/srv`; secrets live encrypted in git (sops + age).

## Services

Per server, at `https://<server>.<tailnet>.ts.net`:

| Path | Service |
|---|---|
| `/` | Landing page: all services with live status |
| `/code/` | code-server (VS Code in the browser) |
| `/files/` | FileBrowser (web file manager over the SMB data) |

Plus, outside HTTP: Samba on the LAN (`smb://<server>` in Finder, auto-discovered) with the general `Files` share and the macOS Time Machine target.

Everything HTTP is tailnet-only — nothing is exposed to the public internet, and Tailscale is the authentication layer.

## Current servers

| Host | `TS_HOSTNAME` | Where |
|---|---|---|
| `home` | `homeserver` | Fedora box at home (primary; Time Machine target) |
| `do-pod` | `do-pod` | DigitalOcean droplet |

## Repository layout

```
compose.yml              # top-level; includes each service's compose file
gateway/                 # tailscale node + caddy path router + homepage + socket proxy
code-server/             # code-server
files/                   # filebrowser
samba/                   # SMB + Time Machine (LAN, host networking)
hosts/<host>.sops.env    # encrypted per-server settings (hostname, restic path, ...)
.env.sops                # encrypted shared secrets (same on all servers)
scripts/                 # bootstrap, secrets, backup/restore, tm-usage
renovate.json            # automated image-update PRs
```

Routing lives in two small files: `gateway/serve.json` (tailscale serve → caddy) and `gateway/Caddyfile` (paths → services).

## Prerequisites

- Ubuntu/Debian or Fedora, with `git`.
- A Tailscale account; MagicDNS + HTTPS certificates enabled (admin console → DNS). Joining a new server needs a **reusable, non-ephemeral** auth key.
- A Backblaze B2 bucket + application key (backups), a healthchecks.io check per server (backup alerting).
- `restic`, `age`, `sops` — bootstrap installs age/sops; install restic from your package manager.

## Setting up a server

```bash
git clone https://github.com/shengjiex98/home-server /opt/stacks
cd /opt/stacks
sudo ./scripts/bootstrap.sh
# restore the age key from your password manager to ~/.config/sops/age/keys.txt
./scripts/secrets.sh decrypt <host>     # e.g. `decrypt home` — builds .env
docker compose up -d
docker exec tailscale tailscale status  # approve the node in the admin console if needed
sudo apt install restic || sudo dnf install restic
./scripts/restic-backup.sh              # first backup + repo init
sudo ./scripts/install-restic-timer.sh  # automate daily
```

For a **brand-new server** (not one of the hosts in `hosts/`), first create its config on any machine that has the age key:

```bash
./scripts/secrets.sh edit <newhost>     # creates hosts/<newhost>.sops.env
```

Set `TS_HOSTNAME` (unique tailnet name), `RESTIC_B2_PATH` (**unique per server** — two servers must never share a restic repo path), and its own healthchecks.io `HC_PING_URL`/`HC_CHECK_UUID`. Commit the new file.

To restore another server's data onto this one (e.g. moving primary from cloud to home), run `sudo ./scripts/restic-restore.sh` against the *other* server's `RESTIC_B2_PATH` before `docker compose up -d`.

> [!IMPORTANT]
> Machine identity never moves between servers. `/srv/tailscale` (node keys) is
> excluded from backups — each server always joins the tailnet as itself, with
> its own name. Never copy `/srv/tailscale` from one machine to another: two
> daemons sharing one node identity will fight over it and both go flaky.

## Secrets

Two encrypted files, both committed; plaintext `.env` is generated and gitignored:

- `.env.sops` — shared secrets (Tailscale key, passwords, B2 credentials)
- `hosts/<host>.sops.env` — per-server settings

```bash
./scripts/secrets.sh edit               # edit shared secrets
./scripts/secrets.sh edit <host>        # edit one server's settings
./scripts/secrets.sh decrypt            # rebuild .env (host remembered from setup)
docker compose up -d                    # apply (recreates changed containers)
```

The age key at `~/.config/sops/age/keys.txt` unlocks everything — **keep a copy in your password manager**, along with `RESTIC_PASSWORD`.

## SMB and Time Machine (LAN)

One container ([servercontainers/samba](https://github.com/ServerContainers/samba)) provides the `Files` share, the `TimeMachine` share, and Avahi/mDNS auto-discovery. Finder: `smb://<server>`, user `jerry` with `SMB_PASSWORD`. Time Machine: connect once in Finder, then **System Settings → General → Time Machine → Add Backup Disk**. Both Macs share one TimeMachine share; per-Mac usage: `sudo ./scripts/tm-usage.sh`.

SMB is LAN-only by design (WAN latency makes Finder-over-SMB miserable); use `/files/` remotely.

## Backups

Daily restic backup (03:30) of `/srv` + `/opt/stacks` to `b2:<bucket>:<RESTIC_B2_PATH>`, with 7d/4w/6m retention. Excluded: `/srv/timemachine` (the Macs' own backup), `/srv/tailscale*`/`/srv/ts-*` (machine identity). Each run pings this server's healthchecks.io check — you get an email if backups stop; the dashboard shows the check's status.

Test a restore occasionally:

```bash
./scripts/restic-restore.sh latest /tmp/restore-test
```

## Updating images (Renovate)

All images are pinned. The [Renovate GitHub App](https://github.com/apps/renovate) opens PRs for updates (`renovate.json` understands the compose files, including samba's tag scheme). Apply on each server with `git pull && docker compose up -d`.

## Adding a new HTTP service

1. Create `<name>/compose.yml` with the app container — no published ports, data under `/srv/<name>` with the `:Z` suffix — and add it to the top-level `compose.yml` `include:` list.
2. Route it in `gateway/Caddyfile`: a `redir /<name> /<name>/ 308` plus a `handle_path /<name>/*` (if the app expects to live at `/`) or `handle /<name>/*` (if it supports a base-path setting — prefer this) block.
3. Add a tile in `gateway/homepage/services.yaml` with `href: /<name>/`.

`/srv` is already covered by restic. Services with a database (e.g. Immich's Postgres) additionally need a pre-backup dump step — file-level copies of a running database are not crash-safe.

## Claude Code and Codex in code-server

Install Claude Code / Codex extensions from the Open VSX registry via code-server's Extensions view, or use the CLIs from the integrated terminal:

```bash
npm i -g @anthropic-ai/claude-code
claude
```

> [!CAUTION]
> **CRITICAL WARNINGS**
>
> - Back up the **age key** and **`RESTIC_PASSWORD`** off-server (password manager). Losing them makes the encrypted secrets / backups unrecoverable.
> - Never commit the plaintext `.env`; never share a `RESTIC_B2_PATH` between servers; never copy `/srv/tailscale` between machines.
> - Keep all HTTP services tailnet-only; do not publish ports or run `tailscale funnel` without thinking through auth.

## Backblaze B2 egress

Restoring all of `/srv` downloads all backed-up data. Egress up to 3× stored volume per month is free; beyond that it scales with data volume, so keep the cloud server lean and account for restore time before parking large archives on it.
