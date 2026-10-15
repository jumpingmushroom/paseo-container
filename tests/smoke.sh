#!/usr/bin/env bash
# Behavioural smoke suite. Builds the image, starts it, asserts, tears down.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=tests/lib/assert.sh
source tests/lib/assert.sh

TMP_DIR="$REPO_ROOT/tests/.tmp"
SSH_KEY="$TMP_DIR/id_ed25519"
COMPOSE=(docker compose -f compose.yaml)

cleanup() {
    "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
}

dexec() {
    "${COMPOSE[@]}" exec -T paseo "$@"
}

# dexec_user: runs a command as the container user with that user's HOME,
# because plain `docker compose exec` defaults to root with HOME=/root.
dexec_user() {
    "${COMPOSE[@]}" exec -T -u paseo -e HOME=/home/paseo paseo "$@"
}

# boot_complete: 05-tools writes PID 1's start time into this marker as its
# last action, and 01-user-setup deletes the marker first thing, so a match
# means "this boot's oneshots all finished". /run survives `docker restart`,
# so a bare existence test could see the previous boot's marker; comparing
# against the current PID 1 start time (field 22 of /proc/1/stat) cannot.
# shellcheck disable=SC2016 # the $() must expand inside the container, not here.
boot_complete() {
    dexec sh -c '[ -s /run/paseo-container-ready ] && [ "$(cat /run/paseo-container-ready)" = "$(cut -d" " -f22 /proc/1/stat)" ]'
}

wait_for() {
    local name="$1" timeout="$2"
    shift 2
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    fail "$name" "timed out after ${timeout}s waiting for: $*"
    return 1
}

trap cleanup EXIT

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR/config" "$TMP_DIR/workspace"
ssh-keygen -t ed25519 -N '' -q -f "$SSH_KEY"

SSH_PUBKEY="$(cat "$SSH_KEY.pub")"
export SSH_PUBKEY
PUID="$(id -u)"
PGID="$(id -g)"
export PUID PGID

echo "== build =="
"${COMPOSE[@]}" build

echo "== boot =="
"${COMPOSE[@]}" up -d
wait_for "container reaches s6 ready" 240 boot_complete

echo "== base image =="
assert_eq "paseo user has PUID" "$PUID" "$(dexec id -u paseo | tr -d '\r')"
assert_eq "paseo user has PGID" "$PGID" "$(dexec id -g paseo | tr -d '\r')"
assert_eq "config is owned by paseo" "paseo" "$(dexec stat -c '%U' /config | tr -d '\r')"
# The baseline an agent is told it can assume, one representative per group:
# transfer, archive, network probe, data, and the Python installer that
# PYTHON_TOOLS and uvx-based MCP servers both go through. fd is checked by
# name rather than as fdfind, since the symlink is the point.
for cmd in rsync wget unzip zip tmux tree patch sqlite3 fd dig nc uv uvx; do
    assert_ok "${cmd} is in the image" dexec sh -c "command -v ${cmd} >/dev/null"
done
# The hostname is what every shell prompt and terminal title in the container
# shows, and only the creating command can set it -- a container cannot change
# its own. This asserts the harness matches what the README and the unRAID
# template tell you to pass, so dropping it from either is a failing test
# rather than a prompt that silently reverts to the container ID.
assert_eq "hostname is set at creation" "paseo" "$(dexec hostname | tr -d '\r')"

echo "== config scaffold =="
for path in ssh agents/bin agents/state git; do
    assert_ok "/config/$path exists" dexec test -d "/config/$path"
done
assert_eq "gitconfig links to /config" \
    "/config/git/gitconfig" \
    "$(dexec readlink /home/paseo/.gitconfig | tr -d '\r')"

echo "== the share keeps its own ownership =="
# The share sits inside the home directory, so a recursive chown of home would
# claim every file in it. A file another account owns must keep that owner.
dexec sh -c 'mkdir -p /home/paseo/workspace/.owner-probe \
    && touch /home/paseo/workspace/.owner-probe/file \
    && chown -R 4242:4242 /home/paseo/workspace/.owner-probe'
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "container returns for the ownership check" 240 boot_complete
assert_eq "a share file keeps a foreign owner across boots" "4242" \
    "$(dexec stat -c '%u' /home/paseo/workspace/.owner-probe/file | tr -d '\r')"
assert_eq "/workspace is a symlink to the share" "/home/paseo/workspace" \
    "$(dexec readlink /workspace | tr -d '\r')"
