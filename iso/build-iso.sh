#!/usr/bin/env bash
# 🦾 AnosOS ISO Builder — Standard Linux Distro Build Process
# Base: Ubuntu Jammy (22.04) via debootstrap
# Output: BIOS+UEFI bootable live ISO with SquashFS + standard initramfs
set -euo pipefail

OUTPUT="${1:-anos-os-linux-amd64.iso}"
ARCH="${2:-amd64}"
ANOS_VERSION="${3:-v0.11.0}"

DISTRO="jammy"
MIRROR="http://archive.ubuntu.com/ubuntu/"
WORK="/tmp/anos-build"
ROOTFS="$WORK/rootfs"
ISO="$WORK/iso"
SQUASHFS="$ISO/casper/filesystem.squashfs"
ANOS_REPO="https://github.com/datnp1003/anos"
BINARY_ARCH="x86_64"
[ "$ARCH" = "arm64" ] && BINARY_ARCH="arm64"

LABEL="ANOS_OS"
HOSTNAME="anos"
DEFAULT_USER="anos"
DEFAULT_PASS="anos"
ROOT_PASS="root"

log() { echo -e "\n\033[1;36m$*\033[0m"; }
run_chroot() { sudo chroot "$ROOTFS" /bin/bash -lc "$*"; }

cleanup_mounts() {
  set +e
  for m in dev/pts dev proc sys run; do
    sudo umount -lf "$ROOTFS/$m" 2>/dev/null || true
  done
}
trap cleanup_mounts EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1"; exit 1; }
}

log "🦾 AnosOS ISO Builder"
echo "  Base: Ubuntu $DISTRO"
echo "  Anos: $ANOS_VERSION"
echo "  Arch: $ARCH ($BINARY_ARCH)"
echo "  Output: $OUTPUT"

for cmd in debootstrap mksquashfs xorriso grub-mkstandalone mformat mcopy curl git; do
  require "$cmd"
done

log "[1/9] Clean workspace"
sudo rm -rf "$WORK"
mkdir -p "$ROOTFS" "$ISO"/{casper,boot/grub,EFI/BOOT}

log "[2/9] Bootstrap Ubuntu rootfs"
sudo debootstrap --arch="$ARCH" --variant=minbase "$DISTRO" "$ROOTFS" "$MIRROR"

log "[3/9] Mount virtual filesystems"
sudo mount --bind /dev "$ROOTFS/dev"
sudo mount -t devpts devpts "$ROOTFS/dev/pts"
sudo mount -t proc proc "$ROOTFS/proc"
sudo mount -t sysfs sysfs "$ROOTFS/sys"
sudo mount -t tmpfs tmpfs "$ROOTFS/run"

log "[4/9] Configure APT sources"
sudo tee "$ROOTFS/etc/apt/sources.list" >/dev/null <<EOF
deb http://archive.ubuntu.com/ubuntu $DISTRO main universe multiverse restricted
deb http://archive.ubuntu.com/ubuntu $DISTRO-updates main universe multiverse restricted
deb http://security.ubuntu.com/ubuntu $DISTRO-security main universe multiverse restricted
EOF

log "[5/9] Install kernel + base system packages"
run_chroot "apt-get update"
DEBIAN_FRONTEND=noninteractive run_chroot "apt-get install -y --no-install-recommends \
  linux-image-generic \
  linux-firmware \
  systemd \
  systemd-sysv \
  dbus \
  sudo \
  network-manager \
  net-tools \
  iproute2 \
  iputils-ping \
  openssh-server \
  ca-certificates \
  curl \
  wget \
  git \
  vim \
  nano \
  htop \
  less \
  bash-completion \
  locales \
  tzdata \
  grub-pc-bin \
  grub-efi-amd64-bin \
  casper \
  squashfs-tools \
  initramfs-tools"

log "[6/9] Configure system"
sudo tee "$ROOTFS/etc/hostname" >/dev/null <<< "$HOSTNAME"
sudo tee "$ROOTFS/etc/hosts" >/dev/null <<EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
::1       localhost ip6-localhost ip6-loopback
EOF

