#!/usr/bin/env bash
###############################################################################
# Build a customised Ubuntu LXC template for Proxmox VE → packed as .tar.zst
#   – colourised output
#   – optional SSH-key injection
#   – template label (-t) and custom output name (-o)
#   – target cache directory (-c)
#   – nameserver (-n) or auto-detect from host's /etc/resolv.conf (fallback 8.8.8.8)
#   – installs: systemd-networkd iproute2 procps sssd (+ NSS/PAM) and enables
#     systemd-networkd & timesyncd inside the container
###############################################################################
set -Eeuo pipefail

# ─── colour helpers ──────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors) -ge 8 ]]; then
  RST=$(tput sgr0)  BLD=$(tput bold)
  RED=$(tput setaf 1) GRN=$(tput setaf 2) YLW=$(tput setaf 3) BLU=$(tput setaf 4)
else
  RST='' BLD='' RED='' GRN='' YLW='' BLU=''
fi

die()  { echo -e "${RED}[-]${RST} $*" >&2; exit 1; }
warn() { echo -e "${YLW}[!]${RST} $*"; }
log()  { echo -e "${GRN}[+]${RST} $*"; }

# ─── defaults ────────────────────────────────────────────────────────────────
UBUNTU_RELEASE="24.04"                          # e.g. 22.04, 24.04
TEMPLATE_NAME="cloud"
OUTFILE=""
SSH_KEY="${AUTH_KEY:-}"

# DNS: if empty we auto-detect from host /etc/resolv.conf; fallback to 8.8.8.8
DNS_SERVER=""

BASE_CACHE="/var/lib/vz/template/cache"         # ← Proxmox default
TARGET_CACHE=""                                  # via -c | auto-detect
GUESS_SHARED="/mnt/pve/shared/template/cache"
DEFAULT_TARGET="/var/lib/vz/template/cache"

WORKDIR="$(mktemp -d)"
DATESTAMP="$(date +%Y%m%d)"

cleanup() {
  for m in proc sys dev; do umount -lf "${WORKDIR}/rootfs/$m" 2>/dev/null || true; done
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

usage() {
  cat <<EOF
${BLD}Usage${RST}: $(basename "$0") [options]

  -r, --release <ver>     Ubuntu release (e.g. 22.04, 24.04) (default: ${UBUNTU_RELEASE})
  -t, --template <name>   Template name/label                 (default: ${TEMPLATE_NAME})
  -o, --output  <file>    Output filename                     (.tar.zst appended if missing)
  -k, --ssh-key <key>     Inject public key for root (or set \$AUTH_KEY)
  -n, --nameserver <ip>   DNS server to use inside chroot (default: auto → host → 8.8.8.8)
  -c, --cache-dir <dir>   Where to write the customised template
                          (default: $GUESS_SHARED if exists else $DEFAULT_TARGET)
  -h, --help              Show this help
EOF
  exit 0
}

# ─── helpers ─────────────────────────────────────────────────────────────────
choose_nameserver() {
  local ns=""
  if [[ -n "$DNS_SERVER" ]]; then
    ns="$DNS_SERVER"
  else
    # Prefer a global-looking nameserver from host's /etc/resolv.conf (skip loopbacks)
    if [[ -r /etc/resolv.conf ]]; then
      ns="$(awk '/^nameserver[ \t]+/ {print $2}' /etc/resolv.conf | \
            awk '!/^127\./ && !/^\[?::1\]?$/ {print; exit}')"
      # If nothing global found, take the first even if it's loopback (we'll override later)
      if [[ -z "$ns" ]]; then
        ns="$(awk '/^nameserver[ \t]+/ {print $2; exit}' /etc/resolv.conf || true)"
      fi
    fi
    # If still empty or loopback, fallback to 8.8.8.8
    if [[ -z "$ns" || "$ns" == 127.* || "$ns" == "::1" ]]; then
      ns="8.8.8.8"
    fi
  fi
  DNS_SERVER="$ns"
  log "Using nameserver: ${BLU}${DNS_SERVER}${RST}"
}

# ─── option parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--release)   UBUNTU_RELEASE="$2"; shift 2;;
    -t|--template)  TEMPLATE_NAME="$2"; shift 2;;
    -o|--output)    OUTFILE="$2"; shift 2;;
    -k|--ssh-key)   SSH_KEY="$2"; shift 2;;
    -n|--nameserver) DNS_SERVER="$2"; shift 2;;
    -c|--cache-dir) TARGET_CACHE="$2"; shift 2;;
    -h|--help)      usage;;
    *)              die "Unknown option: $1";;
  esac
