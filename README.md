# internetarchive-docker

A container wrapper around the [`internetarchive`](https://pypi.org/project/internetarchive/)
Python package, so you can use the `ia` command-line tool for
[archive.org](https://archive.org) without installing Python or the package on the host.

Docs for the tool itself: <https://archive.org/developers/internetarchive/>

The container is a one-shot CLI, not a daemon. Arguments go straight to `ia`:

```bash
docker run --rm -v "$PWD/downloads:/data" ghcr.io/jeppestaerk/internetarchive download nasa
```

## Quick start

```bash
# Public data needs no credentials at all
docker run --rm ghcr.io/jeppestaerk/internetarchive metadata nasa

# Download into the current directory, owned by you (not root)
docker run --rm \
  -e PUID="$(id -u)" -e PGID="$(id -g)" \
  -v "$PWD:/data" \
  ghcr.io/jeppestaerk/internetarchive download nasa --glob='*.jpg'
```

With Docker Compose (downloads land in `./downloads`):

```bash
cp .env.example .env      # optional - only needed for authenticated commands
docker compose run --rm ia configure
docker compose run --rm ia download nasa --glob='*.jpg'
docker compose run --rm ia search 'collection:nasa' --itemlist
```

Use `docker compose run`, not `docker compose up` — there is no long-running process.

Until the image is published to GHCR, Compose logs a harmless `error from registry:
denied` while trying to pull, then falls back to building locally.

## Credentials

Three options, resolved by the library itself in this order:

**1. Environment variables** — get keys from <https://archive.org/account/s3.php>.

```bash
docker run --rm \
  -e IA_ACCESS_KEY_ID=xxx -e IA_SECRET_ACCESS_KEY=yyy \
  ghcr.io/jeppestaerk/internetarchive tasks
```

Set **both or neither**; setting only one raises a `ValueError` by design.

**2. A persisted config file** — `IA_CONFIG_FILE` is preset to `/config/ia.ini`, so
`ia configure` writes into whatever you mount at `/config`. With Compose that is the
`ia-config` named volume, so you configure once:

```bash
docker compose run --rm ia configure
```

**3. Nothing** — anonymous access still covers `download`, `metadata`, `list` and
`search` on public items. Only uploads, deletes, tasks and restricted items need keys.

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
docker run --rm -it --entrypoint sh ghcr.io/jeppestaerk/internetarchive
```

## License

MIT
