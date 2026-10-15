#!/usr/bin/env bash
# Shared helpers for paseo-container s6 service scripts.
# Source this file; do not execute it.

set -euo pipefail

CONTAINER_USER="paseo"
CONTAINER_GROUP="paseo"
USER_HOME="/home/paseo"
CONFIG_DIR="/config"
# The share is mounted inside the home directory, not at /workspace, because
# Paseo roots its folder suggestions at $HOME and rejects any path whose real
# path falls outside it (getpaseo/paseo#1787). /workspace is a symlink here.
WORKSPACE_DIR="/home/paseo/workspace"
AGENT_PREFIX="/config/agents"
AGENT_LIB_DIR="/usr/local/lib/paseo-container/agents"
TOOL_PREFIX="/config/tools"
GIT_CREDENTIALS="/config/git/credentials"
export CONTAINER_USER CONTAINER_GROUP USER_HOME CONFIG_DIR WORKSPACE_DIR
export AGENT_PREFIX AGENT_LIB_DIR TOOL_PREFIX GIT_CREDENTIALS

log() {
    printf '[%s] %s\n' "${LOG_TAG:-paseo-container}" "$1"
}

warn() {
    printf '[%s] WARNING: %s\n' "${LOG_TAG:-paseo-container}" "$1" >&2
}

die() {
    printf '[%s] ERROR: %s\n' "${LOG_TAG:-paseo-container}" "$1" >&2
    exit 1
}

# link_persist SOURCE TARGET
#
# Ensures TARGET (inside the ephemeral home directory) is a symlink to SOURCE
# (inside the persistent /config volume). Creates SOURCE's parent directory.
# When TARGET exists as a real file and SOURCE does not, TARGET's content is
# moved to SOURCE. When both exist, /config wins and TARGET is discarded.
#
# A trailing slash on SOURCE marks it as a directory, which link_persist then
# creates. Without it, SOURCE is treated as a regular file and left for
# whoever writes through TARGET to create.
link_persist() {
    local source="$1" target="$2" source_is_dir=0

    case "$source" in
        */) source_is_dir=1 ;;
    esac
    source="${source%/}"
    target="${target%/}"

    mkdir -p "$(dirname "$source")" "$(dirname "$target")"

    if [ -L "$target" ]; then
        if [ "$(readlink "$target")" != "$source" ]; then
            rm -f "$target"
        fi
    elif [ -e "$target" ]; then
        if [ ! -e "$source" ]; then
            mv "$target" "$source"
        else
            rm -rf "$target"
        fi
    fi

    # A directory SOURCE must exist before anything writes through TARGET.
    # open() through a dangling symlink creates the missing file, so a file
    # SOURCE heals itself on first write; mkdir() through one fails with
    # EEXIST, so a directory SOURCE never does. An agent that keeps its
    # credentials in a directory -- Claude Code's ~/.claude, for one -- then
    # loses every write it makes, and asks you to log in again on every
    # single run. This runs after the migration branch above, so an existing
    # real TARGET directory is still moved to SOURCE rather than shadowed by
    # an empty new one.
    if [ "$source_is_dir" = 1 ] && [ ! -d "$source" ]; then
        mkdir -p "$source"
    fi

    [ -L "$target" ] || ln -s "$source" "$target"
}

# npm_agent_install PACKAGE
#
# Installs an npm package into AGENT_PREFIX so its executables land in
# /config/agents/bin, which persists across container recreates. npm's own
# cache stays in the ephemeral home directory; it holds nothing worth keeping.
#
# Runs as CONTAINER_USER, not root: npm and the package's own lifecycle scripts
# (postinstall etc.) execute arbitrary code from a third-party package, and by
# the time 04-agents runs, AGENT_PREFIX and USER_HOME are already
# paseo-owned, so dropping privilege here costs nothing.
npm_agent_install() {
    local package="$1"
    /command/s6-setuidgid "$CONTAINER_USER" \
        env HOME="$USER_HOME" PATH="$PATH" \
        npm install --global \
            --prefix "$AGENT_PREFIX" \
            --no-fund --no-audit --loglevel=error \
            "$package"
}

# tool_env: prints the environment every uv invocation in this image needs, so
# that an interactive `uvx` in a pane and the boot-time PYTHON_TOOLS install
# agree on where things live -- all of it under TOOL_PREFIX, which is on the
# /config volume.
#
# Keep this in sync with /etc/profile.d/paseo-container.sh, which exports the
# same five variables into interactive shells; the profile script cannot
# source this file, because sourcing anything that sets -e into a login shell
# makes the first failing command close the session.
#
# UV_PYTHON_INSTALL_DIR is the one that is easy to leave out and expensive to
# get wrong. uv builds a tool's virtualenv against an interpreter it downloads
# itself, and a virtualenv outlives the image it was built under, so pointing
# uv at the image's own /usr/bin/python3 would break every persisted tool on
# the first base image upgrade that moves to a new Python minor version.
# UV_PYTHON_PREFERENCE makes that a guarantee rather than a default uv is free
# to change: only-managed never reaches for the image's Python at all.
tool_env() {
    printf '%s\n' \
        "UV_TOOL_DIR=${TOOL_PREFIX}/uv/tools" \
        "UV_TOOL_BIN_DIR=${TOOL_PREFIX}/bin" \
        "UV_PYTHON_INSTALL_DIR=${TOOL_PREFIX}/uv/python" \
        "UV_PYTHON_PREFERENCE=only-managed" \
        "UV_CACHE_DIR=${TOOL_PREFIX}/uv/cache"
}

