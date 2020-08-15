FROM archlinux/base:latest

LABEL maintainer="lapicidae"

WORKDIR /tmp

ENV LANG="de_DE.UTF-8" \
    LANGUAGE="de_DE:de" \
    TZ="Europe/Berlin"

ADD https://github.com/just-containers/s6-overlay/releases/download/v2.0.0.1/s6-overlay-amd64.tar.gz /tmp/

ADD https://github.com/just-containers/socklog-overlay/releases/download/v3.1.0-2/socklog-overlay-amd64.tar.gz /tmp/

COPY build/ /

RUN echo "**** add the vdr4arch repository ****" && \
    echo -e "[vdr4arch]\nServer = https://vdr4arch.github.io/\$arch\nSigLevel = Never" >> /etc/pacman.conf && \
    pacman -Sy && \
    echo "**** timezone and locale ****" && \
    rm -f /etc/locale.gen && \
    pacman -S glibc --overwrite=* --noconfirm && \
    rm -f /etc/localtime && \
    ln -s /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    sed -i '/en_US.UTF-8/s/^# *//' /etc/locale.gen && \
    sed -i "/$LANG/s/^# *//" /etc/locale.gen && \
    locale-gen && \
    echo 'LANG='$LANG > /etc/locale.conf && \
    echo "**** install runtime packages ****" && \
    pacman -S --noconfirm \
      binutils \
      gawk \
      grep \
      tar \
      ttf-vdrsymbols \
      unison \
      vdr \
      vdr-dvbapi \
      vdr-streamdev-server \
      vdr-vnsiserver && \
    echo "**** install build packages ****" && \
    pacman -S --noconfirm --needed \
      base-devel \
      git \
      sudo && \
    echo "**** add builduser ****" && \
    useradd -m -d /build -s /bin/bash builduser && \
    echo -e "root ALL=(ALL) ALL\nbuilduser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers && \
    echo "**** install vdrctl ****" && \
    pacman -S --noconfirm perl-pod-parser && \
    sudo -u builduser bash -c ' \
      git clone https://aur.archlinux.org/vdrctl.git && \
      cd vdrctl && \
      makepkg -s' && \
    pacman -U /tmp/vdrctl/vdrctl*.pkg.tar.zst --noconfirm && \
    echo "**** install ddci2 ****" && \
    sudo -u builduser bash -c ' \
      git init vdr-ddci2 && \
      cd vdr-ddci2 && \
      git remote add origin https://github.com/VDR4Arch/vdr4arch.git && \
      git config core.sparsecheckout true && \
      git config pull.rebase false && \
      echo "plugins/vdr-ddci2/*" >> .git/info/sparse-checkout && \
      git pull origin master && \
      cd plugins/vdr-ddci2 && \
      sed -i "s/vdr-api=/vdr-api>=/g" PKGBUILD && \
      makepkg -s' && \
    pacman -U /tmp/vdr-ddci2/plugins/vdr-ddci2/vdr-ddci2*.pkg.tar.zst --noconfirm && \
    echo "**** install ciplus ****" && \
    git clone https://github.com/lmaresch/vdr-ciplus.git && \
    cd vdr-ciplus && \
    sed -i "s/vdr-api=/vdr-api>=/g" PKGBUILD && \
    awk '1;/prepare()/{c=2}c&&!--c{print "  patch -p1 < /tmp/addlib.patch"}' PKGBUILD > tmp && mv tmp PKGBUILD && \
    chown -R builduser /tmp/vdr-ciplus && \
    sudo -u builduser bash -c ' \
      makepkg -s' && \
    pacman -U /tmp/vdr-ciplus/vdr-ciplus*.pkg.tar.zst --noconfirm && \
    echo "**** install s6-overlay ****" && \
    tar xzf /tmp/s6-overlay-amd64.tar.gz -C / --exclude='./bin' && tar xzf /tmp/s6-overlay-amd64.tar.gz -C /usr ./bin && \
    tar xzf /tmp/socklog-overlay-amd64.tar.gz -C / && \
    echo "**** folders and symlinks ****" && \
    mkdir -p /vdr && \
    mkdir -p /vdr/config/cache && \
    mkdir -p /vdr/config/etc && \
    mkdir -p /vdr/config/lib && \
    ln -s /var/cache/vdr/epgimages /vdr/epgimages && \
    ln -s /srv/vdr/video /vdr/recordings && \
    echo "**** vdr config ****" && \
    mv /etc/vdr/conf.avail/50-ddci2.conf /etc/vdr/conf.avail/10-ddci2.conf && \
    mv /etc/vdr/conf.avail/50-dvbapi.conf /etc/vdr/conf.avail/20-dvbapi.conf && \
    mv /etc/vdr/conf.avail/50-ciplus.conf /etc/vdr/conf.avail/30-ciplus.conf && \
    echo "**** cleanup ****" && \
    userdel -r -f builduser && \
    pacman -Rsu --noconfirm \
      autoconf \
      automake \
      bison \
      fakeroot \
      file \
      flex \
      gcc \
      gettext \
      git \
      groff \
      libtool \
      m4 \
      make \
      patch \
      pkgconf \
      sudo \
      texinfo \
      which && \
    pacman -R --noconfirm \
      argon2 \
      cryptsetup \
      device-mapper \
      hwids \
      iptables \
      json-c \
      kbd \
      kmod \
      libnetfilter_conntrack \
      libnftnl \
      libpcap \
      libseccomp \
      pcre2 \
      popt \
      util-linux \
      systemd && \
    pacman -Scc --noconfirm && \
    rm -rf /tmp/* /var/tmp/* /etc/sudoers* && \
    echo "**** refresh package databases ****" && \
    pacman -Sy

COPY root/ /

WORKDIR /vdr

EXPOSE 2004 3000 6419 6419/udp 8008 8009 34890

VOLUME ["/vdr/config", "/vdr/epgimages", "/vdr/recordings"]

ENTRYPOINT ["/init"]
