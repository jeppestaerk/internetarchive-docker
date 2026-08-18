ARG BASE_IMAGE=python
ARG BASE_VERSION=3.14.7-alpine3.24
ARG BASE_DIGEST=sha256:05b2b8b732ecd268fee8727a369f936f022d1321b59befd13c30ede22769dcdc

# Pinned by digest as well as tag, so a rebuild cannot silently pick up a
# different base image. Renovate keeps the pair in sync.
FROM ${BASE_IMAGE}:${BASE_VERSION}@${BASE_DIGEST}

# Redeclare so the values are visible after FROM (for the OCI labels below)
ARG BASE_VERSION
ARG BASE_DIGEST

ARG IA_VERSION=5.11.0

# su-exec drops privileges in the entrypoint; tzdata makes TZ meaningful
RUN apk add --no-cache \
    tzdata \
    su-exec && \
    rm -rf /var/cache/apk/*

# Install the internetarchive CLI. All runtime deps (requests, urllib3, tqdm,
# jsonpatch) are pure Python, so no build toolchain is needed on any arch.
#
# Then remove the installer toolchain. `ia` is already installed and nothing in
# the container installs packages at runtime, so pip (with its vendored
# msgpack), setuptools and the ensurepip wheels are pure attack surface - and
# they are the only things the base image gets flagged for.
RUN pip install --no-cache-dir "internetarchive==${IA_VERSION}" && \
    python -m pip uninstall -y pip setuptools wheel 2>/dev/null || true; \
    rm -rf /root/.cache \
           /usr/local/lib/python*/site-packages/pip* \
           /usr/local/lib/python*/site-packages/setuptools* \
           /usr/local/lib/python*/site-packages/pkg_resources \
           /usr/local/lib/python*/site-packages/wheel* \
           /usr/local/lib/python*/ensurepip \
           /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.*

# /config holds ia.ini (written by `ia configure`), /data is the download target
ENV IA_CONFIG_FILE=/config/ia.ini \
    HOME=/config \
    PUID=1000 \
    PGID=1000 \
    PYTHONDONTWRITEBYTECODE=1

# Own these as the default PUID/PGID at build time. Docker seeds an empty named
# volume with the image directory's ownership, so this is what makes
# `docker run --user 1000:1000` work against a fresh /config volume - that path
# skips the entrypoint's chown.
RUN mkdir -p /config /data && \
    chown 1000:1000 /config /data

VOLUME [ "/config", "/data" ]
WORKDIR /data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Arguments are passed straight through to `ia`, e.g.
#   docker run --rm -v "$PWD:/data" IMAGE download nasa
#
# The entrypoint starts as root purely to chown /config and /data, then drops to
# PUID:PGID via su-exec. `ia` itself never runs as root. See README "Security".
ENTRYPOINT ["/entrypoint.sh"]
CMD ["--help"]

# OCI Image Labels - https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.title="Internet Archive CLI"
LABEL org.opencontainers.image.description="Containerized ia command-line tool for archive.org (internetarchive Python package)"
LABEL org.opencontainers.image.authors="Jeppe Stærk"
LABEL org.opencontainers.image.url="https://github.com/jeppestaerk/internetarchive-docker"
LABEL org.opencontainers.image.source="https://github.com/jeppestaerk/internetarchive-docker"
LABEL org.opencontainers.image.documentation="https://github.com/jeppestaerk/internetarchive-docker/blob/main/README.md"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.vendor="Jeppe Stærk"
LABEL org.opencontainers.image.version="${IA_VERSION}"
LABEL org.opencontainers.image.base.name="docker.io/library/python:${BASE_VERSION}"
LABEL org.opencontainers.image.base.digest="${BASE_DIGEST}"
LABEL maintainer="Jeppe Stærk"
