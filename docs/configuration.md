# Configuration reference

You configure paseo-container through environment variables, because that is
what an Unraid template edits. This page documents every variable the
container reads, the two volumes you mount, and the one setting that has to be
a `docker run` flag rather than a variable.

## Variables

### `PASEO_PASSWORD`

- **Default:** none
- **Effect:** Sets the password for direct LAN connections. Paseo admits every
  connection as owner when no password is set, so the container always runs
  with one. When you leave this variable empty, `02-config-scaffold`
  generates a random password into `/config/paseo/password`, mode `0600`, on
  the first boot, and the daemon reads it from there. The password reaches
  the daemon as an environment variable, so other processes that run as
  `paseo` can read it from `/proc/<pid>/environ`. See
  [the LAN password](security.md#the-lan-password).
- **Example:** `correct-horse-battery-staple`

### `PASEO_HOSTNAMES`

- **Default:** none
- **Effect:** Extra `Host` header values the daemon accepts, comma-separated.
  Paseo rejects a request whose `Host` header is not `localhost` or an IP
  address with `403 Host not allowed`. Set this variable to connect by name.
- **Example:** `tower.local,tower.lan`

### `PUID`

- **Default:** `99`
- **Effect:** Sets the UID of the `paseo` user. The `01-user-setup` oneshot
  compares the user's current UID to `PUID` and runs `usermod` when they
  differ, then claims every file in `/config` and the home directory whose
  owner differs. The share mounted inside the home directory is excluded. `99` is
  Unraid's `nobody` account.
- **Example:** `1000`

### `PGID`

- **Default:** `100`
- **Effect:** Sets the GID of the `paseo` group. `01-user-setup` runs
  `groupmod` when the current GID differs from `PGID`, then chowns every file
  in `/config` whose owner or group differs, and the share's mount point, to
  `PUID:PGID`. `100` is Unraid's `users`
  group. If your source share is already group-owned by a different GID, set
  `PGID` to match it. Otherwise the container claims the mount point under its
  own group the first time it boots.
- **Example:** `1000`

### `UMASK`

- **Default:** `022`
- **Effect:** Sets the file creation mask for the Paseo daemon, and so for the
  agents it starts, and for SSH login shells. `01-user-setup` applies it and
  writes it to a runtime file that `paseo-daemon` reads back before it starts
  and that `/etc/profile.d/paseo-container.sh` reads back for every SSH login
  shell. The other oneshots, and any other process, keep the image's default
  umask.
- **Example:** `002`

### `TZ`

- **Default:** `UTC`
- **Effect:** Sets the container's time zone. `01-user-setup` symlinks
  `/etc/localtime` to the matching file under `/usr/share/zoneinfo` and writes
  the zone name to `/etc/timezone`, so both `TZ`-aware code and anything that
  reads `/etc/localtime` agree. An unrecognized zone name logs a warning and
  leaves `/etc/localtime` unchanged rather than stopping the container from
  booting.
- **Example:** `America/Los_Angeles`

### `SSH_PUBKEY`

- **Default:** none
- **Effect:** One or more SSH public keys, one per line. On every boot,
  `03-ssh-keys` merges each non-blank, non-comment line into
  `/config/ssh/authorized_keys`, skipping lines already present so you can
  restart the container without duplicating entries. When you leave this
  variable unset, the container logs a warning that no key grants access.
- **Example:** `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQ... you@laptop`

### `SSHD_ENABLED`

- **Default:** `1`
- **Effect:** Set to `0` to boot without SSH. The `sshd` service exits
  immediately and s6 does not restart it, so port 22 never opens.
- **Example:** `0`

### `AGENTS`

- **Default:** `claude` in the image, `claude,codex` in the Unraid template
- **Effect:** A comma-separated list of agent names for `04-agents` to
  install. Set it to an empty string to install no agents. See
  [the agents guide](agents.md) for the installer contract and the agents the
  image ships.
- **Example:** `claude,codex`

### `AGENT_UPDATE`

- **Default:** `0`
- **Effect:** Set to `1` to make `04-agents` reinstall every agent named in
  `AGENTS` on the next boot, even when it is already present. When you leave it
  at `0`, a later boot skips agents it already installed. Set it back to `0`
  after the boot that updates.
- **Example:** `1`

### `GIT_USER_NAME`

- **Default:** none
- **Effect:** Seeds `user.name` in `/config/git/gitconfig` the first time
  `02-config-scaffold` finds that file empty. It has no effect once the file
  holds content, so edit `/config/git/gitconfig` directly to change it later.
- **Example:** `Jane Doe`

### `GIT_USER_EMAIL`

- **Default:** none
- **Effect:** Seeds `user.email` in `/config/git/gitconfig` under the same
  first-run-only condition as `GIT_USER_NAME`.
- **Example:** `jane@example.com`

### `GIT_TOKEN`

- **Default:** none
- **Effect:** An access token for pushing. On the first boot that finds no
  `/config/git/credentials`, `02-config-scaffold` writes the token into that
  file in git's credential-store format, mode `0600`, and points
  `credential.helper` at it. It also rewrites `git@<host>:` remotes to HTTPS
  in the container's own gitconfig, so a repository you cloned over SSH uses
  the token without changing the remote for anyone else. Like
  `GIT_USER_NAME`, it seeds once: a later boot with a different value leaves
  the existing file alone, so rotate a token by editing
  `/config/git/credentials`. To keep the token out of the container's
  environment, write that file yourself. See
  [the outbound git credential](security.md#the-outbound-git-credential).
- **Example:** `github_pat_...`

### `GIT_TOKEN_HOST`

- **Default:** `github.com`
- **Effect:** The host `GIT_TOKEN` authenticates to, and the host whose SSH
  remotes the container rewrites to HTTPS. Set it for a self-hosted forge.
- **Example:** `git.example.com`

### `GH_TOKEN`

- **Default:** none
- **Effect:** A token for the GitHub CLI (`gh`). The daemon passes it through
  to the agents. Set it, or run `gh auth login` once in the container. The
  `gh auth login` credential persists in `~/.config/gh` through
  [`HOME_PERSIST`](#home_persist).
- **Example:** `github_pat_...`

### `NPM_TOOLS`

- **Default:** none
- **Effect:** Command-line tools to install from npm, separated by spaces or
  commas. `05-tools` installs each one into `/config/tools`, so its commands
  land in `/config/tools/bin`, which is on `PATH` for SSH shells and for the
  daemon and its agents, and survive a container recreate. `05-tools` records
  each installed spec in `/config/tools/.installed`, so later boots skip it. A
  spec is anything `npm install` accepts, so you can pin a version. A failed
  install logs a warning and the container keeps booting.
- **Example:** `prettier @redocly/cli`

### `PYTHON_TOOLS`

- **Default:** none
- **Effect:** The same as `NPM_TOOLS`, for PyPI, installed with
  `uv tool install`. Each package gets its own virtualenv under
  `/config/tools/uv`, built against an interpreter that uv downloads into the
  same tree rather than the image's own Python. The interpreter takes around
  110 MB in `/config`, arrives once on the first boot that installs a Python
  tool, and keeps those virtualenvs working across an image update. This is
  the supported way to install a Python CLI here, because `pip3 install`
  refuses to run: Debian marks its Python installation as externally managed
  (PEP 668).
- **Example:** `python-openstackclient ansible-core`

### `BIN_TOOLS`

- **Default:** none
- **Effect:** Single-binary tools as space-separated `name=url` pairs, for
  tools that ship on neither npm nor PyPI. `05-tools` downloads each URL to
  `/config/tools/bin/<name>` and marks it executable. A URL that ends in
  `#sha256=<hex>` is verified against that digest first. See
  [`BIN_TOOLS`, for single-binary tools](tools.md#bin_tools-for-single-binary-tools)
  for the format and its limits.
- **Example:** `kubectl=https://dl.k8s.io/release/v1.34.1/bin/linux/amd64/kubectl`

### `HOME_PERSIST`

- **Default:** `.config/ .kube/ .talos/`
- **Effect:** Home-directory paths that `04-agents` links into
  `/config/home`, separated by spaces, so tool configuration survives a
  container recreate. Write each entry relative to `/home/paseo`. A trailing
  `/` marks a directory, and an entry without one marks a file. The container
  ignores an entry, with a warning in the log, when it is an absolute path,
  contains a `..` segment, names the home directory itself, or overlaps the
  share (it is the share's mount point, or sits above or below it). It also
  ignores an entry that equals or sits inside an earlier one, such as
  `.config/gh/` after `.config/`, because the earlier link already persists
  it. The default covers `gh` credentials, the OpenStack `clouds.yaml`, `kubectl`'s
  config, and `talosctl`'s config. See
  [tool configuration persists with `HOME_PERSIST`](tools.md#tool-configuration-persists-with-home_persist).
- **Example:** `.config/ .kube/ .talos/ .aws/ .docker/`

### `TOOL_UPDATE`

- **Default:** `0`
- **Effect:** Set to `1` to make `05-tools` reinstall every tool named in
  `NPM_TOOLS`, `PYTHON_TOOLS`, and `BIN_TOOLS` on the next boot, ignoring
  `/config/tools/.installed`. It is the counterpart to `AGENT_UPDATE`, and it
  is how you restore a tool whose files you deleted by hand.
- **Example:** `1`

### `APT_PACKAGES`

- **Default:** none
- **Effect:** A space-separated list of Debian package names for `04-agents`
  to install with `apt-get` on every boot. A failed install logs a warning and
  the container keeps booting. Unlike the tool variables, this installs into
  the container's own filesystem rather than `/config`: the packages disappear
  on a recreate and reinstall on every boot, so keep the list short. See
  [tools and MCP servers](tools.md) for when to build your own image instead.
- **Example:** `build-essential gnupg`

## Volumes

### `/config`

Mount `/config` to a persistent path. On Unraid, use an appdata share such as
`/mnt/user/appdata/paseo-container`. It holds everything the container must
not lose on a recreate:

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
  ssh/hostkeys/                  this deployment's SSH host keys
  ssh/authorized_keys            merged SSH_PUBKEY entries
  ssh/id_ed25519                 outbound SSH identity, mode 0600
  ssh/id_ed25519.pub             the half you publish on other hosts
  ssh/config                     optional ssh client config
  ssh/known_hosts                hosts this container has accepted
  git/gitconfig                  seeded git identity
  git/credentials                outbound git token, mode 0600
  tools/bin/                     NPM_TOOLS, PYTHON_TOOLS, and BIN_TOOLS commands
  tools/uv/                      virtualenvs and interpreter for PYTHON_TOOLS
  home/                          HOME_PERSIST targets
  agents/bin/                    claude and codex executables
  agents/state/                  .claude/, .claude.json, .codex/
```

`/config` always belongs to the container, so on every boot `01-user-setup`
walks it and chowns to `PUID:PGID` each entry whose owner or group differs.
`/config` grows over time with agent state, tool caches, and Paseo's
worktrees, `node_modules` included, so the walk leaves correctly owned entries
alone instead of rewriting every one of them on each boot.

On the first boot that finds no `/config/paseo/config.json`,
`02-config-scaffold` writes one that turns the relay on. The container never
rewrites an existing file, so changes you make in the app or with
`paseo daemon config set` survive. The container writes the relay setting to
the file instead of setting `PASEO_RELAY_ENABLED`, because that variable locks
the setting and the app could then not turn the relay off.

### The source share

Mount your source share at `/home/paseo/workspace`. The container creates
`/workspace` as a symlink to it, so both paths work inside the container.

The mount point is inside the home directory for a reason. Paseo roots its
folder suggestions at the daemon's `$HOME` and rejects any path whose real path
falls outside it (Paseo issue #1787). A share mounted at `/workspace` gets no
suggestions, and a symlink inside `$HOME` doesn't help because Paseo resolves
it. With the share at `/home/paseo/workspace`, typing `~/workspace/` in the
apps lists your projects.

`01-user-setup` chowns only the mount point itself, not its contents.
Recursing into a large source tree would make boot time scale with the size of
that tree. Files already in the share keep whatever ownership they had before
the container touched them.

`/home/paseo` itself is not persisted. `04-agents` links each agent's persist
paths from `/home/paseo` into `/config/agents/state`, and each `HOME_PERSIST`
path into `/config/home`. At startup, Paseo writes orchestration skills into
`~/.agents/skills`, `~/.claude/skills`, and `~/.codex/skills`. The `.claude`
and `.codex` copies persist through the agent links, and Paseo regenerates
`~/.agents` on every start.

## Outbound SSH

`SSH_PUBKEY` and `/config/ssh/authorized_keys` control who can ssh into this
container. They have nothing to do with the other direction: an agent in the
container reaching a build host, a NAS, or a router. That direction needs a
private key in the container and its public half in `authorized_keys` on each
host you want to reach.

On the first boot that finds no `/config/ssh/id_ed25519`, `03-ssh-keys`
generates one, commented `paseo-container@<hostname>` so you can recognize it
in a target's `authorized_keys` a year from now. To print the public half, run:

```bash
docker exec paseo-container cat /config/ssh/id_ed25519.pub
```

Install it on every host you want the container to reach. The banner prints
the key's fingerprint on every boot, and `none` when there is no key.

To use a key someone else issued, put the pair in `/config/ssh/id_ed25519` and
`/config/ssh/id_ed25519.pub` and restart. The container never overwrites a key
that is already there, and never deletes one it can't read, because its public
half may be authorized on hosts this container can't reach. A bad key is
reported and left alone. The container reports a passphrase-protected key the
same way, because nothing in the container can answer a passphrase prompt at
boot. A key that an unattended agent can use has no passphrase.

`ssh` finds `~/.ssh/id_ed25519` by itself, so a host that needs nothing but a
hostname needs no further configuration. For hosts that want a different user
name, a non-standard port, or a jump host, write an ordinary ssh client config
to `/config/ssh/config`:

```text
Host build
    HostName build.lan
    User ci
    Port 2200
```

`03-ssh-keys` copies the key and the config into `~/.ssh` at mode `0600` on
every boot instead of symlinking them. `ssh` refuses an identity file that its
group or anyone else can read, and a config file that either can write, and
Unraid appdata shares are commonly mode 777. `/config` stays the source of
truth: delete `/config/ssh/config` and restart, and the copy goes with it.

`known_hosts` is the exception. The container symlinks it, because `ssh`
writes to it every time it accepts a new host, and a copy would lose those
answers on the next boot.

See [the security model](security.md#the-outbound-ssh-identity) for who can
use this key once it exists.

## Hostname

Docker names an unnamed container after its container ID, and every shell
prompt and terminal title inside the container then shows that ID. The
container can't fix this from the inside, because changing a running
container's hostname needs `CAP_SYS_ADMIN`, which Docker doesn't grant by
default. Set the name when you create the container:

- **`docker run`:** `--hostname paseo`
- **Compose:** `hostname: paseo` next to `container_name`
- **Unraid:** the template ships `--hostname=paseo` in **Extra Parameters**.
  To fix a container that predates that field, go to **Docker >
  paseo-container > Edit**, switch to **Advanced View**, add
  `--hostname=paseo` to **Extra Parameters**, and click **Apply**. Unraid
  recreates the container, and `/config` and the share carry across untouched.

Any name works. The examples use `paseo`. Pick something short, because you
read it in the prompt on every line.

## The web UI is always on

The daemon's run script sets `PASEO_WEB_UI_ENABLED=true`, which serves
Paseo's web UI on port 6767. Paseo treats a setting that comes from an
environment variable as locked, so you can't turn the web UI off from the app
or with `paseo daemon config set`. See
[the web UI cannot be turned off](security.md#the-web-ui-cannot-be-turned-off).

## Stop timeout

Set `--stop-timeout 30` (Compose: `stop_grace_period: 30s`). On `SIGTERM`, the
Paseo supervisor tells the worker to shut down. The worker closes each agent
with a 5-second timeout, saves state, and exits within 10 seconds, and the
supervisor kills the worker after 10 more seconds. The s6 service grace time
is 25 seconds (`S6_SERVICES_GRACETIME=25000`), so s6 finishes stopping the
services inside Docker's 30-second timeout. Docker's default of 10 seconds can
cut that short. The Unraid template sets the flag for you.
