# paseo-container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `ghcr.io/jumpingmushroom/paseo-container`, an Unraid image that runs the Paseo daemon with Claude Code and Codex, reachable over the Paseo relay and the LAN.

**Architecture:** Seed the repo from `~/code/herdr_container` (Debian trixie, s6-overlay, `PUID`/`PGID`, agent installers, tool volume, SSH, git credential, CI). Replace herdr's `herdr-server` and `herdr-gui` services with a `paseo-daemon` longrun that execs Paseo's supervisor. Add `gh`, `BIN_TOOLS`, and `HOME_PERSIST`. Every behavior is pinned by `tests/smoke.sh`, which builds the image and asserts against a running container.

**Tech Stack:** Docker (buildx, multi-arch), Debian trixie, s6-overlay 3, bash, Node.js 24, npm, uv, GitHub Actions, Unraid Docker template XML.

**Spec:** `docs/superpowers/specs/2026-10-14-paseo-container-design.md`. Read it before starting any task.

**Source skeleton:** `~/code/herdr_container` at commit `bbc55c3`. Tasks copy files from it and then change them.

## Global Constraints

- Paseo version: `PASEO_VERSION=0.11.2`, installed with `npm install -g "@getpaseo/cli@${PASEO_VERSION}" "@getpaseo/server@${PASEO_VERSION}"` into root-owned `/usr/local`.
- `PASEO_HOME=/config/paseo`. Paseo listens on `0.0.0.0:6767`.
- Container user and group: `paseo`. Home: `/home/paseo`. `PUID` default `99`, `PGID` default `100`.
- Source share mount point: `/home/paseo/workspace`. `/workspace` is a symlink to it.
- Do not name any shell variable `PASEO_HOME` except Paseo's own setting. The container user's home lives in `USER_HOME`; the user name lives in `CONTAINER_USER`, the group in `CONTAINER_GROUP`.
- Never `chown -R` the home directory without pruning `WORKSPACE_DIR`. The share sits inside the home directory.
- `paseo-daemon` sets `PASEO_DESKTOP_MANAGED=1` and never sets `NODE_ENV`.
- The relay setting goes into `/config/paseo/config.json`, seeded once. Never set `PASEO_RELAY_ENABLED` from the container.
- Ports: container `6767` (Paseo), container `22` (SSH). Unraid template host ports `6767` and `2223`.
- Stop timeout: Unraid `--stop-timeout=30`; compose `stop_grace_period: 30s`; s6 `S6_SERVICES_GRACETIME=25000`.
- `HOME_PERSIST` default: `.config/ .kube/ .talos/`. `BIN_TOOLS` format: space-separated `name=url`, optional `#sha256=<hex>` suffix.
- Appdata path in all docs and the template: `/mnt/user/appdata/paseo-container`. Never recommend `/mnt/cache`.
- Prose in docs, comments, and commit bodies follows the Google developer documentation style: second person, active voice, present tense, sentence-case headings, serial comma.
- Commit messages: Conventional Commits, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Recursive chown reaching the share.** The share now sits inside the home directory, and herdr-container's `01-user-setup` and `04-agents` both `chown -R` the home directory. A file in the share owned by another user must keep its owner across boots. Pinned in Task 1.
2. **Stale `paseo.pid` after an unclean stop.** A container killed with `SIGKILL` must still start its daemon on the next boot. Pinned in Task 5.
3. **Clean stop cut short.** `docker stop` must give Paseo's supervisor time to finish; a clean stop removes `paseo.pid`, so its absence after stop proves the shutdown completed. Pinned in Task 5.
4. **`PASEO_PASSWORD` with shell metacharacters.** A password containing spaces, `$`, and quotes must authenticate verbatim. Pinned in Task 6.
5. **A bad `BIN_TOOLS` entry.** A wrong checksum or unreachable URL must not stop the boot, and must not leave a partial binary on `PATH`. Pinned in Task 3.

---

## File map

| Path | Responsibility | Task |
| --- | --- | --- |
| `Dockerfile` | Image build: base packages, s6, Node, uv, gh, Paseo, user | 1, 4, 5 |
| `compose.yaml` | Local test harness for `tests/smoke.sh` | 1, 5, 6 |
| `rootfs/usr/local/lib/paseo-container/common.sh` | Shared constants and helpers | 1, 2, 3 |
| `rootfs/usr/local/lib/paseo-container/agents/{claude,codex}.sh` | Agent installers | 1 |
| `rootfs/etc/s6-overlay/s6-rc.d/01-user-setup/run` | UID, GID, umask, TZ, ownership | 1 |
| `rootfs/etc/s6-overlay/s6-rc.d/02-config-scaffold/run` | `/config` tree, git, Paseo seeding | 1, 6 |
| `rootfs/etc/s6-overlay/s6-rc.d/03-ssh-keys/run` | SSH keys (copied unchanged apart from renames) | 1 |
| `rootfs/etc/s6-overlay/s6-rc.d/04-agents/run` | APT packages, `HOME_PERSIST`, agents | 1, 2 |
| `rootfs/etc/s6-overlay/s6-rc.d/05-tools/run` | npm, Python, and binary tools; banner | 1, 3, 7 |
| `rootfs/etc/s6-overlay/s6-rc.d/06-paseo-prep/` | Removes a stale `paseo.pid` | 5 |
| `rootfs/etc/s6-overlay/s6-rc.d/paseo-daemon/` | Runs Paseo's supervisor | 5 |
| `rootfs/usr/local/bin/paseo-container-banner` | Boot banner | 1, 7 |
| `rootfs/etc/profile.d/paseo-container.sh` | Login-shell `PATH` and uv variables | 1 |
| `rootfs/etc/ssh/sshd_config.d/paseo.conf` | sshd policy | 1 |
| `tests/smoke.sh`, `tests/lib/assert.sh` | Behavioral test suite | 1–7 |
| `unraid/paseo-container.xml` | Unraid Community Applications template | 8 |
| `.github/workflows/{ci,release,paseo-version-check}.yml` | CI, release, version bumps | 8 |
| `README.md`, `docs/*.md`, `NOTICE` | Operator documentation | 9 |

---

### Task 1: Seed the repository from herdr-container

Produces an image that boots the oneshots and sshd as user `paseo`, with the share at `/home/paseo/workspace`, and a smoke suite that passes. No Paseo yet.

**Files:**
- Create (copied): `Dockerfile`, `compose.yaml`, `.dockerignore`, `.gitignore`, `.hadolint.yaml`, `LICENSE`, `rootfs/**`, `tests/smoke.sh`, `tests/lib/assert.sh`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- Modify after copy: every file above

**Interfaces:**
- Produces, in `common.sh`: `CONTAINER_USER=paseo`, `CONTAINER_GROUP=paseo`, `USER_HOME=/home/paseo`, `CONFIG_DIR=/config`, `WORKSPACE_DIR=/home/paseo/workspace`, `AGENT_PREFIX=/config/agents`, `AGENT_LIB_DIR=/usr/local/lib/paseo-container/agents`, `TOOL_PREFIX=/config/tools`, `GIT_CREDENTIALS=/config/git/credentials`, and the functions `log`, `warn`, `die`, `link_persist`, `npm_agent_install`, `tool_env`, `npm_tool_install`, `uv_tool_install`, `chown_home`.
- Produces: `/run/paseo-container-ready`, which `05-tools` creates as its last action and `01-user-setup` deletes as its first. `tests/smoke.sh` defines `boot_complete`, `dexec`, `dexec_user`, and `wait_for`.

- [ ] **Step 1: Copy the skeleton**

```bash
cd ~/code/paseo-container
SRC=~/code/herdr_container
cp -a "$SRC"/{Dockerfile,compose.yaml,.dockerignore,.gitignore,.hadolint.yaml,LICENSE} .
cp -a "$SRC"/rootfs .
mkdir -p tests/lib .github/workflows
cp -a "$SRC"/tests/smoke.sh tests/
cp -a "$SRC"/tests/lib/assert.sh tests/lib/
cp -a "$SRC"/.github/workflows/{ci.yml,release.yml} .github/workflows/
mv rootfs/usr/local/lib/herdr-container rootfs/usr/local/lib/paseo-container
mv rootfs/usr/local/bin/herdr-container-banner rootfs/usr/local/bin/paseo-container-banner
mv rootfs/etc/profile.d/herdr-container.sh rootfs/etc/profile.d/paseo-container.sh
mv rootfs/etc/ssh/sshd_config.d/herdr.conf rootfs/etc/ssh/sshd_config.d/paseo.conf
rm -rf rootfs/etc/s6-overlay/s6-rc.d/herdr-server rootfs/etc/s6-overlay/s6-rc.d/herdr-gui
rm -f rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/herdr-server \
      rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/herdr-gui
```

- [ ] **Step 2: Apply the mechanical renames**

```bash
cd ~/code/paseo-container
files=$(grep -rlI . rootfs tests Dockerfile compose.yaml .github)
sed -i \
  -e 's/herdr-container/paseo-container/g' \
  -e 's/HERDR_USER/CONTAINER_USER/g' \
  -e 's/HERDR_GROUP/CONTAINER_GROUP/g' \
  -e 's/HERDR_HOME/USER_HOME/g' \
  -e 's#/home/herdr#/home/paseo#g' \
  $files
```

