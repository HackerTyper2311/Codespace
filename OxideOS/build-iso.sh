#!/bin/bash
# build-iso.sh — Build OxideOS Live ISO
#
# Prerequisites (Debian/Ubuntu host with root):
#   apt install debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools systemd-container
#
# Usage:
#   sudo ./build-iso.sh
#
# Environment overrides:
#   OXIDE_DRIVE_ID   — Google Drive file ID for users.yaml (default from oxide-boot-sync)
#   OXIDE_ISO_NAME   — output ISO filename (default: oxideos-live-YYYYMMDD.iso)
#   OXIDE_VERSION    — version string (default: 0.1.0)

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
readonly DRIVE_ID="${OXIDE_DRIVE_ID:-1JywIYjQ94UIu9_-fQV0fEphtm_XGFRsk}"
readonly VERSION="${OXIDE_VERSION:-0.1.0}"
readonly ISO_NAME="${OXIDE_ISO_NAME:-oxideos-live-$(date +%Y%m%d).iso}"
readonly BUILD_DIR="$(pwd)/build"
readonly CHROOT_DIR="${BUILD_DIR}/chroot"
readonly ISO_DIR="${BUILD_DIR}/iso"
readonly DEBIAN_RELEASE="bookworm"
readonly ARCH="amd64"
readonly PACKAGES=(
    # Base system
    systemd systemd-sysv dbus
    # Shell & utils
    bash coreutils util-linux passwd adduser sudo
    apt ca-certificates curl wget
    # Network
    iproute2 iputils-ping netbase ifupdown
    systemd-resolved
    # Python runtime for oxide-syncd
    python3 python3-requests python3-yaml
    python3-pip
    # Boot
    linux-image-amd64
    live-boot
    # Optional: SSH for remote login
    openssh-server
)

# ── Colors ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
step()  { echo -e "${CYAN}[*]${NC} $*"; }
err()   { echo -e "${RED}[!]${NC} $*"; exit 1; }

# ── Sanity checks ──────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || err "Must run as root (sudo ./build-iso.sh)"
for cmd in debootstrap mksquashfs xorriso; do
    command -v "$cmd" >/dev/null 2>&1 || err "Missing required tool: $cmd"
done

step "OxideOS ${VERSION} Live ISO Builder"
step "Drive ID: ${DRIVE_ID:0:12}..."
step "Target: ${ISO_NAME}"

# ── Stage 1: Bootstrap Debian base ─────────────────────────────
info "Bootstrapping Debian ${DEBIAN_RELEASE} (${ARCH})..."
rm -rf "${CHROOT_DIR}" "${ISO_DIR}"
mkdir -p "${CHROOT_DIR}" "${ISO_DIR}"

debootstrap \
    --arch="${ARCH}" \
    --include="$(IFS=,; echo "${PACKAGES[*]}")" \
    --components=main,contrib,non-free-firmware \
    "${DEBIAN_RELEASE}" \
    "${CHROOT_DIR}" \
    http://deb.debian.org/debian \
    || err "debootstrap failed"

# ── Stage 2: Install oxide-syncd into chroot ────────────────────
info "Installing oxide-syncd into the rootfs..."

# Copy the daemon and boot script
cp -v oxide-syncd       "${CHROOT_DIR}/usr/local/bin/oxide-syncd"
cp -v oxide-boot-sync   "${CHROOT_DIR}/usr/local/sbin/oxide-boot-sync"
chmod +x "${CHROOT_DIR}/usr/local/bin/oxide-syncd"
chmod +x "${CHROOT_DIR}/usr/local/sbin/oxide-boot-sync"

# Embed the Drive ID into the boot script
sed -i "s/^DRIVE_ID=.*/DRIVE_ID=\"${DRIVE_ID}\"/" \
    "${CHROOT_DIR}/usr/local/sbin/oxide-boot-sync"

# Copy systemd unit
cp -v oxide-syncd.service "${CHROOT_DIR}/etc/systemd/system/oxide-syncd.service"

# ── Stage 3: Configure the live system ─────────────────────────
info "Configuring live system..."

# Hostname
echo "oxideos" > "${CHROOT_DIR}/etc/hostname"
cat > "${CHROOT_DIR}/etc/hosts" <<'HOSTS'
127.0.0.1   localhost
127.0.1.1   oxideos
::1         localhost ip6-localhost ip6-loopback
HOSTS

# /etc/issue (pre-login banner)
cat > "${CHROOT_DIR}/etc/issue" <<'ISSUE'
\S{ANSI_COLOR}   ██████╗ ██╗  ██╗██╗██████╗ ███████╗ ██████╗ ███████╗
  ██╔═══██╗╚██╗██╔╝██║██╔══██╗██╔════╝██╔═══██╗██╔════╝
  ██║   ██║ ╚███╔╝ ██║██║  ██║█████╗  ██║   ██║███████╗
  ██║   ██║ ██╔██╗ ██║██║  ██║██╔══╝  ██║   ██║╚════██║
  ╚██████╔╝██╔╝ ██╗██║██████╔╝███████╗╚██████╔╝███████║
   ╚═════╝ ╚═╝  ╚═╝╚═╝╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝\S{ANSI_RESET}

  Declarative OS — users synced from Google Drive
  Version: \s \m \r
  \d \t

\S{ANSI_COLOR}  Login with your Drive-defined credentials.\S{ANSI_RESET}

ISSUE

