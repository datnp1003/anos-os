# 🦾 AnosOS Container — Pulls anos binaries from release, adds OS layer
# Usage: docker build --build-arg ANOS_VERSION=v0.11.0 -t anos-os .

FROM alpine:3.21

ARG ANOS_VERSION=v0.11.0
ENV ANOS_VERSION=${ANOS_VERSION}

LABEL org.opencontainers.image.source="https://github.com/datnp1003/anos-os"
LABEL org.opencontainers.image.description="AnosOS — AI Native OS Container"

# Install system deps
RUN apk add --no-cache ca-certificates curl bash busybox-openrc

# Create anos user
RUN adduser -D -h /home/anos anos && \
    mkdir -p /opt/anos/{config,skills} /home/anos/.anos

# ── Download anos binaries from GitHub Release ──
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/x86_64/') && \
    BASE="https://github.com/datnp1003/anos/releases/download/${ANOS_VERSION}" && \
    echo "Downloading Anos ${ANOS_VERSION} (${ARCH})..." && \
    ( curl -fsSL "${BASE}/anosd-linux-${ARCH}" -o /usr/local/bin/anosd || \
      curl -fsSL "${BASE}/anosd" -o /usr/local/bin/anosd ) && \
    ( curl -fsSL "${BASE}/anos-cli-linux-${ARCH}" -o /usr/local/bin/anos-cli || \
      curl -fsSL "${BASE}/anos-cli" -o /usr/local/bin/anos-cli ) && \
    chmod +x /usr/local/bin/anosd /usr/local/bin/anos-cli

# ── Download skills + prompt from source tarball ──
RUN mkdir -p /tmp/anos-assets && \
    ( curl -fsSL "https://api.github.com/repos/datnp1003/anos/tarball/${ANOS_VERSION}" -o /tmp/anos-source.tar.gz && \
      tar xzf /tmp/anos-source.tar.gz -C /tmp/anos-assets --strip-components=1 && \
      cp /tmp/anos-assets/ANOS-SYSTEM-PROMPT.md /opt/anos/ && \
      cp -r /tmp/anos-assets/skills/* /opt/anos/skills/ ) || \
    echo "⚠️ Could not download assets — using defaults"

# ── Copy OS layer (init + profile) ──
COPY init/anos-init /sbin/init
COPY docker/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /sbin/init /usr/local/bin/docker-entrypoint.sh && \
    chown -R anos:anos /opt/anos /home/anos

ENV ANOS_DIR=/opt/anos
ENV ANOS_SOCKET=/tmp/anos.sock
EXPOSE 8787

USER anos
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
