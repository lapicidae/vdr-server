FROM archlinux:latest

ARG inVM="true" \
    LANGUAGE="en_US:en_GB:en" \
    authors="A. Hemmerle <github.com/lapicidae>" \
    miniVers="false" \
    S6VER="3.2.0.2" \
    baseDigest \
    dateTime \
    vdrRevision \
    vdrVersion

ENV PATH="$PATH:/command:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl"
ENV LANG="en_US.UTF-8" \
    TZ="Europe/London" \
    DISABLE_WEBINTERFACE="${miniVers}" \
    S6_VERBOSITY="1"

ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/s6-overlay-noarch.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/s6-overlay-x86_64.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/syslogd-overlay-noarch.tar.xz /tmp

COPY build/ /

RUN /usr/bin/bash -c '/install.sh'

WORKDIR /vdr

HEALTHCHECK --interval=5m --start-period=10s \
  CMD /usr/local/bin/healthy

LABEL org.opencontainers.image.authors=${authors} \
      org.opencontainers.image.base.digest=${baseDigest} \
      org.opencontainers.image.base.name="docker.io/archlinux:latest" \
      org.opencontainers.image.created=${dateTime} \
      org.opencontainers.image.description="Video Disc Recorder (VDR) for playback and recording of television programmes" \
      org.opencontainers.image.documentation="https://github.com/lapicidae/vdr-server/blob/master/README.md" \
      org.opencontainers.image.licenses="GPL-2.0-or-later AND GPL-3.0-only AND GPL-3.0-or-later" \
      org.opencontainers.image.revision=${vdrRevision} \
      org.opencontainers.image.source="https://github.com/lapicidae/vdr-server/" \
      org.opencontainers.image.title="VDR Server" \
      org.opencontainers.image.url="https://github.com/lapicidae/vdr-server/blob/master/README.md" \
      org.opencontainers.image.version=${vdrVersion}

EXPOSE 3000 8008 34890

VOLUME ["/vdr/cache", "/vdr/config", "/vdr/recordings", "/vdr/system"]

ENTRYPOINT ["/init"]