- [ ] **Step 3: Rewrite the constants block in `common.sh`**

Replace the block from `HERDR_USER="herdr"` (now `CONTAINER_USER="herdr"`) through the second `export` line with:

```bash
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
```

Confirm that `log`, `warn`, and `die` now default their tag to `paseo-container` (Step 2 renamed it).

Append this helper to the end of `common.sh`:

```bash
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
```

- [ ] **Step 4: Fix the Dockerfile**

1. Delete the `gui-build` stage and the `herdr-fetch` stage (everything from the first `# ----` comment block through the end of the `herdr-fetch` stage's last `RUN`).
2. Replace the user-creation `RUN` with:

```dockerfile
RUN set -eux; \
    groupadd -g 100 paseo 2>/dev/null || groupadd paseo; \
    useradd -m -d /home/paseo -s /bin/bash -g paseo paseo; \
    mkdir -p /config /home/paseo/workspace /run/sshd; \
    ln -s /home/paseo/workspace /workspace; \
    chown paseo:paseo /config /home/paseo/workspace
```

3. Delete the two lines `COPY --from=herdr-fetch ...` and `COPY --from=gui-build ...`.
4. In the final `RUN`, keep `chmod 0755 /usr/local/bin/paseo-container-banner` (Step 2 renamed it) and delete the line `herdr --version`.
5. Change `EXPOSE 22 8787` to `EXPOSE 22`. Task 5 adds 6767.

- [ ] **Step 5: Strip herdr from the oneshots**

`01-user-setup/run`:
- Add `rm -f /run/paseo-container-ready` directly after `source .../common.sh`.
- Replace `mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR" "$USER_HOME"` and the recursive chown with:

```bash
mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR" "$USER_HOME"
[ -L /workspace ] || ln -sfn "$WORKSPACE_DIR" /workspace

# /config is small and always ours, so recurse. The home directory holds the
# source share, so chown_home skips it.
chown -R "$PUID:$PGID" "$CONFIG_DIR"
chown_home "$PUID:$PGID"
```

`02-config-scaffold/run`:
- In the first `mkdir -p`, delete `"${CONFIG_DIR}/herdr"` and `"${CONFIG_DIR}/herdr-gui"`.
- Delete everything from the comment `# herdr keeps its unix sockets beside config.toml.` through `link_persist "${CONFIG_DIR}/herdr-gui/" ...` inclusive.
- In the final `chown`, delete the three lines naming `herdr`, `herdr/config.toml`, and `herdr-gui`.

`04-agents/run`:
- Delete the `install_integration` function and its comment block.
- Delete the call `install_integration "$name"` and the comment above the `if [ "${AGENT_UPDATE:-0}" ...` line that mentions `install_integration`.
- Replace the comment `# A failed agent install must not stop herdr and sshd from` with `# A failed agent install must not stop Paseo and sshd from`.
- Replace the last `chown -R "${PUID:-99}:${PGID:-100}" "$AGENT_PREFIX" "$USER_HOME"` with:

```bash
chown -R "${PUID:-99}:${PGID:-100}" "$AGENT_PREFIX"
chown_home "${PUID:-99}:${PGID:-100}"
```

`05-tools/run`: append as the final line:

```bash
: > /run/paseo-container-ready
```

`agents/claude.sh` and `agents/codex.sh`: delete each `agent_integration` function.

`agents/codex.sh`: change `CODEX_WRAPPER_TAG="paseo-container codex wrapper v2"` to `CODEX_WRAPPER_TAG="paseo-container codex wrapper v1"`. Replace the first comment paragraph (lines describing herdr naming panes) with:

```bash
# npm's @openai/codex entry point is a Node shim that spawns the natively
# compiled codex as a child process. This installer replaces the shim with a
# wrapper that execs the native binary, so codex runs as one process and the
# wrapper can clear codex's stale arg0 directories first (see below).
```

and the heredoc comment `# exec, so that this pane's foreground process is codex and herdr sees it.` with `# exec, so that codex replaces this shell rather than running as its child.`

`sshd_config.d/paseo.conf`: change `AllowUsers herdr` to `AllowUsers paseo`.

`03-ssh-keys/run`: no change beyond Step 2.

- [ ] **Step 6: Replace the banner with a minimal one**

Overwrite `rootfs/usr/local/bin/paseo-container-banner`:

```bash
#!/command/with-contenv bash
set -euo pipefail
# shellcheck source=rootfs/usr/local/lib/paseo-container/common.sh
source /usr/local/lib/paseo-container/common.sh

list_bin() {
    local dir="$1" names="" entry
    if [ -d "$dir" ]; then
        for entry in "$dir"/*; do
            [ -e "$entry" ] || continue
            names="${names}$(basename "$entry") "
        done
    fi
    printf '%s' "${names:-none}"
}

outbound_key="$(ssh-keygen -lf "${CONFIG_DIR}/ssh/id_ed25519.pub" 2>/dev/null \
    | awk '{print $2}' || true)"
if [ -n "$outbound_key" ]; then
    outbound_key="${outbound_key} in ${CONFIG_DIR}/ssh/id_ed25519.pub"
else
    outbound_key="none"
fi

cat <<BANNER

  paseo-container

  agents        $(list_bin "${AGENT_PREFIX}/bin")
  tools         $(list_bin "${TOOL_PREFIX}/bin")
  ssh in        container port 22, key-only, user '${CONTAINER_USER}'
  ssh out       ${outbound_key}
  workspace     ${WORKSPACE_DIR}
  config        ${CONFIG_DIR}

BANNER
```

- [ ] **Step 7: Update `compose.yaml`**

Set `container_name: paseo-container-test`, `image: paseo-container:test`, `hostname: paseo`, rename the service key `herdr:` to `paseo:`, and replace the ports and the herdr-only environment:

```yaml
    ports:
      - "2223:22"
    stop_grace_period: 30s
```

Delete these environment lines: `HERDR_INTEGRATIONS`, `HERDR_GUI_PASSWORD`, `HERDR_GUI_ENABLED`. Change `AGENTS: "${AGENTS-claude}"` to `AGENTS: "${AGENTS-claude,codex}"`. Change the workspace volume to:

```yaml
      - ./tests/.tmp/workspace:/home/paseo/workspace
```

- [ ] **Step 8: Rework `tests/smoke.sh` helpers and remove herdr sections**

At the top, replace the `dexec`, `dexec_herdr`, and `herdr_server_running` helpers with:

```bash
dexec() {
    "${COMPOSE[@]}" exec -T paseo "$@"
}

# dexec_user: runs a command as the container user with that user's HOME,
# because plain `docker compose exec` defaults to root with HOME=/root.
dexec_user() {
    "${COMPOSE[@]}" exec -T -u paseo -e HOME=/home/paseo paseo "$@"
}

# boot_complete: 05-tools writes this marker as its last action, and
# 01-user-setup deletes it first thing, so it means "this boot's oneshots all
# finished".
boot_complete() {
    dexec test -e /run/paseo-container-ready
}
```

Then, across the file:
- Replace every `dexec_herdr` with `dexec_user`, every `herdr_server_running` with `boot_complete`, every `logs herdr` with `logs paseo`, every `restart herdr` with `restart paseo`, every `herdr@127.0.0.1` with `paseo@127.0.0.1`, and `-p 2222` with `-p 2223`.
- Replace `wait_for "container reaches s6 ready" 240 dexec test -e /run/paseo-container-umask` and each later `dexec test -e /run/paseo-container-umask` wait with `wait_for "<same name>" 240 boot_complete`.
- Delete `assert_ok "herdr binary runs" ...`.
- Change the user and ownership assertions to name `paseo` (`id -u paseo`, `id -g paseo`, expected owner `"paseo"`).
- Change `assert_eq "hostname is set at creation" "herdr"` to expect `"paseo"`.
- Delete these whole sections, from their `echo "== ... =="` line to the line before the next section: `herdr server`, `web ui`, `new panes open a login bash in /workspace`, `web ui token mode (no password)`, `integrations can be turned off`.
- In `config scaffold`: loop over `ssh agents/bin agents/state git` only; delete the `herdr config.toml links to /config` and `sockets are NOT under /config` assertions.
- In `agents install on the first boot`: delete the three integration assertions (`the claude integration is current`, `the integration hook persists to /config`, `claude settings name the integration hook`) and their comments.
- In `persistence across restart`: write the canary to `/config/canary.txt` and delete the `config.toml link survived restart` assertion.
- In `ssh`: replace the `HERDR_VERSION_STR`/`ssh runs herdr` pair with:

```bash
assert_eq "ssh logs in as paseo" "paseo" \
    "$(ssh "${SSH_OPTS[@]}" paseo@127.0.0.1 whoami 2>/dev/null | tr -d '\r')"
```

- In `herdr sees codex as an agent`: rename the header to `== codex wrapper ==`, change the expected tag to `paseo-container codex wrapper v1`, and delete everything from `CODEX_WS_JSON=` to the end of that section.
- In `service toggles`: delete the `HERDR_GUI_ENABLED=0` block; in the `SSHD_ENABLED=0` block, wait with `boot_complete` instead of curl.
- In `banner`: keep only `banner names the ssh port` and `banner names the outbound key`.
- Change the `image layer hygiene` image name to `paseo-container:test`.

- [ ] **Step 9: Add the share-ownership test (Review Focus 1)**

Add this section after `config scaffold`:

```bash
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
```

- [ ] **Step 10: Confirm no herdr references remain**

Run: `grep -rniI herdr rootfs tests Dockerfile compose.yaml .github`
Expected: matches only in comments that explain history (for example the FUSE self-update comment in the Dockerfile). Rewrite any match that names a herdr binary, path, service, or variable.

- [ ] **Step 11: Update CI references**

In `.github/workflows/ci.yml`, confirm the shellcheck `find` names `paseo-container-banner` (Step 2 renamed it), and delete the whole `template` job. Task 8 adds a new one for the new template. The `smoke` job keeps `needs: [lint]`.

- [ ] **Step 12: Run lint and the smoke suite**

Run: `shellcheck --shell=bash --external-sources $(find rootfs tests -type f \( -name '*.sh' -o -name run -o -name up -o -name paseo-container-banner \))`
Expected: no output.

Run: `./tests/smoke.sh`
Expected: final line `N passed, 0 failed`.

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "feat: seed the image from herdr-container

Copy the herdr-container skeleton, rename the user to paseo, mount the
share inside the home directory, and drop the herdr and her-di-dr
services.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `HOME_PERSIST`

**Files:**
- Modify: `rootfs/etc/s6-overlay/s6-rc.d/04-agents/run`
- Modify: `rootfs/etc/s6-overlay/s6-rc.d/02-config-scaffold/run` (create `/config/home`)
- Modify: `compose.yaml`, `tests/smoke.sh`

**Interfaces:**
- Consumes: `link_persist SOURCE TARGET`, `USER_HOME`, `CONFIG_DIR` from Task 1.
- Produces: `/config/home/<path>` targets; environment variable `HOME_PERSIST` (default `.config/ .kube/ .talos/`).

- [ ] **Step 1: Write the failing test**

Add to `compose.yaml` environment: `HOME_PERSIST: "${HOME_PERSIST-.config/ .kube/ .talos/}"`.

Add a section to `tests/smoke.sh` after `the share keeps its own ownership`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/smoke.sh 2>&1 | grep -A1 'HOME_PERSIST\|FAIL'`
Expected: `FAIL ~/.config links to /config/home`.

- [ ] **Step 3: Implement**

In `02-config-scaffold/run`, add `"${CONFIG_DIR}/home"` to the first `mkdir -p` list and to the final `chown` list.

In `04-agents/run`, insert before `AGENTS="${AGENTS-claude}"`:

```bash
# HOME_PERSIST names home-directory paths that tools other than the agents
# keep their configuration in: gh's credentials under .config/gh, the
# OpenStack client's .config/openstack/clouds.yaml, kubeconfig, talosconfig.
# The home directory is not persisted, so without a link each of those is
# lost on every recreate. These links run before any agent installs, for the
# same reason the agents' own persist paths do.
HOME_PERSIST="${HOME_PERSIST-.config/ .kube/ .talos/}"
while IFS= read -r rel; do
    case "$rel" in
        /*|*..*) warn "HOME_PERSIST: ignoring '${rel}': must be relative to home"; continue ;;
    esac
    link_persist "${CONFIG_DIR}/home/${rel}" "${USER_HOME}/${rel}"
    chown -h "${PUID:-99}:${PGID:-100}" "${USER_HOME}/${rel%/}"
    if [ -e "${CONFIG_DIR}/home/${rel%/}" ]; then
        chown -h "${PUID:-99}:${PGID:-100}" "${CONFIG_DIR}/home/${rel%/}"
    fi
done < <(printf '%s\n' "$HOME_PERSIST" | tr -s '[:space:]' '\n' | sed '/^$/d')
```

At the end of the same script, change `chown -R "${PUID:-99}:${PGID:-100}" "$AGENT_PREFIX"` to:

```bash
chown -R "${PUID:-99}:${PGID:-100}" "$AGENT_PREFIX" "${CONFIG_DIR}/home"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./tests/smoke.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(tools): persist tool configuration with HOME_PERSIST

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `BIN_TOOLS`

**Files:**
- Modify: `rootfs/usr/local/lib/paseo-container/common.sh`
- Modify: `rootfs/etc/s6-overlay/s6-rc.d/05-tools/run`
- Modify: `compose.yaml`, `tests/smoke.sh`

**Interfaces:**
- Consumes: `install_tools KIND INSTALLER LIST` and `split_specs` in `05-tools/run`; `TOOL_PREFIX`, `CONTAINER_USER`, `USER_HOME`.
- Produces: `bin_tool_install SPEC` in `common.sh`, where `SPEC` is `name=url[#sha256=<hex>]`; ledger lines `bin <spec>`.

- [ ] **Step 1: Write the failing test**

The test serves fixtures with `file://` URLs, which `curl` accepts, so it needs no network. Add to `compose.yaml` environment:

```yaml
      BIN_TOOLS: "${BIN_TOOLS-}"
```

Add a section to `tests/smoke.sh` before `== banner ==`:

```bash
echo "== BIN_TOOLS =="
mkdir -p "$TMP_DIR/config/fixtures"
printf '#!/bin/sh\necho hello-bin\n' > "$TMP_DIR/config/fixtures/hello"
GOOD_SHA="$(sha256sum "$TMP_DIR/config/fixtures/hello" | cut -d' ' -f1)"
BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"
"${COMPOSE[@]}" down >/dev/null
BIN_TOOLS="hello=file:///config/fixtures/hello#sha256=${GOOD_SHA} badsum=file:///config/fixtures/hello#sha256=${BAD_SHA} missing=file:///config/fixtures/does-not-exist" \
    "${COMPOSE[@]}" up -d
wait_for "container boots with BIN_TOOLS" 240 boot_complete
assert_eq "a BIN_TOOLS binary runs" "hello-bin" \
    "$(dexec_user hello 2>/dev/null | tr -d '\r')"
assert_eq "a BIN_TOOLS binary is owned by paseo" "paseo" \
    "$(dexec stat -c '%U' /config/tools/bin/hello | tr -d '\r')"
assert_fail "a wrong checksum installs nothing" dexec test -e /config/tools/bin/badsum
assert_fail "an unreachable URL installs nothing" dexec test -e /config/tools/bin/missing
assert_ok "no partial download is left behind" \
    dexec sh -c '! ls /config/tools/bin/.bin-tool.* >/dev/null 2>&1'
BIN_LOGS="$("${COMPOSE[@]}" logs paseo 2>&1)"
assert_contains "a wrong checksum is reported" "$BIN_LOGS" "badsum: checksum mismatch"
"${COMPOSE[@]}" restart paseo >/dev/null
wait_for "container returns for the BIN_TOOLS ledger check" 240 boot_complete
assert_contains "a second boot skips an installed binary" \
    "$("${COMPOSE[@]}" logs paseo 2>&1 | tail -n 200)" "bin: hello=file:///config/fixtures/hello#sha256=${GOOD_SHA} already installed"
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "container returns to the default configuration" 240 boot_complete
```

Note: `restart` keeps the environment from the last `up`, so `BIN_TOOLS` still applies there.

The existing assertion `the ledger records each spec once` expects `2` ledger lines. It runs in `== tools ==`, before this section adds `bin` lines, so its count stays `2`. Place this section after `== tools ==` to keep that true.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/smoke.sh 2>&1 | grep FAIL`
Expected: `FAIL a BIN_TOOLS binary runs`.

- [ ] **Step 3: Implement `bin_tool_install` in `common.sh`**

Append:

```bash
# bin_tool_install SPEC
#
# Installs one single-binary tool into TOOL_PREFIX/bin. SPEC is name=url, with
# an optional #sha256=<hex> suffix on the URL. kubectl and talosctl ship as
# plain executables on neither npm nor PyPI, which is why this exists. The URL
# names the version, so the operator pins it.
#
# The download lands in a temporary file beside its destination and is
# renamed into place only after the checksum passes, so a failed or partial
# download never leaves a broken command on PATH.
bin_tool_install() {
    local spec="$1" name url sha="" tmp
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
        *'#sha256='*) sha="${url##*#sha256=}"; url="${url%#sha256=*}" ;;
    esac

    tmp="$(mktemp "${TOOL_PREFIX}/bin/.bin-tool.XXXXXX")"
    if ! curl -fsSL --retry 3 -o "$tmp" "$url"; then
        rm -f "$tmp"
        warn "bin: ${name}: download failed from ${url}"
        return 1
    fi
    if [ -n "$sha" ] && ! printf '%s  %s\n' "$sha" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$tmp"
        warn "bin: ${name}: checksum mismatch"
        return 1
    fi
    chmod 0755 "$tmp"
    chown "${PUID:-99}:${PGID:-100}" "$tmp"
    mv -f "$tmp" "${TOOL_PREFIX}/bin/${name}"
}
```

- [ ] **Step 4: Wire it into `05-tools/run`**

`split_specs` turns commas into spaces, and a URL can contain commas. Add a space-only splitter after `split_specs`:

```bash
# split_words LIST: one entry per line, split on whitespace only. BIN_TOOLS
# entries are URLs, which may contain commas.
split_words() {
    printf '%s\n' "$1" | tr -s '[:space:]' '\n' | sed '/^$/d'
}
```

Change `install_tools` to take the splitter as a fourth argument, defaulting to `split_specs`:

```bash
install_tools() {
    local kind="$1" installer="$2" list="$3" splitter="${4:-split_specs}" spec
```

and its loop's input from `< <(split_specs "$list")` to `< <("$splitter" "$list")`.

After the `install_tools python ...` line, add:

```bash
install_tools bin bin_tool_install "${BIN_TOOLS:-}" split_words
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./tests/smoke.sh`
Expected: `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(tools): install single-binary tools with BIN_TOOLS

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Bake `gh` into the image

**Files:**
- Modify: `Dockerfile`
- Modify: `tests/smoke.sh`

**Interfaces:**
- Produces: `ARG GH_VERSION`, `ARG GH_SHA256_AMD64`, `ARG GH_SHA256_ARM64` (Task 8's version-check workflow rewrites these three lines by name); `/usr/local/bin/gh`.

- [ ] **Step 1: Write the failing test**

In `tests/smoke.sh`, add `gh` to the `for cmd in ...` loop in `== base image ==`, and add:

```bash
assert_ok "gh runs as paseo" dexec_user gh --version
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/smoke.sh 2>&1 | grep FAIL`
Expected: `FAIL gh is in the image`.

- [ ] **Step 3: Look up the pinned version and digests**

```bash
GH_VERSION="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//')"
curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
  | grep -E "gh_${GH_VERSION}_linux_(amd64|arm64)\.tar\.gz$"
echo "$GH_VERSION"
```

Record the version and both digests.

- [ ] **Step 4: Add the build arguments and install step**

Add to the `runtime` stage's `ARG` block, using the values from Step 3:

```dockerfile
ARG GH_VERSION=<version from Step 3>
ARG GH_SHA256_AMD64=<amd64 digest from Step 3>
ARG GH_SHA256_ARM64=<arm64 digest from Step 3>
```

Add after the uv `RUN`:

```dockerfile
# gh, the GitHub CLI. Agents reach for it for pull requests, issues, and CI
# logs. Debian's package lags upstream, so the release tarball is used, pinned
# by version and digest like Node and uv.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) gharch="amd64"; ghsha="${GH_SHA256_AMD64}" ;; \
      arm64) gharch="arm64"; ghsha="${GH_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gharch}.tar.gz" \
      -o /tmp/gh.tar.gz; \
    echo "${ghsha}  /tmp/gh.tar.gz" | sha256sum -c -; \
    tar -C /usr/local --strip-components=1 --no-same-owner -xzf /tmp/gh.tar.gz \
      "gh_${GH_VERSION}_linux_${gharch}/bin/gh"; \
    rm -f /tmp/gh.tar.gz; \
    gh --version
```

The `<...>` markers in Step 4 are filled with Step 3's output before committing; the committed Dockerfile contains literal values.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./tests/smoke.sh`
Expected: `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(tools): ship the GitHub CLI

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Run the Paseo daemon

**Files:**
- Modify: `Dockerfile`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/06-paseo-prep/{type,up,run,dependencies.d/05-tools}`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/paseo-daemon/{type,run,dependencies.d/06-paseo-prep}`
- Create: `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/{06-paseo-prep,paseo-daemon}`
- Modify: `rootfs/usr/local/lib/paseo-container/common.sh`, `compose.yaml`, `tests/smoke.sh`

**Interfaces:**
- Consumes: `CONTAINER_USER`, `USER_HOME`, `WORKSPACE_DIR`, `TOOL_PREFIX`, `AGENT_PREFIX`, `/run/paseo-container-umask`.
- Produces: `PASEO_DIR=/config/paseo` and `PASEO_PASSWORD_FILE=/config/paseo/password` in `common.sh`; `/etc/paseo-server-entry` containing the supervisor path; smoke helper `paseo_healthy`; the harness password `smoketest`.

- [ ] **Step 1: Write the failing tests**

Add to `compose.yaml`: under `ports`, `- "6767:6767"`; under environment, `PASEO_PASSWORD: "${PASEO_PASSWORD-smoketest}"`.

Add a helper to `tests/smoke.sh` beside `boot_complete`:

```bash
paseo_healthy() {
    curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:6767/api/health
}
```

Add a section after `== base image ==`:

```bash
echo "== paseo daemon =="
wait_for "paseo answers /api/health" 240 paseo_healthy
assert_eq "/api/status without the password is 401" "401" \
    "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:6767/api/status)"
assert_eq "/api/status with the password is 200" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer smoketest' \
        http://127.0.0.1:6767/api/status)"
assert_eq "paseo runs as paseo" "paseo" \
    "$(dexec sh -c 'ps -o user= -C node | head -n1' | tr -d '\r ')"
assert_ok "paseo state lives in /config/paseo" dexec test -s /config/paseo/daemon-keypair.json
assert_ok "worktrees default under /config/paseo" \
    dexec sh -c 'mkdir -p /config/paseo/worktrees && test -d /config/paseo/worktrees'
DAEMON_PID="$(dexec sh -c 'pgrep -u paseo -f supervisor-entrypoint | head -n1' | tr -d '\r')"
DAEMON_ENV="$(dexec sh -c "tr '\0' '\n' < /proc/${DAEMON_PID}/environ")"
assert_contains "self-update is refused" "$DAEMON_ENV" "PASEO_DESKTOP_MANAGED=1"
assert_contains "PASEO_HOME points at /config" "$DAEMON_ENV" "PASEO_HOME=/config/paseo"
assert_ok "NODE_ENV is not set for the daemon" \
    sh -c '! printf "%s" "$1" | grep -q "^NODE_ENV="' _ "$DAEMON_ENV"
assert_fail "the paseo user cannot overwrite Paseo" \
    dexec_user test -w /usr/local/lib/node_modules/@getpaseo
assert_ok "the daemon finds claude on PATH" \
    sh -c 'printf "%s" "$1" | grep -q "^PATH=.*/config/agents/bin"' _ "$DAEMON_ENV"

echo "== a clean stop lets paseo finish =="
# A clean shutdown removes paseo.pid; its absence after stop is the evidence
# that s6 and Docker gave the supervisor enough time.
"${COMPOSE[@]}" stop -t 30 paseo >/dev/null
assert_fail "paseo.pid is gone after a clean stop" test -e "$TMP_DIR/config/paseo/paseo.pid"
"${COMPOSE[@]}" start paseo >/dev/null
wait_for "paseo returns after a clean stop" 240 paseo_healthy

echo "== a stale paseo.pid does not block the next boot =="
"${COMPOSE[@]}" kill -s SIGKILL paseo >/dev/null
# SIGKILL normally leaves the supervisor's lock behind. Plant one with this
# host's boot ID if it did not, so the boot below always meets a stale lock.
[ -e "$TMP_DIR/config/paseo/paseo.pid" ] \
    || printf '{"pid":1,"bootId":"%s"}\n' "$(cat /proc/sys/kernel/random/boot_id)" \
        > "$TMP_DIR/config/paseo/paseo.pid"
"${COMPOSE[@]}" start paseo >/dev/null
wait_for "paseo starts despite a stale paseo.pid" 240 paseo_healthy
```

Change every later readiness wait that uses `boot_complete` after a restart or `up` to wait on `paseo_healthy` instead, except in the `SSHD_ENABLED=0` block, which keeps `boot_complete`. The daemon depends on every oneshot, so health implies boot completion.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/smoke.sh 2>&1 | grep FAIL`
Expected: `FAIL paseo answers /api/health` (timeout).

- [ ] **Step 3: Install Paseo in the Dockerfile**

Add to the `runtime` stage's `ARG` block:

```dockerfile
ARG PASEO_VERSION=0.11.2
```

Add after the `gh` `RUN`:

```dockerfile
# Paseo, pinned. The CLI and the server are installed side by side, as
# Paseo's own image does, so the supervisor entry point sits at a stable path
# under npm's global root. Both land in root-owned /usr/local, where the paseo
# user cannot write: the app's Update button runs `npm install -g` as that
# user, and that install has to fail rather than replace the pinned version.
# ONNXRUNTIME_NODE_INSTALL=skip stops an optional speech dependency from
# downloading native libraries at build time.
RUN set -eux; \
    ONNXRUNTIME_NODE_INSTALL=skip npm install -g --no-fund --no-audit --loglevel=error \
      "@getpaseo/cli@${PASEO_VERSION}" "@getpaseo/server@${PASEO_VERSION}"; \
    npm cache clean --force; \
    entry="$(npm root -g)/@getpaseo/server/dist/scripts/supervisor-entrypoint.js"; \
    test -f "$entry"; \
    node --check "$entry"; \
    printf '%s\n' "$entry" > /etc/paseo-server-entry; \
    test "$(paseo --version | tr -d 'v')" = "${PASEO_VERSION}"
```

If `paseo --version` prints a format other than the bare version, change the last check to `paseo --version | grep -qF "${PASEO_VERSION}"`.

Add to the `ENV` block: `S6_SERVICES_GRACETIME=25000`.

Change `EXPOSE 22` to `EXPOSE 22 6767`.

Add before `ENTRYPOINT`:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:6767/api/health || exit 1
```

The long start period covers the first boot, which installs agents and tools before the daemon starts.

- [ ] **Step 4: Add constants to `common.sh`**

Add to the constants block and its `export` lines:

```bash
# Paseo's own state directory. Paseo reads it from PASEO_HOME, which is why
# the container user's home directory is USER_HOME and never PASEO_HOME.
PASEO_DIR="/config/paseo"
PASEO_PASSWORD_FILE="/config/paseo/password"
export PASEO_DIR PASEO_PASSWORD_FILE
```

- [ ] **Step 5: Create `06-paseo-prep`**

`rootfs/etc/s6-overlay/s6-rc.d/06-paseo-prep/type`:

```text
oneshot
```

`rootfs/etc/s6-overlay/s6-rc.d/06-paseo-prep/up`:

```text
/etc/s6-overlay/s6-rc.d/06-paseo-prep/run
```

`rootfs/etc/s6-overlay/s6-rc.d/06-paseo-prep/dependencies.d/05-tools`: empty file.

`rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/06-paseo-prep`: empty file.

`rootfs/etc/s6-overlay/s6-rc.d/06-paseo-prep/run`:

```bash
#!/command/with-contenv bash
set -euo pipefail
LOG_TAG="06-paseo-prep"
# shellcheck source=rootfs/usr/local/lib/paseo-container/common.sh
source /usr/local/lib/paseo-container/common.sh

mkdir -p "$PASEO_DIR"
chown "${PUID:-99}:${PGID:-100}" "$PASEO_DIR"

# Paseo's supervisor treats paseo.pid as live when the host boot ID matches
# and the recorded PID exists. A container restart keeps the host's boot ID,
# and a new container reuses small PIDs, so a lock left by an unclean stop can
# look live. The daemon then exits as "already running" and s6 restarts it in
# a loop. No daemon runs before this oneshot, so any lock here is stale.
if [ -e "${PASEO_DIR}/paseo.pid" ]; then
    log "removing a stale ${PASEO_DIR}/paseo.pid"
    rm -f "${PASEO_DIR}/paseo.pid"
fi
log "ready"
```

- [ ] **Step 6: Create `paseo-daemon`**

`rootfs/etc/s6-overlay/s6-rc.d/paseo-daemon/type`:

```text
longrun
```

`rootfs/etc/s6-overlay/s6-rc.d/paseo-daemon/dependencies.d/06-paseo-prep`: empty file.

`rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/paseo-daemon`: empty file.

`rootfs/etc/s6-overlay/s6-rc.d/paseo-daemon/run`:

```bash
#!/command/with-contenv bash
set -euo pipefail
LOG_TAG="paseo-daemon"
# shellcheck source=rootfs/usr/local/lib/paseo-container/common.sh
source /usr/local/lib/paseo-container/common.sh

umask "$(cat /run/paseo-container-umask 2>/dev/null || echo 022)"

entry="$(cat /etc/paseo-server-entry)"

password="${PASEO_PASSWORD:-}"
if [ -z "$password" ] && [ -s "$PASEO_PASSWORD_FILE" ]; then
    password="$(cat "$PASEO_PASSWORD_FILE")"
fi
# Paseo admits every connection as owner when it has no password, and it
# listens on every interface here. Refuse to start rather than run open.
[ -n "$password" ] || die "no password: set PASEO_PASSWORD or restore ${PASEO_PASSWORD_FILE}"

# s6 runs a service from a directory it deletes once boot finishes; start in
# the share instead, so nothing inherits a deleted working directory.
cd "$WORKSPACE_DIR" || warn "could not enter ${WORKSPACE_DIR}"

if [ -z "${TERM:-}" ] || [ "$TERM" = "dumb" ]; then
    TERM="xterm-256color"
fi

log "starting paseo on 0.0.0.0:6767"
# The supervisor is exec'd directly rather than through `paseo daemon run`,
# because that command deletes PASEO_DESKTOP_MANAGED, and that variable is
# what makes the daemon refuse the app's self-update request. NODE_ENV is
# removed because an inherited NODE_ENV=production breaks worktree setup
# (getpaseo/paseo#4614). Everything else in the container environment, such
# as an operator's ANTHROPIC_API_KEY or GH_TOKEN, passes through to agents.
exec /command/s6-setuidgid "$CONTAINER_USER" \
    env -u NODE_ENV \
        HOME="$USER_HOME" \
        PATH="${TOOL_PREFIX}/bin:${AGENT_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin" \
        PASEO_HOME="$PASEO_DIR" \
        PASEO_LISTEN="0.0.0.0:6767" \
        PASEO_PASSWORD="$password" \
        PASEO_WEB_UI_ENABLED=true \
        PASEO_DESKTOP_MANAGED=1 \
        CLAUDE_CONFIG_DIR="${USER_HOME}/.claude" \
        CODEX_HOME="${USER_HOME}/.codex" \
        XDG_CONFIG_HOME="${USER_HOME}/.config" \
        TERM="$TERM" \
        SHELL=/bin/bash \
    node "$entry"
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `./tests/smoke.sh`
Expected: `0 failed`.

- [ ] **Step 8: Verify the spec's open items and record the results**

Run each and paste the output into the commit body:

```bash
docker run --rm --entrypoint cat paseo-container:test /etc/paseo-server-entry
docker run --rm --entrypoint sh paseo-container:test -c \
  'grep -rln "PASEO_DESKTOP_MANAGED\|desktopManaged" "$(npm root -g)/@getpaseo/server/dist" | head'
```

Read each listed file's use of the flag. Expected: it gates self-update and the `daemonSelfUpdate` capability only. If it changes any other behavior, stop and report it before continuing.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(paseo): run the Paseo daemon under s6

Install Paseo ${PASEO_VERSION}, exec its supervisor as the paseo user,
clear a stale paseo.pid on boot, and give a stop 25 seconds to finish.

<paste Step 8 findings>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Relay, password, hostnames, and pairing

**Files:**
- Modify: `rootfs/etc/s6-overlay/s6-rc.d/02-config-scaffold/run`
- Modify: `compose.yaml`, `tests/smoke.sh`

**Interfaces:**
- Consumes: `PASEO_DIR`, `PASEO_PASSWORD_FILE` from Task 5.
- Produces: seeded `/config/paseo/config.json` (`{"version":1,"daemon":{"relay":{"enabled":true}}}`); generated `/config/paseo/password`, mode `0600`, owned by `paseo`; pass-through `PASEO_HOSTNAMES`.

- [ ] **Step 1: Write the failing tests**

Add `PASEO_HOSTNAMES: "${PASEO_HOSTNAMES-}"` to `compose.yaml`.

Add after `== paseo daemon ==`:

```bash
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

echo "== pairing =="
PAIR_JSON="$(dexec_user env PASEO_HOME=/config/paseo paseo daemon pair --json 2>/dev/null | tr -d '\r')"
assert_contains "pair prints a pairing URL" "$PAIR_JSON" "https://app.paseo.sh/#offer="

echo "== hostnames =="
# /api/status rather than /api/health, in case the health route is exempt
# from the Host check as it is from the password.
assert_eq "an unknown Host is refused" "403" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: tower.lan' \
        -H 'Authorization: Bearer smoketest' http://127.0.0.1:6767/api/status)"
"${COMPOSE[@]}" down >/dev/null
PASEO_HOSTNAMES="tower.lan" "${COMPOSE[@]}" up -d
wait_for "paseo boots with PASEO_HOSTNAMES" 240 paseo_healthy
assert_eq "a listed Host is accepted" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: tower.lan' \
        -H 'Authorization: Bearer smoketest' http://127.0.0.1:6767/api/status)"

echo "== generated password =="
EMPTY_PW_OVERRIDE="$TMP_DIR/empty-password.compose.yaml"
cat >"$EMPTY_PW_OVERRIDE" <<'EOF'
services:
  paseo:
    environment:
      PASEO_PASSWORD: ""
EOF
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
        http://127.0.0.1:6767/api/status)"
"${COMPOSE[@]}" -f "$EMPTY_PW_OVERRIDE" restart paseo >/dev/null
wait_for "paseo returns with the generated password" 240 paseo_healthy
assert_eq "the generated password is reused across boots" "$GEN_PW" \
    "$(dexec cat /config/paseo/password | tr -d '\r\n')"

echo "== a password with shell metacharacters =="
WEIRD_PW_OVERRIDE="$TMP_DIR/weird-password.compose.yaml"
cat >"$WEIRD_PW_OVERRIDE" <<'EOF'
services:
  paseo:
    environment:
      PASEO_PASSWORD: 'p@ss$$HOME"quoted"`tick`'
EOF
"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" -f "$WEIRD_PW_OVERRIDE" up -d
wait_for "paseo boots with a metacharacter password" 240 paseo_healthy
assert_eq "a metacharacter password authenticates verbatim" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' \
        -H 'Authorization: Bearer p@ss$HOME"quoted"`tick`' \
        http://127.0.0.1:6767/api/status)"

"${COMPOSE[@]}" down >/dev/null
"${COMPOSE[@]}" up -d
wait_for "paseo returns to the default configuration" 240 paseo_healthy
```

Compose turns `$$` into a literal `$`, which is why the override writes `$$HOME`. The password has no spaces because an HTTP bearer token cannot carry one; the run script's quoting is what this test exercises.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/smoke.sh 2>&1 | grep FAIL`
Expected: `FAIL config.json turns the relay on`.

- [ ] **Step 3: Implement seeding in `02-config-scaffold/run`**

Add `"${CONFIG_DIR}/paseo"` to the first `mkdir -p` list. Insert before the closing ownership block:

```bash
# Paseo's relay is off on a fresh install. Seed it on, once, in config.json
# rather than with PASEO_RELAY_ENABLED: that variable locks the setting, and
# the app could then never turn the relay off. A file that already exists is
# yours, and is never rewritten.
if [ ! -e "${CONFIG_DIR}/paseo/config.json" ]; then
    printf '%s\n' '{"version":1,"daemon":{"relay":{"enabled":true}}}' \
        > "${CONFIG_DIR}/paseo/config.json"
    log "seeded ${CONFIG_DIR}/paseo/config.json with the relay on"
fi

# Paseo admits every LAN connection as owner when it has no password, so the
# container always runs with one. Without PASEO_PASSWORD, generate one once
# and keep it; the banner names the file, never the value.
if [ -z "${PASEO_PASSWORD:-}" ] && [ ! -s "$PASEO_PASSWORD_FILE" ]; then
    (
        umask 077
        # Read a fixed amount first: `tr < /dev/urandom | head` ends tr with
        # SIGPIPE, which pipefail turns into a failed boot.
        head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32 > "$PASEO_PASSWORD_FILE"
    )
    log "generated a LAN password in ${PASEO_PASSWORD_FILE}"
fi
```

Add to the final ownership block:

```bash
chown "${PUID:-99}:${PGID:-100}" "${CONFIG_DIR}/paseo" "${CONFIG_DIR}/paseo/config.json"
if [ -e "$PASEO_PASSWORD_FILE" ]; then
    chmod 0600 "$PASEO_PASSWORD_FILE"
    chown "${PUID:-99}:${PGID:-100}" "$PASEO_PASSWORD_FILE"
fi
```

The final `head -c 32` can still end the middle `tr` with `SIGPIPE` when 256 random bytes yield more than 32 characters. Wrap the pipeline so that status cannot fail the boot, and check the result instead:

```bash
        { head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32; } > "$PASEO_PASSWORD_FILE" || true
        [ "$(wc -c < "$PASEO_PASSWORD_FILE")" -eq 32 ] || die "could not generate a password"
```

Use this form in place of the single pipeline above.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/smoke.sh`
Expected: `0 failed`. If `paseo daemon pair --json` emits a URL with a different prefix, read the JSON's `url` field and change the needle to the actual prefix.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(paseo): seed the relay and a LAN password

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Boot banner

**Files:**
- Modify: `rootfs/usr/local/bin/paseo-container-banner`
- Modify: `tests/smoke.sh`

**Interfaces:**
- Consumes: `PASEO_DIR`, `PASEO_PASSWORD_FILE`, `CONTAINER_USER`, `AGENT_PREFIX`, `TOOL_PREFIX`.

- [ ] **Step 1: Write the failing tests**

In the `== banner ==` section, add:

```bash
assert_contains "banner names the paseo port" "$BANNER" "container port 6767"
assert_contains "banner reports the paseo version" "$BANNER" \
    "$(dexec paseo --version 2>/dev/null | tr -d '\r' | head -n1)"
assert_contains "banner reports the relay state" "$BANNER" "relay         on"
assert_contains "banner prints the pairing command" "$BANNER" "paseo daemon pair"
assert_ok "banner never prints the password" \
    sh -c '! printf "%s" "$1" | grep -qF smoketest' _ "$BANNER"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/smoke.sh 2>&1 | grep FAIL`
Expected: `FAIL banner names the paseo port`.

- [ ] **Step 3: Implement**

Replace the `cat <<BANNER ... BANNER` block, and add the lookups above it:

```bash
paseo_version="$(paseo --version 2>/dev/null | head -n1 || echo 'unknown')"

relay="$(jq -r '.daemon.relay.enabled // false' "${PASEO_DIR}/config.json" 2>/dev/null || echo unknown)"
case "$relay" in
    true) relay="on" ;;
    false) relay="off" ;;
