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

`repo-set` checks the ACL before writing it:

- Each identity may have only one role (owner, writer, agent or reader). For
  example, an agent that is also listed as a writer could push to every
  branch except the protected ones, so this is refused.
- Agent names may only use letters, digits, `-` and `_`, because Gitolite
  puts the name into the branch rule `agent/USER/`.
- It warns about identities that have no key in `keydir/` yet. This usually
  means a typing mistake, or a key that still has to be added.

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

Implementation agent
    agent/<its-user>/*: RW
    rest of repository: R

Review agent
    repository: R

CI runner
    repository: R
```

The restriction is enforced by Gitolite on the server, rather than relying only on agent instructions.

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
```

An agent can check which identity it really has:

```bash
ssh internal-git info
```

The first line names the identity, for example `hello agent-impl, this is
git@...`. If it shows your own name, the agent can use your keys.

### Moving admin rights to a separate identity

Older examples used the same name for the admin and the daily identity. To
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

## Testing

Run the Bash test suite (no external test framework required):

```bash
make test
```

Run syntax checks, ShellCheck when installed, and the full test suite:

```bash
make check
```

Run the integration tests against a real Gitolite installation. They need
root and the `gitolite3` package:

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

