# Access control

**English** | [繁體中文](zh-TW/access-control.md)

These commands run inside a `gitolite-admin` working tree on an admin
workstation. They only **stage** changes; run
[`apply`](administration.md#apply-administrative-changes) to deploy them.

- [Users and keys](#users-and-keys)
- [Repository ACLs](#repository-acls)
  - [What the generated ACL means](#what-the-generated-acl-means)
  - [`repo-set` replaces the managed state](#repo-set-replaces-the-managed-state)
  - [Groups](#groups)
  - [Inspect and edit the current state](#inspect-and-edit-the-current-state)
  - [Anonymous reading](#anonymous-reading)
- [Default branch versus protected branch](#default-branch-versus-protected-branch)

## Users and keys

Add your daily identity. It is separate from the admin identity created by
`install`, so this key cannot change access rules:

```bash
/path/to/mini-git-server.sh user-add \
  --name arthur \
  --key ~/.ssh/id_ed25519.pub
```

`user-add` warns when a key is added to an identity that can push to
`gitolite-admin`, and `repo-set` warns when such an identity is used in a
repository ACL. See [Identities and keys](identities.md).

### Several devices for one identity

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

This produces `keydir/desktop/arthur.pub` and `keydir/notebook/arthur.pub`.
Both keys map to the logical Gitolite user `arthur`.

### AI agents

Use separate identities and separate keys:

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

### What `user-add` refuses

- A key that is already stored for another identity, because sshd would use
  only the first match and the two identities would silently become one.
- A name that Gitolite would read as a different user. Gitolite reads
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

## Repository ACLs

`repo-set` is the primary repository-management command. It declares the
**complete desired ACL state** for a repository and stages the resulting
Gitolite fragment. There is no hard-coded `main` branch.

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

| Option | Role |
|---|---|
| `--owner NAME` | Full access (`RW+`); the only identity that can push tags |
| `--writers LIST` | `RW`, except protected branches, tags and `agent/*` |
| `--agents LIST` | `RW` only under `agent/<own-name>/*`; read elsewhere |
| `--readers LIST` | Read only |
| `--protected-branch NAME` | Exact branch that writers and agents cannot update; repeatable |
| `--agent-rewind` | Let agents force-push and delete their own branches; see [Agents](agents.md#letting-agents-rewrite-their-own-branches) |

Lists are comma-separated and may contain [groups](#groups) such as
`@agents`.

`repo-add` remains available as a backward-compatible alias for `repo-set`.
New scripts and documentation should use `repo-set`.

### What the generated ACL means

The example above generates an ACL that looks conceptually like:

```text
repo project-x
    RW+                            =   arthur
    -       refs/heads/trunk$      =   developer1 developer2 agent-impl agent-fix
    -       refs/heads/production$ =   developer1 developer2 agent-impl agent-fix
    -       refs/tags/             =   developer1 developer2 agent-impl agent-fix
    -       agent/                 =   developer1 developer2
    RW                             =   developer1 developer2
    RW      agent/USER/            =   agent-impl agent-fix
    R                              =   agent-impl agent-fix agent-review ci
```

Meaning:

- `arthur` has `RW+` to the repository, and is the only identity that can
  push tags;
- normal writers have `RW`, but cannot update protected branches, cannot
  push tags, and cannot write to `agent/*` branches;
- `agent-impl` can write only under `agent/agent-impl/*`;
- `agent-fix` can write only under `agent/agent-fix/*`;
- agents have `RW`, not `RW+`, so force-pushing their own agent branches is
  not allowed by default;
- review and CI identities are read-only.

Gitolite uses the first rule that matches, so all `-` (deny) rules come
before the writers' `RW` rule.

`--protected-branch` uses an exact branch match. A branch such as
`release/1.2` is escaped before being written as a Gitolite refex, so regex
metacharacters in a valid Git branch name do not broaden the rule
accidentally. If no `--protected-branch` is supplied, the script does not
assume a branch name.

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

### `repo-set` replaces the managed state

> [!WARNING]
> `repo-set` is declarative. Options that are omitted are **removed** from
> the script-managed ACL fragment. Do not pass only the identities being
> added.

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

The easiest way to get the current command is
[`repo-show`](#inspect-and-edit-the-current-state).

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

### Inspect and edit the current state

```bash
/path/to/mini-git-server.sh repo-list
/path/to/mini-git-server.sh repo-show --repo project-x
```

Example output of `repo-show`:

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

## Default branch versus protected branch

These are separate concepts:

| | Default branch | Protected branch |
|---|---|---|
| What it is | The branch the bare repository's `HEAD` points to | An ACL rule |
| What it controls | Which branch a normal clone checks out | Who may update that exact branch |
| Set with | `install --default-branch` (server-wide, new repositories), `repo-set-default` (one repository) | `repo-set --protected-branch` |
| Runs on | Server | Admin workstation |

They do not have to be the same branch.

### Default branch

The server-wide default for **newly created repositories** can be selected
during installation with `install --default-branch trunk`. This sets Git's
`init.defaultBranch` for the Gitolite hosting account.

For an individual repository, use the server-side command:

```bash
sudo ./mini-git-server.sh repo-set-default \
  --repo project-x \
  --branch trunk
```

This performs the equivalent of `HEAD -> refs/heads/trunk`. Use it instead
of editing the bare repository's `HEAD` file by hand.

An empty repository is allowed to point to an unborn branch, which is useful
before the first push. If the branch must already exist, add
`--require-existing`.

`gitolite-admin` is the exception: `repo-set-default` only accepts `master`
for it, because Gitolite ignores pushes to any other branch of the admin
repository.

### Protected branch

`--protected-branch trunk` prevents the users supplied through `--writers`
and `--agents` from updating that exact branch. The owner remains allowed.
