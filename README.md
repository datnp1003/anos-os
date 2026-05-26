# 🦾 AnosOS — AI Native Operating System

> **The OS layer for Anos.** Bootable ISO, Docker containers, kernel configs.
>
> Core tool: [datnp1003/anos](https://github.com/datnp1003/anos)

---

## What is this?

AnosOS is a minimal Linux distribution that boots directly into **Anos AI OS**.  
It bundles the Anos daemon + CLI with a kernel, init system, and multi-user login.

```
Boot → Login → Anos CLI → AI-powered system management
```

## Architecture

```
┌─────────────────────────────────┐
│         AnosOS ISO              │
│  ┌───────────────────────────┐  │
│  │   anosd (daemon)          │  │  ← binary from anos release
│  │   anos-cli (AI shell)     │  │  ← binary from anos release
│  ├───────────────────────────┤  │
│  │   anos-init (PID 1)       │  │  ← THIS repo
│  │   getty + login + passwd  │  │
│  │   busybox userland        │  │
│  ├───────────────────────────┤  │
│  │   Linux kernel            │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘
```

## Features

- 🔐 **Multi-user login** — getty on tty1-3 with `/etc/passwd`, `/etc/shadow`
- 🧠 **Auto AI CLI** — tty1 launches `anos-cli` after login
- 🛟 **Fallback shells** — tty2 (root), tty3 (admin)
- 🐳 **Docker image** — Alpine-based container
- 🏗️ **CI auto-build** — ISO built on every tag push

## Quick Start

### Download ISO (from GitHub Releases)

```bash
# Download latest
wget https://github.com/datnp1003/anos-os/releases/latest/download/anos-os-linux-amd64.iso

# Boot in QEMU
qemu-system-x86_64 -cdrom anos-os-linux-amd64.iso -m 2048

# Write to USB
sudo dd if=anos-os-linux-amd64.iso of=/dev/sdX bs=4M status=progress
```

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
# Clone
git clone https://github.com/datnp1003/anos-os.git
cd anos-os

# Build ISO (requires anos binaries from GitHub Release)
make iso ANOS_VERSION=v0.11.0

# Build Docker image
make docker
```

## Directory Structure

```
anos-os/
├── init/           # PID 1 init script (anos-init)
├── iso/            # ISO builder (build-iso.sh)
├── kernel/         # Custom kernel configs
├── docker/         # Dockerfile + docker-compose
├── .github/        # CI/CD workflows
│   └── workflows/
│       └── build-iso.yml
├── Makefile        # Build all
└── README.md
```

## Relationship with anos

| Repo | Scope | Release |
|------|-------|---------|
| `datnp1003/anos` | CLI + Daemon + Skills | `v0.11.0` |
| `datnp1003/anos-os` | Kernel + Init + ISO + Docker | `os-v0.11.0` |

AnosOS **pins** a specific `anos` release version. ISO build pulls binaries from:
```
https://github.com/datnp1003/anos/releases/download/<version>/
```

## License

MIT