esac

if [ -n "${PASEO_PASSWORD:-}" ]; then
    lan_auth="password from PASEO_PASSWORD"
else
    lan_auth="password in ${PASEO_PASSWORD_FILE}"
fi

cat <<BANNER

  paseo-container

  paseo         ${paseo_version}
  agents        $(list_bin "${AGENT_PREFIX}/bin")
  tools         $(list_bin "${TOOL_PREFIX}/bin")
  relay         ${relay}
  lan           container port 6767, ${lan_auth}
  ssh in        container port 22, key-only, user '${CONTAINER_USER}'
  ssh out       ${outbound_key}
  workspace     ${WORKSPACE_DIR}
  config        ${CONFIG_DIR}

  Pair a phone or desktop app:
    docker exec -it -u ${CONTAINER_USER} -e PASEO_HOME=${PASEO_DIR} <container> paseo daemon pair

  Sign in to the agents:
    docker exec -it -u ${CONTAINER_USER} <container> claude
    docker exec -it -u ${CONTAINER_USER} <container> codex login

BANNER
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/smoke.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(banner): report Paseo, relay, LAN access, and pairing

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Unraid template, CI, and version checks

**Files:**
- Create: `unraid/paseo-container.xml`
- Modify: `.github/workflows/ci.yml` (restore the `template` job)
- Create: `.github/workflows/paseo-version-check.yml`
- Modify: `.github/workflows/release.yml` (no herdr references expected; confirm)

