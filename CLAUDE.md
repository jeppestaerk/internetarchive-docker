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
- **.github/workflows/docker-publish.yml**: multi-arch (amd64/arm64) build, pushes to GHCR, smoke-tests on PRs.
- **.github/workflows/cleanup-ghcr.yml**: weekly prune of untagged GHCR versions.

## Key Components

### Privilege dropping and file ownership

`entrypoint.sh` exists to stop downloads landing as root-owned files on the host. As
root it ensures a `PUID:PGID` user exists, chowns `/config` and `/data`, then
`exec su-exec`s down to that user. The chown is deliberately **non-recursive** — a
recursive chown would crawl the entire download mount, and files written by `ia` get
the right owner anyway.

When started with `docker run --user`, `id -u` is non-zero, the whole block is skipped,
and the entrypoint execs `ia` directly.

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
