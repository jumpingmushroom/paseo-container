# Tools and MCP servers

An agent is only as useful as the commands it can run. This page covers what
the image ships, the ways to add more, and how MCP servers fit into a
container whose `/config` survives a recreate but whose filesystem does not.

## What the image ships

The baseline every agent can assume, with no configuration:

| Area | Commands |
| --- | --- |
| Source control | `git`, `git-lfs`, `gh` (GitHub CLI) |
| Search | `rg` (ripgrep), `fd`, `grep`, `find` |
| Transfer | `ssh`, `scp`, `sftp`, `rsync`, `curl`, `wget` |
| Archives | `tar`, `unzip`, `zip`, `gzip`, `bzip2`, `xz`, `zstd` |
| Data | `jq`, `sqlite3`, `python3`, `node`, `npm`, `npx` |
| Network | `ping`, `dig`, `nc` |
| Session | `tmux`, `nano`, `less`, `tree`, `patch` |
| Python packaging | `uv`, `uvx` |

`fd` is a symlink. Debian ships the binary as `fdfind`, because another
package owns the name, and agents write `fd`.

`gh` is pinned by version and checksum in the image. To sign in, run
`gh auth login` once in the container, or set `GH_TOKEN`. The credential
persists in `~/.config/gh` through [`HOME_PERSIST`](#tool-configuration-persists-with-home_persist).

Two things are deliberately absent. There is no compiler, because
`build-essential` is around 250 MB and most work in this container doesn't need
one. And `pip3 install` doesn't work, because Debian marks its Python
installation as externally managed (PEP 668). Use `uv` for Python, which is why
it ships.

Every agent inherits the daemon's `PATH`, which starts with
`/config/tools/bin` and `/config/agents/bin`, so a tool you add there is
available to every agent without further setup.

## Add tools

### `NPM_TOOLS` and `PYTHON_TOOLS`, for anything with a CLI

Reach for these first. Both take a list of package names separated by spaces
(commas work too), and both install into `/config/tools/bin`, which is on
`PATH` in every SSH shell and for the daemon and its agents:

```yaml
NPM_TOOLS: "prettier @redocly/cli"
PYTHON_TOOLS: "python-openstackclient ansible-core"
```

`05-tools` installs each one on boot and records it in
`/config/tools/.installed`, so a restart skips work it already did. Because the
install lands in `/config`, it survives recreating the container, which is what
an image update on Unraid does. To reinstall everything named in these
variables, set `TOOL_UPDATE=1` for one boot, then set it back to `0`.

A spec is anything the underlying installer accepts, so `ansible-core==2.17.*`
and `prettier@3` pin versions.

Python tools each get their own virtualenv under `/config/tools/uv`, built
against an interpreter that uv downloads into the same tree. That interpreter
takes around 110 MB in `/config` and arrives once, on the first boot that
installs a Python tool. Every later tool reuses it, and it keeps those
virtualenvs working after an image update ships a new Python version.

A tool that fails to install logs a warning and the container keeps booting,
as a failed agent install does.

### `BIN_TOOLS`, for single-binary tools

Some tools, such as `kubectl` and `talosctl`, ship as plain executables on
neither npm nor PyPI. `BIN_TOOLS` installs them. List them as space-separated
`name=url` pairs:

```text
BIN_TOOLS="kubectl=https://dl.k8s.io/release/v1.34.1/bin/linux/amd64/kubectl talosctl=https://github.com/siderolabs/talos/releases/download/v1.11.2/talosctl-linux-amd64"
```

For each pair, `05-tools` downloads the URL to `/config/tools/bin/<name>`,
marks it executable, and records the pair in `/config/tools/.installed`, so
later boots skip it. The URL names the version, so you pin each tool yourself.
`talosctl` needs this, because its version must match the cluster's Talos
version. `TOOL_UPDATE=1` reinstalls every pair.

To verify a download, end the URL with `#sha256=<hex>`:

```text
BIN_TOOLS="kubectl=https://dl.k8s.io/release/v1.34.1/bin/linux/amd64/kubectl#sha256=<64 hex digits>"
```

`05-tools` checks the file against that digest before it installs it. A
mismatch logs a warning and installs nothing. A failed download also logs a
warning, and the container keeps booting.

`BIN_TOOLS` installs raw binaries only, not archives. A tool that ships only as
an archive belongs in [your own image](#your-own-image-for-anything-heavy).

### `APT_PACKAGES`, for system packages

For anything that isn't a language package, such as a compiler, `gnupg`,
`ffmpeg`, or a database client:

```yaml
APT_PACKAGES: "build-essential gnupg"
```

Two caveats apply. It runs `apt-get install` on every boot, so a long list
slows every start. And apt installs into the container's own filesystem, not
`/config`, so a recreate loses the packages and the next boot reinstalls them.
It suits a handful of small packages. For a long list, build your own image.

### Your own image, for anything heavy

```dockerfile
FROM ghcr.io/jumpingmushroom/paseo-container:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential golang-go \
    && rm -rf /var/lib/apt/lists/*
```

Build it and point your container at the result. Everything else, including
`/config`, the agents, and the tools, behaves as before. Use this for a
toolchain you depend on daily, a private registry, or anything that takes
minutes to install.

## Tool configuration persists with `HOME_PERSIST`

`/home/paseo` isn't persisted, so a tool's configuration vanishes on a
recreate unless you link it into `/config`. `HOME_PERSIST` does that. It lists
paths relative to the home directory, separated by spaces. Before it installs
any agent, `04-agents` links each path from `/home/paseo` into `/config/home`.

A trailing `/` marks a directory. An entry without one marks a file:

```text
HOME_PERSIST=".config/ .kube/ .talos/ .aws/ .docker/ .netrc"
```

The default is `.config/ .kube/ .talos/`, which covers:

- `gh` credentials in `~/.config/gh`.
- The OpenStack client's `~/.config/openstack/clouds.yaml`.
- `~/.kube/config` for `kubectl`.
- `~/.talos/config` for `talosctl`.

To persist another tool's configuration, add its path to the variable, and
keep the defaults in the list if you still need them.

Mark every directory with a trailing slash. A directory without one is treated
as a file, and the tool can't create its contents.

The container ignores an entry, with a warning in the container log, when the
entry:

- Is an absolute path.
- Contains a `..` segment.
- Names the home directory itself.
- Overlaps the share. That is the share's mount point, `workspace`, or a path
  above or below it. Linking the share would hide or delete your repositories.

## Install from inside the container

You can install a tool from a shell, and it persists as long as it lands in
`/config`:

```bash
uv tool install python-openstackclient   # -> /config/tools/bin/openstack
npm install --global --prefix /config/tools prettier
```

The login profile exports five environment variables that point `uv` at
`/config`: `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, `UV_PYTHON_INSTALL_DIR`,
`UV_PYTHON_PREFERENCE=only-managed`, and `UV_CACHE_DIR`. The command above is
the same install that `PYTHON_TOOLS` performs. `only-managed` stops uv from
building a virtualenv against the image's own Python, which would break the next
time the image ships a new Python version. Override it in your own shell if you
want the system interpreter. The difference from the variable is that
`PYTHON_TOOLS` reproduces the install on a fresh `/config`, and a hand-run
command doesn't. Put anything you would miss into the variable.

Installing with `apt-get` from a shell needs root, which the `paseo` user
doesn't have. Use `APT_PACKAGES`.

## MCP servers

### Claude Code and Codex load their own servers

Paseo starts Claude Code with the `user`, `project`, and `local` setting
sources. Servers that you register with `claude mcp add --scope user` and a
project's `.mcp.json` therefore load in Paseo agents. Codex reads
`mcp_servers` from `~/.codex/config.toml`.

### They already persist

Claude Code keeps its MCP configuration in `~/.claude.json` and `~/.claude/`,
both of which are symlinks into `/config/agents/state`. A server that you
register with `claude mcp add --scope user` is still registered after a
container recreate. The same goes for Codex and `~/.codex`.

### Node servers work as they are

`npx` is in the image, so an MCP server that documents

```bash
claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp
```

works with no further setup. `npx -y` downloads the package into the home
directory's npm cache, which isn't in `/config`, so every recreate pays that
cost again on first use. To avoid it, name the server in `NPM_TOOLS`. The
package then installs once into `/config/tools/bin`, and the MCP entry invokes
the command directly instead of through `npx`.

### Python servers need `uvx`

```bash
claude mcp add --scope user fetch -- uvx mcp-server-fetch
```

`uvx` caches into `/config/tools/uv/cache`, so unlike `npx` it downloads once
across recreates.

### Remote servers fit this container best

An MCP server that runs as its own Docker container on your Unraid server and
speaks HTTP or SSE needs nothing installed here:

```bash
claude mcp add --scope user --transport sse gateway http://tower.lan:9000/sse
```

### Docker-based MCP servers

A server distributed as `docker run ...` needs the Docker CLI in this container
and the host's `/var/run/docker.sock` mounted into it. That socket is root on
your Unraid host: anything that can reach it can start a privileged container
that mounts your array. Handing it to a container whose purpose is running an
agent that executes code it writes is a large step down in security, and the
image doesn't do it or document a way to.

Run the server as its own container on the host and connect over HTTP or SSE,
as above. It gets its own Docker socket access, if it needs it, without
putting your host inside the agent's reach.

## Where things live

```text
/config/tools/
  bin/                 every installed tool's command, on PATH
  lib/node_modules/    npm packages from NPM_TOOLS
  uv/tools/            one virtualenv per PYTHON_TOOLS package
  uv/python/           the interpreter uv downloaded for them
  uv/cache/            uv's download cache, shared with uvx
  .installed           what 05-tools installed, so a restart can skip it
/config/home/          HOME_PERSIST targets
```

Delete `/config/tools` and the next boot rebuilds it from `NPM_TOOLS`,
`PYTHON_TOOLS`, and `BIN_TOOLS`. That is the fastest way out of a tool
installation that went wrong.
