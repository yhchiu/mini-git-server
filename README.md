# mini-git-server

`mini-git-server` is a minimal self-hosted Git server toolkit. The `mini-git-server.sh` CLI is a small Bash helper for a minimal private Git service based on:

- Debian 13
- OpenSSH
- Git
- Gitolite 3

It intentionally does **not** add a web forge, database, Redis, container runtime, package registry, or CI system.

Upgrading from an earlier version? See [13. Upgrading](#13-upgrading).

## Design goals

- Keep the Git server small and auditable.
- Use Debian packages instead of third-party installers.
- Keep Gitolite's standard `gitolite-admin` workflow as the source of truth.
- Give AI agents separate SSH identities.
- Let agents push only to their own `agent/USER/*` namespace by default.
- Keep `agent/*` branches for agents and tags for the repository owner.
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
host-keys
ssh-limits
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
group-set
group-remove
group-list
sync
apply
```

Project commands (run inside a clone of a project repository):

```text
agent-branches
```

Deploy commands (run on any machine that can read the repository):

```text
share
```

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
`arthur`). See [Identities and keys](#identities-and-keys).

## 2. Install the server

Copy `mini-git-server.sh` and the public key to a fresh Debian 13 server.

Example using SSH port `2222` and `trunk` as the Git default branch for newly created repositories:

```bash
sudo ./mini-git-server.sh install \
  --admin-key ./gitolite-admin.pub \
  --admin-name arthur-admin \
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
7. adds an SSH `Match User git` hardening drop-in, which also accepts the
   `GIT_PROTOCOL` variable so Git can use protocol v2;
8. validates the SSH configuration before reloading SSH;
9. prints the SSH host key fingerprints and `known_hosts` lines.

`--ssh-port` now **configures sshd**, rather than being informational only.

`--default-branch` only affects repositories created after installation. The
`gitolite-admin` repository always uses the `master` branch, because Gitolite
3.6.12 (the Debian 13 package) only applies pushes to `master` of
`gitolite-admin`. The installer pins this branch during `gitolite setup` and
stops if the admin repository ends up on any other branch.

The script does not modify nftables/iptables, a cloud firewall, router ACLs, or VPN policy. If a non-default SSH port is used, make sure that port is reachable before ending the current administrative session.

If another active `Port` directive already exists elsewhere in the sshd configuration, the script warns that sshd may listen on more than one port. The installer is intended primarily for a fresh Debian host.

## 3. Configure the admin workstation

Use one SSH host alias per identity. Here `internal-git-admin` uses the
admin key and is only used for `gitolite-admin`, and `internal-git` uses the
daily key (added in step 5):

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
printed (or run `sudo ./mini-git-server.sh host-keys --host
git.example.internal` on the server) to `~/.ssh/known_hosts`. Then SSH does
not have to ask whether to trust an unknown host key.

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

## 4. Initialize script-managed ACL fragments

Inside the `gitolite-admin` working tree:

```bash
/path/to/mini-git-server.sh admin-init
```

This adds, in this order:

```text
include "groups/*.conf"
include "repos/*.conf"
```

and stores script-managed groups under `conf/groups/` and repository ACLs
under `conf/repos/`. Gitolite needs a group to be defined before a rule uses
it, so the groups include always comes first. Running `admin-init` again is
safe: on a working tree set up before 0.3.0, it adds the groups include in
front of the existing repos include (see
[Upgrading to 0.3.0](docs/upgrade/0.3.0.md)).

Deploy the change after review:

```bash
/path/to/mini-git-server.sh apply \
  -m "Initialize managed Gitolite repository ACLs"
```

## 5. Add users and devices

Add your daily identity. It is separate from the admin identity created by
`install`, so this key cannot change access rules:

```bash
/path/to/mini-git-server.sh user-add \
  --name arthur \
  --key ~/.ssh/id_ed25519.pub
```

`user-add` warns when a key is added to an identity that can push to
`gitolite-admin`, and `repo-set` warns when such an identity is used in a
repository ACL.

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

`user-add` refuses:

- a key that is already stored for another identity, because sshd would use
  only the first match and the two identities would silently become one;
- a name that Gitolite would read as a different user. Gitolite reads
  `arthur@laptop.pub` as user `arthur`, so use `--key-id laptop` for device
  labels. E-mail style names such as `a@example.com` are fine.

### Remove keys

```bash
# Remove keydir/arthur.pub
/path/to/mini-git-server.sh user-remove --name arthur

# Remove one device key: keydir/notebook/arthur.pub
/path/to/mini-git-server.sh user-remove --name arthur --key-id notebook

# Remove every key of an identity, for example a retired agent
/path/to/mini-git-server.sh user-remove --name agent-fix --all
```

`user-remove` refuses to remove the last key that can push to
`gitolite-admin`, because nobody could change access rules afterwards. Add
another admin key first, or pass `--force` if that is really intended.

When an identity has no keys left but is still named in an access rule,
`user-remove` lists the files. Remove the name from those rules too:
otherwise a key added later under the same name would get the old access
back.

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
    -       refs/heads/trunk$    =   developer1 developer2 agent-impl agent-fix
    -       refs/heads/production$ =   developer1 developer2 agent-impl agent-fix
    -       refs/tags/           =   developer1 developer2 agent-impl agent-fix
    -       agent/               =   developer1 developer2
    RW                          =   developer1 developer2
    RW      agent/USER/         =   agent-impl agent-fix
    R                           =   agent-impl agent-fix agent-review ci
```

Meaning:

- `arthur` has `RW+` to the repository, and is the only identity that can
  push tags;
- normal writers have `RW`, but cannot update protected branches, cannot
  push tags, and cannot write to `agent/*` branches;
- `agent-impl` can write only under `agent/agent-impl/*`;
- `agent-fix` can write only under `agent/agent-fix/*`;
- agents have `RW`, not `RW+`, so force-pushing their own agent branches is not allowed by default;
- review and CI identities are read-only.

Gitolite uses the first rule that matches, so all `-` (deny) rules come
before the writers' `RW` rule.

`--protected-branch` uses an exact branch match. A branch such as
`release/1.2` is escaped before being written as a Gitolite refex, so regex
metacharacters in a valid Git branch name do not broaden the rule accidentally.

If no `--protected-branch` is supplied, the script does not assume a branch
name.

`repo-set` checks the ACL before writing it:

- Each identity may have only one role (owner, writer, agent or reader). For
  example, an agent that is also listed as a writer could push to every
  branch except the protected ones, so this is refused.
- Agent names may only use letters, digits, `-` and `_`, because Gitolite
  puts the name into the branch rule `agent/USER/`.
- It warns about identities that have no key in `keydir/` yet. This usually
  means a typing mistake, or a key that still has to be added. Gitolite's
  special users `daemon` and `gitweb` never have a key; for them it says
  what they do instead (see [Anonymous reading](#anonymous-reading)).

### Anonymous reading

`daemon` and `gitweb` are special users of Gitolite, not identities with
keys:

- `--readers daemon` makes Gitolite put a `git-daemon-export-ok` file into
  the repository. `git daemon` and `git http-backend` serve only
  repositories that have this file, to anyone who can reach them, without a
  key.
- `--readers gitweb` lists the repository in `projects.list`, for gitweb.

mini-git-server does not set up `git daemon`, `git http-backend` or gitweb,
so on its own this makes nothing reachable. It matters as soon as one of
them runs on the server.

`@all` includes `daemon` and `gitweb`. A repository with `--readers @all`,
or any other rule for `@all` (such as the `testing` repository that Gitolite
creates), is marked in the same way.

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

### Groups

With several agents and several repositories, list the agents once in a
group and use the group in every repository:

```bash
/path/to/mini-git-server.sh group-set \
  --name agents \
  --members agent-impl,agent-fix

/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --agents @agents \
  --readers agent-review,ci \
  --protected-branch trunk
```

Each member of `@agents` still gets only its own `agent/<name>/*` branches.
To add or remove an agent later, run `group-set` with the new member list
and `apply`. There is no need to run `repo-set` again for each repository.

`group-set` is declarative like `repo-set`: `--members` is the complete
list. Before writing the group, it checks every managed repository that uses
the group with the new members, so a member cannot end up with two roles in
one repository.

```bash
/path/to/mini-git-server.sh group-list
/path/to/mini-git-server.sh group-remove --name agents
```

`group-remove` refuses while a repository still uses the group. Groups may
be used in `--writers`, `--agents` and `--readers`; `@all` works as usual.

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
3. fetches `origin` and stops, without committing, if another machine has
   pushed newer changes;
4. displays the staged diff;
5. commits the change;
6. pushes it to `master` on `origin`.

To commit without pushing:

```bash
/path/to/mini-git-server.sh apply --no-push
```

`apply` refuses to run on any branch other than `master`. Gitolite ignores
pushes to other branches of `gitolite-admin`, so such a push would succeed
without changing any access rules.

### Working from several machines

Each admin workstation has its own `gitolite-admin` working tree. When
another machine has applied changes in the meantime, `apply` stops before
committing. Bring the working tree up to date and apply again:

```bash
/path/to/mini-git-server.sh sync
/path/to/mini-git-server.sh apply -m "Add project-y"
```

`sync`:

- fast-forwards to `origin`, keeping changes that are staged but not
  applied yet;
- rebases local commits that were not pushed (for example after a failed
  push, or `apply --no-push`) onto `origin`;
- never pushes.

`repo-set` writes the complete ACL of a repository. If another machine
changed the same repository, check the staged diff after `sync`, or simply
run the `repo-set` command again on top of the updated state. Running `sync`
before starting a change avoids this.

### Repair an admin repository on the wrong branch

Before 0.3.0, `install --default-branch NAME` created `gitolite-admin` on
branch `NAME` instead of `master`. On such a server every push to
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

Check the result with `ssh internal-git-admin info` on the workstation and
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
    the only identity that can push tags

Writer
    branches: RW, except protected branches and agent/*
    tags: none

Implementation agent
    agent/<its-user>/*: RW
    rest of repository: R

Review agent
    repository: R

CI runner
    repository: R
```

The restriction is enforced by Gitolite on the server, rather than relying only on agent instructions.

### Letting agents rewrite their own branches

By default agents cannot force-push or delete, not even their own branches.
After a review, an agent that wants to rebase must push a new branch, for
example `agent/agent-impl/issue-42-v2`, and old branches stay until the owner
deletes them.

Many agent tools rebase and push with `--force-with-lease`. To allow that
inside each agent's own namespace only, add `--agent-rewind`:

```bash
/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --agents @agents \
  --agent-rewind \
  --protected-branch trunk
```

This changes the agent rule from `RW` to `RW+` for `agent/USER/` only.
Agents still cannot write anywhere else, and cannot rewrite or delete
another agent's branches.

### Recovering a rewritten or deleted branch

The Gitolite log records every push with the user, the branch, the old
commit and the new commit. Find the commit you want back:

```bash
sudo grep -h 'refs/heads/agent/agent-impl/issue-42' /home/git/.gitolite/logs/gitolite-*.log
```

New installs also keep a reflog in every hosted repository
(`core.logAllRefUpdates=always`). For a branch that was force-pushed (not
deleted), the reflog lists its earlier commits:

```bash
sudo runuser -u git -- git -C /home/git/repositories/project-x.git \
  reflog show refs/heads/agent/agent-impl/issue-42
```

Then create a new branch at the old commit. This is the one case where you
run Git directly inside a hosted repository:

```bash
sudo runuser -u git -- git -C /home/git/repositories/project-x.git \
  branch recovered/issue-42 OLD_COMMIT
```

Limits:

- Deleting a branch also deletes its reflog. For deleted branches, take the
  commit from the Gitolite log.
- Git may delete commits that no branch or reflog points to once they are
  two weeks old (`gc.pruneExpire`). Commits in a reflog are kept longer
  (30 days by default). Recover soon, or rely on `backup`.
- Installs made before 0.3.0 have no reflog until it is enabled by hand
  (see [Upgrading to 0.3.0](docs/upgrade/0.3.0.md)). `doctor` reports
  whether it is enabled.

### Reviewing and merging agent work

Agents never write to the main branches; the owner merges their work. In a
clone of the project on your workstation, start with an overview:

```bash
/path/to/mini-git-server.sh agent-branches
```

```text
AGENT       BRANCH                    AHEAD  BEHIND  UPDATED           SUBJECT
agent-impl  agent/agent-impl/issue-1      2       0  3 hours ago       Step two
agent-fix   agent/agent-fix/typo          0       1  2 days ago        Fix a typo

Ahead and behind are counted against origin/trunk.
```

`agent-branches` fetches first, lists the newest branches first, and
compares them with the remote's default branch (its `HEAD`), so it does not
assume a branch name. Use `--base BRANCH` to compare with another branch,
`--remote NAME` for another remote, and `--no-fetch` to skip fetching.

Then look at, merge and clean up the branches with plain Git:

```bash
# See what one branch adds on top of trunk
git log --oneline trunk..origin/agent/agent-impl/issue-42
git diff trunk...origin/agent/agent-impl/issue-42

# Compare two versions of the same work, for example after a rebase
git range-diff trunk origin/agent/agent-impl/issue-42 origin/agent/agent-impl/issue-42-v2

# Merge and publish
git switch trunk
git merge --no-ff origin/agent/agent-impl/issue-42
git push origin trunk

# List agent branches whose commits are all in trunk, with the commands
# that delete them on the server
/path/to/mini-git-server.sh agent-branches --merged
git push origin --delete agent/agent-impl/issue-42
```

Branches merged with squash or rebase still show commits ahead in
`agent-branches`, because their own commits are not in the base branch.

A review agent listed in `--readers` can only read. To let it hand back
fixes or notes as a branch, list it in `--agents` instead: it then gets its
own `agent/agent-review/*` namespace.

### Instructions for the agents

[`examples/AGENTS.md`](examples/AGENTS.md) is a template for the instructions
file in each project repository (`AGENTS.md`, `CLAUDE.md`, or whatever your
agent tool reads). It tells agents how to find their identity, which branches
they may push to, what to do when a push is denied, and what to report when
they hand over work. The server enforces the rules either way; the file only
saves agents from work that would be rejected.

## Identities and keys

Gitolite decides who you are only from the SSH key that connects. Any process
that can use a key **is** that identity. The server-side rules above therefore
protect you only as far as the keys are kept apart on the client side.

Use three kinds of identities:

| Identity | Example | Access | Where the private key lives |
|---|---|---|---|
| Admin | `arthur-admin` | `gitolite-admin` only | Admin workstation; preferably a FIDO2 key (`-sk`) |
| Daily (owner) | `arthur` | Owner of your repositories | Your workstations |
| Agent | `agent-impl` | `agent/agent-impl/*`, read elsewhere | Only the agent's own environment |

The admin identity should not be an owner, writer, agent or reader of any
repository, and no AI agent should ever be able to use the admin or daily
keys.

### Keeping agent keys apart

An AI agent that runs in your own terminal can usually use every key you can:
it inherits `SSH_AUTH_SOCK` (your ssh-agent) and can read `~/.ssh`. Gitolite
then sees your identity, not the agent's. To keep the agent restricted:

- Run each agent as its own Unix user, or in its own container or VM.
- Give that environment only the agent's private key. Do not mount your
  `~/.ssh` or forward your ssh-agent into it.
- Clear `SSH_AUTH_SOCK` in the agent's environment, and use
  `IdentityAgent none` and `IdentitiesOnly yes` in its SSH configuration.
- Protect the admin key (and ideally the daily key) with a FIDO2 security
  key. An agent cannot press the button, even if it can reach the key.
- Give each agent role its own identity. Several hosts may share one
  identity by using `--key-id`, but then they also share one branch
  namespace.

Example SSH configuration inside an agent environment:

```sshconfig
Host internal-git
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/agent-impl
    IdentitiesOnly yes
    IdentityAgent none
    StrictHostKeyChecking yes
    UserKnownHostsFile ~/.ssh/known_hosts
```

Put the `known_hosts` lines from `host-keys` into that file when you set up
the agent environment. With `StrictHostKeyChecking yes` the agent refuses an
unknown or changed host key, instead of waiting at a prompt or being told to
turn the check off.

### Server host keys

```bash
sudo ./mini-git-server.sh host-keys --host git.example.internal
```

This prints the fingerprint of every SSH host key and a `known_hosts` line
for each. The port is read from sshd; pass `--port` to override it. Copy the
lines to admin workstations and agent hosts over a channel you trust.

### Many agents at once

- **Git protocol v2.** New installs accept `GIT_PROTOCOL` for the hosting
  account, so Git can use protocol v2. With v2 the server lists only the
  refs a client asks for (for example only `trunk` in `git fetch origin
  trunk`), instead of every branch and tag on every connection. This
  matters when a repository collects many agent branches. Installs made
  before 0.3.0 need one manual change for this (see
  [Upgrading to 0.3.0](docs/upgrade/0.3.0.md)). `doctor` reports whether it
  is enabled.
- **Connection bursts.** By default sshd starts dropping new connections
  at random once 10 of them are waiting to log in (`MaxStartups 10:30:100`).
  If many agents fetch at the same moment and some fail with "Connection
  closed", raise the limit:

  ```bash
  sudo ./mini-git-server.sh ssh-limits --max-startups 50:30:200
  ```

  `ssh-limits` writes `/etc/ssh/sshd_config.d/99-gitolite-limits.conf`,
  checks it with sshd, and reloads sshd. If sshd rejects the value, or
  another `MaxStartups` line overrides it, the previous setting is
  restored. Run `ssh-limits` without options to see the current value, and
  `ssh-limits --reset` to go back to sshd's default. `install` accepts the
  same value with `--max-startups`, and `status` shows the effective value.

An agent can check which identity it really has:

```bash
ssh internal-git info
```

The first line names the identity, for example `hello agent-impl, this is
git@...`. If it shows your own name, the agent can use your keys.

### Moving admin rights to a separate identity

Examples before 0.3.0 used the same name for the admin and the daily
identity. To
move admin rights to `arthur-admin` without locking yourself out:

1. Create the admin key (step 1) and add it:

   ```bash
   /path/to/mini-git-server.sh user-add \
     --name arthur-admin \
     --key ~/.ssh/gitolite-admin.pub
   ```

2. In `conf/gitolite.conf`, add the new identity to the `gitolite-admin`
   rule, for example `RW+ = arthur arthur-admin`. Then run
   `git add conf/gitolite.conf` and `apply`.
3. Point the admin working tree at the admin key and check it:

   ```bash
   git remote set-url origin internal-git-admin:gitolite-admin
   ssh internal-git-admin info
   ```

   The output must list `R W` for `gitolite-admin`.
4. Remove the old identity from the `gitolite-admin` rule
   (`RW+ = arthur-admin`), then `git add conf/gitolite.conf` and `apply`.
   `arthur` keeps its keys and stays the owner of your repositories.

## One-off deploys

A machine that needs the code only once, for example for a one-off deploy,
does not need a key of its own. Run `share` on a machine that can read the
repository, such as your workstation, and run the command it prints on the
target:

```bash
/path/to/mini-git-server.sh share \
  --from internal-git:project-x \
  --ref trunk \
  --bind 10.0.0.5
```

```text
[INFO] Exporting 'trunk' from internal-git:project-x
Sharing project-x-trunk.tar.gz (13M) until 2026-11-04 11:59:41, or after 1 download. Press Ctrl-C to stop earlier.

URL:     http://10.0.0.5:40719/5d74b83578475deaead8f86fdfc6becc/project-x-trunk.tar.gz
SHA-256: 29d8a7d51554e73e7837be043843c912a8b266073d823f807a33881d919fd91a

On the target:
  curl -fsS -o 'project-x-trunk.tar.gz' 'http://10.0.0.5:40719/5d74b83578475deaead8f86fdfc6becc/project-x-trunk.tar.gz' && echo '29d8a7d51554e73e7837be043843c912a8b266073d823f807a33881d919fd91a  project-x-trunk.tar.gz' | sha256sum -c - && tar -xzf 'project-x-trunk.tar.gz'
```

`share`:

1. exports the branch or tag with `git archive` through Gitolite, using
   your own identity, so it can only share what you can read;
2. serves the archive at a URL that contains 128 random bits, and answers
   every other path with 404;
3. stops after 30 minutes (`--ttl`), after one complete download
   (`--max-downloads`), or on Ctrl-C, and then removes everything it
   created.

The archive is removed from the disk as soon as the server has opened it,
and the server stops by itself within about a second when `share` is gone.
So once the URL is printed, even `kill -9` leaves nothing behind but an
empty temporary directory.

The target only needs `curl`, `sha256sum` and `tar` (or `unzip`). The
machine that runs `share` needs `python3` (and `openssl` for `--tls`), and
the target must be able to reach it: `share` does not change any firewall.

| Option | Effect |
|---|---|
| `--depth N` | Include `.git` with the last N commits, so the target gets a shallow clone instead of only the files. The remote and the reflog, which name the Git server, are removed. |
| `--format zip` | A zip archive instead of tar.gz, for example for a Windows target |
| `--tls` | HTTPS with a throwaway self-signed certificate. The printed command pins its key, so no CA is involved. |
| `--max-downloads N` | Allow N complete downloads, for several targets; `0` means no limit until the time limit |
| `--ttl TIME` | Stop after `90s`, `30m`, `2h` and so on; at most `24h` |
| `--port PORT`, `--url-host NAME` | A fixed port, for example for a firewall rule, and the host name to print in the URL |

Keep in mind:

- **Without `--tls`, the network can read the archive and change it in
  transit.** The printed command checks the SHA-256 checksum. That only
  helps if the command reaches the target over a channel you trust, for
  example your SSH session or the console. On networks you do not trust,
  use `--tls`.
- **The URL is the only secret.** Anyone who has it can download the
  archive until the share stops, so keep `--max-downloads` low. `share`
  does not log the token or pass it on any command line. On the target,
  however, the URL is in the shell history, and in the process list while
  curl runs, and a proxy in between may log it.
- **`--bind` is required.** Listen on the address the target uses. With
  `0.0.0.0` or `::`, `share` also listens on every other network the
  machine is on, for example a public Wi-Fi.
- `share` removes only what it created. The copy on the target is yours to
  remove.
- Submodules are not included, and Git LFS files contain only their
  pointers.

If you can log in to the target over SSH anyway, you do not need `share`.
Stream the archive over that connection instead:

```bash
git archive --remote=internal-git:project-x --format=tar trunk | ssh web-1 'mkdir -p /srv/app && tar -x -C /srv/app'
```

A target in another network may not reach your workstation. Run `share` on
a host that it can reach, or forward the port over SSH. A public tunnel
service also works with `--bind 127.0.0.1`, but then the code passes
through that service, and anyone on the internet who has the URL can
download it.

## 10. Server health checks

```bash
sudo ./mini-git-server.sh status
sudo ./mini-git-server.sh doctor
sudo ./mini-git-server.sh fsck
```

`status` also reports the effective sshd ports and the hosting account's configured Git default branch.
Run it as root: without root, it says so, and the fields that only root can
read (for example the sshd ports and the default branch) show `(needs root)`
instead of a guess.

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

The repositories are owned by the hosting account, and Git refuses to open a
repository owned by another user ("detected dubious ownership"). The backup
therefore reads each repository through `git upload-pack` running as the
hosting account. Root only writes and checks the new mirror, which is owned
by root.

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

## 13. Upgrading

Upgrading replaces the script. It never changes access rules by itself:
existing keys and repository ACLs keep working, and Gitolite itself is not
touched. When a new version needs changes on the server or in
`gitolite-admin`, its upgrade notes list them, and you make them by hand.

Check which version you have:

```bash
./mini-git-server.sh version
```

### Upgrade notes

Read the notes of every version newer than yours, oldest first:

| Version | Upgrading from | Notes |
|---|---|---|
| 0.3.0 | 0.2.x | [docs/upgrade/0.3.0.md](docs/upgrade/0.3.0.md) |

### General steps

1. Read the upgrade notes of the new version, and of every version you skip.
2. Replace `mini-git-server.sh` on the server and on every admin workstation
   with the new copy, and check it:

   ```bash
   ./mini-git-server.sh version
   ```

3. On the server, make a backup before changing anything else:

   ```bash
   sudo ./mini-git-server.sh backup
   ```

4. On the server, run `doctor` and note every `[FAIL]` and `[WARN]` line:

   ```bash
   sudo ./mini-git-server.sh doctor
   ```

5. Do the server steps from the upgrade notes.
6. On each admin workstation, bring the `gitolite-admin` working tree up to
   date:

   ```bash
   /path/to/mini-git-server.sh sync
   ```

7. Do the workstation steps from the upgrade notes on **one** workstation
   only, review the staged diff, and `apply` it. The other workstations get
   the result with `sync`.
8. Run `doctor` on the server again. No `[FAIL]` line should be left; the
   upgrade notes explain any `[WARN]` line that may stay.

The commands assume the default hosting account `git` with the home
directory `/home/git`. If you installed with `--git-user`, use that account
instead, and pass `--git-user` to the server commands.

## Testing

Run the Bash test suite (no external test framework required):

```bash
make test
```

The `share` tests need `python3` and `curl`, and the `--tls` test also
`openssl`. Tests whose commands are missing are reported as skipped.

Run syntax checks, ShellCheck when installed, and the full test suite:

```bash
make check
```

Run the integration tests against a real Gitolite installation. They need
root, the `gitolite3` package, `python3` and `curl`:

```bash
sudo make test-integration
```

The integration tests create a temporary hosting account and remove it
afterwards. They do not start sshd or change the SSH configuration:
`tests/fake-ssh` runs each key's forced command from the Gitolite
`authorized_keys` file, the same way sshd would. They cover installation
with `--default-branch`, the admin workflow, the generated ACL (with real
pushes), `status`, `doctor`, `fsck` and `backup`. Run them on a disposable
machine or container rather than a production Git server.

The install end-to-end test runs the real `install` on Debian 13, then starts
sshd and checks the result over real SSH connections: host keys, Git
protocol v2, the admin workflow, access rules, `doctor`, `status` and
`backup`. It also checks that a second `install` is refused without
changing anything. It installs packages, creates the `git` account and
changes `/etc/ssh`, so it refuses to run unless `MGS_E2E_DISPOSABLE=1` is
set. Run it only in a throwaway container, for example:

```bash
docker run --rm -v "$PWD:/src:ro" -w /src debian:trixie bash -c '
  apt-get update &&
  apt-get install -y --no-install-recommends ca-certificates git make shellcheck openssh-client openssh-server gitolite3 python3 curl openssl &&
  make check && make test-integration && MGS_E2E_DISPOSABLE=1 make test-install'
```

GitHub Actions runs the unit and integration tests on Ubuntu, and all three
test suites in a Debian 13 container.