**Interfaces:**
- Consumes: `ARG PASEO_VERSION`, `ARG GH_VERSION`, `ARG GH_SHA256_AMD64`, `ARG GH_SHA256_ARM64` lines in `Dockerfile`.

- [ ] **Step 1: Write the template check (the failing test)**

Add this job to `.github/workflows/ci.yml`:

```yaml
  template:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate the Unraid template
        run: |
          sudo apt-get update
          sudo apt-get install -y libxml2-utils
          xmllint --noout unraid/paseo-container.xml
          for field in Name Repository Overview Category WebUI Support; do
            grep -q "<${field}>" unraid/paseo-container.xml \
              || { echo "missing <${field}>"; exit 1; }
          done
          for var in PUID PGID UMASK TZ SSH_PUBKEY AGENTS AGENT_UPDATE \
                     PASEO_PASSWORD PASEO_HOSTNAMES SSHD_ENABLED \
                     GIT_USER_NAME GIT_USER_EMAIL GIT_TOKEN GIT_TOKEN_HOST GH_TOKEN \
                     APT_PACKAGES NPM_TOOLS PYTHON_TOOLS BIN_TOOLS HOME_PERSIST \
                     TOOL_UPDATE; do
            grep -q "Name=\"${var}\"" unraid/paseo-container.xml \
              || { echo "template is missing ${var}"; exit 1; }
          done
          grep -q -- "--stop-timeout=30" unraid/paseo-container.xml \
            || { echo "template is missing --stop-timeout=30"; exit 1; }
          grep -q 'Target="/home/paseo/workspace"' unraid/paseo-container.xml \
            || { echo "template mounts the share at the wrong path"; exit 1; }
          echo "template ok"
```

