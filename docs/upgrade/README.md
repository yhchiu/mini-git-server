# Upgrading

**English** | [繁體中文](../zh-TW/upgrade.md)

Upgrading replaces the script. It never changes access rules by itself:
existing keys and repository ACLs keep working, and Gitolite itself is not
touched. When a new version needs changes on the server or in
`gitolite-admin`, its upgrade notes list them, and you make them by hand.

Check which version you have:

```bash
./mini-git-server.sh version
```

## Upgrade notes

Read the notes of every version newer than yours, oldest first:

| Version | Upgrading from | Notes |
|---|---|---|
| 0.3.0 | 0.2.x | [0.3.0.md](0.3.0.md) |

## General steps

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
