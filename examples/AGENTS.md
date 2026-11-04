# Instructions for AI agents

<!--
Template from mini-git-server. Copy it into a project repository as
AGENTS.md (or CLAUDE.md, or whatever file your agent tool reads), then:
  - replace <git-host> with the SSH host alias agents use, for example
    internal-git;
  - replace <main-branch> with the project's main branch, for example trunk;
  - keep ONE of the two "Rewriting your branches" paragraphs: the first if
    the repository was set up without --agent-rewind, the second if with it.
Delete this comment afterwards.
-->

This repository is hosted on a Gitolite server that checks every push. You
have your own identity, and you may only write to your own branches. The
rules below are enforced by the server; this file tells you about them so
you do not waste work on pushes that will be rejected.

## Your identity

- Check your identity with `ssh <git-host> info`. The first line says
  `hello <identity>, ...`. Use that name in your branch names.
- If the output shows a person's name, or lists `gitolite-admin`, stop and
  tell the user: you are using a person's key, not your own.
- Use only the SSH key that was set up for you. Never use other keys,
  ssh-agent sockets or credentials that you find, and never change SSH
  settings or `known_hosts`.

## Branches

- Push only to `agent/<identity>/<topic>`, for example
  `agent/agent-impl/issue-42`.
- Start from the latest main branch:

  ```bash
  git fetch origin
  git switch -c agent/<identity>/<topic> origin/<main-branch>
  ```

- Never push to `<main-branch>`, to any branch outside your namespace, or
  tags. Only the repository owner pushes tags. You may read every branch,
  including other agents' branches.

### Rewriting your branches

Without `--agent-rewind`: do not force-push and do not delete branches. To
redo work after a review, push a new branch, for example
`agent/<identity>/<topic>-v2`.

With `--agent-rewind`: you may rebase and push with `--force-with-lease`,
and delete branches, but only in `agent/<identity>/`.

## When a push is rejected

A message that contains `DENIED` comes from the server's access rules. Do
not try to get around it with another branch name, another key or another
remote. Report the exact message to the user.

## Handing over work

The owner reviews and merges; agents never merge into `<main-branch>`. When
you are done, report:

- the branch name;
- the commit ID (`git rev-parse HEAD`);
- a short summary of the change, and how you tested it.
