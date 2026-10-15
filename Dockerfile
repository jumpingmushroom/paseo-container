# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Stage: runtime
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS runtime

ARG TARGETARCH
ARG S6_VERSION=3.2.3.2
ARG S6_SHA256_NOARCH=5379750ed30a84bbd2e2dd74847ba6b5bd29cd0b2e3ea2ec58049b57eb2eda12
ARG S6_SHA256_AMD64=e6befcc96a437a3831386ecfc51808c5d3e939dc5fe3c02ae9284599e8aa2408
ARG S6_SHA256_ARM64=b17f17a82e7a515c682a91edaf2ffdabb73f891981b6c1fd712115693a2f8b4c
ARG NODE_VERSION=24.20.0
ARG NODE_SHA256_AMD64=2f2c0da162318f0de47665410c7c8c2ed3d36c8f3105de4bbc61176c70a7cbf2
ARG NODE_SHA256_ARM64=5f4ddab610c1ab2016b3c227cebdbf6d9495161487e4739c7b90090595f465f7
ARG UV_VERSION=0.12.10
ARG UV_SHA256_AMD64=173d95a0c32d18c896c46ba6fafbf3cf9c14ab74b033f81b76c883ef492a976b
ARG UV_SHA256_ARM64=9ff6b9d4665edcdd3a88dcc73cd1eb641754deb927f14e8c62ebfde6bf4f5f5e

ENV DEBIAN_FRONTEND=noninteractive \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_KEEP_ENV=1 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    LANG=C.UTF-8

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The package set is the baseline an agent can assume: transfer and archive
# tools, a shell multiplexer, network probes for reaching the other containers
# on the host, and sqlite3 for reading an application's database. Anything
# heavier -- a compiler, gnupg, ffmpeg -- goes in APT_PACKAGES, and anything
# with a CLI on npm or PyPI goes in NPM_TOOLS or PYTHON_TOOLS, which install
# into /config and survive a recreate.
#
# Debian ships ripgrep's companion as fdfind, because fd is taken by another
# package, so the symlink below gives agents the name every fd tutorial uses.
#
# Debian generates SSH host keys when openssh-server is installed. Shipping
# them inside a public image would give every user of that image the same
# host identity, so they are removed in this same RUN — a separate later RUN
# would only write a whiteout, leaving the keys recoverable from this layer
# by anyone who pulls the image. 03-ssh-keys generates a unique set into
# /config on first boot.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash-completion \
        bind9-dnsutils \
        bzip2 \
        ca-certificates \
        curl \
        fd-find \
        git \
        git-lfs \
        iputils-ping \
        jq \
        less \
        locales \
        nano \
        netcat-openbsd \
        openssh-server \
        patch \
        procps \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        rsync \
        sqlite3 \
        tmux \
        tree \
        tzdata \
        unzip \
        wget \
        xz-utils \
        zip \
        zstd \
    && rm -f /etc/ssh/ssh_host_* \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd

# s6-overlay
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) s6arch="x86_64"; s6sha="${S6_SHA256_AMD64}" ;; \
      arm64) s6arch="aarch64"; s6sha="${S6_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/just-containers/s6-overlay/releases/download/v${S6_VERSION}"; \
    curl -fsSL --retry 3 "${base}/s6-overlay-noarch.tar.xz" -o /tmp/s6-noarch.tar.xz; \
    echo "${S6_SHA256_NOARCH}  /tmp/s6-noarch.tar.xz" | sha256sum -c -; \
    curl -fsSL --retry 3 "${base}/s6-overlay-${s6arch}.tar.xz" -o /tmp/s6-arch.tar.xz; \
    echo "${s6sha}  /tmp/s6-arch.tar.xz" | sha256sum -c -; \
    tar -C / -Jxpf /tmp/s6-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-arch.tar.xz; \
    rm -f /tmp/s6-noarch.tar.xz /tmp/s6-arch.tar.xz

