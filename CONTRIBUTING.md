# Contributing

## Checks

Run the full local check before committing:

```bash
make check
```

The test suite is intentionally written in Bash and does not require Bats or another test framework. `shellcheck` is optional locally; GitHub Actions installs it in CI.

Changes to server commands, generated ACLs, or anything that talks to Gitolite should also pass the integration tests. They need root and the `gitolite3` package, so run them on a disposable machine or container:

```bash
sudo make test-integration
```

GitHub Actions runs them in a separate `integration` job.

## Upgrade notes

When a change needs manual steps on existing installations (server settings,
the `gitolite-admin` layout, or commands that now behave differently),
describe them in `docs/upgrade/<next-version>.md` and add a row to the
"Upgrade notes" table in the README. Keep the README upgrade section limited
to the general steps that apply to every version.

## Design constraints

Keep the project small and conservative:

- prefer Debian packages over third-party installers;
- preserve Gitolite's standard `gitolite-admin` workflow;
- do not silently push ACL or key changes;
- keep AI-agent permissions least-privilege by default;
- do not assume a specific primary branch name;
- do not add a database, web forge, or CI server to the Git host.
