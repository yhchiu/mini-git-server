# mini-git-server

`mini-git-server` is a minimal self-hosted Git server toolkit. The `mini-git-server.sh` CLI is a small Bash helper for a minimal private Git service based on:

- Debian 13
- OpenSSH
- Git
- Gitolite 3

It intentionally does **not** add a web forge, database, Redis, container runtime, package registry, or CI system.

## Design goals

- Keep the Git server small and auditable.
- Use Debian packages instead of third-party installers.
- Keep Gitolite's standard `gitolite-admin` workflow as the source of truth.
- Give AI agents separate SSH identities.
- Let agents push only to their own `agent/USER/*` namespace by default.
- Do not assume that the primary branch is named `main`.
- Support explicit protected branches.
- Separate the repository default branch (`HEAD`) from access-control policy.
- Stage administration changes first; only `apply` commits and pushes them.

## Commands

Server-side commands:

```text
install
status
doctor
backup
fsck
repo-set-default
```

Admin-workstation commands:

```text
admin-clone
admin-init
user-add
user-remove
user-list
repo-set
repo-add (compatibility alias)
repo-show
repo-list
apply
```

## 1. Generate a dedicated admin key

On the administrator workstation:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/gitolite-admin -C gitolite-admin
```

Use a dedicated key rather than reusing an unrelated server-login key.

## 2. Install the server

Copy `mini-git-server.sh` and the public key to a fresh Debian 13 server.

Example using SSH port `2222` and `trunk` as the Git default branch for newly created repositories:

```bash
sudo ./mini-git-server.sh install \
  --admin-key ./gitolite-admin.pub \
  --admin-name arthur \
  --ssh-port 2222 \
  --default-branch trunk
```

Defaults:

- hosting Unix user: `git`
- SSH port: `22`
- repositories: `/home/git/repositories`
- Git default branch: unchanged unless `--default-branch` is specified

The installer:

1. installs `openssh-server`, `git`, `gitolite3`, and `ca-certificates` from Debian;
2. creates the dedicated `git` hosting account if necessary;
3. locks its password;
4. optionally sets `init.defaultBranch` for the hosting account;
5. initializes Gitolite with the supplied admin key;
6. writes an sshd port drop-in at `/etc/ssh/sshd_config.d/00-gitolite-port.conf`;
7. adds an SSH `Match User git` hardening drop-in;
8. validates the SSH configuration before reloading SSH.

`--ssh-port` now **configures sshd**, rather than being informational only.

`--default-branch` only affects repositories created after installation. The
`gitolite-admin` repository always uses the `master` branch, because Gitolite
3.6.12 (the Debian 13 package) only applies pushes to `master` of
`gitolite-admin`. The installer pins this branch during `gitolite setup` and
stops if the admin repository ends up on any other branch.

The script does not modify nftables/iptables, a cloud firewall, router ACLs, or VPN policy. If a non-default SSH port is used, make sure that port is reachable before ending the current administrative session.

If another active `Port` directive already exists elsewhere in the sshd configuration, the script warns that sshd may listen on more than one port. The installer is intended primarily for a fresh Debian host.

## 3. Configure the admin workstation

For a non-default SSH port, using an SSH host alias is recommended:

```sshconfig
Host internal-git
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/gitolite-admin
    IdentitiesOnly yes
```

Verify access:

```bash
ssh internal-git info
```

Clone the admin repository:

```bash
git clone internal-git:gitolite-admin
```

Or without an SSH config alias:

```bash
./mini-git-server.sh admin-clone \
  --host git.example.internal \
  --port 2222 \
  --identity ~/.ssh/gitolite-admin
```

## 4. Initialize script-managed ACL fragments

Inside the `gitolite-admin` working tree:

```bash
/path/to/mini-git-server.sh admin-init
```

This adds:

```text
include "repos/*.conf"
```

and stores script-managed repository ACLs under `conf/repos/`.

Deploy the change after review:

```bash
/path/to/mini-git-server.sh apply \
  -m "Initialize managed Gitolite repository ACLs"
```

## 5. Add users and devices

One key:

```bash
/path/to/mini-git-server.sh user-add \
  --name arthur \
  --key ~/.ssh/id_ed25519.pub
```

Several computers mapped to the same Gitolite identity:

```bash
/path/to/mini-git-server.sh user-add \
  --name arthur \
  --key ~/keys/desktop.pub \
  --key-id desktop

