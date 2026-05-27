#!/bin/bash
# 🦾 AnosOS ISO Builder v2
# Approach: ISO9660 as rootfs (kernel mounts CD directly - no initrd/squashfs needed)
# Based on working v1.0.1, adding: kernel modules, init scripts, GRUB config
set -euo pipefail

OUTPUT="${1:-anos-os-linux-amd64.iso}"
ARCH="${2:-amd64}"
ANOS_VERSION="${3:-}"
ROOTFS="/tmp/anos-rootfs"
ISO_LABEL="ANOS_OS"
ANOS_REPO="https://github.com/datnp1003/anos"
BINARY_ARCH="$ARCH"; [ "$ARCH" = "amd64" ] && BINARY_ARCH="x86_64"

get_latest_version() {
    curl -s "https://api.github.com/repos/datnp1003/anos/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\(.*\)".*/\1/' || echo "v0.11.0"
}

if [ -z "$ANOS_VERSION" ]; then
    ANOS_VERSION=$(get_latest_version)
    echo "🦾 Auto-detected Anos: $ANOS_VERSION"
fi

echo "🦾 AnosOS ISO Builder v2"
echo "  Anos: $ANOS_VERSION  Arch: $ARCH  Output: $OUTPUT"
echo ""

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{bin,sbin,boot,dev,etc,home/anos,opt/anos/{config,skills},proc,run,sys,tmp,usr/bin,var/log,media,mnt,root}

DOWNLOAD_DIR="/tmp/anos-dl-$$"; mkdir -p "$DOWNLOAD_DIR"

# ── 1. Anos binaries ──
echo "📦 [1/5] Downloading Anos $ANOS_VERSION..."
DL_BASE="$ANOS_REPO/releases/download/$ANOS_VERSION"
curl -fsSL "$DL_BASE/anosd-linux-$BINARY_ARCH" -o "$DOWNLOAD_DIR/anosd" || curl -fsSL "$DL_BASE/anosd" -o "$DOWNLOAD_DIR/anosd"
curl -fsSL "$DL_BASE/anos-cli-linux-$BINARY_ARCH" -o "$DOWNLOAD_DIR/anos-cli" || curl -fsSL "$DL_BASE/anos-cli" -o "$DOWNLOAD_DIR/anos-cli"
chmod +x "$DOWNLOAD_DIR/anosd" "$DOWNLOAD_DIR/anos-cli"
cp "$DOWNLOAD_DIR/anosd" "$ROOTFS/usr/bin/"
cp "$DOWNLOAD_DIR/anos-cli" "$ROOTFS/usr/bin/"