Run the same script locally: it fails because the template does not exist.

- [ ] **Step 2: Write `unraid/paseo-container.xml`**

```xml
<?xml version="1.0"?>
<Container version="2">
  <Name>paseo-container</Name>
  <Repository>ghcr.io/jumpingmushroom/paseo-container:latest</Repository>
  <Registry>https://github.com/jumpingmushroom/paseo-container/pkgs/container/paseo-container</Registry>
  <Network>bridge</Network>
  <Privileged>false</Privileged>
  <Support>https://github.com/jumpingmushroom/paseo-container/issues</Support>
  <Project>https://github.com/jumpingmushroom/paseo-container</Project>
  <Overview>
    Runs the Paseo daemon with Claude Code and Codex. Connect from the Paseo
    desktop and phone apps through Paseo's end-to-end encrypted relay, or on
    the LAN on port 6767. Agents keep running when every app disconnects.

    After the first boot, pair a device with:
    docker exec -it -u paseo -e PASEO_HOME=/config/paseo paseo-container paseo daemon pair

    Exclude this container from automatic updates and from backups that stop
    containers: a restart interrupts any agent turn that is running.
  </Overview>
  <Category>Productivity: Tools:Utilities</Category>
  <WebUI>http://[IP]:[PORT:6767]/</WebUI>
  <Icon>https://paseo.sh/favicon.png</Icon>
  <ExtraParams>--hostname=paseo --stop-timeout=30</ExtraParams>
  <PostArgs></PostArgs>
  <DonateText></DonateText>
  <DonateLink></DonateLink>

  <Config Name="Paseo" Target="6767" Default="6767" Mode="tcp"
          Description="Paseo API, web UI, and LAN direct connections."
          Type="Port" Display="always" Required="true" Mask="false">6767</Config>

  <Config Name="SSH" Target="22" Default="2223" Mode="tcp"
          Description="SSH port. Connect with: ssh -p 2223 paseo@[IP]"
          Type="Port" Display="always" Required="true" Mask="false">2223</Config>

  <Config Name="Config" Target="/config" Default="/mnt/user/appdata/paseo-container"
          Mode="rw"
          Description="Paseo state, the relay keypair, worktrees, agent logins, SSH keys, and tools."
          Type="Path" Display="always" Required="true" Mask="false">/mnt/user/appdata/paseo-container</Config>

  <Config Name="Workspace" Target="/home/paseo/workspace" Default="/mnt/user/code" Mode="rw"
          Description="Your source repositories. Mounted inside the home directory so the apps can suggest folders from it."
          Type="Path" Display="always" Required="true" Mask="false">/mnt/user/code</Config>

  <Config Name="PASEO_PASSWORD" Target="PASEO_PASSWORD" Default="" Mode=""
          Description="Password for LAN direct connections. Leave empty and the container generates one in /config/paseo/password."
          Type="Variable" Display="always" Required="false" Mask="true"></Config>

  <Config Name="PASEO_HOSTNAMES" Target="PASEO_HOSTNAMES" Default="" Mode=""
          Description="Extra host names the daemon accepts, comma-separated, for example tower.local. IP addresses always work."
          Type="Variable" Display="always" Required="false" Mask="false"></Config>

  <Config Name="SSH_PUBKEY" Target="SSH_PUBKEY" Default="" Mode=""
          Description="Your SSH public key. Password authentication is disabled."
          Type="Variable" Display="always" Required="true" Mask="false"></Config>

  <Config Name="AGENTS" Target="AGENTS" Default="claude,codex" Mode=""
          Description="Comma-separated coding agents to install on boot. Supported: claude, codex."
          Type="Variable" Display="always" Required="false" Mask="false">claude,codex</Config>

  <Config Name="GIT_USER_NAME" Target="GIT_USER_NAME" Default="" Mode=""
          Description="Seeds git user.name on the first boot."
          Type="Variable" Display="always" Required="false" Mask="false"></Config>

  <Config Name="GIT_USER_EMAIL" Target="GIT_USER_EMAIL" Default="" Mode=""
          Description="Seeds git user.email on the first boot."
          Type="Variable" Display="always" Required="false" Mask="false"></Config>

  <Config Name="GIT_TOKEN" Target="GIT_TOKEN" Default="" Mode=""
          Description="Access token for pushing. Seeds /config/git/credentials on the first boot."
          Type="Variable" Display="always" Required="false" Mask="true"></Config>

  <Config Name="GIT_TOKEN_HOST" Target="GIT_TOKEN_HOST" Default="github.com" Mode=""
          Description="Host that GIT_TOKEN authenticates to."
          Type="Variable" Display="advanced" Required="false" Mask="false">github.com</Config>

  <Config Name="GH_TOKEN" Target="GH_TOKEN" Default="" Mode=""
          Description="Token for the GitHub CLI. Optional when you sign in with gh auth login."
          Type="Variable" Display="always" Required="false" Mask="true"></Config>

  <Config Name="NPM_TOOLS" Target="NPM_TOOLS" Default="" Mode=""
          Description="npm packages to install into /config/tools."
          Type="Variable" Display="always" Required="false" Mask="false"></Config>

  <Config Name="PYTHON_TOOLS" Target="PYTHON_TOOLS" Default="" Mode=""
          Description="PyPI packages to install into /config/tools with uv, for example python-openstackclient."
          Type="Variable" Display="always" Required="false" Mask="false"></Config>

  <Config Name="BIN_TOOLS" Target="BIN_TOOLS" Default="" Mode=""
          Description="Single-binary tools as name=url pairs separated by spaces, for example kubectl=https://dl.k8s.io/release/v1.34.1/bin/linux/amd64/kubectl. Append #sha256=HEX to verify a download."
          Type="Variable" Display="always" Required="false" Mask="false"></Config>

  <Config Name="HOME_PERSIST" Target="HOME_PERSIST" Default=".config/ .kube/ .talos/" Mode=""
          Description="Home-directory paths kept in /config/home across recreates."
          Type="Variable" Display="advanced" Required="false" Mask="false">.config/ .kube/ .talos/</Config>

  <Config Name="APT_PACKAGES" Target="APT_PACKAGES" Default="" Mode=""
          Description="Debian packages to install on every boot. Keep the list short."
          Type="Variable" Display="advanced" Required="false" Mask="false"></Config>

  <Config Name="AGENT_UPDATE" Target="AGENT_UPDATE" Default="0" Mode=""
          Description="Set to 1 for one boot to reinstall every agent."
          Type="Variable" Display="advanced" Required="false" Mask="false">0</Config>

  <Config Name="TOOL_UPDATE" Target="TOOL_UPDATE" Default="0" Mode=""
          Description="Set to 1 for one boot to reinstall every tool."
          Type="Variable" Display="advanced" Required="false" Mask="false">0</Config>

  <Config Name="SSHD_ENABLED" Target="SSHD_ENABLED" Default="1" Mode=""
          Description="Set to 0 to boot without SSH."
          Type="Variable" Display="advanced" Required="false" Mask="false">1</Config>

  <Config Name="PUID" Target="PUID" Default="99" Mode=""
          Description="User ID that owns files. 99 is Unraid's nobody."
          Type="Variable" Display="advanced" Required="false" Mask="false">99</Config>

  <Config Name="PGID" Target="PGID" Default="100" Mode=""
          Description="Group ID that owns files. 100 is Unraid's users."
          Type="Variable" Display="advanced" Required="false" Mask="false">100</Config>

  <Config Name="UMASK" Target="UMASK" Default="022" Mode=""
          Description="File creation mask for Paseo, its agents, and SSH shells."
          Type="Variable" Display="advanced" Required="false" Mask="false">022</Config>

  <Config Name="TZ" Target="TZ" Default="UTC" Mode=""
          Description="Time zone, for example Europe/Oslo."
          Type="Variable" Display="advanced" Required="false" Mask="false">UTC</Config>
</Container>
```

