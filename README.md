# paseo-container

paseo-container packages the [Paseo](https://paseo.sh) daemon as a Docker image
for Unraid. The daemon runs Claude Code and Codex agents on your server. You
connect to it from the Paseo desktop app and the Paseo phone app, on the LAN or
from anywhere, and the agents keep running when every client disconnects. The
container also gives the agents `gh`, outbound SSH, and the command-line tools
you name, and it keeps their configuration across a container recreate. See
[tools and MCP servers](docs/tools.md).

## Quick start

To run the container with plain Docker, run:

```bash
docker run -d \
  --name paseo-container \
  --hostname paseo \
  --stop-timeout 30 \
  -p 6767:6767 \
  -p 2223:22 \
  -e SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQ... you@laptop" \
  -e AGENTS=claude,codex \
  -v /mnt/user/appdata/paseo-container:/config \
  -v /mnt/user/code:/home/paseo/workspace \
  ghcr.io/jumpingmushroom/paseo-container:latest
```

Replace `/mnt/user/code` with your own source share. Mount the share at
`/home/paseo/workspace`, not at `/workspace`, so the apps can suggest folders
from it. See [folder suggestions](docs/configuration.md#the-source-share).

To install on Unraid, follow the [Unraid install guide](docs/unraid.md).

The first boot installs the agents, which can take several minutes. Wait for
the boot banner in the container log before you continue.

## Sign in to the agents

After the first boot, sign in to each agent once:

```bash
docker exec -it -u paseo paseo-container claude
docker exec -it -u paseo paseo-container codex login
```

The logins persist in `/config`. This container keeps its own logins and does
not share them with other containers.

## Pair your devices

To pair a phone or the desktop app, run:

```bash
docker exec -it -u paseo -e PASEO_HOME=/config/paseo paseo-container paseo daemon pair
```

The command prints a QR code and a pairing link.

- On a phone, scan the QR code in the Paseo app.
- In the desktop app, go to **Settings > Add host** and paste the link.

Traffic between your device and the daemon travels through Paseo's relay,
`relay.paseo.sh`, and is encrypted end to end. You forward no ports.

> **Warning:** The pairing link is a credential. Anyone who has the link gets
> owner access to the daemon, with no password. Don't paste it into chats or
> tickets. To revoke every paired device, see
> [the pairing link is a credential](docs/security.md#the-pairing-link-is-a-credential).

## Connect on the LAN

If you can't use the relay, or you prefer a direct connection:

1. In the desktop app, go to **Settings > Add host > Direct connection**.
2. Enter the server's IP address and port `6767`.
3. Enter the password. It is the value of `PASEO_PASSWORD`, or the contents of
   `/config/paseo/password` when you leave the variable empty.
4. Leave **Use SSL** off.

To connect by name, such as `tower.local`, set `PASEO_HOSTNAMES` to that name.
Without it, the daemon answers `403 Host not allowed`. Never forward port 6767
from the internet. The password doesn't encrypt traffic. See
[the LAN password](docs/security.md#the-lan-password).

## Add a project

For a remote host, the apps offer a typed path search instead of the native
**Browse** dialog, because **Browse** works only for a daemon that runs on the
same computer as the app. To add a project, type `~/workspace/` in the path
search. The daemon lists the folders in your source share.

## Work with Syncthing

If Syncthing syncs your source share, follow these three points:

- Paseo keeps agent worktrees in `/config/paseo/worktrees`, outside the share,
  so Syncthing doesn't copy agent checkouts, build output, or `node_modules`.
- Select **Worktree** when you start an agent. An agent that edits the main
  checkout while you edit the same file on your desktop produces
  `.sync-conflict` files. Commits from a worktree land in the main
  repository's `.git`, so the branches reach your desktop through Syncthing.
  The apps remember the choice per device, so select **Worktree** once on each
  device.
- Add this line to the `.stignore` of each synced folder:

  ```text
  .git/worktrees
  ```

  Git records each worktree in that directory, with paths that exist only
  inside the container. Without the rule, `git worktree prune` on your desktop
  deletes the record, Syncthing deletes it on Unraid, and the agent's worktree
  breaks.

## Ports and volumes

| Port | Purpose |
| --- | --- |
| 6767 | The Paseo daemon: direct connections and the web UI |
| 22 | SSH, key-only, user `paseo` (host port `2223` in the examples) |

| Volume | Purpose |
| --- | --- |
| `/config` | Paseo state, SSH keys, installed agents and tools, git credentials |
| `/home/paseo/workspace` | Your source share. `/workspace` is a symlink to it. |

## Documentation

- [Configuration reference](docs/configuration.md): every environment
  variable, its default, and its effect.
- [Agents](docs/agents.md): how Paseo runs the agents, the installer
  contract, and how to add a new agent.
- [Tools and MCP servers](docs/tools.md): what the image ships, how to add
  more, and where MCP servers fit.
- [Unraid install guide](docs/unraid.md): installing the template, keeping
  agents running through maintenance, and troubleshooting.
- [Security model](docs/security.md): pairing links, the LAN password, SSH,
  and credentials.

## Development

The test harness in `compose.yaml` maps host port `6768` to the container's
`6767`, so `tests/smoke.sh` never talks to a Paseo daemon that already runs on
your machine on port `6767`.

## Publishing

The image publishes to `ghcr.io/jumpingmushroom/paseo-container`. A GHCR
package inherits the visibility of its repository, so make the package public
before anyone outside the repository's owners can pull it.

A daily workflow, `paseo-version-check`, compares the pinned Paseo and `gh`
versions with the latest releases. When they differ, it opens or updates one
pull request on the branch `chore/deps-update`, then dispatches CI on that
branch. Merge the pull request when CI passes, then tag a release. The
workflow needs this repository setting: go to **Settings > Actions > General >
Workflow permissions** and select **Allow GitHub Actions to create and approve
pull requests**.

## Attribution

The container image includes the following third-party software, each under
its own license:

- [Paseo](https://github.com/getpaseo/paseo), licensed under the Apache
  License, Version 2.0. The image carries its license at
  `/usr/share/doc/paseo/LICENSE`.
- [GitHub CLI](https://github.com/cli/cli), licensed under the MIT License.
  The image carries its license at `/usr/share/doc/gh/LICENSE`.

See [NOTICE](NOTICE) for the full attribution text.

## License

paseo-container is licensed under the Apache License, Version 2.0. See
[LICENSE](LICENSE) for the full text.
