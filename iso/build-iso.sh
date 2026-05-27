#!/bin/bash
# 🦾 AnosOS ISO Builder v2 — Minimal, reliable
# Keeps what worked from v1.0.1, adds:
#   - Initrd with /init script
#   - Kernel modules for real hardware
#   - anos-install script
#   - APK package manager
set -euo pipefail

OUTPUT="${1:-anos-os-linux-amd64.iso}"
ARCH="${2:-amd64}"
ANOS_VERSION="${3:-v0.11.0}"
ROOTFS="/tmp/anos-rootfs"
ISO_LABEL="ANOS_OS"
ANOS_REPO="https://github.com/datnp1003/anos"
BINARY_ARCH="$ARCH"
[ "$ARCH" = "amd64" ] && BINARY_ARCH="x86_64"

DEFAULT_USER="anos"
DEFAULT_PASS="anos"
ROOT_PASS="root"

echo "🦾 AnosOS ISO Builder v2"
echo "  Anos:  $ANOS_VERSION  |  Arch: $ARCH  |  Output: $OUTPUT"
echo ""

sudo rm -rf "$ROOTFS" 2>/dev/null || rm -rf "$ROOTFS" 2>/dev/null || true
mkdir -p "$ROOTFS"/{bin,sbin,boot,dev,etc/init.d,home/anos,opt/anos/{config,skills},proc,run,sys,tmp,usr/bin,var/log,media/cdrom,mnt,root}

DOWNLOAD_DIR="/tmp/anos-dl-$$"
mkdir -p "$DOWNLOAD_DIR"

# ── 1. Download Anos binaries ──
echo "📦 [1/6] Downloading Anos $ANOS_VERSION..."
DL_BASE="$ANOS_REPO/releases/download/$ANOS_VERSION"
curl -fsSL "$DL_BASE/anosd-linux-$BINARY_ARCH" -o "$DOWNLOAD_DIR/anosd" || curl -fsSL "$DL_BASE/anosd" -o "$DOWNLOAD_DIR/anosd"
curl -fsSL "$DL_BASE/anos-cli-linux-$BINARY_ARCH" -o "$DOWNLOAD_DIR/anos-cli" || curl -fsSL "$DL_BASE/anos-cli" -o "$DOWNLOAD_DIR/anos-cli"
chmod +x "$DOWNLOAD_DIR/anosd" "$DOWNLOAD_DIR/anos-cli"
cp "$DOWNLOAD_DIR/anosd" "$ROOTFS/usr/bin/"
cp "$DOWNLOAD_DIR/anos-cli" "$ROOTFS/usr/bin/"