Confirm the icon URL returns an image with `curl -fsSI https://paseo.sh/favicon.png`. If it does not, use the icon the paseo.sh home page links in its `<link rel="icon">`.

- [ ] **Step 3: Run the template check to verify it passes**

Run the `template` job's script locally from the repository root.
Expected: `template ok`.

- [ ] **Step 4: Write `.github/workflows/paseo-version-check.yml`**

```yaml
name: paseo-version-check

on:
  schedule:
    - cron: "23 5 * * *"
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - id: check
        name: Compare pinned Paseo and gh versions against upstream
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          semver='^[0-9]+\.[0-9]+\.[0-9]+$'

          paseo_latest="$(npm view @getpaseo/cli version)"
          paseo_pinned="$(grep -oP 'ARG PASEO_VERSION=\K.*' Dockerfile)"
          printf '%s' "$paseo_latest" | grep -qE "$semver" \
            || { echo "npm returned an unusable Paseo version: $paseo_latest" >&2; exit 1; }

          gh_latest="$(gh api repos/cli/cli/releases/latest --jq .tag_name)"
          gh_latest="${gh_latest#v}"
          gh_pinned="$(grep -oP 'ARG GH_VERSION=\K.*' Dockerfile)"
          printf '%s' "$gh_latest" | grep -qE "$semver" \
            || { echo "GitHub returned an unusable gh version: $gh_latest" >&2; exit 1; }

          echo "paseo pinned=${paseo_pinned} latest=${paseo_latest}"
          echo "gh pinned=${gh_pinned} latest=${gh_latest}"

          changes=""
          if [ "$paseo_pinned" != "$paseo_latest" ]; then
            sed -i "s|^ARG PASEO_VERSION=.*|ARG PASEO_VERSION=${paseo_latest}|" Dockerfile
            changes="${changes}paseo ${paseo_pinned} -> ${paseo_latest}; "
          fi

          if [ "$gh_pinned" != "$gh_latest" ]; then
            sums="$(curl -fsSL "https://github.com/cli/cli/releases/download/v${gh_latest}/gh_${gh_latest}_checksums.txt")"
            amd64="$(printf '%s\n' "$sums" | awk "/gh_${gh_latest}_linux_amd64.tar.gz\$/ {print \$1}")"
            arm64="$(printf '%s\n' "$sums" | awk "/gh_${gh_latest}_linux_arm64.tar.gz\$/ {print \$1}")"
            for v in "$amd64" "$arm64"; do
              [ "${#v}" -eq 64 ] || { echo "invalid gh checksum: $v" >&2; exit 1; }
            done
            sed -i \
              -e "s|^ARG GH_VERSION=.*|ARG GH_VERSION=${gh_latest}|" \
              -e "s|^ARG GH_SHA256_AMD64=.*|ARG GH_SHA256_AMD64=${amd64}|" \
              -e "s|^ARG GH_SHA256_ARM64=.*|ARG GH_SHA256_ARM64=${arm64}|" \
              Dockerfile
            changes="${changes}gh ${gh_pinned} -> ${gh_latest}; "
          fi

          if [ -z "$changes" ]; then
            echo "changed=false" >> "$GITHUB_OUTPUT"
          else
            {
              echo "changed=true"
              echo "summary=${changes%; }"
              echo "branch=chore/deps-paseo-${paseo_latest}-gh-${gh_latest}"
            } >> "$GITHUB_OUTPUT"
          fi

      - if: steps.check.outputs.changed == 'true'
        uses: peter-evans/create-pull-request@v7
        with:
          branch: ${{ steps.check.outputs.branch }}
          title: "chore: update ${{ steps.check.outputs.summary }}"
          commit-message: "chore: update ${{ steps.check.outputs.summary }}"
          body: |
            Upstream released new versions: ${{ steps.check.outputs.summary }}.

            CI runs the smoke suite against them. Merge once it is green, then
            tag a release to publish the image.
          delete-branch: true
```

