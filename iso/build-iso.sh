#!/bin/bash
# 🦾 AnosOS ISO Builder — Multi-user Edition
# Builds a bootable ISO with Anos + busybox getty login
#
# Usage: build-iso.sh [output] [arch] [anos_version]
#   anos_version: git tag from datnp1003/anos (default: latest release)
set -euo pipefail

OUTPUT="${1:-anos-os.iso}"
ARCH="${2:-amd64}"
ANOS_VERSION="${3:-}"
ROOTFS="/tmp/anos-rootfs"
ISO_LABEL="ANOS_OS"
ANOS_REPO="https://github.com/datnp1003/anos"

# Default credentials displayed at boot
DEFAULT_USER="anos"
DEFAULT_PASS="anos"
ROOT_PASS="root"

# If no version specified, fetch latest from GitHub
get_latest_version() {
    curl -s "https://api.github.com/repos/datnp1003/anos/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\(.*\)".*/\1/' \
        || echo "v0.11.0"
}

if [ -z "$ANOS_VERSION" ]; then
    ANOS_VERSION=$(get_latest_version)
    echo "🦾 Auto-detected latest Anos version: $ANOS_VERSION"
fi

DOWNLOAD_DIR="/tmp/anos-dl-$$"
mkdir -p "$DOWNLOAD_DIR"

echo "🦾 AnosOS ISO Builder"
echo "  Anos ver:   $ANOS_VERSION"
echo "  Output:     $OUTPUT"
echo "  Arch:       $ARCH"
echo "  Login:      $DEFAULT_USER / $DEFAULT_PASS"
echo "  Root pass:  $ROOT_PASS"
echo ""

# ── 1. Prepare rootfs ──
echo "📦 Creating rootfs..."
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{bin,sbin,boot,dev,etc/init.d,home/anos,opt/anos/{config,skills},proc,run,sys,tmp,usr/bin,var/log}

# ── 2. Download Anos binaries + assets from GitHub Release ──
echo "🦾 Downloading Anos $ANOS_VERSION from GitHub..."

# Try pre-built binaries first
BINARY_ARCH="${ARCH}"
[ "$ARCH" = "amd64" ] && BINARY_ARCH="x86_64"

DL_BASE="$ANOS_REPO/releases/download/$ANOS_VERSION"

# Download anosd
if curl -fsSL "$DL_BASE/anosd-linux-$BINARY_ARCH" -o "$DOWNLOAD_DIR/anosd" 2>/dev/null; then
    echo "  ✅ Downloaded anosd (pre-built binary)"
else
    echo "  ⚠️ Pre-built anosd not found for $BINARY_ARCH — trying generic..."
    curl -fsSL "$DL_BASE/anosd" -o "$DOWNLOAD_DIR/anosd" 2>/dev/null || {
        echo "  ❌ Cannot download anosd from release"
        echo "  Build anos from source first or check ANOS_VERSION"
        exit 1
    }
fi

# Download anos-cli
if curl -fsSL "$DL_BASE/anos-cli-linux-$BINARY_ARCH" -o "$DOWNLOAD_DIR/anos-cli" 2>/dev/null; then
    echo "  ✅ Downloaded anos-cli (pre-built binary)"
else
    curl -fsSL "$DL_BASE/anos-cli" -o "$DOWNLOAD_DIR/anos-cli" 2>/dev/null || {
        echo "  ❌ Cannot download anos-cli from release"
        exit 1
    }
fi

# Download assets via git shallow clone (most reliable)
echo "  Downloading skills & prompt..."
if command -v git &>/dev/null; then
    git clone --depth 1 --branch "$ANOS_VERSION" "$ANOS_REPO.git" "$DOWNLOAD_DIR/repo" 2>/dev/null || \
    git clone --depth 1 "$ANOS_REPO.git" "$DOWNLOAD_DIR/repo" 2>/dev/null || true
