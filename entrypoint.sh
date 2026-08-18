#!/bin/sh
# Entrypoint for the containerized `ia` CLI.
#
# Its only job is file ownership: downloads must land on the host bind mount
# owned by the invoking user rather than by root. When started as root we make
# /config and /data writable by PUID:PGID and drop privileges before exec'ing
# `ia`. When started with `--user`, we are already unprivileged and just exec.
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

if [ "$(id -u)" = "0" ]; then
    if ! getent group "$PGID" >/dev/null 2>&1; then
        addgroup -g "$PGID" ia
    fi
    group_name="$(getent group "$PGID" | cut -d: -f1)"

    if ! getent passwd "$PUID" >/dev/null 2>&1; then
        adduser -D -H -u "$PUID" -G "$group_name" -h /config ia
    fi

    # Top level only. A recursive chown would crawl the whole download mount,
    # and files created by `ia` are owned by PUID:PGID anyway.
    chown "$PUID:$PGID" /config /data 2>/dev/null || true

    exec su-exec "$PUID:$PGID" ia "$@"
fi

exec ia "$@"