dexec rm -rf /home/paseo/workspace/.owner-probe

echo "== HOME_PERSIST =="
for rel in .config .kube .talos; do
    assert_eq "~/${rel} links to /config/home" "/config/home/${rel}" \
        "$(dexec readlink "/home/paseo/${rel}" | tr -d '\r')"
done
dexec_user sh -c 'printf "apiVersion: v1\n" > /home/paseo/.kube/config'
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container returns after a recreate" 240 boot_complete
assert_eq "a kubeconfig survives a recreate" "apiVersion: v1" \
    "$(dexec cat /home/paseo/.kube/config | tr -d '\r')"
assert_eq "persisted config is owned by paseo" "paseo" \
    "$(dexec stat -c '%U' /config/home/.kube/config | tr -d '\r')"

echo "== outbound git credential =="
# compose.yaml sets an obviously fake GIT_TOKEN. What matters is where the
# token lands, how it is protected, and that git actually reaches for it.
assert_eq "the credential file is private" "600" \
    "$(dexec stat -c '%a' /config/git/credentials | tr -d '\r')"
assert_eq "the token is stored in credential-store format" \
    "https://x-access-token:smoke-not-a-real-token@github.com" \
    "$(dexec cat /config/git/credentials | tr -d '\r')"
assert_contains "gitconfig points the helper at that file" \
    "$(dexec cat /config/git/gitconfig | tr -d '\r')" \
    "store --file /config/git/credentials"
assert_ok "the token is not in gitconfig itself" \
    dexec sh -c '! grep -q smoke-not-a-real-token /config/git/gitconfig'
# The behavioural half: a repository cloned over SSH has to resolve to the
# HTTPS URL the token can authenticate to, without its remote being edited.
assert_eq "an ssh remote resolves to https" \
    "https://github.com/example/example.git" \
    "$(dexec_user sh -c 'cd /workspace \
        && rm -rf .credential-probe \
        && git init -q .credential-probe \
        && cd .credential-probe \
        && git remote add origin git@github.com:example/example.git \
        && git ls-remote --get-url origin' | tr -d '\r')"
dexec_user sh -c 'rm -rf /workspace/.credential-probe'

echo "== agents install on the first boot =="
# /config starts empty this run (see the rm -rf of TMP_DIR above), so this is
# the one point in the suite where /config/agents ownership has not yet been
# self-healed by a later boot's recursive chown in 04-agents/run.
# boot_complete only succeeds after 05-tools, which runs after 04-agents, so
# by the time it succeeded above, the install already ran to completion. Asserting here, before the first restart below, is what
# makes this catch a first-boot install failure instead of a self-healed one.
FIRST_BOOT_LOGS="$("${COMPOSE[@]}" logs paseo 2>&1)"
assert_ok "claude installed on the first boot" \
    dexec test -x /config/agents/bin/claude
# shellcheck disable=SC2016 # $1 must expand inside the sh -c subshell below,
# not on the host shell where shellcheck reads this line.
assert_ok "first boot logged no agent install failure" \
    sh -c '! printf "%s" "$1" | grep -q "install failed"' _ "$FIRST_BOOT_LOGS"

# Agents must not update themselves. npm's rename-and-remove cannot finish
# while the running agent holds its own executable open, and on a FUSE-backed
# /config that half-done install destroys it -- see docs/agents.md. Two
# independent guards stand in the way, asserted separately so that losing
# either one is visible here rather than only when an update eats an install:
# the updater is off, and npm's default prefix is somewhere the agent user
# could not write even if it ran anyway.
assert_eq "the agent auto-updater is disabled" "1" \
    "$(dexec_user printenv DISABLE_AUTOUPDATER | tr -d '\r')"
assert_eq "npm's global prefix is not the agent prefix" "/usr/local" \
    "$(dexec_user npm prefix -g | tr -d '\r')"
assert_fail "the agent user cannot write to npm's global prefix" \
    dexec_user test -w /usr/local/lib/node_modules

echo "== persistence across restart =="
dexec sh -c 'echo persistence-canary > /config/canary.txt'
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "container returns after restart" 240 boot_complete
assert_eq "canary survived restart" "persistence-canary" \
    "$(dexec cat /config/canary.txt | tr -d '\r')"

