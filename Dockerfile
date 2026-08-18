ARG BASE_IMAGE=python
ARG BASE_VERSION=3.14.7-alpine3.24

FROM ${BASE_IMAGE}:${BASE_VERSION}

# Redeclare so the value is visible after FROM (for the OCI label below)
ARG BASE_VERSION

ARG IA_VERSION=5.11.0

# su-exec drops privileges in the entrypoint; tzdata makes TZ meaningful
RUN apk add --no-cache \
    tzdata \
    su-exec && \
    rm -rf /var/cache/apk/*

# Install the internetarchive CLI. All runtime deps (requests, urllib3, tqdm,
# jsonpatch) are pure Python, so no build toolchain is needed on any arch.
RUN pip install --no-cache-dir "internetarchive==${IA_VERSION}" && \
    rm -rf /root/.cache

# /config holds ia.ini (written by `ia configure`), /data is the download target
ENV IA_CONFIG_FILE=/config/ia.ini \
    HOME=/config \
    PUID=1000 \
    PGID=1000

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
LABEL maintainer="Jeppe Stærk"