done

# ─── decide target cache ─────────────────────────────────────────────────────
if [[ -z "$TARGET_CACHE" ]]; then
  if [[ -d "$GUESS_SHARED" ]]; then
    TARGET_CACHE="$GUESS_SHARED"
  else
    TARGET_CACHE="$DEFAULT_TARGET"
  fi
fi
[[ -d "$TARGET_CACHE" ]] || die "Target cache '$TARGET_CACHE' not found."

# ─── filename handling (.tar.zst) ────────────────────────────────────────────
if [[ -z "$OUTFILE" ]]; then
  OUTFILE="ubuntu-${UBUNTU_RELEASE}-${TEMPLATE_NAME}_${DATESTAMP}_amd64.tar.zst"
else
  if [[ "$OUTFILE" =~ \.tar\.xz$ ]]; then
    OUTFILE="${OUTFILE%.tar.xz}.tar.zst"
  elif [[ ! "$OUTFILE" =~ \.tar\.zst$ ]]; then
    OUTFILE="${OUTFILE}.tar.zst"
  fi
fi
OUTPATH="${TARGET_CACHE}/${OUTFILE}"

[[ -z "$SSH_KEY" ]] && warn "No SSH key provided – skipping key injection."

# Decide nameserver now (logs chosen value)
choose_nameserver

# ─── locate or download base template ────────────────────────────────────────
log "Refreshing template catalogue"
pveam update >/dev/null || warn "pveam update failed – relying on local files"

# Match both .tar.xz and .tar.zst variants
TEMPLATE_FILE="$(pveam available | awk -v r="$UBUNTU_RELEASE" '
  $2 ~ ("ubuntu-" r "-standard_.*_amd64\\.tar\\.(xz|zst)$") {print $2}' | sort -V | tail -n1)"
[[ -n "$TEMPLATE_FILE" ]] || die "Ubuntu $UBUNTU_RELEASE template not found."
log "Using template ${BLU}${TEMPLATE_FILE%_*}${RST} (Ubuntu ${UBUNTU_RELEASE})"

BASENAME="${TEMPLATE_FILE##*/}"

if   [[ -f "${BASE_CACHE}/${BASENAME}" ]]; then
  BASE_TAR="${BASE_CACHE}/${BASENAME}"
elif [[ -f "${TARGET_CACHE}/${BASENAME}" ]]; then
  BASE_TAR="${TARGET_CACHE}/${BASENAME}"
else
  pveam download local "${TEMPLATE_FILE}"
  BASE_TAR="${BASE_CACHE}/${BASENAME}"
fi

# ─── unpack base ─────────────────────────────────────────────────────────────
log "Unpacking base template"
mkdir -p "${WORKDIR}/rootfs"
case "$BASE_TAR" in
  *.tar.zst)
    command -v unzstd >/dev/null 2>&1 || die "unzstd not found; install zstd."
    unzstd -c -- "${BASE_TAR}" | tar -xpf - -C "${WORKDIR}/rootfs"
    ;;
  *.tar.xz)
    tar -xpf "${BASE_TAR}" -C "${WORKDIR}/rootfs"
    ;;
  *)
    die "Unsupported archive format: ${BASE_TAR##*.}"
    ;;
esac

# ─── helper script inside chroot ─────────────────────────────────────────────
cat > "${WORKDIR}/rootfs/update.sh" <<'EOS'
#!/usr/bin/env bash
set -xEeuo pipefail
export DEBIAN_FRONTEND=noninteractive
KEY="${KEY:-}"

