FROM archlinux:latest

LABEL maintainer="lapicidae"

WORKDIR /tmp

ENV LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en_GB:en" \
    TZ="Europe/London"

ADD https://github.com/just-containers/s6-overlay/releases/download/v2.1.0.2/s6-overlay-amd64-installer /tmp/

ADD https://github.com/just-containers/socklog-overlay/releases/download/v3.1.0-2/socklog-overlay-amd64.tar.gz /tmp/

COPY build/ /

RUN echo "**** configure pacman ****" && \
    sed -i 's/.*NoExtract.*/NoExtract   = usr\/share\/doc\/* usr\/share\/help\/* usr\/share\/info\/* usr\/share\/man\/*/' /etc/pacman.conf && \
    echo "**** add the vdr4arch repository ****" && \
    echo -e "[vdr4arch]\nServer = https://vdr4arch.github.io/\$arch\nSigLevel = Never" >> /etc/pacman.conf && \
    pacman -Sy && \
    #echo "**** rebuild trust database (keyring update error workaround) ****" && \#
    #rm -fr /etc/pacman.d/gnupg && \#
    #pacman-key --init && \#
    #pacman-key --populate archlinux && \#
    #echo "**** update ****" && \#
    #pacman -Su --noconfirm && \#
    echo "**** timezone and locale ****" && \
    rm -f /etc/locale.gen && \
    pacman -S glibc --overwrite=* --noconfirm && \
    rm -f /etc/localtime && \
    ln -s /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    sed -i '/#  /d' /etc/locale.gen && \
    sed -i '/en_US.UTF-8/s/^# *//' /etc/locale.gen && \
    sed -i "/$LANG/s/^# *//" /etc/locale.gen && \
    echo 'LANG='$LANG > /etc/locale.conf && \
    locale-gen && \
    echo "**** install runtime packages ****" && \
    pacman -S --noconfirm \
      binutils \
      busybox \
      msmtp-mta \
      naludump \
      ttf-vdrsymbols \
      unison \
      vdr \
      vdr-dvbapi \
      vdr-streamdev-server \
      vdr-vnsiserver && \
    pacman -D --asexplicit \
      shadow && \
    echo "**** install build packages ****" && \
    pacman -S --noconfirm --needed \
      base-devel \
      gawk \
      git \
      procps-ng \
      sudo \
      tar && \
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
    chmod +x /tmp/s6-overlay-amd64-installer && /tmp/s6-overlay-amd64-installer / && \
    tar xzf /tmp/socklog-overlay-amd64.tar.gz -C / && \
    echo "**** folders and symlinks ****" && \
    mkdir -p /vdr/config && \
    ln -s /vdr /home/vdr && \
    [ -d /var/cache/vdr/epgimages ] || mv /var/cache/vdr/epgimages /vdr/epgimages && \
    [ -d /var/cache/vdr ] || mv /var/cache/vdr /vdr/config/cache && \
    [ -d /srv/vdr/video ] || mv /srv/vdr/video /vdr/recordings && \
    [ -d /etc/vdr ] || mv /etc/vdr /vdr/config/etc && \
    [ -d /var/lib/vdr ] && mv /var/lib/vdr /vdr/config/lib && \
    ln -s /vdr/epgimages /var/cache/vdr/epgimages && \
    ln -s /vdr/recordings /srv/vdr/video  && \
    ln -s /vdr/config/cache /var/cache/vdr && \
    ln -s /vdr/config/etc /etc/vdr && \
    ln -s /vdr/config/lib /var/lib/vdr && \
    ln -s /usr/lib/vdr/bin/shutdown-wrapper /usr/bin/shutdown-wrapper && \
    ln -s /usr/lib/vdr/bin/vdr-recordingaction /usr/bin/vdr-recordingaction && \
    echo "**** vdr config ****" && \
    mv /etc/vdr/conf.avail/50-ddci2.conf /etc/vdr/conf.avail/10-ddci2.conf && \
    mv /etc/vdr/conf.avail/50-dvbapi.conf /etc/vdr/conf.avail/20-dvbapi.conf && \
    mv /etc/vdr/conf.avail/50-ciplus.conf /etc/vdr/conf.avail/30-ciplus.conf && \
    echo "**** SMTP client config ****" && \
    curl -o /etc/msmtprc "https://git.marlam.de/gitweb/?p=msmtp.git;a=blob_plain;f=doc/msmtprc-system.example" && \
    chmod 600 /etc/msmtprc && \
    echo "**** cleanup ****" && \
    userdel -r -f builduser && \
    pacman -Rsu --noconfirm \
      autoconf \
      automake \
      bison \
      fakeroot \
      file \
      flex \
      gawk \
      gcc \
      gettext \
      git \
      grep \
      groff \
      gzip \
      libseccomp \
      libtool \
      m4 \
      make \
      patch \
      procps-ng \
      sed \
      sudo \
      tar \
      texinfo \
      which && \
    pacman -R --noconfirm \
      argon2 \
      base \
      cryptsetup \
      dbus \
      device-mapper \
      hwids \
      iptables \
      iproute2 \
      json-c \
      kbd \
      kmod \
      libmnl \
      libnetfilter_conntrack \
      libnfnetlink \
      libnftnl \
      libnl \
      libpcap \
      pcre2 \
      popt \
      pciutils \
      systemd \
      systemd-sysvcompat \
      util-linux && \
    pacman -Scc --noconfirm && \
    rm -rf \
      /etc/pacman.d/gnupg/pubring.gpg~ \
      /etc/sudoers* \
      /tmp/* \
      /usr/include/* \
      /usr/share/doc/* \
      /usr/share/help/* \
      /usr/share/info/* \
      /usr/share/man/* \
      /var/tmp/* && \
    find /etc -type f -name "*.pacnew" -delete && \
    find /etc -type f -name "*.pacsave" -delete && \
    echo "**** refresh package databases ****" && \
    pacman -Sy && \
    echo "**** install busybox ****" && \
    busybox --install -s

COPY root/ /

WORKDIR /vdr

EXPOSE 2004 3000 6419 6419/udp 8008 8009 34890

VOLUME ["/vdr/config", "/vdr/epgimages", "/vdr/recordings"]

ENTRYPOINT ["/init"]