echo "== ssh =="
SSH_OPTS=(-p 2223 -i "$SSH_KEY" -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o BatchMode=yes
          -o LogLevel=ERROR -o ConnectTimeout=5)

wait_for "sshd accepts connections" 240 \
    ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 true
assert_eq "ssh logs in as paseo" "paseo" \
    "$(ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 whoami 2>/dev/null | tr -d '\r')"
assert_ok "host keys persisted" dexec test -f /config/ssh/hostkeys/ssh_host_ed25519_key
assert_eq "authorized_keys mode is 600" "600" \
    "$(dexec stat -c '%a' /home/paseo/.ssh/authorized_keys | tr -d '\r')"
ROOT_SSH_OUT="$(ssh "${SSH_OPTS[@]}" root@127.0.0.1 true 2>&1 || true)"
assert_contains "root login is refused by sshd" "$ROOT_SSH_OUT" "Permission denied"
assert_contains "password authentication is disabled" \
    "$(dexec sshd -T 2>/dev/null | tr -d '\r')" "passwordauthentication no"

echo "== outbound ssh =="
assert_ok "outbound key generated" dexec test -f /config/ssh/id_ed25519
assert_ok "outbound public half generated" dexec test -f /config/ssh/id_ed25519.pub
assert_eq "outbound key mode in home is 600" "600" \
    "$(dexec stat -c '%a' /home/paseo/.ssh/id_ed25519 | tr -d '\r')"
assert_eq "outbound key is owned by paseo" "paseo" \
    "$(dexec stat -c '%U' /home/paseo/.ssh/id_ed25519 | tr -d '\r')"
# ssh reaches for ~/.ssh/id_ed25519 with no configuration at all, so the copy
# in home has to be the same key /config holds, not merely some key.
assert_eq "home holds the /config outbound key" \
    "$(dexec sha256sum /config/ssh/id_ed25519 | cut -d' ' -f1)" \
    "$(dexec sha256sum /home/paseo/.ssh/id_ed25519 | cut -d' ' -f1)"
assert_eq "known_hosts links to /config" "/config/ssh/known_hosts" \
    "$(dexec readlink /home/paseo/.ssh/known_hosts | tr -d '\r')"
assert_ok "no client config without one in /config" \
    dexec test ! -e /home/paseo/.ssh/config

# Written into the bind mount rather than through the container, so the next
# boot finds it exactly as an operator dropping a file into appdata would.
mkdir -p "$TMP_DIR/config/ssh"
cat > "$TMP_DIR/config/ssh/config" <<'CLIENTCONF'
Host smoke
    HostName smoke.invalid
    User smoketest
CLIENTCONF

HOSTKEY_BEFORE="$(dexec sha256sum /config/ssh/hostkeys/ssh_host_ed25519_key.pub | cut -d' ' -f1)"
OUTBOUND_BEFORE="$(dexec sha256sum /config/ssh/id_ed25519.pub | cut -d' ' -f1)"
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "sshd returns after restart" 240 \
    ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 true
assert_eq "host key is stable across restart" "$HOSTKEY_BEFORE" \
    "$(dexec sha256sum /config/ssh/hostkeys/ssh_host_ed25519_key.pub | cut -d' ' -f1)"
# The whole point of the outbound key: its public half is authorized on hosts
# this container cannot reach, so a boot that regenerates it is an outage.
assert_eq "outbound key is stable across restart" "$OUTBOUND_BEFORE" \
    "$(dexec sha256sum /config/ssh/id_ed25519.pub | cut -d' ' -f1)"
assert_eq "client config mode is 600" "600" \
    "$(dexec stat -c '%a' /home/paseo/.ssh/config | tr -d '\r')"
assert_contains "ssh reads the client config" \
    "$(ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 'ssh -G smoke' 2>/dev/null | tr -d '\r')" \
    "hostname smoke.invalid"

rm -f "$TMP_DIR/config/ssh/config"
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "sshd returns after the config is removed" 240 \
    ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 true
assert_ok "removing the client config removes the copy" \
    dexec test ! -e /home/paseo/.ssh/config

echo "== agents =="
assert_ok "claude is installed" dexec test -x /config/agents/bin/claude
assert_contains "claude is on the ssh PATH" \
    "$(ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 'command -v claude' 2>&1)" \
    "/config/agents/bin/claude"
assert_ok "claude state is linked to /config" \
    dexec test -L /home/paseo/.claude
