#!/bin/sh
# Entrypoint for the containerized `ia` CLI, following the linuxserver.io
# PUID/PGID convention: start as root only long enough to fix ownership, then
# drop to an unprivileged user for the actual work. `ia` itself never runs as
# root.
#
# No addgroup/adduser here on purpose. su-exec takes numeric ids directly, so
# skipping the /etc/passwd and /etc/group writes lets the container run with a
# read-only root filesystem.
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

if [ "$(id -u)" = "0" ]; then
    # Top level only. A recursive chown would crawl the whole download mount,
    # and files created by `ia` are owned by PUID:PGID anyway.
    chown "$PUID:$PGID" /config /data 2>/dev/null || true

    exec su-exec "$PUID:$PGID" ia "$@"
fi

# Already unprivileged (docker run --user). Nothing to drop.
exec ia "$@"