# npm_tool_install SPEC
#
# Installs an npm package into TOOL_PREFIX, so its executables land in
# /config/tools/bin and survive a container recreate. SPEC is anything
# `npm install` accepts, including a version, so `json@11` pins one.
#
# Runs as CONTAINER_USER for the same reason npm_agent_install does: npm runs a
# package's own lifecycle scripts, and there is no reason to hand a
# third-party postinstall script root.
npm_tool_install() {
    local spec="$1"
    /command/s6-setuidgid "$CONTAINER_USER" \
        env HOME="$USER_HOME" PATH="$PATH" \
            npm install --global \
                --prefix "$TOOL_PREFIX" \
                --no-fund --no-audit --loglevel=error \
                "$spec"
}

# uv_tool_install SPEC
#
# Installs a Python CLI into TOOL_PREFIX with uv, each in its own virtualenv,
# and links its executables into /config/tools/bin. SPEC is anything
# `uv tool install` accepts, so `ansible-core==2.17.*` pins one.
#
# `uv tool install` on a package it already has is a no-op that exits 0, which
# is the right thing on an ordinary boot but not what TOOL_UPDATE=1 asks for;
# --reinstall is what actually rebuilds it. npm needs no equivalent, since
# `npm install` re-resolves the spec every time it runs.
uv_tool_install() {
    local spec="$1" env_args=() install_args=(--quiet)
    while IFS= read -r pair; do
        env_args+=("$pair")
    done < <(tool_env)

    if [ "${TOOL_UPDATE:-0}" = "1" ]; then
        install_args+=(--reinstall)
    fi

    /command/s6-setuidgid "$CONTAINER_USER" \
        env HOME="$USER_HOME" PATH="$PATH" "${env_args[@]}" \
            uv tool install "${install_args[@]}" "$spec"
}

# chown_home UID:GID
#
# Claims everything under the home directory except the source share. The
# share is mounted at WORKSPACE_DIR, inside the home directory, so a plain
# `chown -R "$USER_HOME"` would walk every repository in it -- slow on a large
# tree, and wrong for files that Syncthing or another container owns. The
# mount point itself is claimed separately, without recursion, by
# 01-user-setup.
chown_home() {
    local owner="$1"
    find "$USER_HOME" -path "$WORKSPACE_DIR" -prune -o \
        -exec chown -h "$owner" {} +
}

# bin_tool_install SPEC
#
# Installs one single-binary tool into TOOL_PREFIX/bin. SPEC is name=url, with
# an optional #sha256=<hex> suffix on the URL. kubectl and talosctl ship as
# plain executables on neither npm nor PyPI, which is why this exists. You pin
# the version in the URL.
#
# The function downloads to a temporary file beside the destination and
# renames it into place only after the checksum passes, so a failed or partial
# download never puts a broken command on PATH. A #sha256= suffix with a value
# that is not 64 hex characters fails the install: an empty value must not
# silently turn verification off.
bin_tool_install() {
    local spec="$1" name url sha="" has_sha=0 tmp
    name="${spec%%=*}"
    url="${spec#*=}"
    if [ -z "$name" ] || [ "$name" = "$spec" ] || [ -z "$url" ]; then
        warn "bin: '${spec}' is not name=url"
        return 1
    fi
    case "$name" in
        */*|.*) warn "bin: '${name}' is not a plain command name"; return 1 ;;
    esac
    case "$url" in
        *'#sha256='*)
            has_sha=1
            sha="${url##*#sha256=}"
            url="${url%#sha256=*}"
            ;;
    esac
    if [ "$has_sha" = 1 ] && ! [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
        warn "bin: ${name}: invalid sha256 '${sha}'"
        return 1
    fi

    if ! tmp="$(mktemp "${TOOL_PREFIX}/bin/.bin-tool.XXXXXX")"; then
        warn "bin: ${name}: could not create a temporary file in ${TOOL_PREFIX}/bin"
        return 1
    fi
    if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 600 -o "$tmp" "$url"; then
        rm -f "$tmp"
        warn "bin: ${name}: download failed from ${url}"
        return 1
    fi
    if [ "$has_sha" = 1 ] && ! printf '%s  %s\n' "$sha" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$tmp"
        warn "bin: ${name}: checksum mismatch"
        return 1
    fi
    if ! chmod 0755 "$tmp"; then
        rm -f "$tmp"
        warn "bin: ${name}: could not make the download executable"
        return 1
    fi
    chown "${PUID:-99}:${PGID:-100}" "$tmp" \
        || warn "bin: ${name}: could not set ownership"
    mv -f "$tmp" "${TOOL_PREFIX}/bin/${name}"
}
