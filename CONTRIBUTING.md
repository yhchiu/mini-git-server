# Contributing

## Checks

Run the full local check before committing:

```bash
make check
```

The test suite is intentionally written in Bash and does not require Bats or another test framework. `shellcheck` is optional locally; GitHub Actions installs it in CI.

## Design constraints

Keep the project small and conservative:

- prefer Debian packages over third-party installers;
- preserve Gitolite's standard `gitolite-admin` workflow;
- do not silently push ACL or key changes;
- keep AI-agent permissions least-privilege by default;
- do not assume a specific primary branch name;
- do not add a database, web forge, or CI server to the Git host.
