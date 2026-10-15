#!/usr/bin/env bash
# Agent installer: OpenAI Codex CLI.
# Sourced by 04-agents; do not execute directly.

# npm's @openai/codex entry point is a Node shim that spawns the natively
# compiled codex as a child process. This installer replaces the shim with a
# wrapper that execs the native binary, so codex runs as one process and the
# wrapper can clear codex's stale arg0 directories first (see below).

CODEX_BIN="${AGENT_PREFIX}/bin/codex"
CODEX_PKG="${AGENT_PREFIX}/lib/node_modules/@openai/codex"
CODEX_WRAPPER_TAG="paseo-container codex wrapper v1"

# codex_native_bin: prints the vendored native executable that npm's shim
# would have spawned. That executable arrives in a platform-specific optional
# dependency, so npm is free to leave it nested under @openai/codex or to
# hoist it to the install prefix's own node_modules, and both the arch pair in
# its package name and the target triple below it differ between amd64 and
# arm64. Globbing covers all four cases without the installer having to know
# the architecture it is running on.
codex_native_bin() {
    local root candidate
    for root in "${CODEX_PKG}/node_modules/@openai" \
                "${AGENT_PREFIX}/lib/node_modules/@openai"; do
        for candidate in "${root}"/codex-linux-*/vendor/*/bin/codex; do
            if [ -x "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done
    return 1
}

# codex_write_wrapper: replaces whatever npm left at CODEX_BIN with the
# wrapper. Removing it first is not optional: npm leaves a symlink into the
# package there, and a redirection through a symlink truncates what it points
# at -- here, the shim's own codex.js.
codex_write_wrapper() {
    local native
    native="$(codex_native_bin)" || return 1

    rm -f "$CODEX_BIN"
    cat > "$CODEX_BIN" <<EOF
#!/bin/sh
# ${CODEX_WRAPPER_TAG}, written by ${AGENT_LIB_DIR}/codex.sh.
# exec, so that codex replaces this shell rather than running as its child.
CODEX_MANAGED_PACKAGE_ROOT="${CODEX_PKG}"
CODEX_MANAGED_BY_NPM=1
export CODEX_MANAGED_PACKAGE_ROOT CODEX_MANAGED_BY_NPM
unset CODEX_MANAGED_BY_BUN CODEX_MANAGED_BY_PNPM CODEX_MANAGED_BY_VITE_PLUS

# Clear stale arg0 helper directories before codex looks at them.
#
# codex keeps a run's helper symlinks in \$CODEX_HOME/tmp/arg0/codex-arg0*, and
# on startup removes the ones no live process owns: it flocks a directory's
# .lock to prove that, then unlinks the contents while that fd is still open,
# then rmdir's. Unlinking an open file drops its directory entry at once on a
# normal filesystem, so the rmdir succeeds. On FUSE it does not: the file is
# renamed to .fuse_hiddenXXXX in the same directory instead, the rmdir fails
# with ENOTEMPTY, and codex prints
#   WARNING: failed to clean up stale arg0 temp dirs: Directory not empty
# on every single run. That failure aborts the whole pass, so each run also
# leaks a directory -- empty by the time the fd closes, and skipped by every
# later run. /config is a bind mount the operator chooses, and on Unraid that
# is shfs, a FUSE filesystem, so this is the default case there rather than an
# exotic one. Clearing them here leaves codex's own pass nothing to trip over.
#
# A directory holding a .lock is judged by that lock alone and never by its
# age: flock -n fails while a live codex holds it and succeeds once that
# process is gone, so the directory the previous run left behind goes even
# when it is seconds old, which is what running codex twice in a minute
# produces. Age is consulted only for a directory with no .lock at all, which
# is either a long dead leftover or a codex that started moments ago and has
# not created its lock yet; skipping the young ones costs one stale directory
# and closes the only window in which this could delete a directory in use.
codex_arg0_dir="\${CODEX_HOME:-\$HOME/.codex}/tmp/arg0"
if [ -d "\$codex_arg0_dir" ]; then
    for d in "\$codex_arg0_dir"/codex-arg0*; do
        [ -d "\$d" ] || continue
        if [ -e "\$d/.lock" ]; then
            flock -n "\$d/.lock" true 2>/dev/null || continue
        else
            [ -n "\$(find "\$d" -maxdepth 0 -mmin +1 2>/dev/null)" ] || continue
        fi
        rm -rf "\$d"
    done
fi

exec "${native}" "\$@"
EOF
    chmod 0755 "$CODEX_BIN"
}

agent_persist_paths() {
    printf '%s\n' .codex/
}

# Testing for the wrapper rather than for any executable is what heals an
# install made before the wrapper existed, or one a manual `npm install -g`
# has since put npm's shim back over: it reports itself not installed, and
# the next boot reinstalls it once.
#
# The tag carries a version for the same reason. A wrapper this image wrote an
# edition ago is still executable and still tagged, so an unversioned test
# would call it installed and leave the old one in place on every future boot
# -- an upgrade would reach new installs and no existing one. Bump the suffix
# whenever the generated wrapper changes in a way already-installed containers
# need, and they repair themselves on the next boot.
agent_installed() {
    [ -x "$CODEX_BIN" ] && grep -q "$CODEX_WRAPPER_TAG" "$CODEX_BIN" 2>/dev/null
}

agent_install() {
    npm_agent_install "@openai/codex" || return 1
    # A missing native binary is not a wrapper problem: npm's own shim throws
    # "Missing optional dependency" and codex does not run either way. That
    # is a real install failure, and 04-agents should report it as one.
    codex_write_wrapper
}

agent_version() {
    "$CODEX_BIN" --version 2>/dev/null | head -n1
}
