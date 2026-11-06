# Identities and keys

**English** | [繁體中文](zh-TW/identities.md)

Gitolite decides who you are only from the SSH key that connects. Any process
that can use a key **is** that identity. The server-side access rules
therefore protect you only as far as the keys are kept apart on the client
side.

- [Three kinds of identities](#three-kinds-of-identities)
- [Keeping agent keys apart](#keeping-agent-keys-apart)
- [Moving admin rights to a separate identity](#moving-admin-rights-to-a-separate-identity)

## Three kinds of identities

| Identity | Example | Access | Where the private key lives |
|---|---|---|---|
| Admin | `arthur-admin` | `gitolite-admin` only | Admin workstation; preferably a FIDO2 key (`-sk`) |
| Daily (owner) | `arthur` | Owner of your repositories | Your workstations |
| Agent | `agent-impl` | `agent/agent-impl/*`, read elsewhere | Only the agent's own environment |

The admin identity should not be an owner, writer, agent or reader of any
repository, and no AI agent should ever be able to use the admin or daily
keys.

## Keeping agent keys apart

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

Put the `known_hosts` lines from
[`host-keys`](install.md#server-host-keys) into that file when you set up
the agent environment. With `StrictHostKeyChecking yes` the agent refuses an
unknown or changed host key, instead of waiting at a prompt or being told to
turn the check off.

To check which identity an agent really has, run `ssh internal-git info` in
its environment; see [Agent workflow](agents.md#agent-workflow).

## Moving admin rights to a separate identity

Examples before 0.3.0 used the same name for the admin and the daily
identity. To move admin rights to `arthur-admin` without locking yourself
out:

1. Create the admin key ([step 1 of the installation](install.md#1-generate-a-dedicated-admin-key))
   and add it:

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
