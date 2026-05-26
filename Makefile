.PHONY: all iso docker clean

ANOS_VERSION ?= v0.11.0
ISO_OUTPUT ?= anos-os-linux-amd64.iso

all: iso

# ── Build ISO ──
iso:
	@echo "🦾 Building AnosOS ISO (anos $(ANOS_VERSION))"
	@bash iso/build-iso.sh $(ISO_OUTPUT) amd64 $(ANOS_VERSION)

# ── Build Docker image ──
docker:
	@echo "🐳 Building Docker image..."
	docker build -t anos-os:$(ANOS_VERSION) -f docker/Dockerfile .
	docker tag anos-os:$(ANOS_VERSION) anos-os:latest

# ── Run ISO in QEMU ──
run-iso: iso
	@echo "🖥️ Booting ISO in QEMU..."
	qemu-system-x86_64 -cdrom $(ISO_OUTPUT) -m 2048

# ── Clean ──
clean:
	rm -f $(ISO_OUTPUT)
	rm -rf /tmp/anos-rootfs /tmp/anos-root.squashfs /tmp/initrd-root /tmp/initrd.img
