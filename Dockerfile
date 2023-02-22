FROM archlinux:latest

ARG maintainer="lapicidae <github.com/lapicidae>" \
    S6VER="3.1.4.1" \
    miniVers="false" \
    inVM="true" \
    LANGUAGE="en_US:en_GB:en"

ENV PATH="$PATH:/command:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl"
ENV LANG="en_US.UTF-8" \
    TZ="Europe/London" \
    DISABLE_WEBINTERFACE="${miniVers}" \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME="0" \
    S6_VERBOSITY="1"

ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/s6-overlay-noarch.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/s6-overlay-x86_64.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/syslogd-overlay-noarch.tar.xz /tmp

COPY build/ /

RUN /usr/bin/bash -c '/install.sh'

WORKDIR /vdr

HEALTHCHECK --interval=5m --start-period=10s \
  CMD /usr/local/bin/healthy

LABEL maintainer=$maintainer

EXPOSE 3000 8008 34890

VOLUME ["/vdr/cache", "/vdr/config", "/vdr/recordings", "/vdr/system"]

ENTRYPOINT ["/init"]