- [ ] **Step 5: Lint the workflows**

Run: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "ci: add the Unraid template and daily version checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Documentation

Write each page in Google developer documentation style (Global Constraints). The spec holds the facts; each page below lists the sections it must contain and the exact commands and values to use.

**Files:**
- Create: `README.md`, `NOTICE`, `docs/configuration.md`, `docs/agents.md`, `docs/tools.md`, `docs/security.md`, `docs/unraid.md`
- Source to adapt: the same files in `~/code/herdr_container`

- [ ] **Step 1: Write `NOTICE`**

```text
paseo-container
Copyright 2026 jumpingmushroom

This product installs, but does not redistribute, the following software at
build time:

- Paseo (https://github.com/getpaseo/paseo), licensed under the Apache
  License, Version 2.0.
- GitHub CLI (https://github.com/cli/cli), licensed under the MIT License.
```

Confirm Paseo's license in its repository's `LICENSE` file before committing.

- [ ] **Step 2: Write `README.md`**

Sections, in order:
1. One-paragraph overview from the spec's Overview.
2. **Quick start**: a `docker run` example with `--hostname paseo`, `--stop-timeout 30`, `-p 6767:6767`, `-p 2223:22`, `-e SSH_PUBKEY=...`, `-e AGENTS=claude,codex`, `-v /mnt/user/appdata/paseo-container:/config`, `-v /mnt/user/code:/home/paseo/workspace`, and the image `ghcr.io/jumpingmushroom/paseo-container:latest`. A link to `docs/unraid.md`.
3. **Sign in to the agents**: the two `docker exec` commands from the banner.
4. **Pair your devices**: the `paseo daemon pair` command; scan the QR code in the phone app; paste the link in the desktop app under **Settings > Add host**; a warning that the link is a credential.
5. **Connect on the LAN**: **Settings > Add host > Direct connection**, host IP, port `6767`, the password from `PASEO_PASSWORD` or `/config/paseo/password`, **Use SSL** off; `PASEO_HOSTNAMES` for names.
6. **Add a project**: type `~/workspace/` in the path search; why **Browse** is absent for a remote host.
7. **Working with Syncthing**: the three points from the spec's "Working with Syncthing" section, including the `.stignore` line `.git/worktrees`.
8. **Ports and volumes** tables.
9. **Documentation** links and **Attribution**.

