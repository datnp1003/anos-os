#!/bin/bash
# 🦾 AnosOS ISO Builder v2 — Minimal build
set -euo pipefail

OUTPUT="${1:-anos-os-linux-amd64.iso}"
ARCH="${2:-amd64}"
ANOS_VERSION="${3:-v0.11.0}"

ROOTFS="/tmp/anos-r"
SQUASHFS="/tmp/anos.squashfs"
INITRD_ROOT="/tmp/anos-initrd"
BINARY_ARCH="$ARCH"; [ "$ARCH" = "amd64" ] && BINARY_ARCH="x86_64"

echo "🦾 AnosOS ISO Builder v2"
echo "  Anos: $ANOS_VERSION  Arch: $ARCH  Output: $OUTPUT"
echo ""

# Clean stale files
rm -rf "$ROOTFS" "$SQUASHFS" "$INITRD_ROOT" 2>/dev/null || true
sudo rm -rf "$ROOTFS" "$SQUASHFS" "$INITRD_ROOT" /tmp/anos-dl-* 2>/dev/null || true

mkdir -p "$ROOTFS"/{bin,sbin,boot,dev,etc,home/anos,opt/anos/{config,skills},proc,run,sys,tmp,usr/bin,var/log,media,mnt,root}

# ── 1. Download Anos binaries ──
echo "[1/5] Downloading Anos $ANOS_VERSION..."
DL="/tmp/anos-dl-$$"; mkdir -p "$DL"
B="https://github.com/datnp1003/anos/releases/download/$ANOS_VERSION"
curl -fsSL "$B/anosd-linux-$BINARY_ARCH" -o "$ROOTFS/usr/bin/anosd" || curl -fsSL "$B/anosd" -o "$ROOTFS/usr/bin/anosd"
curl -fsSL "$B/anos-cli-linux-$BINARY_ARCH" -o "$ROOTFS/usr/bin/anos-cli" || curl -fsSL "$B/anos-cli" -o "$ROOTFS/usr/bin/anos-cli"
chmod +x "$ROOTFS/usr/bin/anosd" "$ROOTFS/usr/bin/anos-cli"