# Clone repo for skills + prompt
git clone --depth 1 "$ANOS_REPO.git" "$DOWNLOAD_DIR/repo" 2>/dev/null || true
if [ -d "$DOWNLOAD_DIR/repo" ]; then
    cp "$DOWNLOAD_DIR/repo/ANOS-SYSTEM-PROMPT.md" "$ROOTFS/opt/anos/" 2>/dev/null || true
    cp -r "$DOWNLOAD_DIR/repo/skills"/* "$ROOTFS/opt/anos/skills/" 2>/dev/null || true
fi

# ── 2. Busybox + base config ──
echo "📦 [2/6] Setting up busybox..."
BUSYBOX_SRC=""
for bb in /bin/busybox-static /usr/bin/busybox-static /bin/busybox /usr/bin/busybox "$(command -v busybox 2>/dev/null)"; do
    [ -f "$bb" ] && BUSYBOX_SRC="$bb" && break
done
if [ -z "$BUSYBOX_SRC" ]; then
    curl -fsSL "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -o "$ROOTFS/bin/busybox"
else
    cp "$BUSYBOX_SRC" "$ROOTFS/bin/busybox"
fi
chmod +x "$ROOTFS/bin/busybox"
"$ROOTFS/bin/busybox" --install -s "$ROOTFS/bin/" 2>/dev/null || true
for u in sh mount umount cat ls echo getty login passwd su adduser addgroup modprobe \
    insmod rmmod switch_root reboot poweroff sync dd sleep grep find mknod cp mv \
    ln mkdir rmdir rm chmod chown df du ps kill yes head tail wc clear tty id whoami \
    mountpoint blkid; do
    [ -e "$ROOTFS/bin/$u" ] || ln -sf /bin/busybox "$ROOTFS/bin/$u" 2>/dev/null || true
done
mkdir -p "$ROOTFS/sbin"
for u in getty login init reboot poweroff switch_root; do
    [ -e "$ROOTFS/sbin/$u" ] || ln -sf /bin/busybox "$ROOTFS/sbin/$u" 2>/dev/null || true
done

# ── 3. Copy init scripts ──
echo "📦 [3/6] Copying init scripts..."
cp "$(dirname "$0")/../init/anos-init" "$ROOTFS/sbin/init"
cp "$(dirname "$0")/../init/anos-install" "$ROOTFS/usr/bin/anos-install"
cp "$(dirname "$0")/../init/initrd-init" "$ROOTFS/usr/bin/initrd-init"
chmod +x "$ROOTFS/sbin/init" "$ROOTFS/usr/bin/anos-install" "$ROOTFS/usr/bin/initrd-init"

# DHCP client
for dhcp in udhcpc dhclient; do
    for p in /usr/sbin/$dhcp /sbin/$dhcp /usr/bin/$dhcp; do
        [ -f "$p" ] && cp "$p" "$ROOTFS/usr/bin/" && break
    done 2>/dev/null || true
done

# APK package manager
echo "  📦 Adding APK..."
APK_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/${BINARY_ARCH}/apk-tools-static-2.14.6-r3.apk"
if curl -fsSL "$APK_URL" -o /tmp/apk-tools.apk 2>/dev/null; then
    tar xzf /tmp/apk-tools.apk -C /tmp/ sbin/apk.static 2>/dev/null || true
    if [ -f /tmp/sbin/apk.static ]; then
        cp /tmp/sbin/apk.static "$ROOTFS/usr/bin/apk"
        chmod +x "$ROOTFS/usr/bin/apk"
        mkdir -p "$ROOTFS/etc/apk/keys" "$ROOTFS/lib/apk/db" "$ROOTFS/var/cache/apk"
        touch "$ROOTFS/lib/apk/db/installed"
        cat > "$ROOTFS/etc/apk/repositories" << 'APKREPO'
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
APKREPO
        echo "    ✅ APK ready"
    fi
    rm -rf /tmp/apk-tools.apk /tmp/sbin
fi

# ── 4. Kernel + modules ──
echo "🐧 [4/6] Copying kernel + modules..."
KERNEL_VER=$(ls /lib/modules/ | grep -E 'generic|amd64|x86' | head -1 || ls /lib/modules/ | head -1)
echo "  Kernel: $KERNEL_VER"

MOD_DEST="$ROOTFS/lib/modules/$KERNEL_VER"
mkdir -p "$MOD_DEST/kernel/drivers"

# Copy essential modules
for cat in ata nvme virtio scsi "usb/storage" block; do
    [ -d "$MOD_DEST/kernel/drivers/$cat" ] || mkdir -p "$MOD_DEST/kernel/drivers/$cat"
    find "/lib/modules/$KERNEL_VER/kernel/drivers/$cat" -name "*.ko*" -exec cp {} "$MOD_DEST/kernel/drivers/$cat/" \; 2>/dev/null || true
done
for cat in ext2 ext4 vfat isofs squashfs overlayfs xfs btrfs; do
    mkdir -p "$MOD_DEST/kernel/fs/$cat"
    find "/lib/modules/$KERNEL_VER/kernel/fs/$cat" -name "*.ko*" -exec cp {} "$MOD_DEST/kernel/fs/$cat/" \; 2>/dev/null || true
done
cp "/lib/modules/$KERNEL_VER/modules.dep" "$MOD_DEST/" 2>/dev/null || true

# Kernel image
KERNEL_IMG=""
for k in /boot/vmlinuz /vmlinuz "/boot/vmlinuz-$KERNEL_VER"; do
    [ -f "$k" ] && [ -r "$k" ] && KERNEL_IMG="$k" && break
done
if [ -z "$KERNEL_IMG" ]; then
    echo "  ⚠️  No kernel found — using busybox fallback"
else
    cp "$KERNEL_IMG" "$ROOTFS/boot/vmlinuz"
    echo "  ✅ Kernel: $(basename "$KERNEL_IMG")"
fi

# Copy /lib/modules modules.alias, modules.builtin
for f in modules.alias modules.builtin modules.order; do
    cp "/lib/modules/$KERNEL_VER/$f" "$MOD_DEST/" 2>/dev/null || true
done

# ── 5. User accounts + system config ──
echo "⚙️ [5/6] Configuring system..."

ANOS_HASH=$(python3 -c "import crypt; print(crypt.crypt('$DEFAULT_PASS', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo '$6$lHWbbl2fteHvrMve$ifBVepML7plgqJVnqudt1SQLHMakyMv3norKFhLOQWEMUV6NHMZRUQSe68jvSF1/Fbii2/8AsrgnnAtFUVGBp1')
ROOT_HASH=$(python3 -c "import crypt; print(crypt.crypt('$ROOT_PASS', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo '$6$lHWbbl2fteHvrMve$ifBVepML7plgqJVnqudt1SQLHMakyMv3norKFhLOQWEMUV6NHMZRUQSe68jvSF1/Fbii2/8AsrgnnAtFUVGBp1')

cat > "$ROOTFS/etc/passwd" << PASSWD
root:x:0:0:root:/root:/bin/sh
anos:x:1000:1000:Anos AI User:/home/anos:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
PASSWD

cat > "$ROOTFS/etc/shadow" << SHADOW
root:${ROOT_HASH}:20000:0:99999:7:::
anos:${ANOS_HASH}:20000:0:99999:7:::
nobody:*:20000:0:99999:7:::
SHADOW

cat > "$ROOTFS/etc/group" << GROUP
root:x:0:
anos:x:1000:
nogroup:x:65534:
GROUP

chmod 644 "$ROOTFS/etc/passwd"
chmod 600 "$ROOTFS/etc/shadow"
chmod 644 "$ROOTFS/etc/group"

cat > "$ROOTFS/etc/profile" << 'PROFILE'
export PATH=/usr/bin:/bin:/sbin:/usr/sbin
export ANOS_DIR=/opt/anos
export ANOS_SOCKET=/tmp/anos.sock
if [ "$(tty)" = "/dev/tty1" ] && [ "$(whoami)" = "anos" ]; then
    clear 2>/dev/null || true
    echo "╔══════════════════════════════════════════════╗"
    echo "║       🦾 AnosOS — AI Native OS              ║"
    echo "╚══════════════════════════════════════════════╝"
    [ -S /tmp/anos.sock ] && exec /usr/bin/anos-cli || exec /bin/sh
fi
echo ""
echo "🦾 AnosOS v2.0"
echo "  anos-cli       AI Shell"
echo "  anos-install   Install to disk"
echo "  apk add <pkg>  Install packages"
echo ""
PROFILE

cat > "$ROOTFS/etc/issue" << 'ISSUE'

╔══════════════════════════════════════════════╗
║       🦾 AnosOS — AI Native OS               ║
║          v2.0 — \l                            ║
║──────────────────────────────────────────────║
║  Login:  anos / anos                         ║
║  Root:   root / root                         ║
║  anos-install → install to disk             ║
║  ⚠️  CHANGE PASSWORDS on first login!       ║
╚══════════════════════════════════════════════╝

ISSUE

cat > "$ROOTFS/etc/motd" << 'MOTD'
🦾 AnosOS v2.0 — AI Native OS

  anos-cli       Start AI shell
  anos-install   Install to hard disk
  apk add <pkg>  Install packages (htop curl nano docker...)
  exit           Log out

⚠️  Change passwords: passwd anos / passwd root
MOTD

echo "anos" > "$ROOTFS/etc/hostname"
echo "127.0.0.1 localhost anos" > "$ROOTFS/etc/hosts"

mkdir -p "$ROOTFS/etc/dropbear" "$ROOTFS/etc/profile.d"

# ── 6. Build initrd + ISO ──
echo "💿 [6/6] Building ISO..."

# Build initrd
INITRD_ROOT="/tmp/anos-initrd"
rm -rf "$INITRD_ROOT"
mkdir -p "$INITRD_ROOT"/{bin,sbin,lib/modules}

# /init script
cp "$(dirname "$0")/../init/initrd-init" "$INITRD_ROOT/init"
chmod +x "$INITRD_ROOT/init"

# Busybox in initrd
cp "$ROOTFS/bin/busybox" "$INITRD_ROOT/bin/busybox"
chmod +x "$INITRD_ROOT/bin/busybox"
for u in sh mount umount cat ls echo mkdir sleep insmod modprobe rmmod find grep mknod switch_root chroot cp ln dd sync reboot; do
    ln -sf /bin/busybox "$INITRD_ROOT/bin/$u" 2>/dev/null || true
done
ln -sf /bin/busybox "$INITRD_ROOT/sbin/switch_root" 2>/dev/null || true

# Kernel modules in initrd
cp -r "$ROOTFS/lib/modules/$KERNEL_VER" "$INITRD_ROOT/lib/modules/" 2>/dev/null || true

# Build squashfs
mkdir -p /tmp/anos-squash-root
cp -a "$ROOTFS"/* /tmp/anos-squash-root/ 2>/dev/null || true
mksquashfs /tmp/anos-squash-root /tmp/anos.squashfs -comp xz -noappend 2>&1 | tail -1

# Embed squashfs in initrd
cp /tmp/anos.squashfs "$INITRD_ROOT/anos.squashfs"
(cd "$INITRD_ROOT" && find . | cpio -o -H newc) > "$ROOTFS/boot/initrd.img"

# GRUB config
mkdir -p "$ROOTFS/boot/grub"
cat > "$ROOTFS/boot/grub/grub.cfg" << 'GRUB'
set timeout=5
set default=0
menuentry "🦾 AnosOS Live" {
    linux /boot/vmlinuz console=tty1 quiet
    initrd /boot/initrd.img
}
menuentry "AnosOS — Verbose" {
    linux /boot/vmlinuz console=tty1
    initrd /boot/initrd.img
}
menuentry "AnosOS — Rescue (root shell)" {
    linux /boot/vmlinuz console=tty1 init=/bin/sh
    initrd /boot/initrd.img
}
GRUB

# Build ISO (use whatever tool is available)
echo "  Building ISO..."
if command -v grub-mkrescue &>/dev/null; then
    grub-mkrescue -o "$OUTPUT" "$ROOTFS" \
        --modules="part_gpt fat iso9660 normal boot linux configfile search all_video" \
        --fonts="" 2>&1 | tail -3
elif command -v genisoimage &>/dev/null; then
    genisoimage -R -r -J -V "$ISO_LABEL" -o "$OUTPUT" \
        -b boot/grub/grub.cfg -no-emul-boot "$ROOTFS" 2>&1 | tail -3
elif command -v xorriso &>/dev/null; then
    xorriso -as mkisofs -R -r -J -V "$ISO_LABEL" -o "$OUTPUT" \
        -b boot/grub/grub.cfg -no-emul-boot "$ROOTFS" 2>&1 | tail -3
else
    echo "❌ No ISO tool available"
    exit 1
fi

# Cleanup function (runs on exit)
cleanup() {
    sudo rm -rf "$ROOTFS" "$INITRD_ROOT" /tmp/anos.squashfs /tmp/anos-squash-root "$DOWNLOAD_DIR" 2>/dev/null || true
}

echo ""
if [ -f "$OUTPUT" ]; then
    echo "✅ ISO built: $(ls -lh "$OUTPUT" | awk '{print $5}')"
    echo "   Test: qemu-system-x86_64 -cdrom $OUTPUT -m 2048"
else
    echo "❌ Build failed"
    exit 1
fi
