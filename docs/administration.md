# Administration workflow

All access rules live in the `gitolite-admin` repository. mini-git-server
commands edit a working tree of it on an admin workstation and **stage**
the changes; nothing reaches the server until `apply` commits and pushes
them.

```mermaid
flowchart LR
    A["user-add / repo-set / group-set ..."] -->|stage| B["gitolite-admin working tree"]
    B -->|"apply: review, commit, push"| C["Gitolite on the server"]
    C -->|"sync"| B
```

- [Initialize script-managed ACL fragments](#initialize-script-managed-acl-fragments)
- [Apply administrative changes](#apply-administrative-changes)
- [Working from several machines](#working-from-several-machines)
- [Repair an admin repository on the wrong branch](#repair-an-admin-repository-on-the-wrong-branch)

The commands that stage changes are described in
[Access control](access-control.md).

## Initialize script-managed ACL fragments

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
[Upgrading to 0.3.0](upgrade/0.3.0.md)).

Deploy the change after review:

```bash
/path/to/mini-git-server.sh apply \
  -m "Initialize managed Gitolite repository ACLs"
```

## Apply administrative changes

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

## Working from several machines

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

## Repair an admin repository on the wrong branch

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
