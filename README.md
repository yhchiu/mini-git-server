# mini-git-server

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

You need a fresh Debian 13 server and an admin workstation with OpenSSH and
Git. Details for every step are in [Installation](docs/install.md).

**1. Create a dedicated admin key** on the workstation. A FIDO2 security key
(`ed25519-sk`) is recommended; without one, use `-t ed25519` with a
passphrase.

```bash
ssh-keygen -t ed25519-sk -f ~/.ssh/gitolite-admin -C gitolite-admin
```

**2. Install the server.** Copy `mini-git-server.sh` and
`gitolite-admin.pub` to the server, then:

```bash
sudo ./mini-git-server.sh install \
  --admin-key ./gitolite-admin.pub \
  --admin-name arthur-admin \
  --ssh-port 2222 \
  --default-branch trunk
```

> [!IMPORTANT]
> The script does not change any firewall. If you use a non-default SSH
> port, make sure it is reachable before you end your current session.

**3. Configure the workstation.** Add the `known_hosts` lines that `install`
printed to `~/.ssh/known_hosts`, and one SSH host alias per identity:

```sshconfig
# Admin key, used only for gitolite-admin
Host internal-git-admin
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/gitolite-admin
    IdentitiesOnly yes

# Your daily key
Host internal-git
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

**4. Clone and prepare `gitolite-admin`:**

```bash
git clone internal-git-admin:gitolite-admin
cd gitolite-admin
/path/to/mini-git-server.sh admin-init
```

**5. Add users, agents and a repository.** These commands only stage
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

**6. Review and deploy:**

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
| [Installation](docs/install.md) | Admin key, `install` options and what it changes, workstation SSH setup, host keys |
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