# Node.js. Debian's packaged Node is older than current agent CLIs support,
# so the official distribution tarball is used instead.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) nodearch="x64"; nodesha="${NODE_SHA256_AMD64}" ;; \
      arm64) nodearch="arm64"; nodesha="${NODE_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${nodearch}.tar.xz" \
      -o /tmp/node.tar.xz; \
    echo "${nodesha}  /tmp/node.tar.xz" | sha256sum -c -; \
    tar -C /usr/local --strip-components=1 --no-same-owner -Jxf /tmp/node.tar.xz \
      --exclude CHANGELOG.md --exclude LICENSE --exclude README.md; \
    rm -f /tmp/node.tar.xz; \
    node --version; \
    npm --version

# Agents are updated by this container, never by themselves.
#
# An agent's own updater runs `npm install --global` from inside the running
# agent, and npm does not overwrite a package in place: it renames the old
# directory aside, installs the new one, then removes what it renamed. That
# last step is an rmdir, and the running agent still holds its own executable
# open. Unlinking an open file drops its directory entry immediately on a
# normal filesystem, so the rmdir succeeds -- but /config is a bind mount the
# operator chooses, and on Unraid it is shfs, which is FUSE. FUSE renames an
# unlinked-but-still-open file to .fuse_hiddenXXXX in that same directory
# instead, so the rmdir fails with ENOTEMPTY and npm aborts having already
# moved the working install aside. The agent's executable is gone, and every
# later attempt trips over the same hidden file.
#
# The first self-update is what plants the hidden file and it appears to
# succeed; the next one is what destroys the install. That delay is why this
# is worth a comment rather than a one-line revert: it looks like it works.
#
# So npm's global prefix is deliberately left at root-owned /usr/local, where
# an agent running as paseo cannot write, and the updater is switched off
# outright so it does not nag about a prefix it is never meant to reach.
# npm_agent_install and npm_tool_install pass --prefix explicitly and are
# unaffected. Updating an agent is AGENT_UPDATE=1, which reinstalls on the
# next boot -- the one moment nothing holds an agent executable open, and so
# the one moment npm's rename-and-remove is safe.
ENV DISABLE_AUTOUPDATER=1

# uv. One static binary that provides both `uv tool install`, which is how
# PYTHON_TOOLS puts a CLI such as the OpenStack client into /config, and
# `uvx`, which is how most Python MCP servers expect to be run. It replaces
# pipx here: pip itself cannot install anything into this image, because
# Debian marks its Python installation externally managed (PEP 668).
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) uvarch="x86_64-unknown-linux-gnu"; uvsha="${UV_SHA256_AMD64}" ;; \
      arm64) uvarch="aarch64-unknown-linux-gnu"; uvsha="${UV_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uvarch}.tar.gz" \
      -o /tmp/uv.tar.gz; \
    echo "${uvsha}  /tmp/uv.tar.gz" | sha256sum -c -; \
    tar -C /usr/local/bin --strip-components=1 --no-same-owner -xzf /tmp/uv.tar.gz; \
    rm -f /tmp/uv.tar.gz; \
    uv --version; \
    uvx --version

RUN set -eux; \
    groupadd -g 100 paseo 2>/dev/null || groupadd paseo; \
    useradd -m -d /home/paseo -s /bin/bash -g paseo paseo; \
    mkdir -p /config /home/paseo/workspace /run/sshd; \
    ln -s /home/paseo/workspace /workspace; \
    chown paseo:paseo /config /home/paseo/workspace

COPY LICENSE /usr/share/doc/paseo-container/
COPY rootfs/ /

RUN set -eux; \
    find /etc/s6-overlay/s6-rc.d -type f \( -name run -o -name up \) -exec chmod 0755 {} +; \
    chmod 0755 /usr/local/bin/paseo-container-banner

EXPOSE 22

ENTRYPOINT ["/init"]
