# Installation

**English** | [繁體中文](zh-TW/install.md)

This page covers the first-time setup in detail. For the short version, see
the [Quick start](../README.md#quick-start).

- [1. Generate a dedicated admin key](#1-generate-a-dedicated-admin-key)
- [2. Install the server](#2-install-the-server)
- [3. Configure the admin workstation](#3-configure-the-admin-workstation)
- [Server host keys](#server-host-keys)

Next steps: [prepare `gitolite-admin`](administration.md#initialize-script-managed-acl-fragments),
then [add users and repositories](access-control.md).

## 1. Generate a dedicated admin key

On the administrator workstation, preferably with a FIDO2 security key, so
that every use of the admin key needs a physical touch:

```bash
ssh-keygen -t ed25519-sk -f ~/.ssh/gitolite-admin -C gitolite-admin
```

Without a security key, use a normal key with a passphrase:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/gitolite-admin -C gitolite-admin
```

Use a dedicated key rather than reusing an unrelated server-login key. The
admin key can change every access rule, so it should belong to its own
Gitolite identity (for example `arthur-admin`) that is used only for
`gitolite-admin`. Day-to-day work uses a separate identity (for example
`arthur`). See [Identities and keys](identities.md).

## 2. Install the server

Copy `mini-git-server.sh` and the public key to a fresh Debian 13 server.

Example using SSH port `2222` and `trunk` as the Git default branch for
newly created repositories:

```bash
sudo ./mini-git-server.sh install \
  --admin-key ./gitolite-admin.pub \
  --admin-name arthur-admin \
  --ssh-port 2222 \
  --default-branch trunk
```

Defaults:

| Setting | Default |
|---|---|
| Hosting Unix user (`--git-user`) | `git` |
| SSH port (`--ssh-port`) | `22` |
| Repositories | `/home/git/repositories` |
| Git default branch (`--default-branch`) | unchanged |
| sshd `MaxStartups` (`--max-startups`) | sshd's default; see [SSH connection limits](operations.md#ssh-connection-limits) |

The installer:

1. installs `openssh-server`, `git`, `gitolite3`, and `ca-certificates` from Debian;
2. creates the dedicated `git` hosting account if necessary;
3. locks its password;
4. optionally sets `init.defaultBranch` for the hosting account;
5. initializes Gitolite with the supplied admin key;
6. writes an sshd port drop-in at `/etc/ssh/sshd_config.d/00-gitolite-port.conf`;
7. adds an SSH `Match User git` hardening drop-in, which also accepts the
   `GIT_PROTOCOL` variable so Git can use protocol v2;
8. validates the SSH configuration before reloading SSH;
9. prints the SSH host key fingerprints and `known_hosts` lines.

> [!IMPORTANT]
> The script does not modify nftables/iptables, a cloud firewall, router
> ACLs, or VPN policy. If a non-default SSH port is used, make sure that port
> is reachable **before ending the current administrative session**.

Notes:

- `--ssh-port` configures sshd; it is not informational only. If another
  active `Port` directive already exists elsewhere in the sshd
  configuration, the script warns that sshd may listen on more than one
  port. The installer is intended primarily for a fresh Debian host.
- `--default-branch` only affects repositories created after installation.
  The `gitolite-admin` repository always uses the `master` branch, because
  Gitolite 3.6.12 (the Debian 13 package) only applies pushes to `master` of
  `gitolite-admin`. The installer pins this branch during `gitolite setup`
  and stops if the admin repository ends up on any other branch. See also
  [Default branch versus protected branch](access-control.md#default-branch-versus-protected-branch).
- Running `install` again on an installed server is refused before anything
  is changed.

## 3. Configure the admin workstation

Use one SSH host alias per identity. Here `internal-git-admin` uses the
admin key and is only used for `gitolite-admin`, and `internal-git` uses the
daily key (added later with [`user-add`](access-control.md#users-and-keys)):

```sshconfig
Host internal-git-admin
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/gitolite-admin
    IdentitiesOnly yes

Host internal-git
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Before the first connection, add the `known_hosts` lines that `install`
printed (or see [Server host keys](#server-host-keys)) to
`~/.ssh/known_hosts`. Then SSH does not have to ask whether to trust an
unknown host key.

Verify access:

```bash
ssh internal-git-admin info
```

Clone the admin repository:

```bash
git clone internal-git-admin:gitolite-admin
```

Or without an SSH config alias:

```bash
./mini-git-server.sh admin-clone \
  --host git.example.internal \
  --port 2222 \
  --identity ~/.ssh/gitolite-admin
```

## Server host keys

```bash
sudo ./mini-git-server.sh host-keys --host git.example.internal
```

This prints the fingerprint of every SSH host key and a `known_hosts` line
for each. The port is read from sshd; pass `--port` to override it. Copy the
lines to admin workstations and agent hosts over a channel you trust.
