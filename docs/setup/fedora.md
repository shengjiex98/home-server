# Fedora host setup

OS-level setup for a Fedora machine that will run this stack — everything that happens *before* the README's "Setting up a server" section. Written from setting up `home` (S1: Ryzen 5 5600X, 32 GB, RTX 2060, 2 TB NVMe, Fedora 44 Workstation), which doubles as an HTPC/Steam/dev box; skip sections that don't apply to a pure server.

## 1. Install & first boot

- Fedora Workstation ISO via Fedora Media Writer. In the BIOS, enable Resizable BAR / Above 4G Decoding if present.
- Anaconda: default automatic partitioning (btrfs with `root` + `home` subvolumes). The `data` subvolume is created post-install — subvolumes share one pool, no sizing decisions needed.
- Create the admin user, then on first boot enable SSH and restore `~/.ssh` (check `authorized_keys` works **before** hardening):

  ```bash
  sudo systemctl enable --now sshd
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
    | sudo tee /etc/ssh/sshd_config.d/50-hardening.conf
  sudo sshd -t && sudo systemctl reload sshd
  ```

- If a coding agent (e.g. Claude Code) is driving the setup: its shell has no tty and cannot answer sudo password prompts. Grant temporary passwordless sudo and **remove it as the final step**:

  ```bash
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-agent-setup
  # ... later: sudo rm /etc/sudoers.d/99-agent-setup
  ```

## 2. System basics

```bash
sudo hostnamectl set-hostname <name>
sudo dnf upgrade --refresh -y     # slow on a fresh install; usually brings a new kernel
sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
                 https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf swap ffmpeg-free ffmpeg --allowerasing && sudo dnf group install multimedia
```

firewalld is the Fedora default (no ufw); ssh is allowed out of the box. The stack's `bootstrap.sh` opens what samba needs.

## 3. Storage: `/data` subvolume + `/srv` bind mount

Big files and all stack data live in a `data` subvolume that survives reinstalls (next reinstall: keep the btrfs volume, recreate only root/home):

```bash
sudo mount -o subvolid=5 /dev/nvme0n1p<btrfs-part> /mnt
sudo btrfs subvolume create /mnt/data
sudo umount /mnt
sudo mkdir /data
# fstab (copy UUID from the existing / line):
#   UUID=<uuid>  /data      btrfs  subvol=data,compress=zstd:1  0 0
#   /data/srv    /srv       none   bind                         0 0
sudo systemctl daemon-reload && sudo mount /data
sudo chown $USER:$USER /data
mkdir -p /data/srv /data/{SteamLibrary,datasets,media,docker-volumes}
chattr +C /data/docker-volumes    # no-CoW for heavy random writes
sudo mkdir -p /data/srv/timemachine && sudo chattr +C /data/srv/timemachine  # sparsebundles fragment badly on CoW
sudo mount /srv
```

`/srv` must be a **bind mount**, not a symlink: restic archives a symlink as a symlink, so backups of `/srv` would silently store a one-line link instead of the data.

## 4. NVIDIA driver — mind Secure Boot

```bash
sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda
```

**If Secure Boot is enabled, the akmod-built module is unsigned and the kernel refuses to load it** (`nvidia-smi` fails; `journalctl -k` shows "Loading of unsigned module is rejected"). Before rebooting, either disable Secure Boot in the BIOS, or sign the modules:

```bash
sudo kmodgenca -a
sudo mokutil --import /etc/pki/akmods/certs/public_key.der   # sets a one-time password
sudo akmods --force --rebuild
# reboot → blue MOK screen → Enroll MOK → enter that password
```

The kmod builds for the *newest installed* kernel, not the running one; check with
`modinfo -F version -k $(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1) nvidia`. Verify after reboot: `nvidia-smi`.

## 5. Docker + GPU containers

```bash
sudo dnf install docker docker-compose runc
sudo systemctl enable --now docker
sudo usermod -aG docker $USER      # takes effect at next login
```

- **`runc` must be installed explicitly**: Fedora's moby-engine only pulls in crun, and dockerd fails to start without runc (F44 finding). If docker hit its start limit before runc was installed: `sudo systemctl reset-failed docker`, then start it again.
- SELinux stays Enforcing; the stack's compose files carry the needed `:Z`/`label=disable` options.
- GPU containers:

  ```bash
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
    | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
  sudo dnf install nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
  docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi   # after the NVIDIA reboot
  ```

## 6. Host Tailscale (optional)

The stack's gateway container is the server's tailnet node. A *separate* host-level tailscale is only for SSH-ing to the actual host over the tailnet, and needs a distinct hostname:

```bash
sudo dnf config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
sudo dnf install tailscale && sudo systemctl enable --now tailscaled
sudo tailscale up --hostname=<host-name>   # interactive browser auth
```

If the name is taken by a stale node, tailscale silently joins as `<name>-1` — delete the old machine in the admin console and rename.

## 7. Desktop hosts: don't sleep through backups

GNOME idle-suspends even with active SSH/SMB sessions, which kills remote logins and aborts Time Machine backups mid-transfer. After cloning the stack, install the sleep inhibitor (see README "Desktop hosts: sleep inhibitor"):

```bash
sudo /opt/stacks/scripts/install-sleep-inhibitor.sh
```

## 8. HTPC / gaming / dev extras

- `sudo dnf install steam`, then in Steam → Settings → Storage add `/data/SteamLibrary` (GUI only).
- Flatpak apps: Fedora ships a *filtered* flathub remote that blocks most apps — `sudo flatpak remote-modify flathub --no-filter` first, then e.g. `sudo flatpak install -y flathub com.stremio.Stremio`.
- Dev: `sudo dnf install git gcc gcc-c++ make cmake python3-devel`; VS Code from the Microsoft repo (`rpm --import` needs the rpm lock — fails while a big dnf upgrade runs).

## 9. Deploy the stack

Continue with the README's "Setting up a server" (`bootstrap.sh`, age key, `secrets.sh decrypt <host>`, `docker compose up -d`, restic). Then remove the temporary NOPASSWD file and reboot.