# Clone for skills
git clone --depth 1 "https://github.com/datnp1003/anos.git" "$DL/repo" 2>/dev/null || true
[ -d "$DL/repo" ] && cp "$DL/repo/ANOS-SYSTEM-PROMPT.md" "$ROOTFS/opt/anos/" 2>/dev/null || true
[ -d "$DL/repo/skills" ] && cp -r "$DL/repo/skills"/* "$ROOTFS/opt/anos/skills/" 2>/dev/null || true
rm -rf "$DL"

# ── 2. Busybox ──
echo "[2/5] Setting up busybox..."
BB=""
for try in /bin/busybox-static /usr/bin/busybox-static /bin/busybox; do
    [ -f "$try" ] && BB="$try" && break
done
if [ -z "$BB" ]; then
    curl -fsSL "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -o "$ROOTFS/bin/busybox"
else
    cp "$BB" "$ROOTFS/bin/busybox"
fi
chmod +x "$ROOTFS/bin/busybox"
"$ROOTFS/bin/busybox" --install -s "$ROOTFS/bin/" 2>/dev/null || true

# Ensure critical tools symlinked
for u in getty login passwd su modprobe insmod rmmod switch_root reboot poweroff sync sleep grep find dd mknod cp mv ln sh mount umount cat ls echo mkdir rmdir rm chmod chown kill yes head tail wc clear tty id whoami blkid mountpoint; do
    [ -e "$ROOTFS/bin/$u" ] || ln -sf /bin/busybox "$ROOTFS/bin/$u" 2>/dev/null || true
done
mkdir -p "$ROOTFS/sbin"
ln -sf /bin/busybox "$ROOTFS/sbin/init" 2>/dev/null || true
ln -sf /bin/busybox "$ROOTFS/sbin/getty" 2>/dev/null || true
ln -sf /bin/busybox "$ROOTFS/sbin/login" 2>/dev/null || true
ln -sf /bin/busybox "$ROOTFS/sbin/reboot" 2>/dev/null || true
ln -sf /bin/busybox "$ROOTFS/sbin/poweroff" 2>/dev/null || true
ln -sf /bin/busybox "$ROOTFS/sbin/switch_root" 2>/dev/null || true

# DHCP client
for dhcp in udhcpc dhclient; do
    for p in /usr/sbin/$dhcp /sbin/$dhcp /usr/bin/$dhcp; do
        [ -f "$p" ] && cp "$p" "$ROOTFS/usr/bin/" && break 2
    done
done

# ── 3. Init scripts ──
echo "[3/5] Copying init scripts..."
cp "$(dirname "$0")/../init/anos-init" "$ROOTFS/sbin/init"
cp "$(dirname "$0")/../init/anos-install" "$ROOTFS/usr/bin/anos-install"
cp "$(dirname "$0")/../init/initrd-init" "$ROOTFS/usr/bin/initrd-init"
chmod +x "$ROOTFS/sbin/init" "$ROOTFS/usr/bin/anos-install" "$ROOTFS/usr/bin/initrd-init"

# ── 4. Users + config ──
echo "[4/5] Configuring system..."
HASH='$6$lHWbbl2fteHvrMve$ifBVepML7plgqJVnqudt1SQLHMakyMv3norKFhLOQWEMUV6NHMZRUQSe68jvSF1/Fbii2/8AsrgnnAtFUVGBp1'
python3 -c "import crypt; print(crypt.crypt('anos', crypt.mksalt(crypt.METHOD_SHA512)))" > /dev/null 2>&1 && \
    HASH=$(python3 -c "import crypt; print(crypt.crypt('anos', crypt.mksalt(crypt.METHOD_SHA512)))") || true
ROOT_HASH=$(python3 -c "import crypt; print(crypt.crypt('root', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo "$HASH")

cat > "$ROOTFS/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
anos:x:1000:1000:Anos AI User:/home/anos:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
EOF
cat > "$ROOTFS/etc/shadow" << EOF
root:${ROOT_HASH}:20000:0:99999:7:::
anos:${HASH}:20000:0:99999:7:::
nobody:*:20000:0:99999:7:::
EOF
cat > "$ROOTFS/etc/group" << EOF
root:x:0:
anos:x:1000:
nogroup:x:65534:
EOF
chmod 644 "$ROOTFS/etc/passwd"; chmod 600 "$ROOTFS/etc/shadow"; chmod 644 "$ROOTFS/etc/group"

cat > "$ROOTFS/etc/profile" << 'PROFILE'
export PATH=/usr/bin:/bin:/sbin:/usr/sbin
export ANOS_DIR=/opt/anos
export ANOS_SOCKET=/tmp/anos.sock
if [ "$(tty)" = "/dev/tty1" ] && [ "$(whoami)" = "anos" ]; then
    clear 2>/dev/null || true
    echo "╔══════════════════════════════════════════════╗"
    echo "║       🦾 AnosOS — AI Native OS              ║"
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
║       🦾 AnosOS — AI Native OS              ║
║          v2.0                               ║
║─────────────────────────────────────────────║
║  Login: anos / anos                         ║
║  anos-install → install to disk             ║
╚══════════════════════════════════════════════╝
ISSUE

echo "anos" > "$ROOTFS/etc/hostname"
echo "127.0.0.1 localhost anos" > "$ROOTFS/etc/hosts"

# ── 5. Build initrd + ISO ──
echo "[5/5] Building ISO..."

# Initrd: /init + busybox + squashfs
mkdir -p "$INITRD_ROOT"/{bin,sbin,lib/modules}
cp "$(dirname "$0")/../init/initrd-init" "$INITRD_ROOT/init"
chmod +x "$INITRD_ROOT/init"

cp "$ROOTFS/bin/busybox" "$INITRD_ROOT/bin/busybox"
chmod +x "$INITRD_ROOT/bin/busybox"
for u in sh mount umount cat ls echo mkdir sleep grep find mknod switch_root insmod modprobe rmmod cp ln dd sync reboot; do
    ln -sf /bin/busybox "$INITRD_ROOT/bin/$u" 2>/dev/null || true
done
ln -sf /bin/busybox "$INITRD_ROOT/sbin/switch_root" 2>/dev/null || true

# Copy kernel modules if available
KVER=$(ls /lib/modules/ | head -1)
if [ -n "$KVER" ] && [ -d "/lib/modules/$KVER" ]; then
    cp -r "/lib/modules/$KVER" "$INITRD_ROOT/lib/modules/" 2>/dev/null || true
fi

# Build squashfs root
mkdir -p /tmp/anos-sq-root
cp -a "$ROOTFS"/* /tmp/anos-sq-root/ 2>/dev/null || true
mksquashfs /tmp/anos-sq-root "$SQUASHFS" -comp xz -noappend 2>&1 | grep -v "^Parallel" || true

# Embed squashfs in initrd
cp "$SQUASHFS" "$INITRD_ROOT/anos.squashfs"
(cd "$INITRD_ROOT" && find . | cpio -o -H newc) > "$ROOTFS/boot/initrd.img"

# Find + copy kernel
KIMG=""
for k in /boot/vmlinuz /vmlinuz /boot/vmlinuz-*; do
    [ -f "$k" ] && [ -r "$k" ] && KIMG="$k" && break
done
if [ -n "$KIMG" ]; then cp "$KIMG" "$ROOTFS/boot/vmlinuz"; fi

# GRUB config
mkdir -p "$ROOTFS/boot/grub"
cat > "$ROOTFS/boot/grub/grub.cfg" << 'GRUB'
set timeout=5
menuentry "AnosOS Live" { linux /boot/vmlinuz console=tty1 quiet; initrd /boot/initrd.img; }
menuentry "AnosOS Verbose" { linux /boot/vmlinuz console=tty1; initrd /boot/initrd.img; }
menuentry "AnosOS Rescue" { linux /boot/vmlinuz console=tty1 init=/bin/sh; initrd /boot/initrd.img; }
GRUB

# Build ISO
echo "  Building ISO..."
if command -v grub-mkrescue &>/dev/null; then
    grub-mkrescue -o "$OUTPUT" "$ROOTFS" --modules="part_gpt fat iso9660 normal boot linux configfile search all_video" --fonts="" 2>&1 | tail -3
elif command -v genisoimage &>/dev/null; then
    genisoimage -R -r -J -V "ANOS_OS" -o "$OUTPUT" -b boot/grub/grub.cfg -no-emul-boot "$ROOTFS" 2>&1 | tail -3
elif command -v xorriso &>/dev/null; then
    xorriso -as mkisofs -R -r -J -V "ANOS_OS" -o "$OUTPUT" -b boot/grub/grub.cfg -no-emul-boot "$ROOTFS" 2>&1 | tail -3
else
    echo "❌ No ISO tool"; exit 1
fi

# Result
rm -rf "$ROOTFS" "$INITRD_ROOT" "$SQUASHFS" /tmp/anos-sq-root 2>/dev/null || true
if [ -f "$OUTPUT" ]; then
    echo "✅ ISO built: $(ls -lh "$OUTPUT" | awk '{print $5}')"
    echo "Test: qemu-system-x86_64 -cdrom $OUTPUT -m 2048 -enable-kvm"
else
    echo "❌ Build failed"
    exit 1
fi