# Locale/timezone
run_chroot "locale-gen en_US.UTF-8 || true"
run_chroot "update-locale LANG=en_US.UTF-8"
run_chroot "ln -sf /usr/share/zoneinfo/UTC /etc/localtime"

# Users
run_chroot "echo 'root:$ROOT_PASS' | chpasswd"
run_chroot "useradd -m -s /bin/bash $DEFAULT_USER || true"
run_chroot "echo '$DEFAULT_USER:$DEFAULT_PASS' | chpasswd"
run_chroot "usermod -aG sudo $DEFAULT_USER"

# Sudo no password for live user
sudo mkdir -p "$ROOTFS/etc/sudoers.d"
sudo tee "$ROOTFS/etc/sudoers.d/90-anos" >/dev/null <<EOF
$DEFAULT_USER ALL=(ALL) NOPASSWD:ALL
EOF
sudo chmod 440 "$ROOTFS/etc/sudoers.d/90-anos"

# os-release branding
sudo tee "$ROOTFS/etc/os-release" >/dev/null <<EOF
NAME="AnosOS"
VERSION="1.0.2"
ID=anos
ID_LIKE=ubuntu
PRETTY_NAME="AnosOS 1.0.2 (Ubuntu $DISTRO base)"
VERSION_ID="1.0.2"
HOME_URL="https://github.com/datnp1003/anos-os"
EOF

# Enable services
run_chroot "systemctl enable NetworkManager || true"
run_chroot "systemctl enable ssh || true"

log "[7/9] Install Anos binaries + service"
TMPDL="$WORK/download"
mkdir -p "$TMPDL"
BASE="$ANOS_REPO/releases/download/$ANOS_VERSION"
curl -fsSL "$BASE/anosd-linux-$BINARY_ARCH" -o "$TMPDL/anosd"
curl -fsSL "$BASE/anos-cli-linux-$BINARY_ARCH" -o "$TMPDL/anos-cli"
chmod +x "$TMPDL/anosd" "$TMPDL/anos-cli"
sudo install -m 0755 "$TMPDL/anosd" "$ROOTFS/usr/local/bin/anosd"
sudo install -m 0755 "$TMPDL/anos-cli" "$ROOTFS/usr/local/bin/anos-cli"
sudo ln -sf /usr/local/bin/anos-cli "$ROOTFS/usr/bin/anos-cli"
sudo ln -sf /usr/local/bin/anosd "$ROOTFS/usr/bin/anosd"

# Skills + prompt
git clone --depth 1 "$ANOS_REPO.git" "$TMPDL/repo" 2>/dev/null || true
sudo mkdir -p "$ROOTFS/opt/anos/skills" "$ROOTFS/opt/anos/config"
[ -f "$TMPDL/repo/ANOS-SYSTEM-PROMPT.md" ] && sudo cp "$TMPDL/repo/ANOS-SYSTEM-PROMPT.md" "$ROOTFS/opt/anos/" || true
[ -d "$TMPDL/repo/skills" ] && sudo cp -r "$TMPDL/repo/skills"/* "$ROOTFS/opt/anos/skills/" || true

# anosd systemd service
sudo tee "$ROOTFS/etc/systemd/system/anosd.service" >/dev/null <<'EOF'
[Unit]
Description=Anos AI OS Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=ANOS_DIR=/opt/anos
Environment=ANOS_SOCKET=/run/anos.sock
ExecStart=/usr/local/bin/anosd
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
run_chroot "systemctl enable anosd || true"

# auto-login tty1 as anos, then start anos-cli
sudo mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
sudo tee "$ROOTFS/etc/systemd/system/getty@tty1.service.d/override.conf" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $DEFAULT_USER --noclear %I \$TERM
EOF

sudo tee "$ROOTFS/home/$DEFAULT_USER/.bash_profile" >/dev/null <<'EOF'
if [ "$(tty)" = "/dev/tty1" ]; then
  echo ""
  echo "🦾 Welcome to AnosOS"
  echo "Type 'anos-cli' for AI shell, or use normal Ubuntu commands."
  echo ""
fi
EOF
sudo chown "$DEFAULT_USER:$DEFAULT_USER" "$ROOTFS/home/$DEFAULT_USER/.bash_profile"

log "[8/9] Cleanup + generate initramfs"
run_chroot "apt-get clean"
sudo rm -rf "$ROOTFS/tmp"/* "$ROOTFS/var/tmp"/* "$ROOTFS/var/lib/apt/lists"/*

# Ensure initramfs generated
KVER=$(basename "$(ls "$ROOTFS/boot/vmlinuz-"* | sort -V | tail -1 | sed 's#^.*/vmlinuz-##')")
echo "  Kernel version: $KVER"
run_chroot "update-initramfs -c -k $KVER || update-initramfs -u -k $KVER"