# /etc/motd (post-login banner)
cat > "${CHROOT_DIR}/etc/motd" <<'MOTD'
  Welcome to OxideOS!

  All users are managed declaratively via oxide-syncd.
  System state is derived from the Drive-hosted users.yaml.

  Drive file ID: DRIVE_ID_PLACEHOLDER

  To re-sync:  sudo oxide-syncd --drive-id <FILE_ID> --apply
MOTD

# /etc/fstab (live system uses overlay)
cat > "${CHROOT_DIR}/etc/fstab" <<'FSTAB'
proc    /proc    proc    defaults    0 0
sysfs   /sys     sysfs   defaults    0 0
tmpfs   /tmp     tmpfs   defaults,size=512M 0 0
FSTAB

# ── Stage 4: Enable services inside chroot ─────────────────────
info "Enabling systemd services..."

systemd-nspawn -D "${CHROOT_DIR}" --pipe /bin/bash <<'ENDCHROOT'
# Enable oxide-syncd boot service
systemctl enable oxide-syncd.service

# Enable network
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service

# Enable SSH (optional)
systemctl enable ssh.service

# Disable services not needed in live ISO
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# Install argon2-cffi via pip (not packaged for Debian)
pip3 install --break-system-packages argon2-cffi

# Set root password (locked by default in live ISO)
passwd -d root

# Rebuild initramfs so live-boot hooks are included
update-initramfs -u -k all

# Clean up
apt clean
rm -rf /var/lib/apt/lists/*
ENDCHROOT

# ── Stage 5: Live user (auto-login on tty1) ────────────────────
# Create a live user that auto-logs in — oxide-boot-sync will create
# the Drive-defined users alongside this one.
info "Configuring live user auto-login..."

# Override getty@tty1 to auto-login the live user
mkdir -p "${CHROOT_DIR}/etc/systemd/system/getty@tty1.service.d"
cat > "${CHROOT_DIR}/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<AUTOLOGIN
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
AUTOLOGIN

# ── Stage 6: Build squashfs ────────────────────────────────────
info "Building compressed rootfs (squashfs)..."

# Exclude transient/system mounts from the chroot before squashing
rm -rf "${CHROOT_DIR}/run/"*     2>/dev/null || true
rm -rf "${CHROOT_DIR}/tmp/"*     2>/dev/null || true
mkdir -p "${CHROOT_DIR}/run" "${CHROOT_DIR}/tmp"

mksquashfs "${CHROOT_DIR}" \
    "${ISO_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -noappend \
    -e boot \
    || err "mksquashfs failed"

du -sh "${ISO_DIR}/live/filesystem.squashfs"

# ── Stage 7: Set up kernel & initrd ────────────────────────────
info "Copying kernel and initrd..."

mkdir -p "${ISO_DIR}/live"
cp -v "${CHROOT_DIR}/boot/vmlinuz-"*     "${ISO_DIR}/live/vmlinuz"
cp -v "${CHROOT_DIR}/boot/initrd.img-"*   "${ISO_DIR}/live/initrd.img"

# ── Stage 8: GRUB bootloader ───────────────────────────────────
info "Setting up GRUB bootloader..."

mkdir -p "${ISO_DIR}/boot/grub"

cat > "${ISO_DIR}/boot/grub/grub.cfg" <<'GRUBCFG'
set timeout=5
set default=0
set gfxmode=auto
set gfxpayload=keep

insmod all_video
insmod gfxterm
insmod png
insmod part_gpt
insmod ext2

menuentry "OxideOS Live (Default)" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "OxideOS Live (Safe Mode)" {
    linux /live/vmlinuz boot=live components nomodeset noapic
    initrd /live/initrd.img
}

menuentry "OxideOS Live (No Sync)" {
    linux /live/vmlinuz boot=live components quiet oxide.nosync
    initrd /live/initrd.img
}

GRUBCFG

# ── Stage 9: Build ISO with grub-mkrescue ─────────────────────
info "Assembling bootable ISO with grub-mkrescue..."

command -v grub-mkrescue >/dev/null 2>&1 || err "Missing grub-mkrescue (apt install grub-pc-bin grub-efi-amd64-bin xorriso mtools)"

grub-mkrescue \
    -o "${ISO_NAME}" \
    --modules="part_gpt part_msdos ext2 all_video boot normal" \
    --compress=xz \
    "${ISO_DIR}" \
    || err "grub-mkrescue failed"

# ── Done ────────────────────────────────────────────────────────
echo
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  OxideOS Live ISO built successfully!            ║${NC}"
echo -e "${GREEN}║──────────────────────────────────────────────────║${NC}"
echo -e "${GREEN}║  ${ISO_NAME}${NC}"
echo -e "${GREEN}║  Size: $(du -sh "${ISO_NAME}" | cut -f1)${NC}"
echo -e "${GREEN}║──────────────────────────────────────────────────║${NC}"
echo -e "${GREEN}║  Boot the ISO and users will be provisioned      ║${NC}"
echo -e "${GREEN}║  from Google Drive automatically.               ║${NC}"
echo -e "${GREEN}║──────────────────────────────────────────────────║${NC}"
echo -e "${GREEN}║  Kernel cmdline options:                        ║${NC}"
echo -e "${GREEN}║    oxide.drive_id=...   (Drive file ID)         ║${NC}"
echo -e "${GREEN}║    oxide.raw_url=...    (direct HTTPS URL)      ║${NC}"
echo -e "${GREEN}║    oxide.nosync         (skip boot sync)        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo
echo "  Test with:  qemu-system-x86_64 -m 2G -cdrom ${ISO_NAME} -boot d"
echo
