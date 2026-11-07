# mini-git-server

**English** | [繁體中文](README.zh-TW.md)

A single Bash script that turns a fresh Debian 13 host into a private Git
server for people **and AI agents**, using only OpenSSH, Git and Gitolite 3
from Debian.

- **Small and auditable.** One script, Debian packages only. No web forge,
  database, Redis, container runtime, package registry or CI system.
- **Agents are restricted on the server.** Each agent has its own SSH
  identity and, by default, can push only to its own `agent/<name>/*`
  branches. Only the owner can push tags.
- **Nothing changes until you say so.** Admin commands stage changes in
  Gitolite's standard `gitolite-admin` repository; `apply` reviews, commits
  and pushes them.
- **No assumptions about `main`.** Protected branches are listed explicitly,
  and the default branch (`HEAD`) is separate from access-control policy.

> [!NOTE]
> Upgrading from an earlier version? See [Upgrading](docs/upgrade/README.md).

## Contents

- [Quick start](#quick-start)
- [How access works](#how-access-works)
- [Commands](#commands)
- [Documentation](#documentation)
- [Development](#development)
- [License](#license)

## Quick start

You need a fresh Debian 13 server and a workstation with OpenSSH and Git.

### 1. Install the server remotely

`remote-install` runs on the workstation and does the first three steps of
the [manual installation](docs/install.md): it creates the admin key,
installs a fresh Debian 13 server, and writes `known_hosts` and SSH aliases
on this machine.

```bash
./mini-git-server.sh remote-install \
  --host git.example.internal \
  --admin-name arthur-admin \
  --ssh-port 2222 \
  --default-branch trunk
```

The workstation must already be able to SSH to the server. The default login
is `root` on port 22, using whatever keys SSH would normally try. Pass
`--login-user`, `--login-port` and `--login-identity` when that login is
different. A user other than root must be able to run `sudo -n` (passwordless
sudo).

| Option | Default | Purpose |
|---|---|---|
| `--host` | required | Name or IPv4 address clients use for the server |
| `--admin-name` | required | Gitolite admin identity, for example `arthur-admin` |
| `--login-user` | `root` | Unix account used to SSH in and run `install` |
| `--login-port` | `22` | SSH port of that login |
| `--login-identity` | SSH's own choice | Private key for that login |
| `--admin-key` | `~/.ssh/gitolite-admin` | Admin private key to create or reuse |
| `--key-type` | `ed25519-sk` | `ed25519-sk` or `ed25519`; used only when creating the key |
| `--no-passphrase` | prompt | Create the key with an empty passphrase |
| `--git-user` | `git` | Hosting account, passed through to `install` |
| `--ssh-port` | `22` | Port sshd should listen on after installation |
| `--default-branch` | unchanged | Git default branch for new repositories |
| `--admin-alias` | `internal-git-admin` | SSH alias for the admin key |
| `--daily-alias` | `internal-git` | SSH alias for the daily key |
| `--daily-identity` | `~/.ssh/id_ed25519` | Daily private key the daily alias points at |
| `--ssh-config` | `~/.ssh/config` | SSH config file to update |
| `--known-hosts` | `~/.ssh/known_hosts` | `known_hosts` file to update |

`remote-install --help` lists every option, including `--max-startups` and
`--no-ssh-hardening`.

The first connection pins the server host key
(`StrictHostKeyChecking=accept-new`). When `--ssh-port` differs from
`--login-port`, sshd is reloaded onto `--ssh-port`. The command does not
change the firewall. After install it connects once as the hosting user; if
that port does not answer, the workstation files are already written and the
command stops so you can open the port and retry `ssh <admin-alias> info`.

On success the script is left at `/usr/local/sbin/mini-git-server.sh` on the
server. An existing admin key is reused. An existing SSH alias is left as it
is. `remote-install` does not clone `gitolite-admin` or add users; that is
the next step below.

**2. Clone and prepare `gitolite-admin`:**

```bash
git clone internal-git-admin:gitolite-admin
cd gitolite-admin
/path/to/mini-git-server.sh admin-init
```

**3. Add users, agents and a repository.** These commands only stage
changes:

```bash
/path/to/mini-git-server.sh user-add --name arthur     --key ~/.ssh/id_ed25519.pub
/path/to/mini-git-server.sh user-add --name agent-impl --key ~/keys/agent-impl.pub

/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --agents agent-impl \
  --protected-branch trunk
```

**4. Review and deploy:**

```bash
/path/to/mini-git-server.sh apply -m "Add project-x"
```

`agent-impl` can now push to `agent/agent-impl/*` in `project-x`, and you
review its work with `agent-branches`. See
[Working with AI agents](docs/agents.md).

## How access works

`repo-set` gives every identity exactly one role per repository:

| Role | Option | Access |
|---|---|---|
| Owner | `--owner` | Everything (`RW+`); the only identity that can push tags |
| Writer | `--writers` | Push branches, except protected branches, tags and `agent/*` |
| Agent | `--agents` | Push only to `agent/<own-name>/*`, without force-push unless `--agent-rewind`; read everything else |
| Reader | `--readers` | Read only |

> [!WARNING]
> - `repo-set` is **declarative**: options you omit are removed. Use
>   `repo-show` to get the current command, edit it, and run it again.
> - Gitolite identifies users **only by their SSH key**. An agent that can
>   use your keys is you. Keep keys apart as described in
>   [Identities and keys](docs/identities.md).

## Commands

Run `mini-git-server.sh help` for the full list, and
`mini-git-server.sh <command> --help` for the options of a command.

| Where | Command | Purpose |
|---|---|---|
| Server (root) | `install` | Install OpenSSH, Git and Gitolite, then initialize Gitolite |
| | `status`, `doctor`, `fsck` | Show status, check configuration, check repositories |
| | `backup` | Git-aware mirror backup of all repositories |
| | `repo-set-default` | Set a repository's default branch (`HEAD`) |
| | `host-keys` | Print SSH host key fingerprints and `known_hosts` lines |
| | `ssh-limits` | Show or set sshd's `MaxStartups` |
| Admin workstation | `remote-install` | Create the admin key, install a fresh server, and write SSH config |
| Admin workstation (in `gitolite-admin`) | `admin-clone`, `admin-init` | Clone `gitolite-admin`; enable script-managed ACL fragments |
| | `user-add`, `user-remove`, `user-list` | Manage SSH keys and identities |
| | `repo-set`, `repo-show`, `repo-list` | Set and inspect repository ACLs (`repo-add` is an old alias of `repo-set`) |
| | `group-set`, `group-remove`, `group-list` | Manage groups such as `@agents` |
| | `sync`, `apply` | Update from the server; review, commit and push staged changes |
| Project clone | `agent-branches` | List agent branches, ahead/behind the base branch |
| Any machine that can read the repository | `share` | Serve a branch or tag at a temporary random URL for a one-off deploy |
| Anywhere | `version`, `help` | Show the version or the help |

## Documentation

| Guide | Contents |
|---|---|
| [Installation](docs/install.md) | Manual install: admin key, `install`, workstation SSH setup, host keys |
| [Administration workflow](docs/administration.md) | `admin-init`, `apply`, `sync`, several admin machines, repairing the admin branch |
| [Access control](docs/access-control.md) | Users and keys, `repo-set` and the generated ACL, groups, `repo-show`, default vs protected branch |
| [Working with AI agents](docs/agents.md) | Agent workflow, `--agent-rewind`, reviewing and merging, recovering branches, many agents |
| [Identities and keys](docs/identities.md) | Admin/daily/agent identities, isolating agent keys, moving admin rights |
| [One-off deploys](docs/share.md) | `share` usage, options and security notes |
| [Server operations](docs/operations.md) | Health checks, backup, SSH connection limits, operational rules |
| [Upgrading](docs/upgrade/README.md) | General upgrade steps and per-version notes |
| [Agent instructions template](examples/AGENTS.md) | `AGENTS.md` / `CLAUDE.md` template for project repositories |

## Development

```bash
make check                  # syntax checks, ShellCheck (if installed), unit tests
sudo make test-integration  # against a real Gitolite; use a disposable machine
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for all test suites, including the
install end-to-end test, and the design constraints.

## License

[GNU General Public License v3.0](LICENSE).
