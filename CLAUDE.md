# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository containerizes the [`internetarchive`](https://pypi.org/project/internetarchive/)
Python package so the `ia` CLI for archive.org can be run without a host Python install.
Upstream docs: <https://archive.org/developers/internetarchive/>

Unlike most images in the wider `Docker/` tree, this is **not a service**. There is no
daemon, no exposed port, and no `docker compose up`. The container runs one `ia`
command and exits.

## Architecture

- **Dockerfile**: `python:*-alpine` base, pins `internetarchive` via `ARG IA_VERSION`, installs `su-exec` for privilege dropping. `ENTRYPOINT` is `entrypoint.sh`, `CMD` is `--help`, so container args are `ia` args.
- **entrypoint.sh**: the only logic in the repo. Handles file ownership, then `exec`s `ia`.
- **docker-compose.yaml**: a single `ia` service intended for `docker compose run --rm ia <args>`.
- **renovate.json**: custom regex managers for the two `ARG` versions in the Dockerfile.
- **.github/workflows/docker-publish.yml**: two jobs. `verify` builds amd64 with `load: true` (multi-arch images cannot be loaded into the daemon), smoke-tests it, asserts the hardened run still drops privileges, then gates on a Trivy scan. `build-and-push` needs `verify` and does the multi-arch push to GHCR.
- **.github/workflows/cleanup-ghcr.yml**: weekly prune of untagged GHCR versions.

Actions are pinned to commit SHAs with a trailing `# vX.Y.Z` comment. Renovate reads
that comment to offer updates. Keep the comment accurate if you ever repin by hand.

## Key Components

### Privilege dropping and file ownership

`entrypoint.sh` exists to stop downloads landing as root-owned files on the host. This
is the linuxserver.io PUID/PGID convention: as root it chowns `/config` and `/data`,
then `exec su-exec`s down to `PUID:PGID`. `ia` itself never runs as root. The chown is
deliberately **non-recursive** — a recursive chown would crawl the entire download
mount, and files written by `ia` get the right owner anyway.

When started with `docker run --user`, `id -u` is non-zero, the whole block is skipped,
and the entrypoint execs `ia` directly.

**Do not reintroduce `addgroup`/`adduser`.** An earlier version created a passwd/group
entry for `PUID:PGID` before dropping. It is unnecessary — `su-exec` takes numeric ids
directly — and it writes to `/etc/passwd`, which makes the container fail immediately
under `read_only: true` with `adduser: /etc/passwd: Read-only file system`.

### Hardening and the capability set

The Compose service runs with `cap_drop: [ALL]` plus exactly `CHOWN`, `SETUID`,
`SETGID`, `no-new-privileges:true`, `read_only: true` and a `/tmp` tmpfs.

That capability list was derived by testing, not guessed. With no `cap_add` the
container dies at `su-exec: setgroups(...): Operation not permitted`. `CHOWN` covers the
ownership fix; `SETUID`/`SETGID` cover the `su-exec` drop. If the entrypoint ever needs
another capability, that is a signal to question the change, not to widen the list. The
`verify` CI job asserts the full hardened combination still produces a file owned by
`4242:4242`, so a regression fails the build.

Note that `--user` and `PUID`/`PGID` need different capabilities: with `--user` the root
branch never runs, so zero capabilities are required.

### No installer toolchain in the runtime image

The Dockerfile removes `pip`, `setuptools`, `wheel`, `pkg_resources` and `ensurepip`
after installing `ia`. Two reasons: nothing installs packages at runtime, and those were
the only components Trivy flagged (pip vendors a vulnerable `msgpack`, and `setuptools`
70.3.0 carries CVE-2025-47273). With them gone the image scans clean at all severities.

Consequence: you cannot `pip install` inside this image. To add a Python dependency, add
it to the `pip install` line in the Dockerfile and rebuild.

### Why the Dockerfile chowns /config and /data at build time

Docker seeds an empty named volume with the ownership of the corresponding image
directory, and re-applies it on **every** mount while the volume stays empty. Since the
`--user` path skips the entrypoint chown, a fresh `/config` volume would come up
root-owned and `ia configure` would fail with EACCES. Building the dirs as `1000:1000`
makes the default `--user 1000:1000` case work.

This also means inspecting an empty volume from a throwaway container reports the
*image's* ownership, not the last chown — a misleading result when debugging ownership.

### Credential resolution

Handled entirely by the library, not by this repo. Precedence:

1. `IA_ACCESS_KEY_ID` + `IA_SECRET_ACCESS_KEY` env vars
2. `$IA_CONFIG_FILE` (preset to `/config/ia.ini` in the image)
3. `$XDG_CONFIG_HOME/internetarchive/ia.ini`, `~/.config/ia.ini`, `~/.ia`

Setting exactly one of the two env vars raises a `ValueError` upstream. Empty strings
are falsy there, so the `${VAR:-}` defaults in docker-compose.yaml safely fall through
to the config file. Do not add entrypoint logic to synthesize an `ia.ini` from the env
vars — the library reads them natively.

### CLI login vs. env vars

`ia configure` logs in with an archive.org email and password and writes both the `[s3]`
keys and the `[cookies]` `logged-in-user` / `logged-in-sig` session cookies to
`$IA_CONFIG_FILE`. The env vars only ever supply S3 keys, so they cannot cover anything
that needs a logged-in session. When a user reports that an operation works in a browser
but not in the container, check whether they configured via env vars and therefore have
no cookies.

Relevant flags, all verified present in 5.11.0: `-u/--username`, `-p/--password`,
`-n/--netrc`, `-s/--show`, `-C/--check`, `-w/--whoami`, `-c/--print-cookies`,
`-a/--print-auth-header`.

Interactive `ia configure` needs a TTY. `docker compose run` allocates one by default;
plain `docker run` needs an explicit `-it` or the password prompt dies on EOF with a
traceback. Upstream docs: <https://archive.org/developers/internetarchive/configuration.html>

### Why alpine works without a build toolchain

The runtime dependencies (`requests`, `urllib3`, `tqdm`, `jsonpatch`) are pure Python,
so there are no musl wheel problems and no compiler needed, including on arm64.

## Common Commands

```bash
# Build
docker compose build
docker build -t internetarchive .

# Run (note: run, not up)
docker compose run --rm ia --version
docker compose run --rm ia configure
docker compose run --rm ia download nasa --glob='*.jpg'

# Shell inside the image (the entrypoint otherwise always execs ia)
docker run --rm -it --entrypoint sh internetarchive
```

### Smoke tests

There is no test suite; verification is done against a built image:

```bash
docker run --rm internetarchive --version
docker run --rm internetarchive metadata nasa            # anonymous, no credentials
docker run --rm -e PUID=1234 -e PGID=1234 -v vol:/data \
  internetarchive download nasa nasa_meta.xml            # then check the file is 1234:1234
```

When checking ownership, write a file into the volume first — see the empty-volume
caveat above.

### Updating versions

`BASE_VERSION` (python image) and `IA_VERSION` (PyPI) are `ARG`s at the top of the
Dockerfile, tracked by Renovate. `IA_VERSION` uses the **pypi** datasource, not
github-releases. Note that `BASE_VERSION` is declared twice — once before `FROM` for
the base image, once after so the OCI label can reference it.
