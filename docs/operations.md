# Server operations

These commands run on the Git server, as root.

- [Health checks](#health-checks)
- [Backup](#backup)
- [SSH connection limits](#ssh-connection-limits)
- [Operational rules](#operational-rules)

Server host keys are covered in [Installation](install.md#server-host-keys),
and changing a repository's default branch in
[Access control](access-control.md#default-branch).

## Health checks

```bash
sudo ./mini-git-server.sh status
sudo ./mini-git-server.sh doctor
sudo ./mini-git-server.sh fsck
```

| Command | Purpose |
|---|---|
| `status` | Git, Gitolite and SSH status, including the effective sshd ports, `MaxStartups` and the hosting account's configured Git default branch |
| `doctor` | Configuration and permission checks; reports `[ OK ]`, `[WARN]` and `[FAIL]` lines |
| `fsck` | `git fsck` on hosted repositories; `--repo project-x` checks only one |

Run `status` as root: without root, it says so, and the fields that only
root can read (for example the sshd ports and the default branch) show
`(needs root)` instead of a guess.

## Backup

Create a Git-aware mirror backup:

```bash
sudo ./mini-git-server.sh backup
```

Default destination:

```text
/var/backups/gitolite/YYYYMMDD-HHMMSS/
```

The script uses `git clone --mirror file://...` for each repository and runs
`git fsck` on the backup. It also saves relevant Gitolite and sshd
configuration metadata, including the managed SSH-port drop-in.

The repositories are owned by the hosting account, and Git refuses to open a
repository owned by another user ("detected dubious ownership"). The backup
therefore reads each repository through `git upload-pack` running as the
hosting account. Root only writes and checks the new mirror, which is owned
by root.

> [!IMPORTANT]
> Keep a versioned/offline or otherwise independent copy on another system
> for disaster recovery.

## SSH connection limits

By default sshd starts dropping new connections at random once 10 of them
are waiting to log in (`MaxStartups 10:30:100`). If many agents fetch at the
same moment and some fail with "Connection closed", raise the limit:

```bash
sudo ./mini-git-server.sh ssh-limits --max-startups 50:30:200
```

`ssh-limits` writes `/etc/ssh/sshd_config.d/99-gitolite-limits.conf`,
checks it with sshd, and reloads sshd. If sshd rejects the value, or
another `MaxStartups` line overrides it, the previous setting is
restored.

- `ssh-limits` without options shows the current value.
- `ssh-limits --reset` goes back to sshd's default.
- `install` accepts the same value with `--max-startups`, and `status` shows
  the effective value.

## Operational rules

Do not manually edit these during normal administration:

```text
/home/git/.ssh/authorized_keys
/home/git/repositories/*
/home/git/.gitolite/*
```

Use the commands instead: `gitolite-admin` (through `apply`) for keys and
access rules, and `repo-set-default` to change a repository's default
branch rather than editing the bare repository's `HEAD` file. The only
exception is [recovering a lost agent branch](agents.md#recovering-a-rewritten-or-deleted-branch).

Do not run CI jobs or arbitrary repository code on the Git server itself.
Keep the Git server as the repository/control plane and use separate
CI/agent execution hosts.
