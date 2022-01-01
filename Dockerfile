FROM archlinux:latest

LABEL maintainer="lapicidae"

WORKDIR /tmp

ENV LANG="en_US.UTF-8" \
    TZ="Europe/London"

ARG LANGUAGE="en_US:en_GB:en" \
    pacinst="sudo -u builduser paru --nouseask --removemake --cleanafter --noconfirm -S" \
    pacdown="sudo -u builduser paru --getpkgbuild" \
    pacbuild="sudo -u builduser paru --nouseask --removemake --cleanafter --noconfirm -Ui"

ADD https://github.com/just-containers/s6-overlay/releases/download/v2.2.0.3/s6-overlay-amd64-installer /tmp/

ADD https://github.com/just-containers/socklog-overlay/releases/download/v3.1.2-0/socklog-overlay-amd64.tar.gz /tmp/

COPY build/ /

RUN echo "**** configure pacman ****" && \
    sed -i 's/.*NoExtract.*/NoExtract   = usr\/share\/doc\/* usr\/share\/help\/* usr\/share\/info\/* usr\/share\/man\/*/' /etc/pacman.conf && \
    pacman -Sy && \
    echo "**** timezone and locale ****" && \
    rm -f /etc/locale.gen && \
    pacman -S glibc --overwrite=* --noconfirm && \
    curl -o /etc/locale.gen "https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=localedata/SUPPORTED;hb=HEAD" && \
    sed -i -e '1,3d' -e 's|/| |g' -e 's|\\| |g' -e 's|^|#|g' /etc/locale.gen && \
    rm -f /etc/localtime && \
    ln -s /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    sed -i '/#  /d' /etc/locale.gen && \
    sed -i '/en_US.UTF-8/s/^# *//' /etc/locale.gen && \
    sed -i "/$LANG/s/^# *//" /etc/locale.gen && \
    echo "LANG=$LANG" > /etc/locale.conf && \
    locale-gen && \
    echo "**** bash aliases ****" && \
    echo -e "\nif [ -f /etc/bash.aliases ]; then\n  . /etc/bash.aliases\nfi" >> /etc/bash.bashrc && \
    echo "**** system update ****" && \
    pacman -Su --noconfirm && \
    echo "**** install build packages ****" && \
    pacman -S --noconfirm --needed \
      base-devel \
      git \
      sudo && \
    echo "**** add builduser ****" && \
    useradd -m -d /build -s /bin/bash builduser && \
    echo -e "root ALL=(ALL) ALL\nbuilduser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers && \
    echo "**** install paru-bin ****" && \
    export buildDir="/tmp/paru" && \
    mkdir -p $buildDir && \
    cd $buildDir && \
    git clone https://aur.archlinux.org/paru-bin.git && \
    cd paru-bin && \
    chown -R builduser $buildDir/paru-bin && \
    sudo -u builduser makepkg -s --noconfirm && \
    cd $buildDir && \
    pacman --noconfirm -U */*.pkg.tar.zst && \
    rm -rf $buildDir && \
    sed -i "/CleanAfter/s/^# *//" /etc/paru.conf && \
    sed -i "/RemoveMake/s/^# *//" /etc/paru.conf && \
    unset buildDir && \
    cd /tmp && \
    echo "**** install s6-overlay & socklog-overlay ****" && \
    chmod +x /tmp/s6-overlay-amd64-installer && /tmp/s6-overlay-amd64-installer / && \
    tar xzf /tmp/socklog-overlay-amd64.tar.gz -C /

RUN echo "**** install dependencies & tools ****" && \
    $pacinst busybox libdvbcsa ttf-vdrsymbols naludump libva-headless ffmpeg-headless

RUN echo "**** install VDR ****" && \
    $pacinst \
      vdr \
      vdr-api \
      vdrctl && \
    echo "**** install VDR plugins ****" && \
    $pacinst --batchinstall \
      vdr-dvbapi \
      vdr-streamdev-server \
      vdr-vnsiserver && \
    echo "**** install VDR plugin ddci2 ****" && \
    cd /tmp && \
    $pacdown vdr-ddci2 && \
    cd vdr-ddci2 && \
    sed -i "s/vdr-api=/vdr-api>=/g" PKGBUILD && \
    $pacbuild && \
    echo "**** install VDR plugin ciplus ****" && \
    cd /tmp && \
    git clone https://github.com/lmaresch/vdr-ciplus.git && \
    cd vdr-ciplus && \
    sed -i "s/vdr-api=/vdr-api>=/g" PKGBUILD && \
    awk '1;/prepare()/{c=2}c&&!--c{print "  patch -p1 < /tmp/addlib.patch"}' PKGBUILD > tmp && mv tmp PKGBUILD && \
    chown -R builduser /tmp/vdr-ciplus && \
    $pacbuild && \
    cd /tmp

RUN echo "**** folders and symlinks ****" && \
    mkdir -p /vdr/timeshift && \
    ln -s /var/lib/vdr /vdr/config && \
    ln -s /etc/vdr /vdr/system && \
    ln -s /var/cache/vdr /vdr/cache && \
    ln -s /srv/vdr/video /vdr/recordings && \
    ln -s /usr/lib/vdr/bin/shutdown-wrapper /usr/bin/shutdown-wrapper && \
    ln -s /usr/lib/vdr/bin/vdr-recordingaction /usr/bin/vdr-recordingaction && \
    echo "**** vdr config ****" && \
    mv /etc/vdr/conf.avail/50-ddci2.conf /etc/vdr/conf.avail/10-ddci2.conf && \
    mv /etc/vdr/conf.avail/50-dvbapi.conf /etc/vdr/conf.avail/20-dvbapi.conf && \
    mv /etc/vdr/conf.avail/50-ciplus.conf /etc/vdr/conf.avail/30-ciplus.conf && \
    echo "**** SMTP client ****" && \
    $pacinst msmtp-mta && \
    curl -o /etc/msmtprc "https://git.marlam.de/gitweb/?p=msmtp.git;a=blob_plain;f=doc/msmtprc-system.example" && \
    chmod 600 /etc/msmtprc && \
    echo "**** backup default files ****" && \
    mkdir -p /defaults/config && \
    mkdir -p /defaults/system && \
    cp -Ran /var/lib/vdr/* /defaults/config && \
    cp -Ran /etc/vdr/* /defaults/system && \
    echo "**** mark essential packages ****" && \
    pacman -D --asexplicit \
      vdr \
      vdr-api \
      shadow

RUN echo "**** CleanUp ****" && \
    rm -rf \
      /tmp/* \
      /var/tmp/* && \
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
      popt \
      pciutils \
      systemd \
      systemd-sysvcompat && \
    pacman --noconfirm -Scc && \
    find /etc -type f -name "*.pacnew" -delete && \
    find /etc -type f -name "*.pacsave" -delete && \
    echo "**** install busybox ****" && \
    busybox --install -s

RUN echo "**** move sysfiles ****" && \
    find /base -type d -exec chmod 775 {} \; && \
    cp -Rlf /base/* / && \
    rm -rf /base

WORKDIR /vdr

EXPOSE 2004 3000 6419 6419/udp 8008 8009 34890

VOLUME ["/vdr/cache", "/vdr/config", "/vdr/recordings", "/vdr/system"]

ENTRYPOINT ["/init"]
