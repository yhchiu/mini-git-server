# One-off deploys with `share`

A machine that needs the code only once, for example for a one-off deploy,
does not need a key of its own. Run `share` on a machine that can read the
repository, such as your workstation, and run the command it prints on the
target.

> [!TIP]
> If you can log in to the target over SSH anyway, you do not need `share`.
> Stream the archive over that connection instead:
>
> ```bash
> git archive --remote=internal-git:project-x --format=tar trunk | ssh web-1 'mkdir -p /srv/app && tar -x -C /srv/app'
> ```

## Usage

```bash
/path/to/mini-git-server.sh share \
  --from internal-git:project-x \
  --ref trunk \
  --bind 10.0.0.5
```

```text
[INFO] Exporting 'trunk' from internal-git:project-x
Sharing project-x-trunk.tar.gz (13M) until 2026-11-04 11:59:41, or after 1 download. Press Ctrl-C to stop earlier.

URL:     http://10.0.0.5:40719/5d74b83578475deaead8f86fdfc6becc/project-x-trunk.tar.gz
SHA-256: 29d8a7d51554e73e7837be043843c912a8b266073d823f807a33881d919fd91a

On the target:
  curl -fsS -o 'project-x-trunk.tar.gz' 'http://10.0.0.5:40719/5d74b83578475deaead8f86fdfc6becc/project-x-trunk.tar.gz' && echo '29d8a7d51554e73e7837be043843c912a8b266073d823f807a33881d919fd91a  project-x-trunk.tar.gz' | sha256sum -c - && tar -xzf 'project-x-trunk.tar.gz'
```

Requirements:

- The target only needs `curl`, `sha256sum` and `tar` (or `unzip`).
- The machine that runs `share` needs `python3` (and `openssl` for `--tls`).
- The target must be able to reach it: `share` does not change any firewall.

## Options

| Option | Effect |
|---|---|
| `--bind ADDRESS` | **Required.** The address to listen on; see [Security notes](#security-notes) |
| `--depth N` | Include `.git` with the last N commits, so the target gets a shallow clone instead of only the files. The remote and the reflog, which name the Git server, are removed. |
| `--format zip` | A zip archive instead of tar.gz, for example for a Windows target |
| `--tls` | HTTPS with a throwaway self-signed certificate. The printed command pins its key, so no CA is involved. |
| `--max-downloads N` | Allow N complete downloads, for several targets; `0` means no limit until the time limit |
| `--ttl TIME` | Stop after `90s`, `30m`, `2h` and so on; at most `24h` |
| `--port PORT`, `--url-host NAME` | A fixed port, for example for a firewall rule, and the host name to print in the URL |

## How it works

`share`:

1. exports the branch or tag with `git archive` through Gitolite, using
   your own identity, so it can only share what you can read;
2. serves the archive at a URL that contains 128 random bits, and answers
   every other path with 404;
3. stops after 30 minutes (`--ttl`), after one complete download
   (`--max-downloads`), or on Ctrl-C, and then removes everything it
   created.

The archive is removed from the disk as soon as the server has opened it,
and the server stops by itself within about a second when `share` is gone.
So once the URL is printed, even `kill -9` leaves nothing behind but an
empty temporary directory.

## Security notes

- **Without `--tls`, the network can read the archive and change it in
  transit.** The printed command checks the SHA-256 checksum. That only
  helps if the command reaches the target over a channel you trust, for
  example your SSH session or the console. On networks you do not trust,
  use `--tls`.
- **The URL is the only secret.** Anyone who has it can download the
  archive until the share stops, so keep `--max-downloads` low. `share`
  does not log the token or pass it on any command line. On the target,
  however, the URL is in the shell history, and in the process list while
  curl runs, and a proxy in between may log it.
- **`--bind` is required.** Listen on the address the target uses. With
  `0.0.0.0` or `::`, `share` also listens on every other network the
  machine is on, for example a public Wi-Fi.
- `share` removes only what it created. The copy on the target is yours to
  remove.
- Submodules are not included, and Git LFS files contain only their
  pointers.

## Targets in another network

A target in another network may not reach your workstation. Run `share` on
a host that it can reach, or forward the port over SSH. A public tunnel
service also works with `--bind 127.0.0.1`, but then the code passes
through that service, and anyone on the internet who has the URL can
download it.