log "[9/9] Build SquashFS + ISO"
cleanup_mounts
trap - EXIT

# Copy kernel/initrd
KERNEL_FILE=$(ls "$ROOTFS/boot/vmlinuz-"* | sort -V | tail -1)
INITRD_FILE=$(ls "$ROOTFS/boot/initrd.img-"* | sort -V | tail -1)
sudo cp "$KERNEL_FILE" "$ISO/casper/vmlinuz"
sudo cp "$INITRD_FILE" "$ISO/casper/initrd"

# Create squashfs
sudo mksquashfs "$ROOTFS" "$SQUASHFS" -comp xz -noappend -e boot

# filesystem.size
sudo du -sx --block-size=1 "$ROOTFS" | cut -f1 | sudo tee "$ISO/casper/filesystem.size" >/dev/null

# Minimal manifest
run_chroot "dpkg-query -W --showformat='\${Package} \${Version}\n'" | sudo tee "$ISO/casper/filesystem.manifest" >/dev/null || true

# GRUB config
cat > "$ISO/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

menuentry "🦾 AnosOS Live" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "AnosOS Live (verbose)" {
    linux /casper/vmlinuz boot=casper ---
    initrd /casper/initrd
}

menuentry "AnosOS Rescue" {
    linux /casper/vmlinuz boot=casper single ---
    initrd /casper/initrd
}
EOF

# BIOS GRUB image
mkdir -p "$ISO/boot/grub/i386-pc"
grub-mkstandalone \
  --format=i386-pc \
  --output="$ISO/boot/grub/i386-pc/eltorito.img" \
  --install-modules="linux normal iso9660 biosdisk memdisk search tar ls" \
  --modules="linux normal iso9660 biosdisk search" \
  --locales="" \
  --fonts="" \
  "boot/grub/grub.cfg=$ISO/boot/grub/grub.cfg"

# UEFI GRUB image
mkdir -p "$ISO/EFI/BOOT"
grub-mkstandalone \
  --format=x86_64-efi \
  --output="$ISO/EFI/BOOT/BOOTX64.EFI" \
  --install-modules="linux normal iso9660 search echo all_video gfxterm" \
  --modules="linux normal iso9660 search all_video" \
  --locales="" \
  --fonts="" \
  "boot/grub/grub.cfg=$ISO/boot/grub/grub.cfg"

# EFI image
EFI_IMG="$WORK/efiboot.img"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=10 status=none
mkfs.vfat "$EFI_IMG" >/dev/null
mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$ISO/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/

# Build hybrid ISO
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "$LABEL" \
  -eltorito-boot boot/grub/i386-pc/eltorito.img \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --eltorito-catalog boot/grub/boot.cat \
  --grub2-boot-info \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  -eltorito-alt-boot \
  -e "$(basename "$EFI_IMG")" \
  -no-emul-boot \
  -append_partition 2 0xef "$EFI_IMG" \
  -output "$OUTPUT" \
  "$ISO"

# ISO checksum
sha256sum "$OUTPUT" > "$OUTPUT.sha256"

log "✅ Build complete"
ls -lh "$OUTPUT" "$OUTPUT.sha256"
echo "Test: qemu-system-x86_64 -m 4096 -cdrom $OUTPUT"