# `test -L` passes on a dangling symlink too. Claude Code keeps its OAuth
# credentials in ~/.claude/.credentials.json, and mkdir through a dangling
# symlink fails, so a link to a directory that does not exist costs you the
# login on every single run. These two assertions are what tell the two
# states apart.
assert_ok "claude state points at a real directory" \
    dexec test -d /config/agents/state/.claude
assert_ok "claude state is writable through the home symlink" \
    dexec_user sh -c 'touch /home/paseo/.claude/.smoke-probe'
assert_ok "a write through the symlink lands in /config" \
    dexec test -f /config/agents/state/.claude/.smoke-probe
dexec sh -c 'rm -f /config/agents/state/.claude/.smoke-probe'

echo "== tools =="
# NPM_TOOLS and PYTHON_TOOLS are set in compose.yaml, one small package each.
assert_ok "an NPM_TOOLS package installed" dexec test -x /config/tools/bin/json
assert_ok "a PYTHON_TOOLS package installed" dexec test -x /config/tools/bin/yq
assert_ok "a PYTHON_TOOLS package runs" dexec_user /config/tools/bin/yq --version
# uv builds a tool's virtualenv against an interpreter it downloads, and both
# have to be inside /config or the tools do not survive an image update.
assert_ok "python tool venvs are in /config" \
    dexec test -d /config/tools/uv/tools/yq
assert_ok "uv's interpreter is in /config" \
    dexec sh -c 'ls -d /config/tools/uv/python/* >/dev/null 2>&1'
assert_contains "tools are on the ssh PATH" \
    "$(ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 'command -v yq' 2>&1)" \
    "/config/tools/bin/yq"
assert_eq "an ssh shell points uv at /config" "/config/tools/bin" \
    "$(ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 'echo $UV_TOOL_BIN_DIR' 2>/dev/null | tr -d '\r')"
assert_eq "tools are owned by paseo" "paseo" \
    "$(dexec stat -c '%U' /config/tools/bin/yq | tr -d '\r')"
# The ledger is what makes a restart cheap. Two restarts have already happened
# by this point in the suite, so a duplicated or re-run install shows up here.
assert_eq "the ledger records each spec once" "2" \
    "$(dexec sh -c 'wc -l < /config/tools/.installed' | tr -d '\r ')"
assert_contains "the ledger names the python tool" \
    "$(dexec cat /config/tools/.installed | tr -d '\r')" "python yq"
assert_contains "a restart skips an installed tool" \
    "$("${COMPOSE[@]}" logs paseo 2>&1)" "yq already installed"
assert_contains "the banner lists the installed tools" \
    "$("${COMPOSE[@]}" logs paseo 2>&1)" "tools         json"

echo "== agents are not reinstalled on the second boot =="
dexec sh -c 'echo canary > /config/agents/bin/.install-canary'
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "container returns after agent restart" 240 boot_complete
wait_for "agents settle after restart" 240 dexec test -x /config/agents/bin/claude
assert_contains "second boot skipped the install" \
    "$("${COMPOSE[@]}" logs paseo 2>&1 | tail -n 200)" \
    "claude: already installed"

echo "== an unknown agent name does not brick the boot =="
"${COMPOSE[@]}" down >/dev/null
AGENTS="claude,codex,definitely-not-an-agent" "${COMPOSE[@]}" up -d
wait_for "container boots with an unknown agent" 240 boot_complete
assert_contains "unknown agent logged a warning" \
    "$("${COMPOSE[@]}" logs paseo 2>&1)" "definitely-not-an-agent"
assert_ok "codex is installed" dexec test -x /config/agents/bin/codex

echo "== codex wrapper =="
# npm's @openai/codex entry point is a Node shim that stays running while the
# real, natively compiled codex runs as its child. The installer replaces that
# shim with a wrapper that execs the native binary in its place.
assert_ok "codex on PATH is not npm's shim symlink" \
    dexec test '!' -L /config/agents/bin/codex
assert_contains "codex on PATH execs the native binary" \
    "$(dexec cat /config/agents/bin/codex | tr -d '\r')" \
    'exec "/config/agents/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-'
assert_ok "codex runs through the wrapper" \
    dexec_user sh -c '/config/agents/bin/codex --version >/dev/null'

# The tag agent_installed greps for carries a version, so that a container
# still holding a wrapper from an older edition of this image regenerates it
# on the next boot instead of being reported as already installed.
assert_contains "the codex wrapper carries the current tag" \
    "$(dexec cat /config/agents/bin/codex | tr -d '\r')" \
    "paseo-container codex wrapper v1"

