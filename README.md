# Home Server Stack

A distro-independent, container-based home server stack. Every HTTP service is published on the tailnet under its own hostname by a dedicated Tailscale sidecar — no port numbers, no reverse-proxy config, HTTPS certificates handled automatically. A [homepage](https://gethomepage.dev) dashboard on the gateway node is the landing page for everything. Compose definitions, service config, and operational scripts live in git at `/opt/stacks`; all container-written data lives in visible bind mounts under `/srv`; secrets live encrypted in git (`.env.sops`, sops + age).

## Services

| URL | Service |
|---|---|
| `https://<gateway>.<tailnet>.ts.net` | Landing page: all services with live status |
| `https://code.<tailnet>.ts.net` | code-server (VS Code in the browser) |
| `https://files.<tailnet>.ts.net` | FileBrowser (web file manager over the SMB data) |
| `smb://<server>` (LAN, auto-discovered) | Samba: general share + Time Machine |

Everything HTTP is tailnet-only — nothing is exposed to the public internet, and Tailscale is the authentication layer. The first load of each URL can take a few seconds while the TLS certificate is minted.

## Repository layout

```
compose.yml              # top-level; includes each service's compose file
gateway/                 # tailscale gateway node + homepage dashboard + docker socket proxy
code-server/             # code-server + its tailscale sidecar
files/                   # filebrowser + its tailscale sidecar
samba/                   # SMB + Time Machine (LAN, host networking)
scripts/                 # bootstrap, secrets, backup/restore, tm-usage
.env.sops                # encrypted secrets (the only copy in git)
.sops.yaml               # sops config: age public key
renovate.json            # automated image-update PRs
```

Each HTTP service follows the same pattern: the app container (no published ports) plus a `tailscale/tailscale` sidecar whose `serve.json` (in git) proxies HTTPS 443 to the app over the Docker network. The sidecar's `hostname:` is the service's tailnet name.

## Prerequisites

- A cloud VM or home PC running Ubuntu/Debian or Fedora.
- A Tailscale account and a **reusable, non-ephemeral** auth key from the [admin console](https://login.tailscale.com/admin/settings/keys) (one key is shared by the gateway and all sidecars). MagicDNS and HTTPS certificates must be enabled for the tailnet (Admin console → DNS).
- A Backblaze B2 bucket and application key (for backups).
- `git`, `restic` (backups), `age` + `sops` (secrets — installed by bootstrap if missing).

## First run

```bash
git clone https://github.com/shengjiex98/home-server /opt/stacks
cd /opt/stacks
sudo ./scripts/bootstrap.sh
```

Then set up secrets — one of:

- **Fresh setup (no existing age key):**

  ```bash
  mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/keys.txt
  # put the printed public key into .sops.yaml, then:
  cp .env.example .env && nano .env       # fill in all secrets
  chmod 600 .env
  ./scripts/secrets.sh encrypt            # writes .env.sops; commit it
  ```

  **Back up `~/.config/sops/age/keys.txt` to your password manager now.** It is the single key that unlocks every secret in this repo.

- **Migrating (age key exists):**

  ```bash
  # restore the age key from your password manager to ~/.config/sops/age/keys.txt
  ./scripts/secrets.sh decrypt            # recreates .env from .env.sops
  nano .env                               # regenerate TS_AUTHKEY; update TS_HOSTNAME if desired
  ./scripts/secrets.sh encrypt            # keep .env.sops in sync
  ```

Then bring the stack up:

```bash
docker compose up -d
docker exec tailscale tailscale status   # approve nodes in the admin console if needed
sudo apt install restic || sudo dnf install restic
./scripts/restic-backup.sh               # first backup + repo init
sudo ./scripts/install-restic-timer.sh   # automate daily
```

Four nodes join the tailnet: the gateway (`TS_HOSTNAME`), `code`, and `files` (plus future service sidecars). Sidecar state persists under `/srv/ts-*`, so the auth key is only needed on each node's first start.

## Editing secrets later

```bash
./scripts/secrets.sh edit      # opens the encrypted file in $EDITOR
./scripts/secrets.sh decrypt   # refresh the plaintext .env the stack reads
docker compose up -d           # re-create anything whose env changed
```

Commit `.env.sops` after changes. The plaintext `.env` is gitignored and exists only on the server.

## SMB and Time Machine (LAN)

One container ([servercontainers/samba](https://github.com/ServerContainers/samba)) provides the general `Files` share, the `TimeMachine` share, and Avahi/mDNS so Macs discover the server automatically. It was chosen over a dedicated Time Machine image (e.g. `mbentley/timemachine`) because it covers both roles in a single actively-maintained container configured entirely through environment variables — a TM-only image would have required a second SMB container.

- Finder: `smb://<server>` — authenticate as `jerry` with `SMB_PASSWORD`.
- Time Machine: connect in Finder once, then **System Settings → General → Time Machine → Add Backup Disk** and select `TimeMachine`. Both Macs back up to the same share; each gets its own `<MacName>.sparsebundle`.
- Per-Mac disk usage: `sudo ./scripts/tm-usage.sh`

SMB is LAN-only by design: Finder browsing over WAN latency is slow (per-file metadata round trips) and roaming laptops handle dropped SMB mounts poorly. For remote file access use the FileBrowser URL instead — same data, one HTTP request per action.

## Updating images (Renovate)

All images are pinned to exact versions. To get automated update PRs, install the [Renovate GitHub App](https://github.com/apps/renovate) on this repository; `renovate.json` is already configured (it understands the compose files, including samba's `a<alpine>-s<samba>` tag scheme). Apply an update with:

```bash
git pull && docker compose up -d
```

## Adding a new HTTP service

Copy the pattern from `files/`: create `<name>/compose.yml` with the app container (data under `/srv/<name>`, `:Z` suffix) plus a tailscale sidecar (`hostname: <name>`, state under `/srv/ts-<name>`) and a `serve.json` proxying to the app's port. Add the file to the top-level `compose.yml` `include:` list and an entry to `gateway/homepage/services.yaml`. `/srv` is already covered by restic, so backups follow automatically.

> [!NOTE]
> Services with a database (e.g. Immich's Postgres) additionally need a pre-backup dump step before restic runs — file-level copies of a running database are not crash-safe.

## Claude Code and Codex in code-server

Install Claude Code / Codex extensions from the Open VSX registry via code-server's Extensions view, or use the CLIs from the integrated terminal:

```bash
npm i -g @anthropic-ai/claude-code
claude
```

## Migrate to another machine

```bash
git clone https://github.com/shengjiex98/home-server /opt/stacks
cd /opt/stacks
sudo ./scripts/bootstrap.sh
# restore age key, then:
./scripts/secrets.sh decrypt
nano .env && ./scripts/secrets.sh encrypt   # fresh TS_AUTHKEY; same B2/restic creds
sudo ./scripts/restic-restore.sh            # pulls /srv data down from B2
docker compose up -d
```

The only things that move outside git are the age key (password manager) and the `/srv` data (restic). Tailscale URLs stay the same for the sidecar services (`code`, `files`); the gateway's URL follows `TS_HOSTNAME`.

> [!CAUTION]
> **CRITICAL WARNINGS**
>
> - Back up the **age key** (`~/.config/sops/age/keys.txt`) and **`RESTIC_PASSWORD`** off the server, e.g. in a password manager. Losing them makes the encrypted secrets / backups unrecoverable.
> - Never commit the plaintext `.env`.
> - Keep all HTTP services tailnet-only; do not publish ports or run `tailscale funnel` on them without thinking through auth.
> - Test a restore once before trusting the backups:
>
>   ```bash
>   ./scripts/restic-restore.sh latest /tmp/restore-test
>   ```

## Backblaze B2 egress

Restoring all of `/srv` downloads all backed-up data. B2 egress is inexpensive but still scales with data volume, so keep the cloud phase lean and do not park a large photo archive there unless you have accounted for its restore cost and time.