# Skills + prompt
git clone --depth 1 "$ANOS_REPO.git" "$DOWNLOAD_DIR/repo" 2>/dev/null || true
if [ -d "$DOWNLOAD_DIR/repo" ]; then
    cp "$DOWNLOAD_DIR/repo/ANOS-SYSTEM-PROMPT.md" "$ROOTFS/opt/anos/" 2>/dev/null || true
    cp -r "$DOWNLOAD_DIR/repo/skills"/* "$ROOTFS/opt/anos/skills/" 2>/dev/null || true
fi

# ── 2. Busybox ──
echo "📦 [2/5] Busybox..."
BB=""
for try in /bin/busybox-static /usr/bin/busybox-static /bin/busybox "$(command -v busybox 2>/dev/null)"; do
    [ -n "$try" ] && [ -f "$try" ] && BB="$try" && break
done
if [ -z "$BB" ]; then
    BB_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/${BINARY_ARCH}/busybox-static-1.37.0-r12.apk"
    curl -fsSL "$BB_URL" -o /tmp/bb.apk 2>/dev/null && tar xzf /tmp/bb.apk -C /tmp/ 2>/dev/null || true
    for f in /tmp/bin/busybox.static /tmp/busybox.static; do
        [ -f "$f" ] && cp "$f" "$ROOTFS/bin/busybox" && break
    done
    rm -rf /tmp/bb.apk /tmp/bin 2>/dev/null || true
    [ ! -f "$ROOTFS/bin/busybox" ] && {
        curl -fsSL "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -o "$ROOTFS/bin/busybox" 2>/dev/null || true
    }
else
    cp "$BB" "$ROOTFS/bin/busybox"
fi
chmod +x "$ROOTFS/bin/busybox"
"$ROOTFS/bin/busybox" --install -s "$ROOTFS/bin/" 2>/dev/null || true
mkdir -p "$ROOTFS/sbin"
for u in getty login init reboot poweroff; do
    ln -sf /bin/busybox "$ROOTFS/sbin/$u" 2>/dev/null || true
done

# DHCP
for dhcp in udhcpc dhclient; do
    for p in "/usr/sbin/$dhcp" "/sbin/$dhcp" "/usr/bin/$dhcp"; do
        [ -f "$p" ] && cp "$p" "$ROOTFS/usr/bin/" && break 2
    done
done 2>/dev/null || true

# ── 3. Init scripts ──
echo "📦 [3/5] Init scripts..."
cp "$(dirname "$0")/../init/anos-init" "$ROOTFS/sbin/init"
cp "$(dirname "$0")/../init/anos-install" "$ROOTFS/usr/bin/anos-install"
chmod +x "$ROOTFS/sbin/init" "$ROOTFS/usr/bin/anos-install"

# ── 4. Kernel + modules + users + config ──
echo "📦 [4/5] Kernel + modules + config..."

# Kernel
KERNEL=""
for k in /boot/vmlinuz /vmlinuz /boot/vmlinuz-*; do
    [ -f "$k" ] && [ -r "$k" ] && KERNEL="$k" && break
done
if [ -n "$KERNEL" ]; then
    cp "$KERNEL" "$ROOTFS/boot/vmlinuz"
    echo "  Kernel: $(basename "$KERNEL")"
fi

# Modules
KVER=$(ls /lib/modules/ | head -1)
if [ -n "$KVER" ] && [ -d "/lib/modules/$KVER" ]; then
    MOD_DEST="$ROOTFS/lib/modules/$KVER"
    mkdir -p "$MOD_DEST/kernel/drivers"
    for cat in ata nvme virtio scsi "usb/storage" block "net/ethernet/intel" "net/ethernet/realtek"; do
        mkdir -p "$MOD_DEST/kernel/drivers/$cat"
        find "/lib/modules/$KVER/kernel/drivers/$cat" -name "*.ko*" -exec cp {} "$MOD_DEST/kernel/drivers/$cat/" \; 2>/dev/null || true
    done
    for cat in ext2 ext4 vfat isofs squashfs overlayfs xfs btrfs; do
        mkdir -p "$MOD_DEST/kernel/fs/$cat"
        find "/lib/modules/$KVER/kernel/fs/$cat" -name "*.ko*" -exec cp {} "$MOD_DEST/kernel/fs/$cat/" \; 2>/dev/null || true
    done
    for f in modules.dep modules.alias modules.builtin modules.order; do
        cp "/lib/modules/$KVER/$f" "$MOD_DEST/" 2>/dev/null || true
    done
    echo "  Modules: $KVER"
fi

# Users
HASH='$6$lHWbbl2fteHvrMve$ifBVepML7plgqJVnqudt1SQLHMakyMv3norKFhLOQWEMUV6NHMZRUQSe68jvSF1/Fbii2/8AsrgnnAtFUVGBp1'
ANOS_HASH=$(python3 -c "import crypt; print(crypt.crypt('anos', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo "$HASH")
ROOT_HASH=$(python3 -c "import crypt; print(crypt.crypt('root', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo "$HASH")

cat > "$ROOTFS/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
daemon:x:1:1:daemon:/usr/sbin:/bin/false
bin:x:2:2:bin:/bin:/bin/false
sys:x:3:3:sys:/dev:/bin/false
sync:x:4:65534:sync:/bin:/bin/sync
anos:x:1000:1000:Anos AI User:/home/anos:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
EOF

cat > "$ROOTFS/etc/shadow" << EOF
root:${ROOT_HASH}:20000:0:99999:7:::
daemon:*:20000:0:99999:7:::
bin:*:20000:0:99999:7:::
sys:*:20000:0:99999:7:::
sync:*:20000:0:99999:7:::
anos:${ANOS_HASH}:20000:0:99999:7:::
nobody:*:20000:0:99999:7:::
EOF

cat > "$ROOTFS/etc/group" << EOF
root:x:0:
daemon:x:1:
bin:x:2:
sys:x:3:
admin:x:100:anos
anos:x:1000:
nogroup:x:65534:
EOF

chmod 644 "$ROOTFS/etc/passwd"; chmod 600 "$ROOTFS/etc/shadow"; chmod 644 "$ROOTFS/etc/group"

# Profile
cat > "$ROOTFS/etc/profile" << 'PROFILE'
export PATH=/usr/bin:/bin:/sbin:/usr/sbin
export ANOS_DIR=/opt/anos
export ANOS_SOCKET=/tmp/anos.sock
if [ "$(tty)" = "/dev/tty1" ] && [ "$(whoami)" = "anos" ]; then
    clear 2>/dev/null || true
    echo "╔══════════════════════════════════════════════╗"
    echo "║       🦾 AnosOS - AI Native OS              ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    [ -S /tmp/anos.sock ] && exec /usr/bin/anos-cli || exec /bin/sh
fi
echo ""
echo "🦾 AnosOS v2.0"
echo "  anos-cli       AI Shell"
echo "  anos-install   Install to disk"
echo ""
PROFILE

cat > "$ROOTFS/etc/issue" << 'ISSUE'

╔══════════════════════════════════════════════╗
║       🦾 AnosOS - AI Native OS               ║
║          v2.0 - \l                            ║
║──────────────────────────────────────────────║
║  Login:  anos / anos                         ║
║  Root:   root / root                         ║
║  anos-install → install to disk             ║
╚══════════════════════════════════════════════╝

ISSUE

echo "anos" > "$ROOTFS/etc/hostname"
echo "127.0.0.1 localhost anos" > "$ROOTFS/etc/hosts"

# ── 5. GRUB + initrd + ISO ──
echo "📀 [5/5] Building initrd + ISO..."

# Build minimal initrd (just /init + /bin/sh + kernel modules)
INITRD="/tmp/anos-initrd"
rm -rf "$INITRD"; mkdir -p "$INITRD"/{bin,lib/modules}

cp "$(dirname "$0")/../init/initrd-init" "$INITRD/init"
chmod +x "$INITRD/init"

# Only 1 busybox binary: as /bin/busybox AND /bin/sh (hardlink for shebang)
cp "$ROOTFS/bin/busybox" "$INITRD/bin/busybox"
cp "$ROOTFS/bin/busybox" "$INITRD/bin/sh"
chmod +x "$INITRD/bin/busybox" "$INITRD/bin/sh"

# Kernel modules (initrd needs storage drivers to find CD)
if [ -n "$KVER" ] && [ -d "/lib/modules/$KVER" ]; then
    cp -r "/lib/modules/$KVER" "$INITRD/lib/modules/" 2>/dev/null || true
fi

# Pack initrd
(cd "$INITRD" && find . | cpio -o -H newc) > /tmp/initrd.img
cp /tmp/initrd.img "$ROOTFS/boot/initrd.img"

# GRUB config
mkdir -p "$ROOTFS/boot/grub"
cat > "$ROOTFS/boot/grub/grub.cfg" << 'GRUBCFG'
set timeout=5
set default=0
loadfont unicode

menuentry "🦾 AnosOS — AI Native OS" {
    linux /boot/vmlinuz console=tty1 quiet
    initrd /boot/initrd.img
}

menuentry "AnosOS — Verbose" {
    linux /boot/vmlinuz console=tty1
    initrd /boot/initrd.img
}

menuentry "AnosOS — Rescue" {
    linux /boot/vmlinuz console=tty1 init=/bin/sh
    initrd /boot/initrd.img
}
GRUBCFG

# Build ISO
if command -v grub-mkrescue &>/dev/null; then
    grub-mkrescue -o "$OUTPUT" \
        --modules="part_gpt fat ext2 iso9660 normal boot linux configfile search all_video" \
        --fonts="" \
        "$ROOTFS" 2>&1 | tail -3
elif command -v genisoimage &>/dev/null; then
    genisoimage -R -r -J -V "$ISO_LABEL" -o "$OUTPUT" \
        -b boot/grub/grub.cfg -no-emul-boot "$ROOTFS" 2>&1 | tail -3
elif command -v xorriso &>/dev/null; then
    xorriso -as mkisofs -R -r -J -V "$ISO_LABEL" -o "$OUTPUT" \
        -b boot/grub/grub.cfg -no-emul-boot "$ROOTFS" 2>&1 | tail -3
else
    echo "❌ No ISO tool"; exit 1
fi

# Cleanup
rm -rf "$ROOTFS" "$INITRD" "$DOWNLOAD_DIR" /tmp/initrd.img 2>/dev/null || true

echo ""
if [ -f "$OUTPUT" ]; then
    echo "✅ $(ls -lh "$OUTPUT" | awk '{print $5}') - $OUTPUT"
    echo "   Test: qemu-system-x86_64 -cdrom $OUTPUT -m 2048 -enable-kvm"
else
    echo "❌ Build failed"; exit 1
fi