/path/to/mini-git-server.sh user-add \
  --name arthur \
  --key ~/keys/notebook.pub \
  --key-id notebook
```

This produces:

```text
keydir/desktop/arthur.pub
keydir/notebook/arthur.pub
```

Both keys map to the logical Gitolite user `arthur`.

For AI agents, use separate identities and separate keys:

```bash
/path/to/mini-git-server.sh user-add \
  --name agent-impl \
  --key ~/keys/agent-impl.pub \
  --key-id agent-host-1

/path/to/mini-git-server.sh user-add \
  --name agent-review \
  --key ~/keys/agent-review.pub \
  --key-id agent-host-1
```

## 6. Set and inspect repository ACLs

`repo-set` is the primary repository-management command. It declares the
**complete desired ACL state** for a repository and stages the resulting
Gitolite fragment.

There is no hard-coded `main` branch.

Example using `master` as the protected branch:

```bash
/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --writers developer1 \
  --agents agent-impl,agent-fix \
  --readers agent-review,ci \
  --protected-branch master
```

Multiple exact branches can be protected:

```bash
/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --writers developer1,developer2 \
  --agents agent-impl,agent-fix \
  --readers agent-review,ci \
  --protected-branch trunk \
  --protected-branch production
```

A generated ACL looks conceptually like:

```text
repo project-x
    RW+                         =   arthur
    -       refs/heads/trunk$   =   developer1 developer2 agent-impl agent-fix
    -       refs/heads/production$ = developer1 developer2 agent-impl agent-fix
    RW                          =   developer1 developer2
    RW      agent/USER/         =   agent-impl agent-fix
    R                           =   agent-impl agent-fix agent-review ci
