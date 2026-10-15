# Security model

Read this before you expose any port on this container beyond your LAN.

## What this container hands out

A Paseo client that reaches the daemon, SSH access, or a pairing link gives you
owner access: agents that run commands as the `paseo` user, with write access
to the source share and to every credential the installed agents stored in
`/config`. Every Paseo client is owner. The daemon has no read-only role.

Don't forward SSH or port 6767 from the internet. Remote access goes through
Paseo's relay, which needs no open ports, or through a VPN such as
[Tailscale](https://tailscale.com). This container doesn't terminate TLS.

## The pairing link is a credential

To pair a device, you run `paseo daemon pair`, which prints a QR code and a
pairing link. Over the relay, Paseo admits a client that presents no password,
and rejects only a wrong one. Possession of the link therefore grants owner
access.

- Treat the link as a password. Don't paste it into chats, tickets, or
  screenshots.
- The boot banner prints the pairing command, never the link.
- The relay sees only metadata. Traffic between client and daemon is encrypted
  end to end with the keypair in `/config/paseo/daemon-keypair.json`.

To revoke every paired device, delete `/config/paseo/daemon-keypair.json` and
restart the container. The daemon generates a new keypair, the old links stop
working, and each device needs to pair again.

## The LAN password

The daemon listens on `0.0.0.0:6767`. Paseo admits every connection as owner
when no password is set, so the container always runs with one. The run script
refuses to start the daemon when it finds none. The password comes from
`PASEO_PASSWORD`, or from `/config/paseo/password`, which `02-config-scaffold`
generates on the first boot, mode `0600`, owned by `paseo`. The boot banner
names the source and never prints the value.

The password does not encrypt traffic. A direct connection on port 6767 is
plain HTTP and WebSocket, and anyone on the network path can read it. Use the
direct connection on a LAN you trust, and use the relay for everything else.
Never forward port 6767 from the internet.

The password reaches the daemon as an environment variable, so other processes
that run as `paseo` can read it from `/proc/<pid>/environ`. See the next
section for what that means for agents.

## Agents inherit the daemon's environment

Agents are child processes of the daemon, so they inherit its environment. That
includes `PASEO_PASSWORD` and `GIT_TOKEN`, when you set them, and any other
variable you pass to the container, such as `GH_TOKEN`.

The container accepts this on purpose:

- Every Paseo client is owner anyway. An agent that learns `PASEO_PASSWORD`
  gains nothing a connected client doesn't already have.
- The git token is the agents' push credential by design. Scope it as
  [described below](#the-outbound-git-credential).

If you don't want a secret in the agents' environment, leave the variable
empty. For the git token, write `/config/git/credentials` yourself. For the
LAN password, leave `PASEO_PASSWORD` empty and let the container generate the
file. Even then the daemon, and so its agents, receive the password in the
environment, because that is how the daemon reads it.

## The web UI cannot be turned off

The daemon's run script sets `PASEO_WEB_UI_ENABLED=true`. Paseo locks any
setting that an environment variable sets, so the app can't turn the web UI
off. The daemon serves the web UI on port 6767, so everything
[the LAN password](#the-lan-password) section says about that port applies to
it: it is plain HTTP, and it belongs on a LAN you trust.

## Self-update is blocked

The Paseo app shows an **Update** button for the daemon. Its request would run
`npm install -g @getpaseo/cli@latest`, which ignores the version this image
pins. Two safeguards stop it:

- The run script starts the daemon with `PASEO_DESKTOP_MANAGED=1`, and the
  daemon refuses the self-update request when that variable is set. The script
  starts Paseo's supervisor directly, because `paseo daemon run` removes the
  variable.
- `/usr/local` is root-owned, so npm fails with `EACCES` when the `paseo` user
  tries a global install.

To update Paseo, pull a newer image tag. A daily workflow opens a pull request
that bumps the pinned version, and merging it and tagging a release publishes
the new image.

## SSH

`rootfs/etc/ssh/sshd_config.d/paseo.conf` sets:

- `PasswordAuthentication no` and `KbdInteractiveAuthentication no`. Only a key
  in `authorized_keys` gets you in.
- `PermitEmptyPasswords no`.
- `PermitRootLogin no` and `AllowUsers paseo`. Only the `paseo` account can
  authenticate, and never as root.

You add keys with the `SSH_PUBKEY` variable. See the
[configuration reference](configuration.md#ssh_pubkey).

The desktop app's **Remote SSH** host type also works through this port.

### Host keys

The image ships no SSH host keys. The Dockerfile removes the ones Debian
generates when it installs `openssh-server`, so every image build starts
identical. The first time a container boots against a given `/config` volume,
the `03-ssh-keys` oneshot generates a unique ed25519 and RSA host key pair into
`/config/ssh/hostkeys` and reuses them on every later boot. Your deployment
gets its own host identity, and your laptop's `known_hosts` entry stays valid
across container recreates.

`03-ssh-keys` copies these keys into `/etc/ssh` with root-only permissions
instead of pointing `sshd` at `/config`. sshd's `StrictModes` setting refuses a
host key on a path that its group or anyone else can write, and Unraid appdata
shares are commonly mode 777. `/config` remains the source of truth, and
`/etc/ssh` holds the copy that sshd trusts.

## Process privilege

The setup oneshots (`01-user-setup` through `06-paseo-prep`) run as root,
because adjusting the `paseo` user's UID and GID and fixing ownership of
`/config` and the share's mount point requires it. After they finish,
`paseo-daemon` execs through `s6-setuidgid paseo`, so the daemon and its agents
never run as root.

`sshd` is the exception. The daemon itself runs as root, because binding port
22 and managing per-connection privilege separation both require it. This
doesn't widen your exposure: `AllowUsers paseo` means only the `paseo` account
can authenticate, and every session that sshd hands out runs as `paseo`.

## The outbound SSH identity

`authorized_keys` controls who gets into this container.
`/config/ssh/id_ed25519` is the other direction: the key an agent presents when
it connects out. See the [configuration reference](configuration.md#outbound-ssh)
for how to set one up.

Apply the same reasoning as for the git credential below. The `paseo` user owns
the key, every agent runs as that user, and those agents execute code they
wrote themselves. Anything with a shell or a Paseo client in this container can
use the key for as long as it exists. The question is not whether it can be read
but what it opens:

- Give it an account on the target host that can do the work and nothing more.
  A container that needs to run a build doesn't need root on the build host.
- Don't copy your laptop's private key in here. A key generated in this
  container can be revoked on the targets without touching anything else you
  use that key for.
- Constrain it on the target where the target supports it. An `authorized_keys`
  line takes `command=`, `restrict`, and `from=`, and a key that can run only
  one command is a much smaller thing to hand an agent than a shell.

A key generated here has no passphrase, which lets an unattended agent use it
and is also why the preceding points matter. The container writes the private
half mode `0600` in `/config` and copies it into `~/.ssh` at the same mode on
every boot.

### Revoke the SSH identity

Remove the public key from `authorized_keys` on every host you installed it on,
then delete `/config/ssh/id_ed25519*` and restart. The removal on the targets
is what revokes access. Deleting the file only stops this container from
offering the key, and the next boot generates a replacement.

## The outbound git credential

`GIT_TOKEN` and `/config/git/credentials` control what the container can reach
out and write to. They exist so an agent can push the work it has done.

Treat the token as readable by everything in the container. The `paseo` user
owns it, every agent runs as that user, and those agents execute code they
wrote themselves, so the question is not whether the token can be read but what
it can do once it is. Scope it accordingly:

- Use a fine-grained token limited to the repositories you want written to, not
  a classic token with `repo` across your whole account.
- Grant the narrowest permissions that let the work happen. A push needs
  Contents read/write. Add Actions read only if you want the agent to see why
  CI failed.
- Don't reuse a token that also has access to anything else you care about.

The file is mode `0600`, and the container runs `chmod` on it every boot,
because a `/config` restored from a backup can arrive world-readable.

### Keep the token out of the environment

`GIT_TOKEN` is convenient, because an Unraid template can edit it. But the
daemon passes the variable on to every agent, and any process that runs as
`paseo` can read it from the daemon's `/proc/<pid>/environ`. PID 1 runs as
root, so the `paseo` user can't read `/proc/1/environ`, but that protects
nothing: each agent already holds the token in its own environment. The
variable also sits in your template, where you may not expect it. To avoid that, leave the variable empty and write the file
yourself:

```bash
umask 077
printf 'https://x-access-token:%s@github.com\n' 'YOUR_TOKEN' \
    > /config/git/credentials
```

Then restart the container so `02-config-scaffold` wires gitconfig to it.

### Revoke the git token

Delete `/config/git/credentials` and revoke the token at your forge, in that
order. Deleting the file stops this container from using the token. Revoking is
what stops anything that already copied it.
