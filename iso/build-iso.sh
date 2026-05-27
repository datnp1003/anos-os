#!/bin/bash
# 🦾 AnosOS ISO Builder v2 — Full-featured bootable ISO
# Builds a proper ISO with:
#   - Initrd with /init script (mount squashfs + switch_root)
#   - Kernel modules for real hardware
#   - UEFI + BIOS dual boot via GRUB
#   - anos-install (disk detection, GPT partitioning, ext4, GRUB install)
#   - anosd + anos-cli + skills
#
# Usage: build-iso.sh [output] [arch] [anos_version]
set -eo pipefail
# Note: no -u — CI may have unset vars; guarded with defaults below

OUTPUT="${1:-anos-os-linux-amd64.iso}"
ARCH="${2:-amd64}"
ANOS_VERSION="${3:-}"
ROOTFS="/tmp/anos-rootfs"
INITRD_ROOT="/tmp/anos-initrd"
SQUASHFS="/tmp/anos-root.squashfs"
ISO_DIR="/tmp/anos-iso"
ISO_LABEL="ANOS_OS"
ANOS_REPO="https://github.com/datnp1003/anos"

# Default credentials
DEFAULT_USER="anos"
DEFAULT_PASS="anos"
ROOT_PASS="root"

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
get_latest_version() {
    curl -s "https://api.github.com/repos/datnp1003/anos/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\(.*\)".*/\1/' \
        || echo "v0.11.0"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "❌ Required: $1 — install it first"
        exit 1
    }
}

# ─────────────────────────────────────────────
# Init
# ─────────────────────────────────────────────
if [ -z "$ANOS_VERSION" ]; then
    ANOS_VERSION=$(get_latest_version)
    echo "🦾 Auto-detected latest Anos version: $ANOS_VERSION"
fi

BINARY_ARCH="${ARCH}"
[ "$ARCH" = "amd64" ] && BINARY_ARCH="x86_64"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║       🦾 AnosOS ISO Builder v2              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Anos ver:   $ANOS_VERSION"
echo "  Output:     $OUTPUT"
echo "  Arch:       $ARCH (binary: $BINARY_ARCH)"
echo "  Login:      $DEFAULT_USER / $DEFAULT_PASS"
echo ""

# Check essential tools
for cmd in mksquashfs cpio curl; do
    require_cmd "$cmd"
done

# Clean temp dirs
rm -rf "$ROOTFS" "$INITRD_ROOT" "$SQUASHFS" "$ISO_DIR"

DOWNLOAD_DIR="/tmp/anos-dl-$$"
mkdir -p "$DOWNLOAD_DIR" "$ROOTFS" "$INITRD_ROOT" "$ISO_DIR"

# ─────────────────────────────────────────────
# 1. Download Anos binaries + assets
# ─────────────────────────────────────────────
echo "🦾 [1/12] Downloading Anos $ANOS_VERSION..."

DL_BASE="$ANOS_REPO/releases/download/$ANOS_VERSION"

# Download anosd
for try in "anosd-linux-$BINARY_ARCH" "anosd"; do
    if curl -fsSL "$DL_BASE/$try" -o "$DOWNLOAD_DIR/anosd" 2>/dev/null; then
        echo "  ✅ anosd ($try)"
        break
    fi
done

# Download anos-cli
for try in "anos-cli-linux-$BINARY_ARCH" "anos-cli"; do
    if curl -fsSL "$DL_BASE/$try" -o "$DOWNLOAD_DIR/anos-cli" 2>/dev/null; then
        echo "  ✅ anos-cli ($try)"
        break
    fi
done

# Clone repo for skills + prompt (shallow)
if command -v git &>/dev/null; then
    git clone --depth 1 --branch "$ANOS_VERSION" "$ANOS_REPO.git" "$DOWNLOAD_DIR/repo" 2>/dev/null || \
    git clone --depth 1 "$ANOS_REPO.git" "$DOWNLOAD_DIR/repo" 2>/dev/null || true
fi

