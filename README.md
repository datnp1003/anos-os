# 🦾 AnosOS — AI Native Operating System

> **The OS layer for Anos.** Full-featured bootable ISO with installer.
>
> Core tool: [datnp1003/anos](https://github.com/datnp1003/anos)

---

## What is this?

AnosOS is a minimal Linux distribution that boots directly into **Anos AI OS**.  
It bundles the Anos daemon + CLI with a kernel, init system, multi-user login, and a full disk installer.

```
Boot CD/USB → Live System → Login → Anos CLI → AI-powered system management
                                    └─ anos-install → Install to hard disk
```

## Architecture

```
┌──────────────────────────────────────────────┐
│            AnosOS ISO (BIOS + UEFI)          │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │  initrd.img                            │  │
│  │  ├─ /init          (mount + switch)    │  │
│  │  ├─ /bin/busybox   (shell)            │  │
│  │  ├─ /lib/modules/  (kernel drivers)   │  │
│  │  └─ /anos.squashfs (rootfs embedded)  │  │
│  ├────────────────────────────────────────┤  │
│  │  anos.squashfs (read-only root)        │  │
│  │  ├─ anosd + anos-cli                  │  │
│  │  ├─ anos-init (PID 1)                 │  │
│  │  ├─ anos-install (disk installer)     │  │
│  │  ├─ busybox userland                  │  │
│  │  └─ kernel modules                    │  │
│  ├────────────────────────────────────────┤  │
│  │  EFI/BOOT/BOOTX64.EFI (UEFI)          │  │
│  │  boot/grub/i386-pc/   (BIOS)          │  │
│  │  boot/vmlinuz          (kernel)        │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

## Features

- 🔐 **Multi-user login** — getty on tty1-3 with `/etc/passwd`, `/etc/shadow`
- 🦾 **Auto AI CLI** — tty1 launches `anos-cli` after login
- 🛟 **Fallback shells** — tty2 (root), tty3 (admin)
- 💿 **Full disk installer** — `anos-install` with GPT, ext4, GRUB
- 🖥️ **UEFI + BIOS dual boot** — boots on both modern and legacy hardware
- 📦 **Live system** — overlayfs (squashfs + tmpfs) for read-write live environment
- 🔌 **Kernel modules** — storage (ATA, NVMe, virtio), FS (ext4, vfat, xfs, btrfs), network drivers
- 🐳 **Docker image** — Alpine-based container
- 🏗️ **CI auto-build** — ISO built on every tag push

## Quick Start

### Download ISO

```bash
wget https://github.com/datnp1003/anos-os/releases/latest/download/anos-os-linux-amd64.iso
```

### Boot

```bash
# QEMU test
qemu-system-x86_64 -cdrom anos-os-linux-amd64.iso -m 2048 -enable-kvm

# Write to USB
sudo dd if=anos-os-linux-amd64.iso of=/dev/sdX bs=4M status=progress
```

### Install to Disk

```
1. Boot ISO → Login as anos / anos
2. Run: anos-install
3. Select disk, confirm, reboot
4. Remove media, boot from disk
```

### Boot Options

| Kernel param | Effect |
|---|---|
| (default) | Normal boot → getty login |
| `install` | Skip login, launch `anos-install` directly |
| `rescue` | Boot to root shell (no login) |
| `live` | Force live mode detection |

### Docker

```bash
docker pull ghcr.io/datnp1003/anos-os:latest
docker run -d --name anos -p 8788:8787 ghcr.io/datnp1003/anos-os:latest
```

## Default Credentials

| User | Password | tty | Role |
|------|----------|-----|------|
| `anos` | `anos` | tty1 | AI User → auto anos-cli |
| `root` | `root` | tty2 | Fallback shell |

⚠️ **Change all passwords on first boot!**

## Build from Source

```bash
git clone https://github.com/datnp1003/anos-os.git
cd anos-os

# Build ISO
make iso ANOS_VERSION=v0.11.0

# Build + test in QEMU
make run-iso

# Docker image
make docker
```

### Requirements

- `xorriso`, `squashfs-tools`, `cpio`, `busybox-static`
- `grub-pc-bin`, `grub-efi-amd64-bin` (for dual boot)
- `mtools`, `dosfstools`, `e2fsprogs`, `parted` (for installer tools)

## Directory Structure

```
anos-os/
├── init/
│   ├── anos-init       # PID 1 init (multi-user, respawn)
│   ├── initrd-init     # Initrd /init (mount + switch_root)
│   └── anos-install    # Disk installer (GPT, ext4, GRUB)
├── iso/
│   └── build-iso.sh    # ISO builder (v2: UEFI+BIOS, modules, tools)
├── kernel/             # Custom kernel configs (future)
├── docker/             # Dockerfile + docker-compose
├── .github/workflows/
│   └── build-iso.yml   # CI: auto-build on tag push
├── Makefile
└── README.md
```

## Relationship with anos

| Repo | Scope | Release |
|------|-------|---------|
| `datnp1003/anos` | CLI + Daemon + Skills | `v0.11.0` |
| `datnp1003/anos-os` | Kernel + Init + ISO + Installer | `v1.0.1` |

AnosOS **pins** a specific `anos` release version. ISO build pulls binaries from:
```
https://github.com/datnp1003/anos/releases/download/<version>/
```

## Boot Flow

```
Power on
  ↓
BIOS/UEFI → GRUB → kernel + initrd
  ↓
initrd /init:
  1. Mount proc/sys/dev
  2. Load storage + FS kernel modules
  3. Locate anos.squashfs (CD/USB/embedded)
  4. Mount squashfs + tmpfs overlay
  5. switch_root → /sbin/init
  ↓
/sbin/init (anos-init):
  1. Mount virtual filesystems
  2. Load network + storage modules
  3. DHCP network
  4. Start anosd daemon
  5. Spawn getty on tty1-tty3
  ↓
Login → anos-cli (tty1) / shell (tty2-3)
```

## License

MIT
