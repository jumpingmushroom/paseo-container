# Agents

paseo-container ships no coding agents in its image. You name the ones you
want in the `AGENTS` variable (see [the configuration reference](configuration.md)),
and the `04-agents` oneshot installs each one on boot into `/config/agents`,
where it persists across container recreates.

The image ships two installers: `claude` for Claude Code, and `codex` for the
OpenAI Codex CLI.

An agent is a program the container installs and puts on `PATH`, and so is
everything in [tools and MCP servers](tools.md). The difference is what they
are for. An agent gets an entry here and a name in `AGENTS`, because the
container also has to persist its credentials. A tool is a command, and
belongs in `NPM_TOOLS`, `PYTHON_TOOLS`, or `BIN_TOOLS`.

## How Paseo runs the agents

Paseo resolves `claude` and `codex` from `PATH` and fails if it can't find
them. Claude Code runs through `@anthropic-ai/claude-agent-sdk` with
`pathToClaudeCodeExecutable` set to the `PATH` binary, and Codex runs as
`codex app-server`. The installers put both executables in
`/config/agents/bin`, which is on the daemon's `PATH`.

You sign in to each agent once. Your logins persist in `/config/agents/state`.
Run each CLI in the container:

```bash
docker exec -it -u paseo paseo-container claude
docker exec -it -u paseo paseo-container codex login
```

You can also sign in over SSH on host port `2223`.

## The installer contract

Each agent is one shell file at
`/usr/local/lib/paseo-container/agents/<name>.sh`. `04-agents` sources the
file into a subshell, so its function definitions can't leak into the next
agent's install, and calls these functions:

| Function | Contract |
| --- | --- |
| `agent_persist_paths` | Prints home-directory-relative paths, one per line, that hold the agent's credentials and settings. End a path with `/` to mark it a directory. `04-agents` links each one into `/config/agents/state` before it calls `agent_install`, so an installer that writes files during setup writes them straight into persistent storage. |
| `agent_installed` | Exits `0` when the agent is already present, and non-zero otherwise. `04-agents` calls this before installing, and skips a present agent unless `AGENT_UPDATE=1`. |
| `agent_install` | Installs the agent's executable into `/config/agents/bin`. A non-zero exit logs a warning. It doesn't stop the container from booting. |
| `agent_version` | Prints the installed version to standard output, for the boot banner. A non-zero exit is tolerated. |

`04-agents` runs `agent_persist_paths` and creates the resulting links before
it runs `agent_install`, in that order, on every boot, whether or not the agent
is already installed.

Mark every directory with a trailing slash. A missing file heals itself the
first time the agent writes it, because `open()` follows a dangling symlink and
creates what it points at, but `mkdir()` through a dangling symlink fails. A
directory left unmarked swallows every write the agent makes into it, and an
agent that keeps its credentials in a directory asks you to log in again on
every run.

`common.sh` provides one helper that installers can use:
`npm_agent_install <package>` runs `npm install --global` with
`--prefix /config/agents`, so the resulting executables land in
`/config/agents/bin` automatically.

When `AGENTS` names an agent with no matching file, `04-agents` logs a warning
that names the known agents and continues. A typo in `AGENTS` doesn't prevent
the container from booting.

## Agents do not update themselves

The image sets `DISABLE_AUTOUPDATER=1` so that agents don't try to update.
`AGENT_UPDATE=1` is how you update them, on the next boot.

This is a deliberate constraint. npm doesn't overwrite a package in place:
`npm install --global` renames the existing directory aside, installs the new
one, then removes what it renamed. An agent that updates itself is running, so
it holds its own executable open, and that final removal is an `rmdir`.
Unlinking an open file drops its directory entry at once on a normal
filesystem, and the `rmdir` succeeds. On FUSE it doesn't. The filesystem
renames the file to `.fuse_hiddenXXXX` inside that same directory, the `rmdir`
fails with `ENOTEMPTY`, and npm gives up after it moved the working install
aside. The agent's executable is gone, and the dangling symlink on `PATH` is
all that remains.

