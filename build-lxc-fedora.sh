#!/usr/bin/env bash
###############################################################################
# Build a customised Fedora LXC template for Proxmox VE  (.tar.xz output)
#   – colourised output
#   – optional SSH-key injection
#   – dnf vs dnf5 autodetection
#   – template label (-t) and custom output name (-o)
#   – target cache directory (-c)
#   – nameserver (-n) or auto-detect from host's /etc/resolv.conf (fallback 8.8.8.8)
#   – installs: systemd-networkd iproute procps-ng sssd-client and enables
#     systemd-networkd inside the container
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
FEDORA_RELEASE=42
TEMPLATE_NAME="cloud"
OUTFILE=""
SSH_KEY="${AUTH_KEY:-}"

# DNS: if empty we auto-detect from host /etc/resolv.conf; fallback to 8.8.8.8
DNS_SERVER=""

BASE_CACHE="/var/lib/vz/template/cache"          # ← Proxmox default
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

  -r, --release <ver>     Fedora release          (default: ${FEDORA_RELEASE})
  -t, --template <name>   Template name/label     (default: ${TEMPLATE_NAME})
  -o, --output  <file>    Output filename         (.tar.xz appended if missing)
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
    # Try a global-looking nameserver from host's /etc/resolv.conf (skip loopbacks)
    if [[ -r /etc/resolv.conf ]]; then
      ns="$(awk '/^nameserver[ \t]+/ {print $2}' /etc/resolv.conf | \
            awk '!/^127\./ && !/^\[?::1\]?$/ {print; exit}')"
      # If none, try first nameserver (even if loopback)
      if [[ -z "$ns" ]]; then
        ns="$(awk '/^nameserver[ \t]+/ {print $2; exit}' /etc/resolv.conf || true)"
      fi
    fi
    # Fallback or loopback → use 8.8.8.8
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
    -r|--release)   FEDORA_RELEASE="$2"; shift 2;;
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

# ─── filename handling ───────────────────────────────────────────────────────
if [[ -z "$OUTFILE" ]]; then
  OUTFILE="fedora-${FEDORA_RELEASE}-${TEMPLATE_NAME}_${DATESTAMP}_amd64.tar.xz"
else
  [[ "$OUTFILE" =~ \.tar\.xz$ ]] || OUTFILE="${OUTFILE}.tar.xz"
fi
OUTPATH="${TARGET_CACHE}/${OUTFILE}"

[[ -z "$SSH_KEY" ]] && warn "No SSH key provided – skipping key injection."

# Decide nameserver now (logs chosen value)
choose_nameserver

# ─── locate or download base template ────────────────────────────────────────
log "Refreshing template catalogue"
pveam update >/dev/null || warn "pveam update failed – relying on local files"

TEMPLATE_FILE="$(pveam available | awk -v r="$FEDORA_RELEASE" '
  $2 ~ ("fedora-" r "-default_.*_amd64.tar.xz$") {print $2}' | sort -V | tail -n1)"
[[ -n "$TEMPLATE_FILE" ]] || die "Fedora $FEDORA_RELEASE template not found."
log "Using template ${BLU}${TEMPLATE_FILE%_*}${RST} (Fedora ${FEDORA_RELEASE})"

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
tar -xpf "${BASE_TAR}" -C "${WORKDIR}/rootfs"

# ─── helper script inside chroot ─────────────────────────────────────────────
cat >"${WORKDIR}/rootfs/update.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail

# determine package manager
auto_dnf() {
  if command -v dnf5 >/dev/null 2>&1; then echo "dnf5 -y"; else echo "dnf -y"; fi
}
DNF=$(auto_dnf)
SKIP=""
if [[ "$DNF" == "dnf5 -y" ]]; then
  : # dnf5 – no --skip-broken
else
  SKIP="--skip-broken"
fi

# Make DNS work in chroot (caller drops a stub with concrete nameserver)
if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
  mkdir -p /etc
  # Only copy if /etc/resolv.conf does NOT already resolve to the stub
  if [[ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" != "/run/systemd/resolve/stub-resolv.conf" ]]; then
    if ! cmp -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null; then
      cp -f /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
  fi
fi

# upgrade & required packages
$DNF upgrade $SKIP

# mandatory runtime packages
PKGS=(systemd-networkd iproute procps-ng sssd-client iputils openssh-server python3 python3-libdnf5 vim lsof)
$DNF install $SKIP "${PKGS[@]}"

# SSH key injection if provided
if [[ -n "${KEY:-}" ]]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
  grep -qxF "${KEY}" /root/.ssh/authorized_keys || echo "${KEY}" >> /root/.ssh/authorized_keys
fi

# enable networkd
systemctl enable systemd-networkd.service >/dev/null 2>&1 || true

# disable resolved, as /etc/resolv.conf will be overwritten by proxmox
systemctl mask systemd-resolved.service >/dev/null 2>&1 || true

# disable systemd-homed - otherwise prompt for username comes up
systemctl disable systemd-homed.service >/dev/null 2>&1 || true
systemctl mask systemd-homed.service >/dev/null 2>&1 || true

# Show ipv4 and ipv6 address before login
mkdir -p /etc/issue.d
cat > /etc/issue.d/22_clhm_eth0.issue <<'ISSUE'
eth0: \4{eth0} \6{eth0}
ISSUE

# Prefer socket-activated sshd (lighter in containers)
systemctl disable sshd.service >/dev/null 2>&1 || true
systemctl enable  sshd.socket >/dev/null 2>&1 || true

# systemctl seems not execture
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service


# At firstboot all systemd service which have the preset enabled,
# will be enabled again. Therefore any system disable <nanme> or
# deleting the created symlinks will fail. With changing the presets
# it works!

mkdir -p /etc/systemd/system-preset/
cat >/etc/systemd/system-preset/90-local.preset <<'EOF'
disable sshd.service
EOF

$DNF clean all
rm -rf /var/cache/{dnf,yum} /tmp/* /var/tmp/*
EOS
chmod +x "${WORKDIR}/rootfs/update.sh"

# Provide DNS for chrooted operations: always concrete nameserver (not 127.0.0.1/53)
mkdir -p "${WORKDIR}/rootfs/run/systemd/resolve"
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

# ─── repack customised template ──────────────────────────────────────────────
log "Packing template → ${BLU}${OUTFILE}${RST}"
tar --numeric-owner --xattrs -C "${WORKDIR}/rootfs" -c . | xz -T0 -9 > "${OUTPATH}"

log "Template ready at: ${BLU}${OUTPATH}${RST}"
cat <<EOF
${GRN}[+]${RST} Create with:
    pct create <CTID> local:vztmpl/${OUTFILE} --storage local --ostype fedora \\
        --ssh-public-keys /root/.ssh/id_ed25519.pub
EOF