```

Meaning:

- `arthur` has `RW+` to the repository;
- normal writers have `RW`, but cannot update protected branches;
- `agent-impl` can write only under `agent/agent-impl/*`;
- `agent-fix` can write only under `agent/agent-fix/*`;
- agents have `RW`, not `RW+`, so force-pushing their own agent branches is not allowed by default;
- review and CI identities are read-only.

`--protected-branch` uses an exact branch match. A branch such as
`release/1.2` is escaped before being written as a Gitolite refex, so regex
metacharacters in a valid Git branch name do not broaden the rule accidentally.

If no `--protected-branch` is supplied, the script does not assume a branch
name.

### `repo-set` replaces the managed state

`repo-set` is declarative. Options that are omitted are removed from the
script-managed ACL fragment.

For example, if a repository currently has:

```text
writers = developer1 developer2
agents  = agent-impl agent-fix
readers = agent-review ci
```

and you want to remove `developer1` and `agent-fix`, run the complete desired
state again:

```bash
/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --writers developer2 \
  --agents agent-impl \
  --readers agent-review,ci \
  --protected-branch trunk
```

Do not pass only the identities being added. `repo-set` means "make the
managed ACL look exactly like this."

`repo-add` remains available as a backward-compatible alias for `repo-set`.
New scripts and documentation should use `repo-set`.

### Inspect and edit the current state

Use `repo-show`:

```bash
/path/to/mini-git-server.sh repo-show --repo project-x
```

Example output:

```text
Repository: project-x
Owner: arthur
Writers: developer1 developer2
Agents: agent-impl agent-fix
Readers: agent-review ci
Protected branches:
  - trunk

Reapply command:
mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --writers developer1,developer2 \
  --agents agent-impl,agent-fix \
  --readers agent-review,ci \
  --protected-branch trunk
```

The command is intended to be copied, edited, and executed again. The change
is only staged; `apply` is still required to commit and push it.

To inspect the exact Gitolite fragment instead:

```bash
/path/to/mini-git-server.sh repo-show --repo project-x --raw
```

`repo-show` can also parse fragments produced by earlier 0.2.x releases that
do not yet contain the metadata written by `repo-set`.

## 7. Default branch versus protected branch

These are separate concepts.

### Default branch

The repository's default branch is the branch referenced by the bare repository's `HEAD`. It controls which branch a normal clone initially checks out.

The server-wide default for **newly created repositories** can be selected during installation:

```bash
sudo ./mini-git-server.sh install \
  --admin-key ./gitolite-admin.pub \
  --default-branch trunk
```

This sets Git's `init.defaultBranch` for the Gitolite hosting account.

### Change one repository's default branch

For an individual repository, use the server-side command:

```bash
sudo ./mini-git-server.sh repo-set-default \
  --repo project-x \
  --branch trunk
```

This performs the equivalent of:

```text
HEAD -> refs/heads/trunk
```

An empty repository is allowed to point to an unborn branch, which is useful before the first push.

`gitolite-admin` is the exception: `repo-set-default` only accepts `master`
for it, because Gitolite ignores pushes to any other branch of the admin
repository.

If the branch must already exist:

```bash
sudo ./mini-git-server.sh repo-set-default \
  --repo project-x \
  --branch trunk \
  --require-existing
```

### Protected branch

A protected branch is an ACL policy. For example:

```bash
--protected-branch trunk
```

prevents the users supplied through `--writers` and `--agents` from updating that exact branch. The owner remains allowed.

Therefore the default branch and protected branches do not have to be the same.

## 8. Apply administrative changes

Administration commands stage changes but do not push automatically.

Review and deploy them with:

```bash
/path/to/mini-git-server.sh apply \
  -m "Add project-x and agent access"
```

`apply`:

1. checks that the working tree is on the `master` branch;
2. runs `git diff --check --cached`;
3. displays the staged diff;
4. commits the change;
5. pushes it to `master` on `origin`.

To commit without pushing:

```bash
/path/to/mini-git-server.sh apply --no-push
```

`apply` refuses to run on any branch other than `master`. Gitolite ignores
pushes to other branches of `gitolite-admin`, so such a push would succeed
without changing any access rules.

### Repair an admin repository on the wrong branch

Earlier versions of `install --default-branch NAME` created `gitolite-admin`
on branch `NAME` instead of `master`. On such a server every push to
`gitolite-admin` succeeds, but Gitolite never applies it: new keys and
repositories do not appear. `doctor` reports this as a failure, and `apply`
refuses to run on that branch.

To repair it, first point the admin repository at `master` on the server:

```bash
sudo ./mini-git-server.sh repo-set-default \
  --repo gitolite-admin \
  --branch master
```

Then, inside the `gitolite-admin` working tree on the admin workstation,
rename the local branch and push it. This push makes Gitolite apply the
configuration:

```bash
git fetch origin
git branch -m master
git push -u origin master
```

Optionally remove the old branch from the server, replacing `trunk` with the
branch name that was used:

```bash
git push origin --delete trunk
```

Check the result with `ssh internal-git info` on the workstation and
`sudo ./mini-git-server.sh doctor` on the server.

## 9. Agent workflow

An implementation agent should use its own SSH key and branch namespace:

```bash
git switch -c agent/agent-impl/issue-42
git push -u origin agent/agent-impl/issue-42
```

A recommended authorization model is:

```text
Human owner
    entire repository: RW+

Implementation agent
    agent/<its-user>/*: RW
    rest of repository: R

Review agent
    repository: R

CI runner
    repository: R
```

The restriction is enforced by Gitolite on the server, rather than relying only on agent instructions.

## 10. Server health checks

```bash
sudo ./mini-git-server.sh status
sudo ./mini-git-server.sh doctor
sudo ./mini-git-server.sh fsck
```

`status` also reports the effective sshd ports and the hosting account's configured Git default branch.

Check only one repository:

```bash
sudo ./mini-git-server.sh fsck --repo project-x
```

## 11. Backup

Create a Git-aware mirror backup:

```bash
sudo ./mini-git-server.sh backup
```

Default destination:

```text
/var/backups/gitolite/YYYYMMDD-HHMMSS/
```

The script uses `git clone --mirror file://...` for each repository and runs `git fsck` on the backup. It also saves relevant Gitolite and sshd configuration metadata, including the managed SSH-port drop-in.

Keep a versioned/offline or otherwise independent copy on another system for disaster recovery.

## 12. Important operational rules

Do not manually edit these during normal administration:

```text
/home/git/.ssh/authorized_keys
/home/git/repositories/*
/home/git/.gitolite/*
```

The exception is not needed for changing a repository default branch: use `repo-set-default` instead of editing the bare repository's `HEAD` file manually.

Do not run CI jobs or arbitrary repository code on the Git server itself. Keep the Git server as the repository/control plane and use separate CI/agent execution hosts.

## Testing

Run the Bash test suite (no external test framework required):

```bash
make test
```

Run syntax checks, ShellCheck when installed, and the full test suite:

```bash
make check
```

