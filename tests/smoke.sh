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
# compose.yaml maps the container's 6767 to this host port.
PASEO_URL="http://127.0.0.1:6768"

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

# paseo_healthy: /api/health is the one Paseo route that needs no password.
# The daemon depends on every oneshot, so an answer here also means the boot
# finished.
paseo_healthy() {
    curl -fsS -o /dev/null --max-time 3 "${PASEO_URL}/api/health"
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

echo "== agents install on the first boot =="
# /config starts empty this run (see the rm -rf of TMP_DIR above), and this is
# the first boot, so nothing has yet had a chance to repair a failed install:
# 04-agents installs again on any boot that finds an agent missing. Asserting
# here, before the first restart or recreate, is what makes this catch a
# first-boot install failure instead of a self-healed one. boot_complete only
# succeeds after 05-tools, which runs after 04-agents, so the install has
# already run to completion.
FIRST_BOOT_LOGS="$("${COMPOSE[@]}" logs paseo 2>&1)"
assert_ok "claude installed on the first boot" \
    dexec test -x /config/agents/bin/claude
# shellcheck disable=SC2016 # $1 must expand inside the sh -c subshell below,
# not on the host shell where shellcheck reads this line.
assert_ok "first boot logged no agent install failure" \
    sh -c '! printf "%s" "$1" | grep -q "install failed"' _ "$FIRST_BOOT_LOGS"
assert_ok "claude runs as paseo" dexec_user /config/agents/bin/claude --version
# compose.yaml installs codex alongside claude by default.
assert_ok "codex runs as paseo" dexec_user /config/agents/bin/codex --version
# The sign-in commands the banner prints are plain `docker exec ... claude`,
# which runs no login shell, so the agents must be on the image's own PATH.
assert_ok "claude runs by bare name from docker exec" dexec_user claude --version
assert_ok "codex runs by bare name from docker exec" dexec_user codex --version
# shellcheck disable=SC2016 # $UV_TOOL_BIN_DIR must expand inside the container.
assert_ok "uv env is set for docker exec" \
    dexec_user sh -c '[ "$UV_TOOL_BIN_DIR" = /config/tools/bin ]'

echo "== base image =="
assert_eq "paseo user has PUID" "$PUID" "$(dexec id -u paseo | tr -d '\r')"
assert_eq "paseo user has PGID" "$PGID" "$(dexec id -g paseo | tr -d '\r')"
assert_eq "config is owned by paseo" "paseo" "$(dexec stat -c '%U' /config | tr -d '\r')"
# The baseline an agent is told it can assume, one representative per group:
# transfer, archive, network probe, data, and the Python installer that
# PYTHON_TOOLS and uvx-based MCP servers both go through. fd is checked by
# name rather than as fdfind, since the symlink is the point.
for cmd in rsync wget unzip zip tmux tree patch sqlite3 fd dig nc uv uvx gh; do
    assert_ok "${cmd} is in the image" dexec sh -c "command -v ${cmd} >/dev/null"
done
assert_ok "gh runs as paseo" dexec_user gh --version
# The hostname is what every shell prompt and terminal title in the container
# shows, and only the creating command can set it -- a container cannot change
# its own. This asserts the harness matches what the README and the unRAID
# template tell you to pass, so dropping it from either is a failing test
# rather than a prompt that silently reverts to the container ID.
assert_eq "hostname is set at creation" "paseo" "$(dexec hostname | tr -d '\r')"

echo "== paseo daemon =="
wait_for "paseo answers /api/health" 240 paseo_healthy
assert_eq "/api/status without the password is 401" "401" \
    "$(curl -s -o /dev/null -w '%{http_code}' "${PASEO_URL}/api/status")"
assert_eq "/api/status with the password is 200" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer smoketest' \
        "${PASEO_URL}/api/status")"
# Paseo renames its processes, so they show as "Paseo Supervisor" and
# "Paseo Daemon" rather than as node and its script path.
# shellcheck disable=SC2016 # the $() must expand inside the container.
assert_eq "paseo runs as paseo" "paseo" \
    "$(dexec sh -c 'ps -o user= -p "$(pgrep -d, -f "^Paseo (Supervisor|Daemon)\$")" | sort -u' \
        | tr -d '\r ')"
assert_ok "paseo state lives in /config/paseo" dexec test -s /config/paseo/daemon-keypair.json
DAEMON_PID="$(dexec sh -c 'pgrep -u paseo -f "^Paseo Supervisor\$" | head -n1' | tr -d '\r')"
assert_ok "the supervisor process is found" test -n "$DAEMON_PID"
# Root in the container lacks CAP_SYS_PTRACE, so only the owner can read
# another process's environment. With no PID, the environment stays empty and
# the assertions below fail by name instead of aborting the suite.
DAEMON_ENV=""
if [ -n "$DAEMON_PID" ]; then
    DAEMON_ENV="$(dexec_user sh -c "tr '\0' '\n' < /proc/${DAEMON_PID}/environ" || true)"
fi
assert_contains "self-update is refused" "$DAEMON_ENV" "PASEO_DESKTOP_MANAGED=1"
assert_contains "PASEO_HOME points at /config" "$DAEMON_ENV" "PASEO_HOME=/config/paseo"
# shellcheck disable=SC2016 # $1 expands in the inner sh, not here.
assert_ok "NODE_ENV is not set for the daemon" \
    sh -c '! printf "%s" "$1" | grep -q "^NODE_ENV="' _ "$DAEMON_ENV"
assert_fail "the paseo user cannot overwrite Paseo" \
    dexec_user test -w /usr/local/lib/node_modules/@getpaseo
# shellcheck disable=SC2016 # $1 expands in the inner sh, not here.
assert_ok "the daemon finds claude on PATH" \
    sh -c 'printf "%s" "$1" | grep -q "^PATH=.*/config/agents/bin"' _ "$DAEMON_ENV"
# Agents start MCP servers such as `uvx some-server` without a login shell, so
# the uv environment profile.d exports has to come from the daemon itself.
assert_contains "the daemon points uv's cache at /config" "$DAEMON_ENV" \
    "UV_CACHE_DIR=/config/tools/uv/cache"
assert_contains "the daemon keeps uv off the image's Python" "$DAEMON_ENV" \
    "UV_PYTHON_PREFERENCE=only-managed"

echo "== agents see the MCP servers a shell adds =="
# Claude Code reads its user config from $CLAUDE_CONFIG_DIR/.claude.json when
# that variable is set and from ~/.claude.json otherwise. A shell has no such
# variable, so the daemon must not have one either, or an MCP server you add
# from a shell never reaches an agent.
# shellcheck disable=SC2016 # $1 expands in the inner sh, not here.
assert_ok "CLAUDE_CONFIG_DIR is not set for the daemon" \
    sh -c '! printf "%s" "$1" | grep -q "^CLAUDE_CONFIG_DIR="' _ "$DAEMON_ENV"
assert_ok "a shell adds a user-scoped MCP server" \
    dexec_user /config/agents/bin/claude mcp add --scope user smoke-mcp -- true
# Runs claude with exactly the supervisor's environment, as an agent would.
MCP_LIST=""
if [ -n "$DAEMON_PID" ]; then
    MCP_LIST="$(dexec_user sh -c "cd /home/paseo && xargs -0 -a /proc/${DAEMON_PID}/environ \
        sh -c 'exec env -i \"\$@\" /config/agents/bin/claude mcp list' _" 2>&1 | tr -d '\r' || true)"
fi
assert_contains "the daemon's claude sees that MCP server" "$MCP_LIST" "smoke-mcp"
dexec_user /config/agents/bin/claude mcp remove --scope user smoke-mcp >/dev/null 2>&1 || true

echo "== relay is seeded once =="
assert_eq "config.json turns the relay on" "true" \
    "$(dexec jq -r .daemon.relay.enabled /config/paseo/config.json | tr -d '\r')"
dexec sh -c 'jq ".daemon.relay.enabled = false" /config/paseo/config.json > /tmp/c \
    && cat /tmp/c > /config/paseo/config.json'
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "paseo returns after editing config.json" 240 paseo_healthy
assert_eq "a later boot keeps an edited config.json" "false" \
    "$(dexec jq -r .daemon.relay.enabled /config/paseo/config.json | tr -d '\r')"
dexec sh -c 'jq ".daemon.relay.enabled = true" /config/paseo/config.json > /tmp/c \
    && cat /tmp/c > /config/paseo/config.json'
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "paseo returns with the relay on" 240 paseo_healthy

echo "== an empty config.json is seeded again =="
# A crash between a truncating redirect and the write leaves a zero-byte file.
dexec sh -c ': > /config/paseo/config.json'
"${COMPOSE[@]}" stop -t 30 paseo >/dev/null
"${COMPOSE[@]}" start paseo >/dev/null
wait_for "paseo boots with an empty config.json" 240 paseo_healthy
assert_eq "an empty config.json is seeded with the relay on" "true" \
    "$(dexec jq -r .daemon.relay.enabled /config/paseo/config.json | tr -d '\r')"

echo "== pairing =="
PAIR_JSON="$(dexec_user env PASEO_HOME=/config/paseo paseo daemon pair --json 2>/dev/null | tr -d '\r')"
assert_contains "pair prints a pairing URL" "$PAIR_JSON" "https://app.paseo.sh/#offer="

echo "== hostnames =="
# /api/status rather than /api/health, in case the health route is exempt
# from the Host check as it is from the password.
assert_eq "an unknown Host is refused" "403" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: tower.lan' \
        -H 'Authorization: Bearer smoketest' "${PASEO_URL}/api/status")"
"${COMPOSE[@]}" down >/dev/null
PASEO_HOSTNAMES="tower.lan" "${COMPOSE[@]}" up -d
wait_for "paseo boots with PASEO_HOSTNAMES" 240 paseo_healthy
assert_eq "a listed Host is accepted" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: tower.lan' \
        -H 'Authorization: Bearer smoketest' "${PASEO_URL}/api/status")"

echo "== generated password =="
EMPTY_PW_OVERRIDE="$TMP_DIR/empty-password.compose.yaml"
cat >"$EMPTY_PW_OVERRIDE" <<'YAML'
services:
  paseo:
    environment:
      PASEO_PASSWORD: ""
YAML
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" -f "$EMPTY_PW_OVERRIDE" up -d
wait_for "paseo boots without PASEO_PASSWORD" 240 paseo_healthy
assert_eq "the generated password file is private" "600" \
    "$(dexec stat -c '%a' /config/paseo/password | tr -d '\r')"
assert_eq "the generated password file is owned by paseo" "paseo" \
    "$(dexec stat -c '%U' /config/paseo/password | tr -d '\r')"
GEN_PW="$(dexec cat /config/paseo/password | tr -d '\r\n')"
assert_eq "the generated password authenticates" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${GEN_PW}" \
        "${PASEO_URL}/api/status")"
"${COMPOSE[@]}" -f "$EMPTY_PW_OVERRIDE" restart paseo >/dev/null
wait_for "paseo returns with the generated password" 240 paseo_healthy
assert_eq "the generated password is reused across boots" "$GEN_PW" \
    "$(dexec cat /config/paseo/password | tr -d '\r\n')"

echo "== a password with shell metacharacters =="
WEIRD_PW_OVERRIDE="$TMP_DIR/weird-password.compose.yaml"
cat >"$WEIRD_PW_OVERRIDE" <<'YAML'
services:
  paseo:
    environment:
      PASEO_PASSWORD: 'p@ss$$HOME"quoted"`tick`'
YAML
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" -f "$WEIRD_PW_OVERRIDE" up -d
wait_for "paseo boots with a metacharacter password" 240 paseo_healthy
# shellcheck disable=SC2016 # the password is literal text, not an expansion.
assert_eq "a metacharacter password authenticates verbatim" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer p@ss$HOME"quoted"`tick`' \
        "${PASEO_URL}/api/status")"

"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "paseo returns to the default configuration" 240 paseo_healthy

echo "== a clean stop lets paseo finish =="
# A clean shutdown removes paseo.pid; its absence after stop is the evidence
# that s6 and Docker gave the supervisor enough time.
"${COMPOSE[@]}" stop -t 30 paseo >/dev/null
assert_fail "paseo.pid is gone after a clean stop" test -e "$TMP_DIR/config/paseo/paseo.pid"
"${COMPOSE[@]}" start paseo >/dev/null
wait_for "paseo returns after a clean stop" 240 paseo_healthy

echo "== a stale paseo.pid does not block the next boot =="
"${COMPOSE[@]}" kill -s SIGKILL paseo >/dev/null
# The lock SIGKILL leaves behind does not block the next boot by itself: in
# the new container its PID is either free or taken by the new supervisor,
# and Paseo clears the first and claims the second. So overwrite it with a
# lock that Paseo reads as live: PID 1, which runs in every container, this
# host's boot ID, and every field Paseo's pidLockInfoSchema requires, written
# as one line of JSON the way Paseo writes it. Only 06-paseo-prep removing
# the file lets the daemon start.
printf '{"pid":1,"startedAt":"%s","hostname":"paseo","uid":%s,"listen":"0.0.0.0:6767","heartbeat":true,"bootId":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$PUID" \
    "$(cat /proc/sys/kernel/random/boot_id)" > "$TMP_DIR/config/paseo/paseo.pid"
STALE_LOCK_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
"${COMPOSE[@]}" start paseo >/dev/null
wait_for "paseo starts despite a stale paseo.pid" 240 paseo_healthy
assert_contains "the boot removes the stale paseo.pid" \
    "$("${COMPOSE[@]}" logs --since "$STALE_LOCK_SINCE" paseo 2>&1)" \
    "removing a stale /config/paseo/paseo.pid"

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
wait_for "container returns for the ownership check" 240 paseo_healthy
assert_eq "a share file keeps a foreign owner across boots" "4242" \
    "$(dexec stat -c '%u' /home/paseo/workspace/.owner-probe/file | tr -d '\r')"
assert_eq "/workspace is a symlink to the share" "/home/paseo/workspace" \
    "$(dexec readlink /workspace | tr -d '\r')"
dexec rm -rf /home/paseo/workspace/.owner-probe

echo "== HOME_PERSIST =="
for rel in .config .kube .talos; do
    # shellcheck disable=SC2088 # the tilde is label text, not a path.
    assert_eq "~/${rel} links to /config/home" "/config/home/${rel}" \
        "$(dexec readlink "/home/paseo/${rel}" | tr -d '\r')"
done
dexec_user sh -c 'printf "apiVersion: v1\n" > /home/paseo/.kube/config'
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container returns after a recreate" 240 paseo_healthy
assert_eq "a kubeconfig survives a recreate" "apiVersion: v1" \
    "$(dexec cat /home/paseo/.kube/config | tr -d '\r')"
assert_eq "persisted config is owned by paseo" "paseo" \
    "$(dexec stat -c '%U' /config/home/.kube/config | tr -d '\r')"

echo "== HOME_PERSIST rejects unsafe entries =="
# Each entry below must be refused with a warning and must never abort the
# boot. The first one names the share's own mount point, which link_persist
# would otherwise delete or fail to replace.
"${COMPOSE[@]}" down >/dev/null
mkdir -p "$TMP_DIR/config/home/workspace"
touch "$TMP_DIR/workspace/.persist-canary"
HOME_PERSIST="workspace/ ./ /etc/ ../x/ foo/../bar/ .kube/" "${COMPOSE[@]}" up -d
wait_for "container boots with unsafe HOME_PERSIST entries" 240 paseo_healthy
assert_ok "the share's canary file survives" \
    dexec test -e /home/paseo/workspace/.persist-canary
assert_ok "the share is still a directory" dexec test -d /home/paseo/workspace
assert_fail "the share is not a symlink" dexec test -L /home/paseo/workspace
# shellcheck disable=SC2088 # the tilde is label text, not a path.
assert_eq "~/.kube still links to /config/home" "/config/home/.kube" \
    "$(dexec readlink /home/paseo/.kube | tr -d '\r')"
assert_contains "the share entry is reported" \
    "$("${COMPOSE[@]}" logs paseo 2>&1)" "HOME_PERSIST: ignoring 'workspace/'"
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container returns to the default HOME_PERSIST" 240 paseo_healthy
rm -rf "$TMP_DIR/config/home/workspace" "$TMP_DIR/workspace/.persist-canary"

echo "== HOME_PERSIST skips an entry inside an earlier one =="
# With .config/ linked, ~/.config/gh already resolves to /config/home/.config/gh.
# Linking it again would see the link's own source as an existing target,
# delete it, and leave a symlink that points at itself.
dexec_user sh -c 'mkdir -p /config/home/.config/gh \
    && echo gh-canary > /config/home/.config/gh/hosts.yml'
"${COMPOSE[@]}" down >/dev/null
OVERLAP_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOME_PERSIST=".config/ .config/gh/ .kube/" "${COMPOSE[@]}" up -d
wait_for "container boots with overlapping HOME_PERSIST entries" 240 paseo_healthy
assert_eq "a nested entry keeps its data on the first boot" "gh-canary" \
    "$(dexec cat /config/home/.config/gh/hosts.yml 2>&1 | tr -d '\r')"
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "container returns with overlapping HOME_PERSIST entries" 240 paseo_healthy
assert_eq "a nested entry keeps its data on a second boot" "gh-canary" \
    "$(dexec cat /home/paseo/.config/gh/hosts.yml 2>&1 | tr -d '\r')"
# A symlink that points at itself fails test -d; a real directory passes.
# shellcheck disable=SC2088 # the tilde is label text, not a path.
assert_ok "~/.config/gh is still a directory" dexec test -d /home/paseo/.config/gh
assert_fail "the persisted gh directory is not a symlink" \
    dexec test -L /config/home/.config/gh
# Linking a directory onto itself through ln -s, once the target is a real
# directory again, plants the loop one level down instead: gh/gh -> gh.
# shellcheck disable=SC2016 # the $() must expand inside the container.
assert_ok "the persisted gh directory holds no symlink loop" \
    dexec sh -c 'test -z "$(find /config/home/.config/gh -type l)"'
assert_contains "the nested entry is reported" \
    "$("${COMPOSE[@]}" logs --since "$OVERLAP_SINCE" paseo 2>&1)" \
    "HOME_PERSIST: ignoring '.config/gh/': already persisted under '.config/'"
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container returns to the default HOME_PERSIST" 240 paseo_healthy

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

echo "== agents do not update themselves =="
# Agents must not update themselves. npm's rename-and-remove cannot finish
# while the running agent holds its own executable open, and on a FUSE-backed
# /config that half-done install destroys it -- see the "Agents do not update
# themselves" section of docs/agents.md. Two independent guards stand in the
# way, asserted separately so that losing
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
wait_for "container returns after restart" 240 paseo_healthy
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
wait_for "container returns after agent restart" 240 paseo_healthy
wait_for "agents settle after restart" 240 dexec test -x /config/agents/bin/claude
assert_contains "second boot skipped the install" \
    "$("${COMPOSE[@]}" logs paseo 2>&1 | tail -n 200)" \
    "claude: already installed"

echo "== an unknown agent name does not brick the boot =="
"${COMPOSE[@]}" down >/dev/null
AGENTS="claude,codex,definitely-not-an-agent" "${COMPOSE[@]}" up -d
wait_for "container boots with an unknown agent" 240 paseo_healthy
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
wait_for "container boots with AGENT_UPDATE=1" 240 paseo_healthy
assert_contains "AGENT_UPDATE forced a reinstall" \
    "$("${COMPOSE[@]}" logs paseo 2>&1)" "claude: reinstalling because AGENT_UPDATE=1"

echo '== AGENTS="" installs no agents =='
dexec sh -c 'find /config/agents/bin -mindepth 1 -delete'
"${COMPOSE[@]}" down >/dev/null
AGENTS="" "${COMPOSE[@]}" up -d
wait_for "container boots with AGENTS empty" 240 paseo_healthy
# shellcheck disable=SC2016 # the $() must expand inside the container's
# shell via dexec, not on the host where shellcheck reads this line.
assert_ok "no agents installed when AGENTS is empty" \
    dexec sh -c 'test -z "$(find /config/agents/bin -mindepth 1)"'

echo "== BIN_TOOLS =="
mkdir -p "$TMP_DIR/config/fixtures"
printf '#!/bin/sh\necho hello-bin\n' > "$TMP_DIR/config/fixtures/hello"
GOOD_SHA="$(sha256sum "$TMP_DIR/config/fixtures/hello" | cut -d' ' -f1)"
BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"
"${COMPOSE[@]}" down >/dev/null
BIN_TOOLS="hello=file:///config/fixtures/hello#sha256=${GOOD_SHA} badsum=file:///config/fixtures/hello#sha256=${BAD_SHA} missing=file:///config/fixtures/does-not-exist emptysum=file:///config/fixtures/hello#sha256= shortsum=file:///config/fixtures/hello#sha256=abc" \
    "${COMPOSE[@]}" up -d
wait_for "container boots with BIN_TOOLS" 240 paseo_healthy
assert_eq "a BIN_TOOLS binary runs" "hello-bin" \
    "$(dexec_user /config/tools/bin/hello 2>/dev/null | tr -d '\r')"
assert_eq "a BIN_TOOLS binary is owned by paseo" "paseo" \
    "$(dexec stat -c '%U' /config/tools/bin/hello | tr -d '\r')"
assert_fail "a wrong checksum installs nothing" dexec test -e /config/tools/bin/badsum
assert_fail "an unreachable URL installs nothing" dexec test -e /config/tools/bin/missing
assert_ok "no partial download is left behind" \
    dexec sh -c '! ls /config/tools/bin/.bin-tool.* >/dev/null 2>&1'
assert_fail "an empty checksum installs nothing" dexec test -e /config/tools/bin/emptysum
assert_fail "a short checksum installs nothing" dexec test -e /config/tools/bin/shortsum
BIN_LEDGER="$(dexec cat /config/tools/.installed | tr -d '\r')"
for bad in badsum missing emptysum shortsum; do
    # shellcheck disable=SC2016 # the script text expands in the inner sh, not here.
    assert_ok "$bad is absent from the ledger" \
        sh -c '! printf "%s\n" "$1" | grep -q "^bin ${2}="' _ "$BIN_LEDGER" "$bad"
done
BIN_LOGS="$("${COMPOSE[@]}" logs paseo 2>&1)"
assert_contains "an empty checksum is reported" "$BIN_LOGS" "emptysum: invalid sha256"
assert_contains "a short checksum is reported" "$BIN_LOGS" "shortsum: invalid sha256"
assert_contains "a wrong checksum is reported" "$BIN_LOGS" "badsum: checksum mismatch"
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "container returns for the BIN_TOOLS ledger check" 240 paseo_healthy
assert_contains "a second boot skips an installed binary" \
    "$("${COMPOSE[@]}" logs paseo 2>&1 | tail -n 200)" "bin: hello=file:///config/fixtures/hello#sha256=${GOOD_SHA} already installed"
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container returns to the default configuration" 240 paseo_healthy

echo "== banner =="
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container boots for the banner check" 240 paseo_healthy
BANNER="$("${COMPOSE[@]}" logs paseo 2>&1)"
# "ssh" alone already appears in ordinary boot log lines (sshd's own startup
# message, and log tags), so a bare substring check would pass even with no
# banner at all. These needles are text that only the banner itself produces.
assert_contains "banner names the ssh port" "$BANNER" "container port 22"
assert_contains "banner names the outbound key" \
    "$BANNER" "/config/ssh/id_ed25519.pub"
assert_contains "banner names the paseo port" "$BANNER" "container port 6767"
assert_contains "banner reports the paseo version" "$BANNER" \
    "$(dexec paseo --version 2>/dev/null | tr -d '\r' | head -n1)"
assert_contains "banner reports the relay state" "$BANNER" "relay         on"
assert_contains "banner prints the pairing command" "$BANNER" "paseo daemon pair"
assert_contains "banner reports the claude version" "$BANNER" \
    "claude        $(dexec_user /config/agents/bin/claude --version 2>/dev/null | tr -d '\r' | head -n1)"
# shellcheck disable=SC2016 # the single quotes keep $1 for the inner sh
assert_ok "banner never prints the password" \
    sh -c '! printf "%s" "$1" | grep -qF smoketest' _ "$BANNER"

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
wait_for "container returns to the default configuration" 240 paseo_healthy

echo "== timezone =="
"${COMPOSE[@]}" down >/dev/null
TZ="Europe/Oslo" "${COMPOSE[@]}" up -d
wait_for "container boots with TZ set" 240 paseo_healthy
assert_eq "TZ is applied to /etc/localtime" "/usr/share/zoneinfo/Europe/Oslo" \
    "$(dexec readlink -f /etc/localtime | tr -d '\r')"

"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container returns to the default configuration" 240 paseo_healthy

echo "== image layer hygiene =="
assert_ok "no ssh host keys are baked into the image" \
    docker run --rm --entrypoint /bin/sh paseo-container:test \
    -c '! ls /etc/ssh/ssh_host_* >/dev/null 2>&1'

summary