# Make DNS work in chroot (caller provides stub resolv with a usable nameserver)
if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
  mkdir -p /etc
  # Only copy if /etc/resolv.conf does NOT already resolve to the stub
  if [[ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" != "/run/systemd/resolve/stub-resolv.conf" ]]; then
    # Avoid copying same inode; only if different content/target
    if ! cmp -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null; then
      cp -f /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
  fi
fi

apt-get update -y
apt-get dist-upgrade -y
apt-get install -y --no-install-recommends \
  systemd systemd-sysv systemd-timesyncd \
  iproute2 procps \
  sssd libnss-sss libpam-sss

systemctl enable systemd-networkd || true
systemctl enable systemd-timesyncd || true

# Minimal DHCP network if none exists
if ! ls /etc/systemd/network/*.network >/dev/null 2>&1; then
  mkdir -p /etc/systemd/network
  cat > /etc/systemd/network/20-container-default.network <<NET
[Match]
Name=eth0

[Network]
DHCP=yes
NET
fi

# SSH key for root (if provided)
if [[ -n "${KEY}" ]]; then
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  grep -qxF "${KEY}" /root/.ssh/authorized_keys || echo "${KEY}" >> /root/.ssh/authorized_keys
fi

apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Tame some noisy services in containers
systemctl mask systemd-udev-hwdb-update.service || true
systemctl mask systemd-udev-trigger.service || true

# Prefer socket-activated sshd (lighter in containers)
systemctl disable ssh.service >/dev/null 2>&1 || true
systemctl enable  ssh.socket >/dev/null 2>&1 || true

# if you don't remove this, the static configuration
# of proxmox will not be picked up.
rm -f /etc/systemd/network/20-container-default.network

# FIXME - disable seems not work
systemctl disable apparmor.service
systemctl disable postfix.service
systemctl disable systemd-resolved.service
systemctl disable cron.service
systemctl disable networkd-dispatcher.service
systemctl disable syslog
systemctl disable rsyslog.service

# apparmor
rm -f "/etc/systemd/system/sysinit.target.wants/apparmor.service"

# postfix
rm -f "/etc/systemd/system/multi-user.target.wants/postfix.service"

# systemd-resolved
rm -f "/etc/systemd/system/sysinit.target.wants/systemd-resolved.service"
rm -f "/etc/systemd/system/dbus-org.freedesktop.resolve1.service"

# cron
rm -f "/etc/systemd/system/multi-user.target.wants/cron.service"

#  networkd-dispatcher
rm -f "/etc/systemd/system/multi-user.target.wants/networkd-dispatcher.service"

# rsyslog
rm -f "/etc/systemd/system/multi-user.target.wants/rsyslog.service"
rm -f "/etc/systemd/system/syslog.service"

# At firstboot all systemd service which have the preset enabled,
# will be enabled again. Therefore any system disable <nanme> or
# deleting the created symlinks will fail. With changing the presets
# it works!

mkdir -p /etc/systemd/system-preset/
cat >/etc/systemd/system-preset/90-local.preset <<'EOF'
disable apparmor.service
disable postfix.service
disable systemd-resolved.service
disable cron.service
disable networkd-dispatcher.service
disable rsyslog.service
disable syslog.service
EOF

EOS
chmod +x "${WORKDIR}/rootfs/update.sh"

# DNS for chrooted apt: always provide a concrete nameserver (not 127.0.0.53)
mkdir -p  "${WORKDIR}/rootfs/run/systemd/resolve"
cat > "${WORKDIR}/rootfs/run/systemd/resolve/stub-resolv.conf" <<EOF
nameserver $DNS_SERVER
EOF

# ─── chroot execution ────────────────────────────────────────────────────────
for m in proc sys dev; do mount --bind "/$m" "${WORKDIR}/rootfs/$m"; done
log "Entering chroot to update & install packages"
chroot "${WORKDIR}/rootfs" /bin/bash -c "KEY='${SSH_KEY}' /update.sh"
rm -f "${WORKDIR}/rootfs/update.sh"
rm -rf "${WORKDIR}/rootfs/run/systemd"

for m in dev sys proc; do umount -lf "${WORKDIR}/rootfs/$m"; done

# ─── repack customised template as .tar.zst ──────────────────────────────────
command -v zstd >/dev/null 2>&1 || die "zstd not found; install zstd."
log "Packing template → ${BLU}${OUTFILE}${RST}"
[ -f "${OUTPATH}" ] && rm -f "${OUTPATH}"
tar --numeric-owner --xattrs -C "${WORKDIR}/rootfs" -c . | zstd -T0 -19 -q -o "${OUTPATH}"

log "Template ready at: ${BLU}${OUTPATH}${RST}"
cat <<EOF
${GRN}[+]${RST} Create with:
    pct create <CTID> local:vztmpl/${OUTFILE} --storage local --ostype ubuntu \\
        --ssh-public-keys /root/.ssh/id_ed25519.pub
EOF