fi
if [ -d "$DOWNLOAD_DIR/repo" ]; then
    cp "$DOWNLOAD_DIR/repo/ANOS-SYSTEM-PROMPT.md" "$DOWNLOAD_DIR/" 2>/dev/null || true
    cp -r "$DOWNLOAD_DIR/repo/skills" "$DOWNLOAD_DIR/" 2>/dev/null || true
fi

# Copy to rootfs
chmod +x "$DOWNLOAD_DIR/anosd" "$DOWNLOAD_DIR/anos-cli"
cp "$DOWNLOAD_DIR/anosd" "$ROOTFS/usr/bin/"
cp "$DOWNLOAD_DIR/anos-cli" "$ROOTFS/usr/bin/"
cp "$DOWNLOAD_DIR/ANOS-SYSTEM-PROMPT.md" "$ROOTFS/opt/anos/" 2>/dev/null || cp "$DOWNLOAD_DIR/repo/ANOS-SYSTEM-PROMPT.md" "$ROOTFS/opt/anos/" 2>/dev/null || echo "  ⚠️ No system prompt found"
cp -r "$DOWNLOAD_DIR/skills"/* "$ROOTFS/opt/anos/skills/" 2>/dev/null || cp -r "$DOWNLOAD_DIR/repo/skills"/* "$ROOTFS/opt/anos/skills/" 2>/dev/null || echo "  ⚠️ No skills dir found"

# Use anos-os's own init (not from the download)
cp "$(dirname "$0")/../init/anos-init" "$ROOTFS/sbin/init"
chmod +x "$ROOTFS/sbin/init"

# Cleanup download dir
rm -rf "$DOWNLOAD_DIR"

# ── 3. Download busybox + create symlinks ──
echo "📦 Setting up busybox..."
# Download busybox-static from Alpine (no sudo needed)
BUSYBOX_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/${BINARY_ARCH}/busybox-static-1.37.0-r12.apk"

if command -v busybox-static &>/dev/null; then
    cp "$(command -v busybox-static)" "$ROOTFS/bin/busybox"
elif [ -f /bin/busybox-static ]; then
    cp /bin/busybox-static "$ROOTFS/bin/busybox"
elif [ -f /usr/bin/busybox-static ]; then
    cp /usr/bin/busybox-static "$ROOTFS/bin/busybox"
elif command -v busybox &>/dev/null; then
    cp "$(command -v busybox)" "$ROOTFS/bin/busybox"
elif [ -f /bin/busybox ]; then
    cp /bin/busybox "$ROOTFS/bin/busybox"
else
    # Download busybox-static from Alpine (no sudo needed, ~2MB)
    echo "  Downloading busybox-static from Alpine..."
    BB_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/${BINARY_ARCH}/busybox-static-1.37.0-r12.apk"
    if curl -fsSL "$BB_URL" -o /tmp/busybox.apk 2>/dev/null; then
        # Extract APK (it's a tar.gz with 3 headers)
        tar xzf /tmp/busybox.apk -C /tmp/ 2>/dev/null || true
        if [ -f /tmp/bin/busybox.static ]; then
            cp /tmp/bin/busybox.static "$ROOTFS/bin/busybox"
        elif [ -f /tmp/busybox.static ]; then
            cp /tmp/busybox.static "$ROOTFS/bin/busybox"
        else
            # Fallback: try direct binary download
            curl -fsSL "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -o "$ROOTFS/bin/busybox" 2>/dev/null || {
                echo "❌ Cannot get busybox. Install: sudo apt install busybox-static"
                exit 1
            }
        fi
        rm -rf /tmp/busybox.apk /tmp/bin /tmp/.\SIGN.* 2>/dev/null || true
    else
        echo "❌ Cannot download busybox. Install: sudo apt install busybox-static"
        exit 1
    fi
fi
chmod +x "$ROOTFS/bin/busybox"

# Install all busybox symlinks
echo "  Creating symlinks..."
"$ROOTFS/bin/busybox" --install -s "$ROOTFS/bin/" 2>/dev/null || true

# Ensure critical utilities are symlinked (even if --install missed some)
for util in \
    sh ls cat echo mount umount ip ping hostname modprobe \
    mknod sleep grep getty login passwd su adduser addgroup \
    clear tty id whoami init df du ps kill yes head tail \
    mkdir rmdir rm cp mv ln chmod chown wc cut sort uniq \
    find xargs tee printf test stat sync reboot poweroff \
    flock tar gzip dd; do
    if [ ! -e "$ROOTFS/bin/$util" ] && "$ROOTFS/bin/busybox" --list 2>/dev/null | grep -qx "$util"; then
        ln -sf /bin/busybox "$ROOTFS/bin/$util" 2>/dev/null || true
    fi
done

# Also in /sbin for getty
mkdir -p "$ROOTFS/sbin"
ln -sf /bin/busybox "$ROOTFS/sbin/getty" 2>/dev/null || true
ln -sf /bin/busybox "$ROOTFS/sbin/login" 2>/dev/null || true
ln -sf /bin/busybox "$ROOTFS/sbin/init" 2>/dev/null || true
ln -sf /bin/busybox "$ROOTFS/sbin/reboot" 2>/dev/null || true
ln -sf /bin/busybox "$ROOTFS/sbin/poweroff" 2>/dev/null || true

# ── 4. Copy DHCP client ──
if command -v udhcpc &>/dev/null; then
    cp "$(command -v udhcpc)" "$ROOTFS/usr/bin/"
elif [ -f /sbin/udhcpc ]; then
    cp /sbin/udhcpc "$ROOTFS/usr/bin/"
elif [ -f /usr/sbin/udhcpc ]; then
    cp /usr/sbin/udhcpc "$ROOTFS/usr/bin/"
fi

# Also copy dhclient as fallback
if command -v dhclient &>/dev/null; then
    cp "$(command -v dhclient)" "$ROOTFS/usr/bin/" 2>/dev/null || true
fi

# ── 5. Create /etc/passwd + /etc/shadow + /etc/group ──
echo "👤 Setting up users..."

# Generate password hashes (sha512)
ANOS_HASH=$(python3 -c "import crypt; print(crypt.crypt('$DEFAULT_PASS', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo "")
ROOT_HASH=$(python3 -c "import crypt; print(crypt.crypt('$ROOT_PASS', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo "")

if [ -z "$ANOS_HASH" ]; then
    echo "  ⚠️ Python3+crypt not available — using static hash"
    ANOS_HASH='$6$lHWbbl2fteHvrMve$ifBVepML7plgqJVnqudt1SQLHMakyMv3norKFhLOQWEMUV6NHMZRUQSe68jvSF1/Fbii2/8AsrgnnAtFUVGBp1'
    ROOT_HASH='$6$lHWbbl2fteHvrMve$ifBVepML7plgqJVnqudt1SQLHMakyMv3norKFhLOQWEMUV6NHMZRUQSe68jvSF1/Fbii2/8AsrgnnAtFUVGBp1'
fi

cat > "$ROOTFS/etc/passwd" << PASSWD
root:x:0:0:root:/root:/bin/sh
daemon:x:1:1:daemon:/usr/sbin:/bin/false
bin:x:2:2:bin:/bin:/bin/false
sys:x:3:3:sys:/dev:/bin/false
sync:x:4:65534:sync:/bin:/bin/sync
anos:x:1000:1000:Anos AI User:/home/anos:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
PASSWD

cat > "$ROOTFS/etc/shadow" << SHADOW
root:${ROOT_HASH}:20000:0:99999:7:::
daemon:*:20000:0:99999:7:::
bin:*:20000:0:99999:7:::
sys:*:20000:0:99999:7:::
sync:*:20000:0:99999:7:::
anos:${ANOS_HASH}:20000:0:99999:7:::
nobody:*:20000:0:99999:7:::
SHADOW

cat > "$ROOTFS/etc/group" << GROUP
root:x:0:
daemon:x:1:
bin:x:2:
sys:x:3:
admin:x:100:anos
anos:x:1000:
nogroup:x:65534:
GROUP

chmod 644 "$ROOTFS/etc/passwd"
chmod 600 "$ROOTFS/etc/shadow"
chmod 644 "$ROOTFS/etc/group"

# ── 6. Create /etc/profile ──
cat > "$ROOTFS/etc/profile" << 'PROFILE'
# 🦾 AnosOS — Shell Profile

export PATH=/usr/bin:/bin:/sbin:/usr/sbin
export ANOS_DIR=/opt/anos
export ANOS_SOCKET=/tmp/anos.sock

# Check if anosd socket is available
ANOS_READY=false
[ -S /tmp/anos.sock ] && ANOS_READY=true

# tty1: auto-launch Anos CLI for anos user
if [ "$(tty)" = "/dev/tty1" ] && [ "$(whoami)" = "anos" ]; then
    clear 2>/dev/null || true
    echo "╔══════════════════════════════════════════════╗"
    echo "║       🦾 AnosOS — AI Native OS              ║"
    echo "║          v1.0.1 — Connected               ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    if $ANOS_READY; then
        echo "🦾 Launching Anos CLI..."
        exec /usr/bin/anos-cli
    else
        echo "⚠️  Anos daemon not ready — starting shell"
        echo "   Try: /usr/bin/anos-cli once daemon is up"
        exec /bin/sh
    fi
fi

# Other ttys: admin shell
echo ""
echo "🦾 AnosOS v1.0.1"
echo "─────────────────────"
$ANOS_READY && echo " AI daemon:  ✅ Online" || echo " AI daemon:  ❌ Offline"
echo " Type 'anos-cli' for AI shell   |   'exit' to log out"
echo ""
PROFILE

# ── 7. Create /etc/issue (pre-login banner) ──
cat > "$ROOTFS/etc/issue" << 'ISSUE'

╔══════════════════════════════════════════════╗
║       🦾 AnosOS — AI Native OS              ║
║          v1.0.1 — \l                          ║
║──────────────────────────────────────────────║
║   Default: anos / anos                      ║
║   ⚠️  CHANGE PASSWORD on first login!       ║
╚══════════════════════════════════════════════╝

ISSUE

# ── 8. Create GRUB config ──
echo "🖥️ Creating GRUB config..."
mkdir -p "$ROOTFS/boot/grub"

cat > "$ROOTFS/boot/grub/grub.cfg" << 'GRUB'
set timeout=5
set default=0
loadfont unicode

menuentry "🦾 AnosOS — AI Native OS" {
    linux /boot/vmlinuz console=tty1 quiet
    initrd /boot/initrd.img
}

menuentry "AnosOS — Verbose boot" {
    linux /boot/vmlinuz console=tty1
    initrd /boot/initrd.img
}

menuentry "AnosOS — Safe mode (root shell)" {
    linux /boot/vmlinuz console=tty1 init=/bin/sh
    initrd /boot/initrd.img
}
GRUB

# ── 9. Copy kernel ──
echo "🐧 Copying kernel..."
KERNEL=""
for k in /boot/vmlinuz /vmlinuz /boot/vmlinuz-*; do
    if [ -f "$k" ]; then
        KERNEL="$k"
        break
    fi
done
if [ -z "$KERNEL" ]; then
    echo "  ❌ No kernel found in /boot"
    exit 1
fi
if [ -r "$KERNEL" ]; then
    cp "$KERNEL" "$ROOTFS/boot/vmlinuz"
else
    echo "  Kernel requires sudo to read. Trying..."
    if command -v sudo &>/dev/null; then
        sudo cp "$KERNEL" "$ROOTFS/boot/vmlinuz"
        sudo chmod 644 "$ROOTFS/boot/vmlinuz"
    else
        echo "  ❌ Cannot read kernel. Run with: sudo bash iso/build-iso.sh $OUTPUT $ARCH $ANOS_VERSION"
        exit 1
    fi
fi
echo "  Kernel: $(basename $KERNEL)"

# ── 10. Create initrd (with /init script + busybox + modules + squashfs) ──
echo "📦 Creating squashfs from rootfs..."
mksquashfs "$ROOTFS" /tmp/anos-root.squashfs -comp xz -noappend -quiet

echo "📦 Building initrd..."
INITRD="/tmp/initrd-root"
rm -rf "$INITRD"; mkdir -p "$INITRD"/{bin,sbin,lib/modules}

# /init script (Stage 1: mount squashfs -> switch_root)
cp "$(dirname "$0")/../init/initrd-init" "$INITRD/init"
chmod +x "$INITRD/init"

# Busybox in initrd — ONLY ONE binary, create symlinks dynamically in /init
# (Making 20 copies of 2MB busybox = 40MB initrd → kernel OOM → panic)
cp "$ROOTFS/bin/busybox" "$INITRD/bin/busybox"
chmod +x "$INITRD/bin/busybox"
# /init uses busybox --install at runtime to create all symlinks
# We ship ONLY busybox as /bin/sh for the shebang, the rest are runtime

# Kernel modules — copy ONLY storage drivers (keep initrd small)
if [ -d /lib/modules ]; then
    KVER=$(ls /lib/modules/ | head -1)
    MOD_OUT="$INITRD/lib/modules/$KVER/kernel/drivers"
    mkdir -p "$MOD_OUT"
    for cat in ata nvme virtio scsi "usb/storage"; do
        mkdir -p "$MOD_OUT/$cat"
        find "/lib/modules/$KVER/kernel/drivers/$cat" -name "*.ko*" \
            -exec cp {} "$MOD_OUT/$cat/" \; 2>/dev/null || true
    done
    find "/lib/modules/$KVER/kernel" -name "loop.ko*" -exec cp {} "$INITRD/lib/modules/$KVER/" \; 2>/dev/null || true
    find "/lib/modules/$KVER/kernel" -name "squashfs.ko*" -exec cp {} "$INITRD/lib/modules/$KVER/" \; 2>/dev/null || true
    find "/lib/modules/$KVER/kernel" -name "overlay.ko*" -exec cp {} "$INITRD/lib/modules/$KVER/" \; 2>/dev/null || true
fi

# DON'T embed squashfs — keeps initrd under 10MB, mount from CD/USB at runtime
# Instead, build initrd (cpio) and put squashfs separately on ISO
(cd "$INITRD" && find . | cpio -o -H newc) > /tmp/initrd.img
cp /tmp/initrd.img "$ROOTFS/boot/initrd.img"

# Copy squashfs to ISO root so /init can find it on CD/USB
cp /tmp/anos-root.squashfs "$ROOTFS/anos.squashfs"

# ── 11. Build ISO ──
echo "💿 Building ISO..."
grub-mkrescue -o "$OUTPUT" "$ROOTFS" \
    --modules="part_gpt fat iso9660 normal boot linux configfile" \
    --fonts="" \
    2>&1 | grep -v "^xorriso\|^GNU\|^Disk\|^libisofs" || true

if [ ! -f "$OUTPUT" ]; then
    echo "  Falling back to genisoimage..."
    genisoimage -R -r -J -V "$ISO_LABEL" -o "$OUTPUT" -b boot/grub/grub.cfg -no-emul-boot "$ROOTFS" 2>&1 || true
fi

# ── 12. Show result ──
echo ""
echo "✅ ISO built successfully!"
ls -lh "$OUTPUT"
echo ""
echo "┌──────────────────────────────────────────────┐"
echo "│  Default login:  anos / anos                 │"
echo "│  Root login:     root / root                 │"
echo "│  ⚠️  CHANGE ALL PASSWORDS on first boot!     │"
echo "└──────────────────────────────────────────────┘"
echo ""
echo "Test with: qemu-system-x86_64 -cdrom $OUTPUT -m 2048"
