# Proxmox Custom LXC Template Builder 🛠️

This repository provides two Bash tools to **build customized LXC container templates** for [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment):

- `build-fedora-template.sh` → produces a **Fedora-based LXC template** (`.tar.xz`)
- `build-ubuntu-template.sh` → produces an **Ubuntu-based LXC template** (`.tar.zst`)

The scripts take the official Proxmox templates as a base, install additional utilities, adjust networking defaults, and apply a set of container-friendly systemd tweaks.  
The resulting archive can be dropped directly into Proxmox’s `vztmpl/` cache and used with `pct create`.

---

## ✨ Features

Both tools provide:

- **Colorized logging** for clear status and error messages  
- **Optional SSH key injection** (via `-k` or `$AUTH_KEY`) so you can log in immediately  
- **Automatic nameserver detection** (from host `/etc/resolv.conf`, with fallback to `8.8.8.8`)  
- **Custom template labels and output names** (`-t` / `-o`)  
- **Custom target cache directory** (`-c`) – defaults to `/var/lib/vz/template/cache` or a shared store if available  
- **Up-to-date base template fetch** via `pveam update` and `pveam download`  
- **System packages preinstalled**, including networking and management tools  
- **Systemd service adjustments** so containers boot cleanly under Proxmox

---

## 📦 What gets installed

### Fedora variant
- Uses `dnf` or `dnf5` automatically  
- Installs:
  - `systemd-networkd`
  - `iproute`
  - `procps-ng`
  - `sssd-client`
  - `iputils`
  - `openssh-server`
  - `python3`, `python3-libdnf5`
  - `vim`, `lsof`  
- Enables `systemd-networkd`  
- Configures **socket-activated SSH**  
- Masks/disables noisy or container-unfriendly services (`systemd-homed`, `systemd-resolved`, etc.)  
- Adds login banner with container IP address

### Ubuntu variant
- Works with Ubuntu `22.04` and `24.04` (defaults to `24.04`)  
- Installs:
  - `systemd`, `systemd-sysv`, `systemd-timesyncd`
  - `iproute2`
  - `procps`
  - `sssd`, `libnss-sss`, `libpam-sss`  
- Enables `systemd-networkd` and `systemd-timesyncd`  
- Provides minimal DHCP config (cleaned up before packaging)  
- Prefers **socket-activated SSH**  
- Disables/masks unnecessary services (`apparmor`, `postfix`, `cron`, `rsyslog`, `systemd-resolved`, etc.)

---

## 🚀 Usage

1. Run the script with your desired options. Example for Fedora:

   ```bash
   ./build-fedora-template.sh -r 42 -t cloud -k ~/.ssh/id_ed25519.pub
   ```

   Example for Ubuntu:

   ```bash
   ./build-ubuntu-template.sh -r 24.04 -t cloud -k ~/.ssh/id_ed25519.pub
   ```

2. When finished, the script outputs the location of the generated template archive, e.g.:

   ```
   /var/lib/vz/template/cache/ubuntu-24.04-cloud_20250908_amd64.tar.zst
   ```

3. Use it in Proxmox:

   ```bash
   pct create <CTID> local:vztmpl/ubuntu-24.04-cloud_20250908_amd64.tar.zst \
       --storage local --ostype ubuntu \
       --ssh-public-keys /root/.ssh/id_ed25519.pub
   ```

---

## ⚙️ Options

```
-r, --release <ver>     Distro release version (e.g. 42 for Fedora, 24.04 for Ubuntu)
-t, --template <name>   Template label/name (default: cloud)
-o, --output  <file>    Output filename (.tar.xz or .tar.zst auto-handled)
-k, --ssh-key <key>     Inject SSH public key for root (or set $AUTH_KEY)
-n, --nameserver <ip>   Custom DNS server (default: auto → host → 8.8.8.8)
-c, --cache-dir <dir>   Target cache directory (default: /var/lib/vz/template/cache)
-h, --help              Show usage
```

---

## 📝 Notes

- The scripts must be run on a Proxmox host (they use `pveam` and `pct` conventions).  
- Root privileges are required (to mount `/proc`, `/sys`, `/dev` into the chroot).  
- Resulting templates are tuned specifically for **LXC under Proxmox VE**.  
- Archives differ in compression:
  - Fedora → `.tar.xz`
  - Ubuntu → `.tar.zst`
