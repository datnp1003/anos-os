.PHONY: all iso docker run-iso clean

ANOS_VERSION ?= v0.11.0
OS_VERSION ?= v1.0.1
ISO_OUTPUT ?= anos-os-linux-amd64.iso

all: iso

# ── Build ISO (live + installer) ──
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
	qemu-system-x86_64 \
		-cdrom $(ISO_OUTPUT) \
		-m 2048 \
		-enable-kvm \
		-cpu host \
		-netdev user,id=net0 -device e1000,netdev=net0

# ── Clean ──
clean:
	rm -f $(ISO_OUTPUT)
	rm -rf /tmp/anos-rootfs /tmp/anos-root.squashfs /tmp/initrd-root /tmp/initrd.img
	rm -rf /tmp/anos-iso /tmp/anos-efi /tmp/anos-efi.img /tmp/anos-dl-*
