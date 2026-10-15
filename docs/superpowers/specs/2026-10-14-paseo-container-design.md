# paseo-container design

Date: 2026-10-14
Status: approved in brainstorming, awaiting written-spec review

## Overview

`paseo-container` packages the [Paseo](https://paseo.sh) daemon as a Docker
image for Unraid. The daemon runs Claude Code and Codex agents on the server.
You connect to it from the Paseo desktop app and the Paseo phone app, from the
LAN or from anywhere, and the agents keep running when every client
disconnects.

The image reuses the skeleton of
[herdr-container](https://github.com/jumpingmushroom/herdr-container): Debian
trixie, s6-overlay, `PUID`/`PGID`, the `AGENTS` installer contract, the
persistent tool volume, SSH in and out, the git credential, the Unraid
template, and the CI pipeline. A single `paseo-daemon` service replaces
herdr's `herdr-server` and `herdr-gui` services, because Paseo serves its own
web UI.

The repository is `jumpingmushroom/paseo-container`. The image is
`ghcr.io/jumpingmushroom/paseo-container`.

herdr-container keeps running beside it. Retiring herdr later means stopping
that container; this design needs no migration step.

## Goals

- Run the Paseo daemon as a supervised service on Unraid.
- Reach the daemon from the desktop app and the phone app over Paseo's
  end-to-end encrypted relay, with no forwarded ports.
- Reach the daemon on the LAN with a direct connection as a fallback.
- Keep agents running when clients disconnect.
- Install Claude Code and Codex through the existing `AGENTS` mechanism.
- Give agents `gh`, outbound SSH, single-binary tools such as `kubectl` and
  `talosctl`, Python and npm CLIs such as the OpenStack client, and MCP
  servers, with their configuration surviving a container recreate.
- Let the folder picker in the apps suggest folders from the source share.
- Keep the Paseo version pinned and reproducible, with a daily automated bump
  PR.
- Run side by side with herdr-container on the same host and the same source
  share.

## Non-goals

- Resuming an agent turn that a container restart interrupted. Paseo does not
  support this. You resume the agent by prompting it again.
- Public internet exposure of port 6767, TLS termination, or a reverse proxy.
- A self-hosted relay. The design uses `relay.paseo.sh`.
- Sharing agent logins with herdr-container.
- Docker socket access for agents.
- Automated tests that run real agent turns or relay round trips.

## Decisions

| Topic | Decision | Reason |
| --- | --- | --- |
| Repository | New sibling repo, seeded from the herdr-container skeleton | Independent image, release cadence, and purpose |
| Base image | Own Debian trixie image, not a child of `ghcr.io/getpaseo/paseo` | Keeps s6, `PUID`/`PGID`, the tool volume, and SSH conventions |
| Paseo install | `npm install -g @getpaseo/cli@<PASEO_VERSION>` at build time into root-owned `/usr/local` | Reproducible; the daemon user cannot overwrite it |
| Paseo updates | Daily CI job opens a version-bump PR; merging and tagging publishes a new image | Paseo releases every few days, and the apps update themselves |
| Remote access | Relay on by default; LAN direct with a password as fallback | No open ports, end-to-end encryption |
| Worktrees | Default `worktrees.root`, which is `/config/paseo/worktrees` | Keeps agent checkouts out of the Syncthing-synced share |
| Source share mount | `/home/paseo/workspace`, with `/workspace` as a symlink | Works around Paseo issue #1787 (see [Folder suggestions](#folder-suggestions)) |
| Appdata path | `/mnt/user/appdata/paseo-container` | Operator requirement |
| Logins | Fresh `claude` and `codex` logins in this container | Copied OAuth refresh tokens can invalidate each other |
| GitHub CLI | `gh` baked into the image, pinned by version and sha256 | Nearly every agent workflow uses it |
| Single-binary tools | New `BIN_TOOLS` variable, installed into `/config/tools/bin` | `kubectl` and `talosctl` ship on neither npm nor PyPI |
| Tool configuration | New `HOME_PERSIST` variable links home-directory paths into `/config/home` | `gh` auth, kubeconfig, talosconfig, and `clouds.yaml` otherwise vanish on recreate |

## Architecture

### Image

The Dockerfile keeps herdr-container's `runtime` stage and drops the
`herdr-fetch` and `gui-build` stages.

- Debian trixie slim, with the same baseline package set as herdr-container.
- s6-overlay, Node.js 24, and uv, each pinned by version and sha256.
- `ARG PASEO_VERSION=0.11.2`. A `RUN npm install -g "@getpaseo/cli@${PASEO_VERSION}"`
  layer installs Paseo into `/usr/local`. npm verifies package integrity, so
  the Dockerfile carries no separate checksum for Paseo.
- `gh`, from GitHub's release tarball, pinned by `ARG GH_VERSION` and a
  sha256 per architecture, installed into `/usr/local/bin`.
- `ENV DISABLE_AUTOUPDATER=1`, kept from herdr-container, stops Claude Code
  from updating itself.
- A `paseo` user and group replace `herdr`, with home directory `/home/paseo`.
- `/home/paseo/workspace` exists as the mount point, and `/workspace` is a
  symlink to it.
- `EXPOSE 22 6767`.

### s6 services

| Service | Type | Behavior |
| --- | --- | --- |
| `01-user-setup` | oneshot | Unchanged: `PUID` (default `99`), `PGID` (default `100`), `UMASK`, and `TZ`. Chowns `/config` recursively and the workspace mount point only. |
| `02-config-scaffold` | oneshot | Keeps git identity and `GIT_TOKEN` seeding. Drops herdr's `config.toml` seeding. Adds Paseo seeding, described below. |
| `03-ssh-keys` | oneshot | Unchanged: host keys, `authorized_keys`, outbound identity, and `known_hosts`. |
| `04-agents` | oneshot | Unchanged installer contract and the `claude` and `codex` installers. Drops `agent_integration` and the `HERDR_INTEGRATIONS` variable. Adds the `HOME_PERSIST` links, described below. |
| `05-tools` | oneshot | Keeps `NPM_TOOLS`, `PYTHON_TOOLS`, and `APT_PACKAGES`. Adds `BIN_TOOLS`, described below. |
| `06-paseo-prep` | oneshot | Deletes `/config/paseo/paseo.pid`. Depends on `05-tools`. |
| `paseo-daemon` | longrun | Runs Paseo's supervisor as the `paseo` user. Depends on `06-paseo-prep`. |
| `sshd` | longrun | Unchanged, user `paseo`. |

#### Paseo seeding in `02-config-scaffold`

On the first boot that finds no `/config/paseo/config.json`, the oneshot
writes:

```json
{
  "version": 1,
  "daemon": {
    "relay": { "enabled": true }
  }
}
```

The oneshot never rewrites an existing file, so changes you make in the app or
with `paseo daemon config set` survive. The design writes the relay setting to
the file rather than setting `PASEO_RELAY_ENABLED`, because that environment
variable locks the setting and the app then cannot turn the relay off.

When `PASEO_PASSWORD` is empty and `/config/paseo/password` does not exist, the
oneshot generates a random password into that file with mode `0600`, owned by
`paseo`.

#### `HOME_PERSIST` in `04-agents`

`HOME_PERSIST` lists home-directory-relative paths, separated by spaces. A path
ending in `/` is a directory. Before it installs any agent, `04-agents` links
each path from `/home/paseo` into `/config/home`, with the same linking code
that persists each agent's `agent_persist_paths`. The default is
`.config/ .kube/ .talos/`, which covers:

- `gh` credentials in `~/.config/gh`.
- The OpenStack client's `~/.config/openstack/clouds.yaml`.
- `~/.kube/config` for `kubectl`.
- `~/.talos/config` for `talosctl`.

To persist another tool's configuration, such as `.aws/` or `.docker/`, add
its path to the variable.

#### `BIN_TOOLS` in `05-tools`

`BIN_TOOLS` lists single-binary tools as `name=url` pairs, separated by spaces.
For each pair, `05-tools` downloads the URL to `/config/tools/bin/<name>`, marks
it executable, and records the pair in `/config/tools/.installed`, so later
boots skip it. A URL that ends in `#sha256=<hex>` is verified against that
digest before installation, and a mismatch logs a warning and installs
nothing. `TOOL_UPDATE=1` reinstalls every pair. A failed download logs a
warning and the container keeps booting.

The URL names the version, so you pin each tool yourself. `talosctl` needs
this, because its version must match the cluster's Talos version:

```text
BIN_TOOLS="kubectl=https://dl.k8s.io/release/v1.34.1/bin/linux/amd64/kubectl talosctl=https://github.com/siderolabs/talos/releases/download/v1.11.2/talosctl-linux-amd64"
```

`BIN_TOOLS` installs raw binaries only, not archives. A tool that ships only
as an archive belongs in your own image built from this one.

#### `06-paseo-prep`

Paseo's supervisor treats `paseo.pid` as live when the host boot ID matches and
the recorded PID exists. A container restart keeps the host boot ID, and a new
container reuses small PIDs, so a lock left by an unclean stop can block the
next start. The daemon then exits as "already running" and s6 restarts it in a
loop. Deleting the file on every boot is safe, because no daemon runs before
this oneshot.

#### `paseo-daemon`

The run script sets the environment, then execs Paseo's supervisor directly
through `s6-setuidgid paseo`:

```text
node /usr/local/lib/node_modules/@getpaseo/cli/node_modules/@getpaseo/server/dist/scripts/supervisor-entrypoint.js
```

The implementation plan confirms the exact path from the installed package.
The official Paseo image starts the daemon the same way.

The script does not use `paseo daemon run`, because that command deletes
`PASEO_DESKTOP_MANAGED` from the environment. With `PASEO_DESKTOP_MANAGED=1`,
the daemon refuses the self-update request that the app's **Update** button
sends. Without it, the update runs `npm install -g @getpaseo/cli@latest`,
which ignores the pin. Root-owned `/usr/local` is the second safeguard: npm
fails with `EACCES` as the `paseo` user.

Environment for the supervisor:

| Variable | Value |
| --- | --- |
| `HOME` | `/home/paseo` |
| `PATH` | `/config/tools/bin:/config/agents/bin:/usr/local/bin:/usr/bin:/bin` |
| `PASEO_HOME` | `/config/paseo` |
| `PASEO_LISTEN` | `0.0.0.0:6767` |
| `PASEO_PASSWORD` | The operator's value, or the contents of `/config/paseo/password` |
| `PASEO_HOSTNAMES` | Passed through when set |
| `PASEO_WEB_UI_ENABLED` | `true` |
| `PASEO_DESKTOP_MANAGED` | `1` |
| `CODEX_HOME` | `/home/paseo/.codex` |
| `XDG_CONFIG_HOME` | `/home/paseo/.config` |
| `TERM` | `xterm-256color` when s6 sets `dumb` |
| `SHELL` | `/bin/bash` |
| `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, `UV_PYTHON_INSTALL_DIR`, `UV_PYTHON_PREFERENCE`, `UV_CACHE_DIR` | The values `tool_env` prints, as for interactive shells |

The script does not set `NODE_ENV`, because Paseo issue #4614 reports that an
inherited `NODE_ENV=production` breaks worktree setup.

The script does not set `CLAUDE_CONFIG_DIR`. With it set, Claude Code reads
its user config from `$CLAUDE_CONFIG_DIR/.claude.json` instead of
`~/.claude.json`, and agents would never see an MCP server added from a shell.

The script starts in `/home/paseo/workspace` and applies the `UMASK` that
`01-user-setup` recorded.

### Persistent layout

```text
/config/
  paseo/config.json              Paseo configuration, seeded once
  paseo/daemon-keypair.json      relay identity; pairing links depend on it
  paseo/password                 generated LAN password, mode 0600
  paseo/agents/                  agent records and provider session handles
  paseo/worktrees/               git worktrees that agents work in
  paseo/schedules/  projects/    Paseo state
  paseo/push-tokens.json         phone push registrations
  paseo/daemon.log               rotating daemon log
  ssh/  git/  tools/             unchanged from herdr-container
  tools/bin/                     also holds BIN_TOOLS binaries
  home/                          HOME_PERSIST targets: .config/, .kube/, .talos/
  agents/bin/                    claude and codex executables
  agents/state/                  .claude/, .claude.json, .codex/
/home/paseo/workspace            the source share
/workspace -> /home/paseo/workspace
```

`/home/paseo` itself is not persisted. `04-agents` links each agent's persist
paths from `/home/paseo` into `/config/agents/state`, as in herdr-container,
and each `HOME_PERSIST` path into `/config/home`. At
startup, Paseo writes orchestration skills into `~/.agents/skills`,
`~/.claude/skills`, and `~/.codex/skills`. The `.claude` and `.codex` copies
persist through the agent links; Paseo regenerates `~/.agents` on every start.

Paseo stores its state as JSON files that it writes to a temporary file and
renames. It uses no SQLite, `flock`, or `mmap`, so the shfs FUSE layer under
`/mnt/user` does not need special handling. Git and `npm install` in worktrees
run slower on shfs than on a direct pool path; the operator accepts this.

### Agents

Paseo resolves `claude` and `codex` from `PATH` and fails if it cannot find
them. Claude Code runs through `@anthropic-ai/claude-agent-sdk` with
`pathToClaudeCodeExecutable` set to the `PATH` binary, and Codex runs as
`codex app-server`. The `04-agents` installers already put both executables in
`/config/agents/bin`, so they need no change beyond removing
`agent_integration`.

To sign in after the first boot, run each CLI once:

```bash
docker exec -it -u paseo paseo-container claude
docker exec -it -u paseo paseo-container codex login
```

You can also sign in over SSH on port 2223.

### Tools and MCP servers

- **Outbound SSH.** Agents use the container's own key in
  `/config/ssh/id_ed25519`, with host aliases in `/config/ssh/config`, as in
  herdr-container.
- **GitHub CLI.** To sign in, run `gh auth login` once in the container, or set
  `GH_TOKEN`. The credential persists in `~/.config/gh`.
- **Python and npm CLIs.** `PYTHON_TOOLS="python-openstackclient"` and
  `NPM_TOOLS` work as in herdr-container.
- **Single-binary tools.** `BIN_TOOLS` installs `kubectl`, `talosctl`, and
  similar tools.
- **MCP servers.** Paseo starts Claude Code with the `user`, `project`, and
  `local` setting sources, so servers registered with
  `claude mcp add --scope user` and a project's `.mcp.json` load in Paseo
  agents. Codex reads `mcp_servers` from `~/.codex/config.toml`. `npx` and
  `uvx` ship in the image. The container gets no Docker socket; run
  Docker-based MCP servers as their own containers and connect over HTTP or
  SSE.

## Connectivity and security

### Relay

The seeded `config.json` turns the relay on. The daemon connects outbound to
`relay.paseo.sh:443`, and clients meet it there. Traffic between client and
daemon is encrypted end to end with the keypair in
`/config/paseo/daemon-keypair.json`, and the relay sees only metadata.

To pair a device, run:

```bash
docker exec -it -u paseo -e PASEO_HOME=/config/paseo paseo-container paseo daemon pair
```

The command prints a QR code for the phone and a pairing link for the desktop
app. The boot banner prints this command, never the link.

Treat the pairing link as a password. Over the relay, Paseo admits a client
that presents no password, and rejects only a wrong one, so possession of the
link grants owner access. To revoke every paired device, delete
`/config/paseo/daemon-keypair.json` and restart the container. Each device then
needs to pair again.

### LAN direct

The daemon listens on `0.0.0.0:6767`. Paseo admits every connection as owner
when no password is set, so the container always runs with one: the operator's
`PASEO_PASSWORD`, or the generated `/config/paseo/password`.

To add the host in the desktop app, go to **Settings > Add host > Direct
connection**, and enter the server IP, port `6767`, and the password, with
**Use SSL** off.

Paseo rejects requests whose `Host` header is not `localhost` or an IP address
with `403 Host not allowed`. To connect by name, such as `tower.local`, set
`PASEO_HOSTNAMES`.

Do not forward port 6767 from the internet. The password does not encrypt
traffic.

### Outbound hosts

The daemon needs outbound access to:

- `relay.paseo.sh:443`, for the relay.
- `exp.host`, for phone push notifications. The daemon posts to Expo's push
  service directly, so push works for a relay-only daemon.
- The Anthropic and OpenAI APIs, for the agents.
- Your git remotes.

### SSH

SSH is unchanged from herdr-container: key-only, `AllowUsers paseo`, host keys
persisted in `/config/ssh/hostkeys`. You use it to sign in to the agents and to
inspect the container. The desktop app's **Remote SSH** host type also works
through it.

## Folder suggestions

The desktop app offers **Browse**, a native folder dialog, only for the daemon
it runs locally. For a remote daemon, the desktop and phone apps offer a typed
path search that the daemon answers from its own filesystem.

Paseo roots that search at the daemon's `$HOME` and rejects any path whose real
path falls outside it (issue #1787). A share mounted at `/workspace` therefore
gets no suggestions, and a symlink inside `$HOME` does not help because the
check resolves it. Mounting the share at `/home/paseo/workspace` puts it inside
`$HOME`, so typing `~/workspace/` lists your projects. If Paseo fixes #1787,
the layout keeps working.

## Persistence and restarts

- **Client disconnects.** The daemon owns the agent processes, and clients only
  subscribe. Agents keep running with every client disconnected.
- **Container stop.** On `SIGTERM`, Paseo's supervisor tells the worker to shut
  down. The worker closes agents with a 5-second timeout each, saves state, and
  exits within 10 seconds; the supervisor kills the worker after 10 more
  seconds. The Unraid template sets `--stop-timeout=30`, and the s6 service
  grace time matches it.
- **After a restart.** Agent records and provider sessions survive in `/config`.
  Paseo does not resume a turn that was running at shutdown. You resume the
  agent by prompting it again.

`docs/unraid.md` tells you to exclude the container from automatic updates and
from backup jobs that stop containers, because either one interrupts running
turns.

## Working with Syncthing

Syncthing syncs the source share across three servers, and you edit code in it
from your desktop. The design accounts for that in three ways:

- Worktrees live in `/config`, outside the synced share. Syncthing does not copy
  agent checkouts, build output, or `node_modules`.
- The README recommends worktree mode for agents. An agent that edits the main
  checkout while you edit the same file on your desktop produces
  `.sync-conflict` files. Commits from a worktree land in the main repository's
  `.git`, so the branches reach your desktop through Syncthing. The apps
  remember the isolation choice per device, so you select **Worktree** once on
  each device.
- The README tells you to add `.git/worktrees` to each synced folder's
  `.stignore`. Git records each worktree in that directory, with paths that
  exist only inside the container. Without the ignore rule, `git worktree prune`
  on your desktop deletes the record, Syncthing deletes it on Unraid, and the
  agent's worktree breaks.

When you archive a workspace, Paseo removes its worktree and runs
`git worktree prune`. Paseo keeps the branch.

## Running beside herdr-container

| | herdr-container | paseo-container |
| --- | --- | --- |
| Appdata | `/mnt/user/appdata/herdr-container` | `/mnt/user/appdata/paseo-container` |
| Source share | `/workspace` | `/home/paseo/workspace` |
| SSH host port | 2222 | 2223 |
| Web port | 8787 | 6767 |
| Hostname | `herdr` | `paseo` |
| Agent logins | its own | its own |
| Outbound SSH key | its own | its own |

You can reuse herdr-container's `GIT_TOKEN`, because a personal access token
does not rotate on use. A separate token lets you tell the two containers'
pushes apart.

Agents from both containers can edit the same checkout at the same time and
overwrite each other's changes. Worktree mode keeps Paseo agents off the main
checkout.

To limit how much CPU and memory the agents in this container use, set
`--cpus` and `--memory` in the template's **Extra Parameters**. The template
leaves them unset.

## Configuration

The container reads every herdr-container variable except `HERDR_INTEGRATIONS`,
`HERDR_GUI_PASSWORD`, and `HERDR_GUI_ENABLED`, and adds:

| Variable | Default | Effect |
| --- | --- | --- |
| `PASEO_PASSWORD` | empty | Password for direct connections. When empty, the container generates one into `/config/paseo/password`. |
| `PASEO_HOSTNAMES` | empty | Extra `Host` header values the daemon accepts, comma-separated. |
| `BIN_TOOLS` | empty | Single-binary tools as `name=url` pairs, installed into `/config/tools/bin`. |
| `HOME_PERSIST` | `.config/ .kube/ .talos/` | Home-directory paths linked into `/config/home`. |
| `GH_TOKEN` | empty | Token for `gh`, passed through to agents. Optional when you sign in with `gh auth login`. |

`AGENTS` defaults to `claude,codex` in the Unraid template.

The password reaches the supervisor as an environment variable, so other
processes running as `paseo` can read it from `/proc/<pid>/environ`. This
matches how herdr-container handled `HERDR_GUI_PASSWORD`.

## Unraid template

`unraid/paseo-container.xml`:

- **Repository:** `ghcr.io/jumpingmushroom/paseo-container:latest`
- **Ports:** container `6767` to host `6767`; container `22` to host `2223`.
- **Paths:** `/config` to `/mnt/user/appdata/paseo-container`;
  `/home/paseo/workspace` to the source share.
- **Variables:** `AGENTS`, `PASEO_PASSWORD` (masked), `PASEO_HOSTNAMES`,
  `SSH_PUBKEY`, `GIT_USER_NAME`, `GIT_USER_EMAIL`, `GIT_TOKEN` (masked),
  `GIT_TOKEN_HOST`, `GH_TOKEN` (masked), `NPM_TOOLS`, `PYTHON_TOOLS`,
  `BIN_TOOLS`, `HOME_PERSIST`, `APT_PACKAGES`,
  `AGENT_UPDATE`, `TOOL_UPDATE`, `PUID`, `PGID`, `UMASK`, and `TZ`.
- **Extra Parameters:** `--hostname=paseo --stop-timeout=30`.
- **WebUI:** `http://[IP]:[PORT:6767]/`.

## Boot banner

The banner at the end of the boot sequence prints:

- The Paseo, Claude Code, and Codex versions.
- Whether the relay is on.
- Where the LAN password lives, never its value.
- The pairing command.
- The outbound SSH key fingerprint, as in herdr-container.

## CI and release

- **`ci.yml`:** hadolint, shellcheck, an image build, and `tests/smoke.sh`.
- **`release.yml`:** on a `vX.Y.Z` tag, builds amd64 and arm64 and publishes
  `:X.Y.Z` and `:latest` to GHCR.
- **`paseo-version-check.yml`:** runs daily and on demand. It reads the latest
  stable version with `npm view @getpaseo/cli version`, rejects anything that
  is not `X.Y.Z`, compares it with `ARG PASEO_VERSION`, and when they differ
  opens a PR that bumps the argument. Paseo's client-server protocol only adds
  optional fields and gates new features on capability flags, so a daemon a few
  days behind the apps keeps working. The same job checks the latest `gh`
  release and, when it differs from `ARG GH_VERSION`, bumps the version and
  both sha256 arguments from the release's checksums file.

## Testing

`tests/smoke.sh`, adapted from herdr-container, builds the image, starts it
with a test `/config`, and asserts:

1. `GET /api/health` on port 6767 returns `200`.
2. A request without the password returns `401`, and one with
   `Authorization: Bearer <password>` returns `200`.
3. With `PASEO_PASSWORD` empty, the container generates `/config/paseo/password`
   with mode `0600` and the daemon accepts it.
4. The first boot seeds `config.json` with the relay on, and a second boot
   leaves an edited `config.json` unchanged.
5. A planted stale `paseo.pid` does not prevent the daemon from starting.
6. `claude --version` and `codex --version` succeed as the `paseo` user.
7. `paseo daemon pair --json` returns a pairing URL.
8. `/workspace` is a symlink to `/home/paseo/workspace`, and the mounted share
   is visible there.
9. `gh --version` succeeds as the `paseo` user.
10. A `BIN_TOOLS` pair served from a local test HTTP server installs into
    `/config/tools/bin`, a wrong `#sha256=` installs nothing, and a second boot
    skips the installed pair.
11. A file written to `~/.kube/config` survives recreating the container
    against the same `/config`.
12. The existing SSH login, `PUID`/`PGID`, and tool-install assertions pass.
13. A daemon self-update request fails, and the installed Paseo version is
    unchanged.

The test run has no outbound access to the relay or agent APIs. A manual
checklist in `docs/unraid.md` covers pairing a phone, running an agent turn,
disconnecting every client mid-turn, and confirming the turn finishes.

## Documentation

- `README.md`: quick start, pairing, the Syncthing note, and attribution.
- `docs/configuration.md`: every variable and volume.
- `docs/agents.md`: the installer contract, without the herdr integration.
- `docs/tools.md`: carried over, plus `gh`, `BIN_TOOLS`, `HOME_PERSIST`, and
  how Paseo agents load MCP servers.
- `docs/security.md`: pairing links as credentials, keypair rotation, the LAN
  password, the no-port-forward rule, and the outbound SSH key and git token.
- `docs/unraid.md`: install, sign-in, pairing, auto-update and backup
  exclusions, running beside herdr-container, and the manual checklist.

## Items the implementation plan verifies

- The exact path of `supervisor-entrypoint.js` under the global npm install.
- That `PASEO_DESKTOP_MANAGED=1` changes nothing besides self-update behavior.
- That `paseo daemon pair` run through `docker exec` reads the running daemon's
  keypair from `PASEO_HOME`.
- That the daemon's directory search does not descend into dot-directories
  under `/home/paseo`, so suggestions stay focused on `~/workspace`.
