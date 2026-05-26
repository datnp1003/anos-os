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

# Download assets (source tarball for skills + prompt + init)
ASSET_URL=$(curl -s "https://api.github.com/repos/datnp1003/anos/releases/tags/$ANOS_VERSION" 2>/dev/null \
    | grep '"browser_download_url"' | grep 'tar.gz' | head -1 | sed 's/.*"browser_download_url": "\(.*\)".*/\1/')

if [ -n "$ASSET_URL" ]; then
    echo "  Downloading source assets..."
    curl -fsSL "$ASSET_URL" -o "$DOWNLOAD_DIR/source.tar.gz" 2>/dev/null || {
        echo "  ⚠️ Cannot download source — trying git clone shallow..."
        ASSET_URL=""
    }
fi

if [ -z "$ASSET_URL" ]; then
    # Fallback: clone shallow and extract skills + prompt
    if command -v git &>/dev/null; then
        echo "  Cloning anos $ANOS_VERSION (shallow)..."
        git clone --depth 1 --branch "$ANOS_VERSION" "$ANOS_REPO.git" "$DOWNLOAD_DIR/repo" 2>/dev/null || \
        git clone --depth 1 "$ANOS_REPO.git" "$DOWNLOAD_DIR/repo" 2>/dev/null || true
        if [ -d "$DOWNLOAD_DIR/repo" ]; then
            cp "$DOWNLOAD_DIR/repo/ANOS-SYSTEM-PROMPT.md" "$DOWNLOAD_DIR/" 2>/dev/null || true
            cp -r "$DOWNLOAD_DIR/repo/skills" "$DOWNLOAD_DIR/" 2>/dev/null || true
            cp "$DOWNLOAD_DIR/repo/anos-init" "$DOWNLOAD_DIR/" 2>/dev/null || true
        fi
    fi
else
    tar xzf "$DOWNLOAD_DIR/source.tar.gz" -C "$DOWNLOAD_DIR/" --strip-components=1
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

# ── 3. Copy busybox + create symlinks ──
echo "📦 Setting up busybox..."
# Prefer busybox-static for login utils (getty, login, passwd, su)
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
    echo "❌ busybox not found! Install busybox-static package."
    exit 1
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
    echo "║          v0.11.0 — Connected               ║"
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
echo "🦾 AnosOS v0.11.0"
echo "─────────────────────"
$ANOS_READY && echo " AI daemon:  ✅ Online" || echo " AI daemon:  ❌ Offline"
echo " Type 'anos-cli' for AI shell   |   'exit' to log out"
echo ""
PROFILE

# ── 7. Create /etc/issue (pre-login banner) ──
cat > "$ROOTFS/etc/issue" << 'ISSUE'

╔══════════════════════════════════════════════╗
║       🦾 AnosOS — AI Native OS              ║
║          v0.11.0 — \l                          ║
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
if [ -f /boot/vmlinuz ]; then
    cp /boot/vmlinuz "$ROOTFS/boot/vmlinuz"
elif [ -f /vmlinuz ]; then
    cp /vmlinuz "$ROOTFS/boot/vmlinuz"
else
    KERNEL=$(ls /boot/vmlinuz-* 2>/dev/null | head -1)
    [ -n "$KERNEL" ] && cp "$KERNEL" "$ROOTFS/boot/vmlinuz"
fi

# ── 10. Create initrd from rootfs ──
echo "📦 Creating squashfs from rootfs..."
mksquashfs "$ROOTFS" /tmp/anos-root.squashfs -comp xz -noappend -quiet

# Create initrd (just squashfs → cpio)
mkdir -p /tmp/initrd-root
cp /tmp/anos-root.squashfs /tmp/initrd-root/anos.squashfs
(cd /tmp/initrd-root && find . | cpio -o -H newc) > /tmp/initrd.img
cp /tmp/initrd.img "$ROOTFS/boot/initrd.img"

# ── 11. Build ISO ──
echo "💿 Building ISO..."
grub-mkrescue -o "$OUTPUT" "$ROOTFS" \
    --modules="part_gpt fat iso9660 normal boot linux configfile" \
    --fonts="" \
    2>&1 | grep -v "^xorriso\|^GNU\|^Disk\|^libisofs" || true

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