- [ ] **Step 3: Write `docs/configuration.md`**

Adapt herdr-container's page. Remove `HERDR_INTEGRATIONS`, `HERDR_GUI_PASSWORD`, and `HERDR_GUI_ENABLED`, and the "Pane defaults" section. Add entries, in the existing `Default`/`Effect`/`Example` format, for `PASEO_PASSWORD`, `PASEO_HOSTNAMES`, `GH_TOKEN`, `BIN_TOOLS`, and `HOME_PERSIST`, using the spec's Configuration table. Replace the `/config` tree with the spec's "Persistent layout". Document `/home/paseo/workspace` as the share mount and why. Set the hostname examples to `paseo`.

- [ ] **Step 4: Write `docs/agents.md`**

Adapt herdr-container's page. Remove the `agent_integration` row and "The herdr integration" section. Add a section "How Paseo runs the agents" with the spec's Agents paragraph: Paseo resolves `claude` and `codex` from `PATH`; sign in once with the two `docker exec` commands.

- [ ] **Step 5: Write `docs/tools.md`**

Adapt herdr-container's page. Add `gh` to the shipped table. Add sections "`BIN_TOOLS`, for single-binary tools" (format, checksum suffix, the kubectl and talosctl example, raw binaries only) and "Tool configuration persists with `HOME_PERSIST`". In "MCP servers", add that Paseo starts Claude Code with the `user`, `project`, and `local` setting sources, so `claude mcp add --scope user` servers and a project's `.mcp.json` load. Replace "herdr pane" with "agent" throughout.

- [ ] **Step 6: Write `docs/security.md`**

Adapt herdr-container's page. Replace the web UI sections with:
- **The pairing link is a credential**: relay admits a client with no password; anyone with the link has owner access; rotation by deleting `/config/paseo/daemon-keypair.json` and restarting.
- **The LAN password**: why the container always sets one; where it lives; that it does not encrypt traffic; do not forward port 6767.
- **Self-update is blocked**: `PASEO_DESKTOP_MANAGED=1` and root-owned `/usr/local`; update by pulling a new image tag.
Keep the SSH, outbound SSH identity, and git credential sections, renamed to `paseo`.

- [ ] **Step 7: Write `docs/unraid.md`**

Sections:
1. **Install the template** (Template URL, `SSH_PUBKEY`, paths `/mnt/user/appdata/paseo-container` and the share, **Apply**).
2. **First boot** (wait for the banner; sign in to the agents; pair devices).
3. **Keep agents running through maintenance**: exclude the container from CA Auto Update and from backup jobs that stop containers; back up `/config` live; exclude `paseo/worktrees` from appdata backups.
4. **Running beside herdr-container**: the spec's comparison table and the shared-checkout caution.
5. **Limit CPU and memory**: `--cpus` and `--memory` in **Extra Parameters**.
6. **Manual checklist**: pair a phone over the relay; start an agent in worktree mode; close every app mid-turn; reopen and confirm the turn finished; restart the container and confirm the agent resumes when prompted.
7. **Troubleshooting**: `403 Host not allowed` (set `PASEO_HOSTNAMES`); `401` on direct connection (password); empty folder suggestions (the share must be mounted at `/home/paseo/workspace`); the app shows **Update** (expected, see the security page).

- [ ] **Step 8: Check for leftovers**

Run: `grep -rniI 'herdr\|8787\|her-di-dr' README.md docs/*.md | grep -v 'docs/superpowers' | grep -vi 'beside herdr\|herdr-container'`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "docs: document paseo-container

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Publish and deploy on Unraid

This task changes things outside the repository. Confirm with the operator before each outward-facing step.

- [ ] **Step 1: Create the GitHub repository and push**

Ask the operator before running:

```bash
gh repo create jumpingmushroom/paseo-container --public --source ~/code/paseo-container --push
```

Expected: CI runs `lint`, `template`, and `smoke`, and all pass.

- [ ] **Step 2: Tag the first release**

Ask the operator before running:

```bash
git -C ~/code/paseo-container tag v0.1.0
git -C ~/code/paseo-container push origin v0.1.0
```

Expected: the `release` workflow publishes `ghcr.io/jumpingmushroom/paseo-container:0.1.0` and `:latest`. If the package is private, make it public in GitHub's package settings so Unraid can pull it without credentials.

- [ ] **Step 3: Operator installs on Unraid**

The operator follows `docs/unraid.md` with the template URL `https://raw.githubusercontent.com/jumpingmushroom/paseo-container/main/unraid/paseo-container.xml`, then runs the manual checklist in that page and reports each result.

---

## Self-review notes

- Spec coverage: image (Tasks 1, 4, 5), s6 services (1, 5), Paseo seeding (6), `06-paseo-prep` (5), `paseo-daemon` (5), persistent layout (1, 2, 5), agents (1), tools and MCP (2, 3, 4, 9), relay and pairing (6, 7), LAN direct and hostnames (6), outbound hosts (9), SSH (1), folder suggestions (1, 9), restarts and stop timeout (5, 8), Syncthing (9), beside herdr (1 ports, 9), configuration (2, 3, 6, 9), template (8), banner (7), CI (8), testing (1–7), documentation (9), verification items (5 Step 8; pairing in 6; directory search noise is in the manual checklist via "Add a project").
- Spec test item 13 ("a daemon self-update request fails") is implemented as two deterministic checks in Task 5: `PASEO_DESKTOP_MANAGED=1` in the supervisor's environment, and `/usr/local/lib/node_modules/@getpaseo` not writable by `paseo`. Sending a real self-update request needs a full Paseo protocol client, which the suite does not have.
