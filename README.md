# internetarchive-docker

A container wrapper around the [`internetarchive`](https://pypi.org/project/internetarchive/)
Python package, so you can use the `ia` command-line tool for
[archive.org](https://archive.org) without installing Python or the package on the host.

Docs for the tool itself: <https://archive.org/developers/internetarchive/>

The container is a one-shot CLI, not a daemon. Arguments go straight to `ia`:

```bash
docker run --rm -v "$PWD/downloads:/data" ghcr.io/jeppestaerk/internetarchive-docker download nasa
```

## Quick start

```bash
# Public data needs no credentials at all
docker run --rm ghcr.io/jeppestaerk/internetarchive-docker metadata nasa

# Download into the current directory, owned by you (not root)
docker run --rm \
  -e PUID="$(id -u)" -e PGID="$(id -g)" \
  -v "$PWD:/data" \
  ghcr.io/jeppestaerk/internetarchive-docker download nasa --glob='*.jpg'
```

With Docker Compose (downloads land in `./downloads`):

```bash
cp .env.example .env      # optional - only needed for authenticated commands
docker compose run --rm ia configure
docker compose run --rm ia download nasa --glob='*.jpg'
docker compose run --rm ia search 'collection:nasa' --itemlist
```

Use `docker compose run`, not `docker compose up` — there is no long-running process.

## Credentials

Three options, resolved by the library itself in this order:

**1. Environment variables** — get keys from <https://archive.org/account/s3.php>.

```bash
docker run --rm \
  -e IA_ACCESS_KEY_ID=xxx -e IA_SECRET_ACCESS_KEY=yyy \
  ghcr.io/jeppestaerk/internetarchive-docker tasks
```

Set **both or neither**; setting only one raises a `ValueError` by design.

**2. Log in with the CLI** — see [Configuring](https://archive.org/developers/internetarchive/configuration.html).
This is usually the better option: you log in with your normal archive.org email and
password, and `ia` fetches your S3 keys *and* your `logged-in-*` session cookies. The
env vars above only ever give you S3 keys, so anything that needs a logged-in session
rather than S3 auth works with this route and not with those.

`IA_CONFIG_FILE` is preset to `/config/ia.ini`, so the login is written to whatever you
mount at `/config`. With Compose that is the `ia-config` named volume — configure once
and every later `run` picks it up:

```bash
docker compose run --rm ia configure
```

```
Enter your Archive.org credentials below to configure 'ia'.

Email address: you@example.com
Password:
Config saved to: /config/ia.ini
```

With plain `docker run` you must pass `-it`, or the password prompt has no terminal to
read from:

```bash
docker run --rm -it -v ia-config:/config ghcr.io/jeppestaerk/internetarchive-docker configure
```

Non-interactively, for scripts:

```bash
docker compose run --rm ia configure -u you@example.com -p 'your-password'
```

Careful: a password given as `-p` lands in your shell history and in `ps` output on the
host. Prefer the interactive prompt, or the env vars, for anything long-lived.

There is also `--netrc`/`-n` to log in from a `netrc` file, if you mount one.

**3. Nothing** — anonymous access still covers `download`, `metadata`, `list` and
`search` on public items. Only uploads, deletes, tasks and restricted items need keys.

### Inspecting and testing a login

All of these read the config at `/config/ia.ini`:

```bash
docker compose run --rm ia configure --show               # dump config as JSON, secrets redacted
docker compose run --rm ia configure --check              # validate S3 keys; exit 0 if valid
docker compose run --rm ia configure --whoami             # account info for the current keys
docker compose run --rm ia configure --print-cookies      # the logged-in-* cookies
docker compose run --rm ia configure --print-auth-header  # an Authorization header
```

```console
$ docker compose run --rm ia configure --show
{"s3": {"access": "testkey", "secret": "REDACTED"}, "general": {"screenname": "tester"}}
```

Re-running `ia configure` updates the credentials and leaves any options you added by
hand in place.

### Config file format

`/config/ia.ini` is plain INI, so you can also write it yourself instead of logging in:

```ini
[s3]
access = your-access-key
secret = your-secret-key

[cookies]
logged-in-user = you%40example.com
logged-in-sig = ...

[general]
screenname = you
user_agent_suffix = my-app
```

## File ownership

The main annoyance with a containerized downloader is ending up with root-owned files.
Set `PUID`/`PGID` to your host user and downloads come out owned by you:

```bash
-e PUID="$(id -u)" -e PGID="$(id -g)"
```

They default to `1000:1000`. The entrypoint chowns `/config` and `/data` (top level
only, so it stays fast on large mounts) and drops privileges via `su-exec` before
running `ia`.

`docker run --user 1000:1000` also works and bypasses the chown entirely. For a UID
other than 1000 on a fresh `/config` volume, prefer `PUID`/`PGID` — the image seeds
that volume as `1000:1000`, and `--user` skips the chown that would fix it.

## Security

**`ia` never runs as root.** Following the linuxserver.io convention, the container
starts as root only long enough to `chown` `/config` and `/data`, then drops to
`PUID:PGID` with `su-exec` before executing anything. Verify it yourself:

```console
$ docker compose run --rm --entrypoint sh ia -c 'su-exec $PUID:$PGID id'
uid=1000 gid=1000 groups=1000
```

The Compose file runs with everything else stripped away:

| Hardening | Setting |
|---|---|
| No capabilities beyond the three it provably needs | `cap_drop: [ALL]`, `cap_add: [CHOWN, SETUID, SETGID]` |
| Cannot gain privileges via setuid | `security_opt: [no-new-privileges:true]` |
| Immutable root filesystem | `read_only: true` + `tmpfs: /tmp` |

The capability list is minimal, not cargo-culted: `CHOWN` for the ownership fix,
`SETUID`+`SETGID` for the `su-exec` drop. Removing any one breaks the container, and CI
asserts the whole hardened combination still works on every build.

The image also carries **no installer toolchain** — `pip`, `setuptools`, `wheel` and the
`ensurepip` wheels are removed after `ia` is installed, since nothing installs packages
at runtime. That is both less attack surface and the reason the image scans clean:

```console
$ trivy image --scanners vuln ghcr.io/jeppestaerk/internetarchive-docker:latest
total vulnerabilities, all severities: 0
```

There are no setuid or setgid binaries in the image.

Running it hardened without Compose:

```bash
docker run --rm \
  --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges \
  --read-only --tmpfs /tmp \
  -e PUID="$(id -u)" -e PGID="$(id -g)" \
  -v "$PWD/downloads:/data" -v ia-config:/config \
  ghcr.io/jeppestaerk/internetarchive-docker download nasa
```

If you run with `--user` instead of `PUID`/`PGID`, no capabilities are needed at all —
use `--cap-drop ALL` with no `--cap-add`.

### Supply chain

- The base image is pinned by **digest** as well as tag, so a rebuild cannot silently
  pick up different content.
- GitHub Actions are pinned to **commit SHAs**, not tags, since a tag can be moved.
- Every build is **scanned with Trivy** and fails on HIGH or CRITICAL.
- Published images carry **SBOM and provenance** attestations.
- Renovate tracks the base image, the `internetarchive` release and the action pins,
  and is allowed to raise security updates outside the weekly window.

## Configuration reference

| Variable | Default | Purpose |
|---|---|---|
| `IA_ACCESS_KEY_ID` | unset | archive.org S3 access key |
| `IA_SECRET_ACCESS_KEY` | unset | archive.org S3 secret key |
| `IA_CONFIG_FILE` | `/config/ia.ini` | Where `ia configure` reads and writes |
| `PUID` / `PGID` | `1000` | Ownership of downloaded files |
| `TZ` | `Europe/Copenhagen` | Container timezone |

| Mount | Purpose |
|---|---|
| `/data` | Working directory; downloads land here |
| `/config` | Holds `ia.ini` |

## Build locally

```bash
docker compose build
# or
docker build -t internetarchive .
```

Versions are pinned as build args at the top of the `Dockerfile` and kept current by
Renovate:

- `BASE_VERSION` — the `python:X.Y.Z-alpineX.YZ` base image
- `IA_VERSION` — the `internetarchive` release on PyPI

Override at build time if needed:

```bash
docker build --build-arg IA_VERSION=5.10.0 -t internetarchive .
```

## Debugging

The entrypoint always execs `ia`, so to get a shell inside the image:

```bash
docker run --rm -it --entrypoint sh ghcr.io/jeppestaerk/internetarchive-docker
```

## License

MIT
