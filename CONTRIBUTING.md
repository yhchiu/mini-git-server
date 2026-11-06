# Contributing

## Checks

There are three test suites. Which ones to run depends on what you change:

| Suite | Command | Run it when you change | Needs | Where to run it |
|---|---|---|---|---|
| [Unit](#unit-tests) | `make check` | Anything; run it before every commit | Bash, Git; optional: `shellcheck`, `python3`, `curl`, `openssl` | Any machine |
| [Integration](#integration-tests) | `sudo make test-integration` | Server commands, generated ACLs, anything that talks to Gitolite | root, `gitolite3`, `python3`, `curl` | A disposable machine or container |
| [Install end-to-end](#install-end-to-end-test) | `MGS_E2E_DISPOSABLE=1 make test-install` | `install` | Debian 13, root | A throwaway container only |

The suites are intentionally written in Bash and do not require Bats or
another test framework. To run all three in a throwaway Debian 13
container:

```bash
docker run --rm -v "$PWD:/src:ro" -w /src debian:trixie bash -c '
  apt-get update &&
  apt-get install -y --no-install-recommends ca-certificates git make shellcheck openssh-client openssh-server gitolite3 python3 curl openssl &&
  make check && make test-integration && MGS_E2E_DISPOSABLE=1 make test-install'
```

GitHub Actions runs the unit and integration tests on Ubuntu (the
integration tests in a separate `integration` job), and all three suites in
the `debian-13` job.

### Unit tests

```bash
make check
```

`make check` runs `bash -n` on every shell file, ShellCheck when it is
installed, and the unit tests (`make test` runs only the tests).
`shellcheck` is optional locally; GitHub Actions installs it in CI. The
`share` tests need `python3` and `curl` (and `openssl` for `--tls`); without
them they are reported as skipped locally, but CI always runs them.

### Integration tests

```bash
sudo make test-integration
```

The integration tests run against a real Gitolite installation. They create
a temporary hosting account and remove it afterwards. They do not start
sshd or change the SSH configuration: `tests/fake-ssh` runs each key's
forced command from the Gitolite `authorized_keys` file, the same way sshd
would. They cover installation with `--default-branch`, the admin workflow,
the generated ACL (with real pushes), `status`, `doctor`, `fsck` and
`backup`. Run them on a disposable machine or container rather than a
production Git server.

### Install end-to-end test

```bash
MGS_E2E_DISPOSABLE=1 make test-install
```

It runs the real `install` on Debian 13, then starts sshd and checks the
result over real SSH connections: host keys, Git protocol v2, the admin
workflow, access rules, `doctor`, `status` and `backup`. It also checks that
a second `install` is refused without changing anything.

> [!CAUTION]
> This test installs packages, creates the `git` account and changes
> `/etc/ssh`. It refuses to run unless `MGS_E2E_DISPOSABLE=1` is set. Run it
> only in a throwaway container, for example with the `docker run` command
> above.

## Writing tests

All test suites run each test with `set -e`: any command that fails stops
the test and marks it as failed, so a plain check such as
`[[ -f "$file" ]]` works anywhere in a test.

- To check that a command fails, wrap it:
  `if out=$(cmd 2>&1); then return 1; fi`, then check `$out`.
- Do not write `! cmd` as a check. Bash ignores the result of a negated
  command under `set -e`, so the check can never fail.
- Do not call a test function as the condition of `if`, `&&` or `||`.
  Bash turns `set -e` off there, so failing checks inside it are ignored.

## Upgrade notes

When a change needs manual steps on existing installations (server settings,
the `gitolite-admin` layout, or commands that now behave differently),
describe them in `docs/upgrade/<next-version>.md` and add a row to the
"Upgrade notes" table in [docs/upgrade/README.md](docs/upgrade/README.md).
Keep that page limited to the general steps that apply to every version.

## Documentation

The README is the entry point: what the project is, a quick start, the
command overview and links. Keep it short; put details in the topic pages
under `docs/`. When you add a command or option, update the command table
in the README, the topic page, and the `--help` text in the script.

## Design constraints

Keep the project small and conservative:

- prefer Debian packages over third-party installers;
- preserve Gitolite's standard `gitolite-admin` workflow;
- do not silently push ACL or key changes;
- keep AI-agent permissions least-privilege by default;
- do not assume a specific primary branch name;
- do not add a database, web forge, or CI server to the Git host.
