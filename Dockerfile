FROM archlinux:latest

LABEL maintainer="lapicidae"

WORKDIR /tmp

ENV LANG="en_US.UTF-8" \
    TZ="Europe/London"

ARG LANGUAGE="en_US:en_GB:en" \
    pacinst="sudo -u builduser paru --nouseask --removemake --cleanafter --noconfirm --clonedir /var/cache/paru -S" \
    pacdown="sudo -u builduser paru --getpkgbuild --noprogressbar --clonedir /var/cache/paru" \
    pacbuild="sudo -u builduser paru --cleanafter --noconfirm --noprogressbar --nouseask --removemake -Ui" \
    buildDir="/var/cache/paru"

ADD https://github.com/just-containers/s6-overlay/releases/download/v2.2.0.3/s6-overlay-amd64-installer /tmp/

ADD https://github.com/just-containers/socklog-overlay/releases/download/v3.1.2-0/socklog-overlay-amd64.tar.gz /tmp/

COPY build/ /

RUN echo "**** configure pacman ****" && \
    sed -i '/NoExtract.*=.*[^\n]*/,$!b;//{x;//p;g};//!H;$!d;x;s//&\nNoExtract   = !usr\/share\/locale\/*\/LC_MESSAGES\/vdr*/' /etc/pacman.conf && \
    sed -i 's|!usr/share/\*locales/en_??|!usr/share/\*locales/*|g' /etc/pacman.conf && \
    pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Sy && \
    echo "**** timezone and locale ****" && \
    pacman -S glibc --overwrite=* --noconfirm && \
    rm -f /etc/localtime && \
    ln -s /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    curl -o /etc/locale.gen "https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=localedata/SUPPORTED;hb=HEAD" && \
    sed -i -e '1,3d' -e 's|/| |g' -e 's|\\| |g' -e 's|^|#|g' /etc/locale.gen && \
    sed -i '/#  /d' /etc/locale.gen && \
    sed -i '/en_US.UTF-8/s/^# *//' /etc/locale.gen && \
    sed -i "/$LANG/s/^# *//" /etc/locale.gen && \
    echo "LANG=$LANG" > /etc/locale.conf && \
    locale-gen && \
    echo "**** bash tweaks ****" && \
    echo -e "\n[ -r /usr/bin/contenv2env ] && . /usr/bin/contenv2env" >> /etc/bash.bashrc && \
    echo -e "\n[ -r /etc/bash.aliases ] && . /etc/bash.aliases" >> /etc/bash.bashrc && \
    echo "**** system update ****" && \
    pacman -Su --noconfirm && \
    echo "**** install build packages ****" && \
    pacman -S --noconfirm --needed \
      base-devel \
      git \
      sudo && \
    echo "**** add builduser ****" && \
    useradd --system --create-home --no-user-group --home-dir $buildDir/.user builduser && \
    echo -e "root ALL=(ALL) ALL\nbuilduser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers && \
    echo "**** install paru-bin ****" && \
    cd $buildDir && \
    git clone https://aur.archlinux.org/paru-bin.git paru-bin && \
    chown -R builduser:users paru-bin && \
    cd paru-bin && \
    sudo -u builduser makepkg -s --noconfirm && \
    cd $buildDir && \
    pacman --noconfirm -U */*.pkg.tar.zst && \
    sed -i "/^\[options\].*/a SkipReview" /etc/paru.conf && \
    sed -i "/^\[options\].*/a CloneDir = /var/cache/paru" /etc/paru.conf && \
    sed -i "/CleanAfter/s/^# *//" /etc/paru.conf && \
    sed -i "/RemoveMake/s/^# *//" /etc/paru.conf && \
    mkdir -p $buildDir && \
    chmod 775 $buildDir && \
    chgrp users $buildDir && \
    cd /tmp && \
    echo "**** install s6-overlay & socklog-overlay ****" && \
    chmod +x /tmp/s6-overlay-amd64-installer && /tmp/s6-overlay-amd64-installer / && \
    tar xzf /tmp/socklog-overlay-amd64.tar.gz -C / && \
    echo "**** install dependencies & tools ****" && \
    $pacinst \
      busybox \
      libdvbcsa \
      ttf-vdrsymbols \
      naludump \
      libva-headless \
      ffmpeg-headless && \
    echo "**** install VDR ****" && \
    $pacinst \
      vdr \
      vdrctl && \
    echo "**** install VDR plugins ****" && \
    $pacinst --batchinstall \
      vdr-dvbapi \
      vdr-streamdev-server \
      vdr-vnsiserver && \
    echo "**** install VDR plugin ddci2 ****" && \
    cd $buildDir && \
    $pacdown vdr-ddci2 && \
    sed -i "s/vdr-api=/vdr-api>=/g" vdr-ddci2/PKGBUILD && \
    chown -R builduser:users vdr-ddci2 && \
    cd vdr-ddci2 && \
    $pacbuild && \
    echo "**** install VDR plugin ciplus ****" && \
    cd $buildDir && \
    git clone https://github.com/lmaresch/vdr-ciplus.git vdr-ciplus && \
    sed -i "s/vdr-api=/vdr-api>=/g" vdr-ciplus/PKGBUILD && \
    cp /tmp/addlib.patch $buildDir/vdr-ciplus && \
    awk '1;/prepare()/{c=2}c&&!--c{print "  patch -p1 < ../../addlib.patch"}' vdr-ciplus/PKGBUILD > tmp && mv tmp vdr-ciplus/PKGBUILD && \
    chown -R builduser:users vdr-ciplus && \
    cd vdr-ciplus && \
    $pacbuild && \
    echo "**** install VDR plugin live ****" && \
    cd $buildDir && \
    echo "install cxxtools" && \
    mkdir -p cxxtools && \
    curl -o cxxtools/PKGBUILD "https://raw.githubusercontent.com/VDR4Arch/vdr4arch/master/deps/cxxtools/PKGBUILD" && \
    chown -R builduser:users cxxtools && \
    cd cxxtools && \
    $pacbuild && \
    echo "install tntnet & vdr-live" && \
    cd $buildDir && \
    $pacinst \
      tntnet \
      vdr-live && \
    cd /tmp && \
    echo "**** folders and symlinks ****" && \
    mkdir -p /vdr/log && \
    mkdir -p /vdr/timeshift && \
    ln -s /etc/PKGBUILD.d /vdr/pkgbuild && \
    ln -s /etc/vdr /vdr/system && \
    ln -s /srv/vdr/video /vdr/recordings && \
    ln -s /usr/lib/vdr/bin/shutdown-wrapper /usr/bin/shutdown-wrapper && \
    ln -s /usr/lib/vdr/bin/vdr-recordingaction /usr/bin/vdr-recordingaction && \
    ln -s /var/cache/vdr /vdr/cache && \
    ln -s /var/lib/vdr /vdr/config && \
    echo "**** vdr config ****" && \
    mv /etc/vdr/conf.avail/50-ddci2.conf /etc/vdr/conf.avail/10-ddci2.conf && \
    mv /etc/vdr/conf.avail/50-dvbapi.conf /etc/vdr/conf.avail/20-dvbapi.conf && \
    mv /etc/vdr/conf.avail/50-ciplus.conf /etc/vdr/conf.avail/30-ciplus.conf && \
    echo "**** SMTP client ****" && \
    $pacinst msmtp-mta && \
    curl -o /etc/msmtprc "https://git.marlam.de/gitweb/?p=msmtp.git;a=blob_plain;f=doc/msmtprc-system.example" && \
    chmod 640 /etc/msmtprc && \
    echo "**** backup default files ****" && \
    mkdir -p /defaults/config && \
    mkdir -p /defaults/system && \
    cp -Ran /var/lib/vdr/* /defaults/config && \
    cp -Ran /etc/vdr/* /defaults/system && \
    echo "**** mark essential packages ****" && \
    pacman -D --asexplicit \
      vdr \
      shadow && \
    echo "**** CleanUp ****" && \
    rm -rf \
      /tmp/* \
      /var/tmp/* && \
    pacman -R --noconfirm \
      argon2 \
      base \
      cryptsetup \
      dbus \
      device-mapper \
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
      popt \
      pciutils \
      systemd \
      systemd-sysvcompat && \
    paru --noconfirm -Sccd && \
    find /etc -type f -name "*.pacnew" -delete && \
    find /etc -type f -name "*.pacsave" -delete && \
    find "$buildDir" -mindepth 1 -maxdepth 1 -type d -not -path '*/\.*' -exec rm -rf {} \; && \
    echo "**** install busybox ****" && \
    busybox --install -s && \
    echo "**** move provided files ****" && \
    find /base -type d -exec chmod 755 {} \; && \
    cp -Rlf /base/* / && \
    rm -rf /base

WORKDIR /vdr

EXPOSE 3000 8008 34890

VOLUME ["/vdr/cache", "/vdr/config", "/vdr/recordings", "/vdr/system"]

ENTRYPOINT ["/init"]
