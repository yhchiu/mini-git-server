# Working with AI agents

**English** | [繁體中文](zh-TW/agents.md)

Each agent gets its own SSH identity and, by default, can push only to its
own `agent/<name>/*` branches. Gitolite enforces this on the server, rather
than relying only on agent instructions.

- [Authorization model](#authorization-model)
- [Agent workflow](#agent-workflow)
- [Letting agents rewrite their own branches](#letting-agents-rewrite-their-own-branches)
- [Reviewing and merging agent work](#reviewing-and-merging-agent-work)
- [Recovering a rewritten or deleted branch](#recovering-a-rewritten-or-deleted-branch)
- [Instructions for the agents](#instructions-for-the-agents)
- [Many agents at once](#many-agents-at-once)

> [!IMPORTANT]
> Gitolite knows an agent only by the SSH key it connects with. An agent
> that can use your keys **is** you. Read
> [Keeping agent keys apart](identities.md#keeping-agent-keys-apart) before
> giving agents access.

## Authorization model

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

See [Repository ACLs](access-control.md#repository-acls) for the
`repo-set` command that sets this up.

## Agent workflow

An implementation agent should use its own SSH key and branch namespace:

```bash
git switch -c agent/agent-impl/issue-42
git push -u origin agent/agent-impl/issue-42
```

An agent can check which identity it really has:

```bash
ssh internal-git info
```

The first line names the identity, for example `hello agent-impl, this is
git@...`. If it shows your own name, the agent can use your keys.

A review agent listed in `--readers` can only read. To let it hand back
fixes or notes as a branch, list it in `--agents` instead: it then gets its
own `agent/agent-review/*` namespace.

## Letting agents rewrite their own branches

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

## Reviewing and merging agent work

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
assume a branch name.

| Option | Effect |
|---|---|
| `--base BRANCH` | Compare with another branch |
| `--remote NAME` | Use another remote |
| `--no-fetch` | Skip fetching |
| `--merged` | List only branches whose commits are all in the base branch, with the commands that delete them on the server |

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

# List agent branches whose commits are all in trunk, then delete them
/path/to/mini-git-server.sh agent-branches --merged
git push origin --delete agent/agent-impl/issue-42
```

Branches merged with squash or rebase still show commits ahead in
`agent-branches`, because their own commits are not in the base branch.

## Recovering a rewritten or deleted branch

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
  (30 days by default). Recover soon, or rely on
  [`backup`](operations.md#backup).
- Installs made before 0.3.0 have no reflog until it is enabled by hand
  (see [Upgrading to 0.3.0](upgrade/0.3.0.md)). `doctor` reports
  whether it is enabled.

## Instructions for the agents

[`examples/AGENTS.md`](../examples/AGENTS.md) is a template for the
instructions file in each project repository (`AGENTS.md`, `CLAUDE.md`, or
whatever your agent tool reads). It tells agents how to find their identity,
which branches they may push to, what to do when a push is denied, and what
to report when they hand over work. The server enforces the rules either
way; the file only saves agents from work that would be rejected.

## Many agents at once

- **Git protocol v2.** New installs accept `GIT_PROTOCOL` for the hosting
  account, so Git can use protocol v2. With v2 the server lists only the
  refs a client asks for (for example only `trunk` in `git fetch origin
  trunk`), instead of every branch and tag on every connection. This
  matters when a repository collects many agent branches. Installs made
  before 0.3.0 need one manual change for this (see
  [Upgrading to 0.3.0](upgrade/0.3.0.md)). `doctor` reports whether it
  is enabled.
- **Connection bursts.** By default sshd starts dropping new connections
  at random once 10 of them are waiting to log in. If many agents fetch at
  the same moment and some fail with "Connection closed", raise the limit
  with `ssh-limits`; see
  [SSH connection limits](operations.md#ssh-connection-limits).