`/config` is whatever you mount, and on Unraid every user share is shfs, which
is FUSE. This case is common there, not exotic. The trap is that the first
self-update plants the hidden file and appears to succeed, and the second one
destroys the install.

A boot-time reinstall has none of this problem, because nothing holds an agent
executable open before the agents start. That is why updates belong to
`AGENT_UPDATE=1`. For the same reason, a manual
`npm install --global --prefix /config/agents <pkg>` is safe only while no
session of that agent is running.

As a second safeguard, `/usr/local` is root-owned, so an npm global install as
the `paseo` user fails with `EACCES`. The same reasoning applies to Paseo
itself. See [self-update is blocked](security.md#self-update-is-blocked).

## Worked example: `claude.sh`

```bash
#!/usr/bin/env bash
# Agent installer: Claude Code.
# Sourced by 04-agents; do not execute directly.

agent_persist_paths() {
    printf '%s\n' .claude/ .claude.json
}

agent_installed() {
    [ -x "${AGENT_PREFIX}/bin/claude" ]
}

agent_install() {
    npm_agent_install "@anthropic-ai/claude-code"
}

agent_version() {
    "${AGENT_PREFIX}/bin/claude" --version 2>/dev/null | head -n1
}
```

`agent_persist_paths` names `.claude/` and `.claude.json`, the two paths Claude
Code writes its credentials and settings to under the home directory.
`04-agents` links `/config/agents/state/.claude` to `~/.claude` and
`/config/agents/state/.claude.json` to `~/.claude.json` before it installs
anything, so a login you complete inside the container survives a recreate.
The trailing slash on `.claude/` makes `04-agents` create that directory.
Claude Code keeps its OAuth credentials in `~/.claude/.credentials.json`, and
without the directory every write there fails.

`agent_installed` checks for the executable that `npm_agent_install` produces.
`agent_install` delegates to the shared npm helper. `agent_version` reads the
installed binary's own `--version` output, and `2>/dev/null` tolerates a
failure.

## Wrap an npm shim that spawns a child

Some npm packages install a launcher that spawns the real program as a child
and waits for it. `@openai/codex` installs `bin/codex.js`, a Node shim that
spawns the natively compiled `codex`. Run that way, the agent is two processes,
and the shim leaves a stale helper directory behind in `~/.codex/tmp/arg0` on
each run. On FUSE, codex can't clean those directories up, and it prints
`failed to clean up stale arg0 temp dirs` on every run.

`codex.sh` replaces npm's shim with a wrapper that clears the stale
directories and then `exec`s the vendored native binary, so `codex` runs as one
process. `claude.sh` needs none of this, because `@anthropic-ai/claude-code`
ships a single native executable.

If a new installer goes through `npm_agent_install`, check what npm left in
`bin/`. If it is a shim, wrap it. Test for the wrapper in `agent_installed`,
not merely for an executable. An install made before the wrapper existed, or
one that a manual `npm install --global` has since overwritten with npm's shim,
then reports itself absent, and the next boot repairs it.

Version the string you test for, as `codex.sh` does with
`paseo-container codex wrapper v1`. A wrapper that an older edition of this
image wrote is still executable and still tagged, so an unversioned test calls
it installed and leaves it in place forever. Bumping the suffix makes
already-installed containers repair themselves on the next boot.

## Contributing a new installer

1. Create `rootfs/usr/local/lib/paseo-container/agents/<name>.sh`.
2. Define `agent_persist_paths`, `agent_installed`, `agent_install`, and
   `agent_version` in that file.
3. Add an assertion to `tests/smoke.sh` that boots the container with your
   agent in `AGENTS` and confirms it installs and runs as the `paseo` user.
4. Add `<name>` to the `AGENTS` description in `unraid/paseo-container.xml`
   and in [the configuration reference](configuration.md#agents).
5. Confirm that Paseo can run the agent as a provider. An installer only puts
   the program on `PATH`, and Paseo decides which providers it starts.

The core `04-agents` script needs no changes. Adding a file is enough, and its
name becomes a valid value for `AGENTS`.
