FROM ubuntu:24.04

LABEL maintainer="Islam ElTayar <https://itayar.com>"

ARG DEBIAN_FRONTEND=noninteractive
ARG DEBCONF_NONINTERACTIVE_SEEN=true

WORKDIR /opt/dropbox

# LAN sync port
EXPOSE 17500
# Prometheus metrics port
EXPOSE 8000
# JSON status API port
EXPOSE 8001

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV LANG="C.UTF-8"
ENV LC_ALL="C.UTF-8"

# Install runtime dependencies, create user, and clean up in a single layer
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
   curl wget ca-certificates gosu tzdata \
   libc6 libatomic1 libglapi-mesa \
   libxext6 libxdamage1 libxfixes3 \
   libxcb-glx0 libxcb-dri2-0 libxcb-dri3-0 \
   libxcb-present0 libxcb-sync1 \
   libxshmfence1 libxxf86vm1 \
   python3 python3-gpg python3-pip \
 && pip3 install --no-cache-dir --break-system-packages prometheus_client==0.21.1 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/dropbox \
 && useradd --home-dir /opt/dropbox --comment "Dropbox Daemon Account" --user-group --shell /usr/sbin/nologin dropbox \
 && chown -R dropbox:dropbox /opt/dropbox

VOLUME ["/opt/dropbox"]

ARG VCS_REF=main
ARG VERSION=""
ARG BUILD_DATE=""

LABEL org.opencontainers.image.title="Dropbox"
LABEL org.opencontainers.image.description="Standalone Dropbox client in Docker"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.source="https://github.com/islamdiaa/dropbox-docker"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.licenses="MIT"

# Configurable settings
ENV POLLING_INTERVAL=5
ENV SKIP_SET_PERMISSIONS=true
ENV ENABLE_MONITORING=false
ENV DROPBOX_MAX_RESTARTS=5
ENV DROPBOX_RESTART_DELAY=10
ENV DROPBOX_STARTUP_TIMEOUT=300

COPY docker-entrypoint.sh /
COPY monitoring.py /

HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
  CMD ["bash", "-c", "gosu dropbox dropbox status | head -1 || exit 1"]

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/opt/dropbox/bin/dropboxd"]
