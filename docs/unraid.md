# Unraid install guide

This guide installs paseo-container on Unraid with the Community Applications
template. It uses generic defaults. Substitute your own appdata path, source
share, and host ports where they differ.

## Install the template

1. In Unraid, go to **Docker > Add Container**.
2. Set **Template URL** to
   `https://raw.githubusercontent.com/jumpingmushroom/paseo-container/main/unraid/paseo-container.xml`.
3. Set **SSH_PUBKEY** to the contents of your laptop's `~/.ssh/id_ed25519.pub`.
4. Map **Config** (`/config`) to `/mnt/user/appdata/paseo-container`.
5. Map **Workspace** (`/home/paseo/workspace`) to your own source share. The
   template's default, `/mnt/user/code`, is a placeholder, so change it to the
   share that holds your projects.
6. Click **Apply**.

The template sets **Extra Parameters** to `--hostname=paseo --stop-timeout=30`.
The hostname makes shell prompts read `paseo@paseo` instead of the container's
ID. The stop timeout gives the daemon time to save agent state when the
container stops. Keep both. To change them, switch to **Advanced View**.

The template maps host port `6767` to the daemon and host port `2223` to SSH.
If another container or service uses either port, change the host port on the
left side of the mapping. The container port stays the same.

## First boot

On the first boot, the container installs each agent named in **AGENTS** and
each tool named in **NPM_TOOLS**, **PYTHON_TOOLS**, and **BIN_TOOLS**, before
the Paseo daemon starts. SSH comes up independently and earlier. This can take
several minutes.

1. Wait for the boot banner. Go to **Docker > paseo-container > Logs**. The
   banner lists the Paseo version, the installed agents and tools, whether the
   relay is on, and where the LAN password lives. Later boots reuse what is in
   `/config` and start in seconds.
2. Sign in to the agents. In the Unraid terminal, run:

   ```bash
   docker exec -it -u paseo paseo-container claude
   docker exec -it -u paseo paseo-container codex login
   ```

3. Pair your devices. Run:

   ```bash
   docker exec -it -u paseo -e PASEO_HOME=/config/paseo paseo-container paseo daemon pair
   ```

   Scan the QR code in the Paseo phone app, or paste the link in the desktop
   app under **Settings > Add host**. The link is a credential. See
   [the pairing link is a credential](security.md#the-pairing-link-is-a-credential).

To connect on the LAN instead, see
[Connect on the LAN](../README.md#connect-on-the-lan) in the README.

## Keep agents running through maintenance

Anything that stops the container interrupts the turns that agents are
running. Paseo doesn't resume a turn that was running at shutdown. After a
restart, you resume the agent by prompting it again.

To avoid interrupting agents:

- Exclude paseo-container from **CA Auto Update**. Pull a newer image on your
  own schedule, when no agent is working.
- Exclude paseo-container from backup jobs that stop containers, such as the
  CA Appdata Backup plugin's stop-and-backup mode.
- Back up `/config` while the container runs. Paseo writes its state as JSON
  files through a temporary file and a rename, so a live copy is consistent.
- Exclude `paseo/worktrees` from appdata backups. It holds agent checkouts that
  you can regenerate from the repositories, and it can be large.

## Run beside herdr-container

You can run paseo-container beside
[herdr-container](https://github.com/jumpingmushroom/herdr-container) on the
same host and the same source share. They don't conflict if you keep these
values apart:

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
doesn't rotate on use. A separate token lets you tell the two containers'
pushes apart.

Agents from both containers can edit the same checkout at the same time and
overwrite each other's changes. Select **Worktree** when you start a Paseo
agent, so it works away from the main checkout.

## Limit CPU and memory

To limit how much CPU and memory the agents use, add `--cpus` and `--memory` to
**Extra Parameters** in **Advanced View**, for example:

```text
--hostname=paseo --stop-timeout=30 --cpus=4 --memory=8g
```

The template leaves both unset.

## Manual checklist

The smoke tests have no outbound access to the relay or the agent APIs, so run
this checklist by hand after a new release:

1. Pair a phone over the relay. Confirm the host appears in the app.
2. Start an agent in worktree mode and give it a task.
3. Close every Paseo app while the agent works on a turn.
4. Reopen an app and confirm the turn finished.
5. Restart the container, reopen the app, and confirm the agent resumes when
   you prompt it.
6. Back up `/config` while the container runs. Restore the backup into a fresh
   appdata directory, point a container at it, and confirm that the container
   boots and your paired devices and agent sign-ins still work.
7. In the desktop app, add the host with the **Remote SSH** host type, using
   `ssh://paseo@<tower>:2223`, where `<tower>` is your server's name or IP
   address. Confirm that the app connects.

## Update the image

A daily workflow, `paseo-version-check`, compares the pinned Paseo and `gh`
versions with the latest releases. When they differ, it opens or updates one
pull request on the branch `chore/deps-update`, then dispatches CI on that
branch. Merge the pull request when CI passes, then tag a release to publish a
new image. Then pull the new tag on Unraid.

If you maintain a fork, the workflow needs this repository setting: go to
**Settings > Actions > General > Workflow permissions** and select **Allow
GitHub Actions to create and approve pull requests**. Without it, the workflow
can't open the pull request.

## Troubleshooting

### SSH connection is refused with "Permission denied"

Check that **SSH_PUBKEY** holds a public key. An empty **SSH_PUBKEY** leaves
`/config/ssh/authorized_keys` empty, and the container logs a warning on boot.
Read it in **Docker > paseo-container > Logs**. Set **SSH_PUBKEY** to your
public key's contents, then restart the container.

### The container won't start, or Unraid reports a port conflict

Another container or service uses host port 6767 or 2223. Open **Docker >
paseo-container > Edit**, change the conflicting host port to a free port, and
click **Apply**. The container port on the right side of the mapping stays the
same.

### The app shows "403 Host not allowed"

The daemon rejects a request whose `Host` header is not `localhost` or an IP
address. You connected by name, such as `tower.local`. Set **PASEO_HOSTNAMES**
to that name, for example `tower.local`, and click **Apply**. Connecting by IP
address needs no setting.

### The app shows "401" on a direct connection

The password is wrong. Use the value of **PASEO_PASSWORD**. When you left it
empty, read the generated password:

```bash
docker exec paseo-container cat /config/paseo/password
```

### The folder suggestions are empty

Paseo lists folders only inside the daemon's home directory. Confirm that your
source share is mounted at `/home/paseo/workspace`, not at `/workspace`. Then
type `~/workspace/` in the path search.

### The app says the daemon is "managed by Paseo Desktop" and offers no working update

This is expected. The container sets `PASEO_DESKTOP_MANAGED=1`, which makes the
daemon refuse the app's self-update request, so the daemon appears as managed
by Paseo Desktop and the update never applies. The setting keeps the pinned
Paseo version in place. To update, pull a newer image tag. See
[self-update is blocked](security.md#self-update-is-blocked).

### The shell prompt shows a random string instead of `paseo`

That string is the container ID, which Docker uses as the hostname when you
create a container without `--hostname`. Open **Docker > paseo-container >
Edit**, switch to **Advanced View**, add `--hostname=paseo` to **Extra
Parameters**, and click **Apply**. Unraid recreates the container, and
`/config` and the share carry across untouched.

### Read the boot banner

Go to **Docker > paseo-container > Logs** to see the banner that every boot
prints. If you missed it, restart the container and reopen the log. The banner
prints after `05-tools`, the last install step, finishes.
