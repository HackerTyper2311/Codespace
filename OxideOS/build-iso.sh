#!/bin/bash
# build-iso.sh — Build OxideOS Live ISO
#
# Prerequisites (Debian/Ubuntu host with root):
#   apt install debootstrap squashfs-tools xorriso dosfstools isolinux syslinux-common grub-pc-bin grub-efi-amd64-bin mtools systemd-container
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
    iproute2 iputils-ping
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
# Ensure target directories exist
mkdir -p /etc/systemd/system/multi-user.target.wants
mkdir -p /etc/systemd/system/sockets.target.wants

# Enable oxide-syncd boot service (direct symlink — safer than systemctl in chroot)
ln -sf /etc/systemd/system/oxide-syncd.service \
  /etc/systemd/system/multi-user.target.wants/oxide-syncd.service

# Enable networkd and resolved (direct symlinks)
ln -sf /lib/systemd/system/systemd-networkd.service \
  /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
ln -sf /lib/systemd/system/systemd-resolved.service \
  /etc/systemd/system/multi-user.target.wants/systemd-resolved.service

# Enable SSH
ln -sf /lib/systemd/system/ssh.service \
  /etc/systemd/system/multi-user.target.wants/ssh.service

# Set root password (unlocked in live ISO)
passwd -d root

# Rebuild initramfs so live-boot hooks are included
update-initramfs -u -k all

# Clean up apt
apt clean
rm -rf /var/lib/apt/lists/*
ENDCHROOT

# ── Network config for systemd-networkd ───────────────────────
info "Configuring network (DHCP)..."

mkdir -p "${CHROOT_DIR}/etc/systemd/network"
cat > "${CHROOT_DIR}/etc/systemd/network/20-wired.network" <<'NETWORK'
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
NETWORK

# systemd-resolved needs this symlink
ln -sf /run/systemd/resolve/stub-resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

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

mkdir -p "${ISO_DIR}/live"

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

# ── Stage 8: Bootloader (ISOLINUX BIOS + GRUB UEFI) ────────────
info "Setting up ISOLINUX (BIOS) and GRUB (UEFI)..."

# 1. ISOLINUX for legacy BIOS boot
mkdir -p "${ISO_DIR}/isolinux"
cp /usr/lib/ISOLINUX/isolinux.bin "${ISO_DIR}/isolinux/"

# MBR for hybrid ISO (try multiple locations)
cp /usr/lib/ISOLINUX/isohdpfx.bin "${BUILD_DIR}/isohdpfx.bin" 2>/dev/null \
  || cp /usr/lib/syslinux/mbr/isohdpfx.bin "${BUILD_DIR}/isohdpfx.bin"

# COM32 modules needed by ISOLINUX 6.x (try multiple locations)
for mod in ldlinux.c32 libcom32.c32 libutil.c32; do
  cp "/usr/lib/ISOLINUX/$mod" "${ISO_DIR}/isolinux/" 2>/dev/null \
    || cp "/usr/lib/syslinux/modules/bios/$mod" "${ISO_DIR}/isolinux/" 2>/dev/null \
    || true
done

cat > "${ISO_DIR}/isolinux/isolinux.cfg" <<'ISOCFG'
DEFAULT live
TIMEOUT 50
PROMPT 1

LABEL live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components quiet splash

LABEL safemode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components nomodeset noapic
ISOCFG

# 2. GRUB for UEFI boot
mkdir -p "${ISO_DIR}/boot/grub"
mkdir -p "${ISO_DIR}/EFI/BOOT"

cat > "${ISO_DIR}/boot/grub/grub.cfg" <<'GRUBCFG'
set timeout=5
set default=0

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

# Embedded config for standalone GRUB EFI to find grub.cfg on ISO
cat > "${BUILD_DIR}/grub-embed.cfg" <<'EOF'
search --set=root --file /boot/grub/grub.cfg
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

# Build BOOTX64.EFI executable
grub-mkimage \
    -O x86_64-efi \
    -c "${BUILD_DIR}/grub-embed.cfg" \
    -o "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" \
    -p /boot/grub \
    part_gpt part_msdos fat ext2 iso9660 search normal linux boot

# 3. FAT image for UEFI El Torito partition
dd if=/dev/zero of="${ISO_DIR}/boot/efiboot.img" bs=1M count=4 status=none
mkfs.fat -F 12 -n "EFI" "${ISO_DIR}/boot/efiboot.img"
mmd -i "${ISO_DIR}/boot/efiboot.img" ::/EFI
mmd -i "${ISO_DIR}/boot/efiboot.img" ::/EFI/BOOT
mcopy -i "${ISO_DIR}/boot/efiboot.img" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/

# ── Stage 9: Build ISO with xorriso ───────────────────────────
info "Assembling bootable hybrid ISO with xorriso..."

xorriso -as mkisofs \
    -iso-level 3 \
    -r -J -joliet-long \
    -full-iso9660-filenames \
    -volid "OXIDEOS" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-mbr "${BUILD_DIR}/isohdpfx.bin" \
    -eltorito-alt-boot \
    -e boot/efiboot.img \
    -no-emul-boot -isohybrid-gpt-basdat \
    -append_partition 2 0xef "${ISO_DIR}/boot/efiboot.img" \
    -output "${ISO_NAME}" \
    "${ISO_DIR}" \
    || err "xorriso failed"

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