# codex clears its own stale arg0 helper dirs at startup, but unlinks their
# contents while still holding the lock fd open. On FUSE -- which is what
# /config is on Unraid, where shfs backs every user share -- the unlinked file
# becomes a .fuse_hidden entry in that same directory, codex's rmdir fails
# with ENOTEMPTY, and it prints "failed to clean up stale arg0 temp dirs" on
# every run while leaking a directory each time. The wrapper clears them
# before codex starts. The bind mount under CI is not FUSE and so cannot
# reproduce the warning itself; these assert the behaviour that prevents it,
# which holds on any filesystem: a dead directory goes, and one a live codex
# still holds stays.
ARG0_DIR=/home/paseo/.codex/tmp/arg0
assert_ok "the wrapper clears a dead arg0 dir" \
    dexec_user sh -c "
        mkdir -p $ARG0_DIR/codex-arg0dead &&
        touch -d '1 hour ago' $ARG0_DIR/codex-arg0dead &&
        /config/agents/bin/codex --version >/dev/null 2>&1
        test ! -d $ARG0_DIR/codex-arg0dead
    "
assert_ok "the wrapper spares an arg0 dir a live codex holds" \
    dexec_user sh -c "
        mkdir -p $ARG0_DIR/codex-arg0held &&
        : > $ARG0_DIR/codex-arg0held/.lock &&
        flock $ARG0_DIR/codex-arg0held/.lock \
            -c '/config/agents/bin/codex --version >/dev/null 2>&1'
        test -d $ARG0_DIR/codex-arg0held
    "

echo "== AGENT_UPDATE=1 forces a reinstall =="
"${COMPOSE[@]}" down >/dev/null
AGENT_UPDATE=1 "${COMPOSE[@]}" up -d
wait_for "container boots with AGENT_UPDATE=1" 240 boot_complete
assert_contains "AGENT_UPDATE forced a reinstall" \
    "$("${COMPOSE[@]}" logs paseo 2>&1)" "claude: reinstalling because AGENT_UPDATE=1"

echo '== AGENTS="" installs no agents =='
dexec sh -c 'find /config/agents/bin -mindepth 1 -delete'
"${COMPOSE[@]}" down >/dev/null
AGENTS="" "${COMPOSE[@]}" up -d
wait_for "container boots with AGENTS empty" 240 boot_complete
# shellcheck disable=SC2016 # the $() must expand inside the container's
# shell via dexec, not on the host where shellcheck reads this line.
assert_ok "no agents installed when AGENTS is empty" \
    dexec sh -c 'test -z "$(find /config/agents/bin -mindepth 1)"'

echo "== banner =="
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container boots for the banner check" 240 boot_complete
BANNER="$("${COMPOSE[@]}" logs paseo 2>&1)"
# "ssh" alone already appears in ordinary boot log lines (sshd's own startup
# message, and log tags), so a bare substring check would pass even with no
# banner at all. These needles are text that only the banner itself produces.
assert_contains "banner names the ssh port" "$BANNER" "container port 22"
assert_contains "banner names the outbound key" \
    "$BANNER" "/config/ssh/id_ed25519.pub"

echo "== service toggles =="
"${COMPOSE[@]}" down >/dev/null
SSHD_ENABLED=0 "${COMPOSE[@]}" up -d
# Gate on the end of the oneshot chain, not on sshd: with sshd disabled it never
# answers, and "not listening" must mean something once boot has finished.
wait_for "container boots with sshd disabled" 240 boot_complete
assert_fail "sshd is not listening" \
    ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 true

"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container returns to the default configuration" 240 boot_complete

echo "== timezone =="
"${COMPOSE[@]}" down >/dev/null
TZ="Europe/Oslo" "${COMPOSE[@]}" up -d
wait_for "container boots with TZ set" 240 boot_complete
assert_eq "TZ is applied to /etc/localtime" "/usr/share/zoneinfo/Europe/Oslo" \
    "$(dexec readlink -f /etc/localtime | tr -d '\r')"

"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container returns to the default configuration" 240 boot_complete

echo "== image layer hygiene =="
assert_ok "no ssh host keys are baked into the image" \
    docker run --rm --entrypoint /bin/sh paseo-container:test \
    -c '! ls /etc/ssh/ssh_host_* >/dev/null 2>&1'

summary