if [ -d "$DOWNLOAD_DIR/repo" ]; then
    cp "$DOWNLOAD_DIR/repo/ANOS-SYSTEM-PROMPT.md" "$DOWNLOAD_DIR/" 2>/dev/null || true
    mkdir -p "$DOWNLOAD_DIR/skills"
    cp -r "$DOWNLOAD_DIR/repo/skills"/* "$DOWNLOAD_DIR/skills/" 2>/dev/null || true
fi

# Validate we have the binaries
if [ ! -f "$DOWNLOAD_DIR/anosd" ] || [ ! -f "$DOWNLOAD_DIR/anos-cli" ]; then
    echo "❌ Cannot download Anos binaries from release $ANOS_VERSION"
    echo "   Check: $DL_BASE"
    exit 1
fi

# ─────────────────────────────────────────────
# 2. Prepare rootfs skeleton
# ─────────────────────────────────────────────
echo "📦 [2/12] Creating rootfs skeleton..."
mkdir -p "$ROOTFS"/{bin,sbin,boot,dev,etc/init.d,home/anos,opt/anos/{config,skills},proc,run,sys,tmp,usr/bin,var/log,media/cdrom,mnt,overlay,root}

# Copy Anos binaries
chmod +x "$DOWNLOAD_DIR/anosd" "$DOWNLOAD_DIR/anos-cli"
cp "$DOWNLOAD_DIR/anosd" "$ROOTFS/usr/bin/"
cp "$DOWNLOAD_DIR/anos-cli" "$ROOTFS/usr/bin/"
cp "$DOWNLOAD_DIR/ANOS-SYSTEM-PROMPT.md" "$ROOTFS/opt/anos/" 2>/dev/null || true
cp -r "$DOWNLOAD_DIR/skills"/* "$ROOTFS/opt/anos/skills/" 2>/dev/null || true

# Copy anos-os init + installer
cp "$(dirname "$0")/../init/anos-init" "$ROOTFS/sbin/init"
chmod +x "$ROOTFS/sbin/init"
cp "$(dirname "$0")/../init/anos-install" "$ROOTFS/usr/bin/anos-install"
chmod +x "$ROOTFS/usr/bin/anos-install"
ln -sf anos-install "$ROOTFS/usr/bin/install" 2>/dev/null || true

# ─────────────────────────────────────────────
# 3. Busybox userland
# ─────────────────────────────────────────────
echo "📦 [3/12] Setting up busybox..."

# Try multiple sources
BB_CP=""
for src in \
    "$(command -v busybox 2>/dev/null)" \
    "$(command -v busybox-static 2>/dev/null)" \
    /bin/busybox \
    /bin/busybox-static \
    /usr/bin/busybox \
    /usr/bin/busybox-static; do
    if [ -n "$src" ] && [ -f "$src" ]; then
        cp "$src" "$ROOTFS/bin/busybox"
        BB_CP="$ROOTFS/bin/busybox"
        break
    fi
done

# Download if not found
if [ -z "$BB_CP" ]; then
    echo "  Downloading busybox-static..."
    BB_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/${BINARY_ARCH}/busybox-static-1.37.0-r12.apk"
    if curl -fsSL "$BB_URL" -o /tmp/busybox.apk 2>/dev/null; then
        tar xzf /tmp/busybox.apk -C /tmp/ 2>/dev/null || true
        for bb in /tmp/bin/busybox.static /tmp/busybox.static; do
            if [ -f "$bb" ]; then cp "$bb" "$ROOTFS/bin/busybox"; break; fi
        done
        rm -rf /tmp/busybox.apk /tmp/bin 2>/dev/null || true
    fi
    # Last resort: busybox.net direct binary
    if [ ! -f "$ROOTFS/bin/busybox" ]; then
        curl -fsSL "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
            -o "$ROOTFS/bin/busybox" 2>/dev/null || true
    fi
fi

if [ ! -f "$ROOTFS/bin/busybox" ]; then
    echo "❌ Cannot obtain busybox"
    exit 1
fi

chmod +x "$ROOTFS/bin/busybox"

# Install symlinks
echo "  Creating symlinks..."
"$ROOTFS/bin/busybox" --install -s "$ROOTFS/bin/" 2>/dev/null || true

# Ensure critical utils
for util in \
    sh ls cat echo mount umount ip ping hostname modprobe \
    mknod sleep grep getty login passwd su adduser addgroup \
    clear tty id whoami init df du ps kill yes head tail \
    mkdir rmdir rm cp mv ln chmod chown wc cut sort uniq \
    find xargs tee printf test stat sync reboot poweroff \
    flock tar gzip dd insmod rmmod lsmod depmod switch_root \
    mountpoint blkid findfs; do
    if [ ! -e "$ROOTFS/bin/$util" ]; then
        ln -sf /bin/busybox "$ROOTFS/bin/$util" 2>/dev/null || true
    fi
done

# /sbin symlinks for login/getty/init
mkdir -p "$ROOTFS/sbin"
for util in getty login init reboot poweroff switch_root; do
    ln -sf /bin/busybox "$ROOTFS/sbin/$util" 2>/dev/null || true
done

# ─────────────────────────────────────────────
# 4. System tools for installer
# ─────────────────────────────────────────────
echo "🔧 [4/12] Installing system tools..."

# ── APK Package Manager ── (base packages installed on first boot)
echo "  📦 Installing APK package manager..."
APK_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/${BINARY_ARCH}/apk-tools-static-2.14.9-r0.apk"
APK_TARBALL="/tmp/apk-tools.apk"

if curl -fsSL "$APK_URL" -o "$APK_TARBALL" 2>/dev/null; then
    tar xzf "$APK_TARBALL" -C /tmp/ sbin/apk.static 2>/dev/null || true
    if [ -f /tmp/sbin/apk.static ]; then
        cp /tmp/sbin/apk.static "$ROOTFS/usr/bin/apk"
        chmod +x "$ROOTFS/usr/bin/apk"
        mkdir -p "$ROOTFS/etc/apk/keys" "$ROOTFS/lib/apk/db" "$ROOTFS/var/cache/apk"
        touch "$ROOTFS/lib/apk/db/installed"

        # Alpine keys
        for key in /etc/apk/keys/*.pub; do
            [ -f "$key" ] && cp "$key" "$ROOTFS/etc/apk/keys/" 2>/dev/null || true
        done
        if [ -z "$(ls "$ROOTFS/etc/apk/keys/" 2>/dev/null)" ]; then
            curl -fsSL "https://alpine.pkgs.org/keys/alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub" \
                -o "$ROOTFS/etc/apk/keys/alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub" 2>/dev/null || true
        fi

        cat > "$ROOTFS/etc/apk/repositories" << 'APKREPO'
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
APKREPO

        # Base packages bootstrap script (runs on first boot)
        cat > "$ROOTFS/etc/profile.d/first-boot.sh" << 'FIRSTBOOT'
#!/bin/sh
# First-boot: install essential tools
if [ ! -f /etc/.first-boot-done ] && [ -x /usr/bin/apk ] && ping -c1 -W2 dl-cdn.alpinelinux.org >/dev/null 2>&1; then
    echo "🛠️  First boot — installing base packages (nano, curl, htop, SSH)..."
    apk update --quiet 2>/dev/null
    apk add --no-cache nano curl htop procps-ng ca-certificates-bundle dropbear dropbear-dbclient 2>/dev/null
    touch /etc/.first-boot-done
    echo "✅ Base packages installed"
fi
FIRSTBOOT
        chmod +x "$ROOTFS/etc/profile.d/first-boot.sh" || true
        mkdir -p "$ROOTFS/etc/profile.d"

        echo "    ✅ APK package manager ready (base packages install on first boot)"
    fi
    rm -rf "$APK_TARBALL" /tmp/sbin 2>/dev/null || true
else
    echo "    ⚠️  Cannot download apk-tools"
fi

# Create default SSH host keys (dropbear)
mkdir -p "$ROOTFS/etc/dropbear"
# Keys will be generated on first boot if not present

# Clean up
rm -f "$APK_STATIC" /tmp/*.apk 2>/dev/null || true

# parted (for disk partitioning)
if command -v parted &>/dev/null; then
    cp "$(command -v parted)" "$ROOTFS/usr/sbin/parted"
    # Copy library dependencies for parted
    for lib in $(ldd "$(command -v parted)" 2>/dev/null | grep -o '/[^ ]*' | grep -v 'linux-vdso'); do
        mkdir -p "$ROOTFS$(dirname "$lib")"
        cp -n "$lib" "$ROOTFS$lib" 2>/dev/null || true
    done
fi

# mkfs.fat
if command -v mkfs.fat &>/dev/null; then
    cp "$(command -v mkfs.fat)" "$ROOTFS/usr/sbin/"
elif command -v mkfs.vfat &>/dev/null; then
    cp "$(command -v mkfs.vfat)" "$ROOTFS/usr/sbin/"
    ln -sf mkfs.vfat "$ROOTFS/usr/sbin/mkfs.fat" 2>/dev/null || true
fi

# mkfs.ext4
if command -v mkfs.ext4 &>/dev/null; then
    cp "$(command -v mkfs.ext4)" "$ROOTFS/usr/sbin/"
fi

# e2fsck, tune2fs, resize2fs
for tool in e2fsck tune2fs resize2fs blkid; do
    if command -v "$tool" &>/dev/null; then
        cp "$(command -v "$tool")" "$ROOTFS/usr/sbin/" 2>/dev/null || true
    fi
done

# GRUB tools
for grub_tool in grub-install grub-mkconfig grub-mkimage; do
    if command -v "$grub_tool" &>/dev/null; then
        cp "$(command -v "$grub_tool")" "$ROOTFS/usr/sbin/" 2>/dev/null || true
    fi
done

# udevadm / partprobe
for tool in udevadm partprobe; do
    if command -v "$tool" &>/dev/null; then
        cp "$(command -v "$tool")" "$ROOTFS/usr/sbin/" 2>/dev/null || true
    fi
done

# DHCP client
for dhcp in udhcpc dhclient; do
    for p in /usr/sbin/$dhcp /sbin/$dhcp /usr/bin/$dhcp /bin/$dhcp; do
        if [ -f "$p" ]; then cp "$p" "$ROOTFS/usr/bin/"; break; fi
    done
done

# ─────────────────────────────────────────────
# 5. Kernel + modules
# ─────────────────────────────────────────────
echo "🐧 [5/12] Copying kernel + modules..."

# Find running kernel
KERNEL_DIR=""
KERNEL_VER=""
for d in /lib/modules/*; do
    [ -d "$d" ] || continue
    # Skip non-standard kernels
    case "$(basename "$d")" in
        *generic|*amd64|*x86*) KERNEL_DIR="$d"; KERNEL_VER=$(basename "$d"); break ;;
    esac
done

if [ -z "$KERNEL_DIR" ]; then
    # Just take the first one
    for d in /lib/modules/*; do
        [ -d "$d" ] && { KERNEL_DIR="$d"; KERNEL_VER=$(basename "$d"); break; }
    done
fi

if [ -z "$KERNEL_VER" ]; then
    echo "❌ No kernel modules found in /lib/modules/"
    exit 1
fi

echo "  Kernel version: $KERNEL_VER"

# Copy kernel modules (critical subset to save space)
echo "  Copying modules..."
MOD_DEST="$ROOTFS/lib/modules/$KERNEL_VER"
mkdir -p "$MOD_DEST/kernel/drivers"

# Copy essential driver categories
copy_mods() {
    local src="$1"
    local dst="$MOD_DEST/kernel/drivers/$2"
    [ -d "$src" ] || return
    mkdir -p "$dst"
    cp -r "$src" "$(dirname "$dst")/" 2>/dev/null || true
}

# Storage (CRITICAL — no disk = no boot)
copy_mods "$KERNEL_DIR/kernel/drivers/ata" "ata"
copy_mods "$KERNEL_DIR/kernel/drivers/nvme" "nvme"
copy_mods "$KERNEL_DIR/kernel/drivers/virtio" "virtio"
copy_mods "$KERNEL_DIR/kernel/drivers/scsi" "scsi"
copy_mods "$KERNEL_DIR/kernel/drivers/usb/storage" "usb/storage"
copy_mods "$KERNEL_DIR/kernel/drivers/block" "block"

# Filesystem
copy_mods "$KERNEL_DIR/kernel/fs/ext4" "ext4"
copy_mods "$KERNEL_DIR/kernel/fs/ext2" "ext2"
copy_mods "$KERNEL_DIR/kernel/fs/vfat" "vfat"
copy_mods "$KERNEL_DIR/kernel/fs/isofs" "isofs"
copy_mods "$KERNEL_DIR/kernel/fs/overlayfs" "overlayfs"
copy_mods "$KERNEL_DIR/kernel/fs/squashfs" "squashfs"
copy_mods "$KERNEL_DIR/kernel/fs/xfs" "xfs"
copy_mods "$KERNEL_DIR/kernel/fs/btrfs" "btrfs"

# Network (common NICs)
copy_mods "$KERNEL_DIR/kernel/drivers/net/ethernet/intel" "net/ethernet/intel"
copy_mods "$KERNEL_DIR/kernel/drivers/net/ethernet/realtek" "net/ethernet/realtek"

# Loop, squashfs, overlay are usually built-in but include just in case
for mod_ko in loop.ko squashfs.ko overlay.ko; do
    find "$KERNEL_DIR" -name "$mod_ko" -exec cp {} "$MOD_DEST/" \; 2>/dev/null || true
done

# Copy modules.dep + modules.builtin if they exist
for f in modules.dep modules.builtin modules.order; do
    [ -f "$KERNEL_DIR/$f" ] && cp "$KERNEL_DIR/$f" "$MOD_DEST/" 2>/dev/null || true
done

# Find and copy kernel image
echo "  Copying kernel..."
KERNEL_IMG=""
for kpath in /boot/vmlinuz /vmlinuz "/boot/vmlinuz-$KERNEL_VER" /boot/vmlinuz-linux; do
    if [ -f "$kpath" ] && [ -r "$kpath" ]; then
        KERNEL_IMG="$kpath"
        break
    fi
done

if [ -z "$KERNEL_IMG" ]; then
    echo "❌ Cannot find kernel image"
    exit 1
fi

cp "$KERNEL_IMG" "$ROOTFS/boot/vmlinuz"
echo "  ✅ Kernel: $(basename "$KERNEL_IMG") ($KERNEL_VER)"

# ─────────────────────────────────────────────
# 6. User accounts
# ─────────────────────────────────────────────
echo "👤 [6/12] Setting up users..."

ANOS_HASH=$(python3 -c "import crypt; print(crypt.crypt('$DEFAULT_PASS', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo '$6$lHWbbl2fteHvrMve$ifBVepML7plgqJVnqudt1SQLHMakyMv3norKFhLOQWEMUV6NHMZRUQSe68jvSF1/Fbii2/8AsrgnnAtFUVGBp1')
ROOT_HASH=$(python3 -c "import crypt; print(crypt.crypt('$ROOT_PASS', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo '$6$lHWbbl2fteHvrMve$ifBVepML7plgqJVnqudt1SQLHMakyMv3norKFhLOQWEMUV6NHMZRUQSe68jvSF1/Fbii2/8AsrgnnAtFUVGBp1')

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

# ─────────────────────────────────────────────
# 7. System config
# ─────────────────────────────────────────────
echo "⚙️ [7/12] Writing system config..."

# Profile
cat > "$ROOTFS/etc/profile" << 'PROFILE'
export PATH=/usr/bin:/bin:/sbin:/usr/sbin
export ANOS_DIR=/opt/anos
export ANOS_SOCKET=/tmp/anos.sock

ANOS_READY=false
[ -S /tmp/anos.sock ] && ANOS_READY=true

# tty1: auto anos-cli for anos user
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
        exec /bin/sh
    fi
fi

echo ""
echo "🦾 AnosOS v1.0.1"
echo "─────────────────────"
$ANOS_READY && echo " AI daemon:  ✅ Online" || echo " AI daemon:  ❌ Offline"
echo " Type 'anos-install' for installation"
echo " Type 'apk add <pkg>' to install packages"
echo " Type 'anos-cli' for AI shell"
echo " Type 'exit' to log out"
echo ""
PROFILE

# Issue (pre-login banner)
cat > "$ROOTFS/etc/issue" << 'ISSUE'

╔══════════════════════════════════════════════╗
║       🦾 AnosOS — AI Native OS               ║
║          v1.0.1 — \l                         ║
║──────────────────────────────────────────────║
║  Login:  anos / anos                         ║
║  Root:   root / root                         ║
║                                              ║
║  Type 'anos-install' to install to disk      ║
║  ⚠️  CHANGE PASSWORDS on first login!        ║
╚══════════════════════════════════════════════╝

ISSUE

# /etc/motd
cat > "$ROOTFS/etc/motd" << 'MOTD'
🦾 AnosOS — AI Native OS

Commands:
  anos-cli         Start AI shell
  anos-install     Install to hard disk
  nano             Text editor
  htop             Process monitor
  curl             HTTP client
  ssh user@host    SSH client
  apk add <pkg>    Install packages (docker, git, vim...)
  exit             Log out

⚠️  Change default passwords: passwd anos / passwd root
MOTD

# Hostname
echo "anos" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" << HOSTS
127.0.0.1 localhost anos
::1       localhost
HOSTS

# ─────────────────────────────────────────────
# 8. Create squashfs (before initrd — initrd embeds it)
# ─────────────────────────────────────────────
echo "📦 [8/12] Creating squashfs..."
mksquashfs "$ROOTFS" "$SQUASHFS" -comp xz -noappend -quiet -wildcards \
    -e "proc/*" "sys/*" "dev/*" "tmp/*" "run/*" "mnt/*" "media/*" "overlay/*" 2>&1 || true
echo "  ✅ Squashfs: $(ls -lh "$SQUASHFS" | awk '{print $5}')"

# ─────────────────────────────────────────────
# 9. Build initrd (embeds squashfs for FUSE-less boot)
# ─────────────────────────────────────────────
echo "📦 [9/12] Building initrd..."

# Copy initrd-init as /init
cp "$(dirname "$0")/../init/initrd-init" "$INITRD_ROOT/init"
chmod +x "$INITRD_ROOT/init"

# Copy kernel modules into initrd too (needed before squashfs mounts)
echo "  Copying kernel modules to initrd..."
mkdir -p "$INITRD_ROOT/lib/modules"
cp -r "$ROOTFS/lib/modules/$KERNEL_VER" "$INITRD_ROOT/lib/modules/" 2>/dev/null || true

# Copy busybox into initrd (needed for early boot)
cp "$ROOTFS/bin/busybox" "$INITRD_ROOT/bin/busybox"
chmod +x "$INITRD_ROOT/bin/busybox"
mkdir -p "$INITRD_ROOT/bin"
ln -sf /bin/busybox "$INITRD_ROOT/bin/sh" 2>/dev/null || true

# Copy essential utilities into initrd
for util in mount umount cat ls echo mkdir sleep modprobe insmod \
    rmmod find grep mknod switch_root chroot cp ln dd; do
    ln -sf /bin/busybox "$INITRD_ROOT/bin/$util" 2>/dev/null || true
done

mkdir -p "$INITRD_ROOT/sbin"
ln -sf /bin/busybox "$INITRD_ROOT/sbin/switch_root" 2>/dev/null || true

# Copy kernel modules.dep for modprobe dependency resolution
cp "$ROOTFS/lib/modules/$KERNEL_VER/modules.dep" "$INITRD_ROOT/lib/modules/$KERNEL_VER/" 2>/dev/null || true

# Embed squashfs into initrd for direct boot (no CD mount needed)
cp "$SQUASHFS" "$INITRD_ROOT/anos.squashfs"

# Build initrd cpio
echo "  Creating initrd cpio archive..."
(cd "$INITRD_ROOT" && find . | cpio -o -H newc) > "$ROOTFS/boot/initrd.img"

# ─────────────────────────────────────────────
# 10. GRUB (BIOS + UEFI)
# ─────────────────────────────────────────────
echo "🖥️ [10/12] Setting up GRUB..."

ISO_GRUB="$ISO_DIR/boot/grub"

# Main grub.cfg
mkdir -p "$ISO_GRUB"

cat > "$ISO_GRUB/grub.cfg" << 'GRUBCFG'
set timeout=5
set default=0
loadfont unicode

menuentry "🦾 AnosOS Live" {
    linux /boot/vmlinuz console=tty1 quiet
    initrd /boot/initrd.img
}

menuentry "AnosOS — Verbose boot" {
    linux /boot/vmlinuz console=tty1
    initrd /boot/initrd.img
}

menuentry "AnosOS — Recovery (root shell)" {
    linux /boot/vmlinuz console=tty1 init=/bin/sh
    initrd /boot/initrd.img
}
GRUBCFG

# GRUB modules
GRUB_MODS="part_gpt part_msdos fat ext2 iso9660 normal boot linux configfile \
    search search_fs_file search_fs_uuid search_label \
    all_video gfxterm gfxmenu gfxterm_background gfxterm_menu \
    png jpeg echo test sleep reboot halt chain"

# BIOS (i386-pc) boot
if command -v grub-mkimage &>/dev/null; then
    echo "  Building BIOS core image..."
    BIOS_DIR="$ISO_GRUB/i386-pc"
    mkdir -p "$BIOS_DIR"
    grub-mkimage \
        --format=i386-pc \
        --output="$BIOS_DIR/core.img" \
        --prefix="/boot/grub" \
        $GRUB_MODS biosdisk 2>/dev/null || true

    # Copy BIOS modules
    if [ -d /usr/lib/grub/i386-pc ]; then
        cp /usr/lib/grub/i386-pc/*.mod "$BIOS_DIR/" 2>/dev/null || true
        cp /usr/lib/grub/i386-pc/*.lst "$BIOS_DIR/" 2>/dev/null || true
    fi
else
    echo "  ⚠️  grub-mkimage not found — BIOS boot may not work"
fi

# UEFI (x86_64-efi) boot
if command -v grub-mkimage &>/dev/null; then
    echo "  Building UEFI boot image..."
    EFI_DIR="/tmp/anos-efi"
    mkdir -p "$EFI_DIR/EFI/BOOT"

    grub-mkimage \
        --format=x86_64-efi \
        --output="$EFI_DIR/EFI/BOOT/BOOTX64.EFI" \
        --prefix="/EFI/BOOT" \
        $GRUB_MODS efi_gop efi_uga 2>/dev/null || true

    # Copy UEFI modules
    UEFI_MOD_DIR="$ISO_GRUB/x86_64-efi"
    mkdir -p "$UEFI_MOD_DIR"
    if [ -d /usr/lib/grub/x86_64-efi ]; then
        cp /usr/lib/grub/x86_64-efi/*.mod "$UEFI_MOD_DIR/" 2>/dev/null || true
        cp /usr/lib/grub/x86_64-efi/*.lst "$UEFI_MOD_DIR/" 2>/dev/null || true
    fi
else
    echo "  ⚠️  grub-mkimage not found — UEFI boot may not work"
fi

# Unicode font for GRUB
for font in /usr/share/grub/unicode.pf2 /boot/grub/fonts/unicode.pf2; do
    [ -f "$font" ] && cp "$font" "$ISO_GRUB/" && break
done

# ─────────────────────────────────────────────
# 11. Assemble ISO directory
# ─────────────────────────────────────────────
echo "💿 [11/12] Assembling ISO directory..."

# Copy boot files to ISO staging dir
cp "$ROOTFS/boot/vmlinuz" "$ISO_DIR/boot/vmlinuz"
cp "$ROOTFS/boot/initrd.img" "$ISO_DIR/boot/initrd.img"
cp "$SQUASHFS" "$ISO_DIR/anos.squashfs"

# ─────────────────────────────────────────────
# 12. Build ISO
# ─────────────────────────────────────────────
echo "💿 [12/12] Building ISO..."

# Build ISO with xorriso (BIOS + UEFI hybrid)
if command -v xorriso &>/dev/null; then
    echo "  Using xorriso (BIOS + UEFI hybrid)..."

    XO_ARGS="-as mkisofs"
    XO_ARGS="$XO_ARGS -R -r -J"
    XO_ARGS="$XO_ARGS -V '$ISO_LABEL'"
    XO_ARGS="$XO_ARGS -o '$OUTPUT'"

    # BIOS boot (El Torito)
    XO_ARGS="$XO_ARGS -b boot/grub/i386-pc/core.img"
    XO_ARGS="$XO_ARGS -no-emul-boot"
    XO_ARGS="$XO_ARGS -boot-load-size 4"
    XO_ARGS="$XO_ARGS -boot-info-table"

    # UEFI boot (EFI System Partition)
    if [ -d "/tmp/anos-efi/EFI" ]; then
        # Copy EFI boot files into ISO dir
        mkdir -p "$ISO_DIR/EFI/BOOT"
        cp /tmp/anos-efi/EFI/BOOT/BOOTX64.EFI "$ISO_DIR/EFI/BOOT/" 2>/dev/null || true

        # Create FAT image for EFI (platform ID 0xef)
        EFI_IMG="/tmp/anos-efi.img"
        dd if=/dev/zero of="$EFI_IMG" bs=1M count=10 2>/dev/null
        mkfs.fat -F12 "$EFI_IMG" 2>/dev/null || mkfs.vfat "$EFI_IMG" 2>/dev/null || true

        if command -v mcopy &>/dev/null; then
            mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT 2>/dev/null || true
            mcopy -i "$EFI_IMG" /tmp/anos-efi/EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/ 2>/dev/null || true

            XO_ARGS="$XO_ARGS -eltorito-alt-boot"
            XO_ARGS="$XO_ARGS -e '$EFI_IMG'"
            XO_ARGS="$XO_ARGS -no-emul-boot"
        fi
    fi

    # Build
    eval "xorriso $XO_ARGS '$ISO_DIR'" 2>&1 | grep -v "^xorriso\|^libisofs\|^GNU\|^Disk\|^ISO\|^Media\|^Created\|^Extents" || true

elif command -v genisoimage &>/dev/null; then
    echo "  Falling back to genisoimage (BIOS only)..."
    genisoimage \
        -R -r -J \
        -V "$ISO_LABEL" \
        -o "$OUTPUT" \
        -b boot/grub/i386-pc/core.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        "$ISO_DIR" 2>&1 | grep -v "^genisoimage\|^I:\|^Total\|^Using" || true

elif command -v grub-mkrescue &>/dev/null; then
    echo "  Falling back to grub-mkrescue..."
    grub-mkrescue \
        --modules="part_gpt fat ext2 iso9660 normal boot linux configfile search all_video" \
        -o "$OUTPUT" "$ISO_DIR" \
        2>&1 | grep -v "^xorriso\|^GNU\|^Disk\|^libisofs\|^grub-mkrescue" || true
else
    echo "❌ No ISO tool available (xorriso, genisoimage, or grub-mkrescue required)"
    exit 1
fi

# ─────────────────────────────────────────────
# 13. Result
# ─────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║       ✅ ISO Build Complete!                ║"
echo "╠══════════════════════════════════════════════╣"
echo "║                                              ║"

if [ -f "$OUTPUT" ]; then
    SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
    echo "║  📀 $OUTPUT ($SIZE)"
    echo "║                                              ║"
    echo "║  Features:                                   ║"
    echo "║   • UEFI + BIOS dual boot                    ║"
    echo "║   • Live system with overlayfs               ║"
    echo "║   • Multi-user login (anos / root)           ║"
    echo "║   • anos-install to hard disk                ║"
    echo "║   • Kernel modules for real hardware         ║"
    echo "║                                              ║"
    echo "║  Login:  anos / anos                         ║"
    echo "║  Root:   root / root                         ║"
    echo "║  ⚠️  CHANGE ALL PASSWORDS!                  ║"
else
    echo "║  ❌ Build FAILED — no ISO produced           ║"
fi

echo "║                                              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
$([ -f "$OUTPUT" ] && echo "Test: qemu-system-x86_64 -cdrom $OUTPUT -m 2048 -enable-kvm")
echo ""
echo "Install: Boot ISO → login → run 'anos-install'"
echo ""

# Cleanup temp
rm -rf "$ROOTFS" "$INITRD_ROOT" "$SQUASHFS" "$ISO_DIR" "$DOWNLOAD_DIR" /tmp/anos-efi /tmp/anos-efi.img 2>/dev/null || true
