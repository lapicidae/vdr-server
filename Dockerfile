FROM archlinux:latest

ARG LANGUAGE="en_US:en_GB:en" \
    pacinst="sudo -u builduser paru --nouseask --removemake --cleanafter --noconfirm --clonedir /var/cache/paru -S" \
    pacdown="sudo -u builduser paru --getpkgbuild --noprogressbar --clonedir /var/cache/paru" \
    pacbuild="sudo -u builduser makepkg --clean --install --noconfirm --noprogressbar --syncdeps" \
    buildDir="/var/cache/paru" \
    buildOptimize="false" \
    maintainer="lapicidae <github.com/lapicidae>" \
    S6VER="3.0.0.2"

ENV PATH="$PATH:/command"
ENV LANG="en_US.UTF-8" \
    TZ="Europe/London" \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME="0"

ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/s6-overlay-noarch-$S6VER.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/s6-overlay-x86_64-$S6VER.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/syslogd-overlay-noarch-$S6VER.tar.xz /tmp

COPY build/ /

RUN echo "**** configure pacman ****" && \
      sed -i '/NoExtract.*=.*[^\n]*/,$!b;//{x;//p;g};//!H;$!d;x;s//&\nNoExtract   = !usr\/share\/locale\/*\/LC_MESSAGES\/vdr*/' /etc/pacman.conf && \
      sed -i 's|!usr/share/\*locales/en_??|!usr/share/\*locales/*|g' /etc/pacman.conf && \
      if [ "${buildOptimize:="false"}" = "true" ]; then sed -i '/^#MAKEFLAGS=.*/a MAKEFLAGS="-j$(nproc)"' "/etc/makepkg.conf"; fi && \
      sed -i "/^#PACKAGER=.*/a PACKAGER=\"$maintainer\"" "/etc/makepkg.conf" && \
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
        pacman-contrib \
        sudo && \
    echo "**** add builduser ****" && \
      useradd --system --create-home --no-user-group --home-dir $buildDir/.user --shell /bin/false builduser && \
      echo -e "root ALL=(ALL) ALL\nbuilduser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers && \
    echo "**** install paru-bin ****" && \
      cd $buildDir && \
      git clone https://aur.archlinux.org/paru-bin.git paru-bin && \
      chown -R builduser:users paru-bin && \
      cd paru-bin && \
      $pacbuild && \
      sed -i "/^\[options\].*/a SkipReview" /etc/paru.conf && \
      sed -i "/^\[options\].*/a CloneDir = /var/cache/paru" /etc/paru.conf && \
      sed -i "/CleanAfter/s/^# *//" /etc/paru.conf && \
      sed -i "/RemoveMake/s/^# *//" /etc/paru.conf && \
      chmod 775 $buildDir && \
      chgrp users $buildDir && \
      cd /tmp && \
    echo "**** s6-overlay ($S6VER) ****" && \
      cd /tmp && \
      tar -C / -Jxpf /tmp/s6-overlay-noarch-$S6VER.tar.xz && \
      tar -C / -Jxpf /tmp/s6-overlay-x86_64-$S6VER.tar.xz && \
      sed -ie "s/$/:\/usr\/sbin/" /etc/s6-overlay/config/global_path && \
    echo "**** syslogd-overlay ($S6VER) ****" && \
      tar -C / -Jxpf /tmp/syslogd-overlay-noarch-$S6VER.tar.xz && \
      touch /etc/s6-overlay/s6-rc.d/syslogd-prepare/dependencies.d/init && \
      patch /etc/s6-overlay/s6-rc.d/syslogd-log/run /tmp/syslogd-log_run.patch && \
      useradd --system --no-create-home --shell /bin/false syslog && \
      useradd --system --no-create-home --shell /bin/false sysllog && \
    echo "**** install dependencies & tools ****" && \
      $pacinst \
        busybox \
        libdvbcsa \
        ttf-vdrsymbols \
        naludump \
        libva-headless \
        ffmpeg-headless && \
    echo "**** install VDR ****" && \
      cd $buildDir && \
      $pacdown vdr && \
      curl -o /tmp/eit-patch.gz "https://www.vdr-portal.de/index.php?attachment/46195-eit-patch-gz/" && \
      gunzip -c /tmp/eit-patch.gz > vdr/eit.patch && \
      cd vdr && \
      sed -i "s/pkgrel=.*/pkgrel=2/g" PKGBUILD && \
      sed -i "/^        '00-vdr.conf'.*/i \ \ \ \ \ \ \ \ 'eit.patch'" PKGBUILD && \
      sed -i "/Don't install plugins with VDR.*/i \ \ # epg2vdr Patch\n \ patch -p1 -i \"\$srcdir/eit.patch\"\n" PKGBUILD && \
      sudo -u builduser updpkgsums && \
      sudo -u builduser makepkg --printsrcinfo > .SRCINFO && \
      chown -R builduser:users . && \
      $pacbuild && \
      $pacinst \
        vdr-checkts \
        vdrctl && \
    echo "**** install VDR plugins ****" && \
      $pacinst --batchinstall \
        vdr-dvbapi \
        vdr-epgsearch \
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
      $pacinst \
        cxxtools \
        tntnet \
        vdr-live && \
    echo "**** folders and symlinks ****" && \
      mkdir -p /vdr/channellogos && \
      mkdir -p /vdr/log && \
      mkdir -p /vdr/pkgbuild && \
      mkdir -p /vdr/timeshift && \
      ln -s /etc/vdr /vdr/system && \
      ln -s /srv/vdr/video /vdr/recordings && \
      ln -s /usr/lib/vdr/bin/shutdown-wrapper /usr/bin/shutdown-wrapper && \
      ln -s /usr/lib/vdr/bin/vdr-recordingaction /usr/bin/vdr-recordingaction && \
      ln -s /var/cache/vdr /vdr/cache && \
      ln -s /var/lib/vdr /vdr/config && \
      ln -s /vdr/channellogos /usr/share/vdr/channel-logos && \
      ln -s /vdr/pkgbuild /etc/PKGBUILD.d && \
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
    echo "**** move provided files ****" && \
      find /base -type d -exec chmod 755 {} \; && \
      cp -Rlf /base/* / && \
      rm -rf /base && \
    echo "**** copy provided settings ****" && \
      cp -Rlf /defaults/config/* /var/lib/vdr && \
      cp -Rlf /defaults/system/* /etc/vdr && \
    echo "**** get channellogos ****" && \
      cd /tmp && \
      git clone https://github.com/lapicidae/svg-channellogos.git chlogo && \
      chmod +x chlogo/tools/install && \
      chlogo/tools/install -c dark -p /tmp/channellogos -r && \
      tar -cpJf /defaults/channellogos.tar.xz -C /tmp/channellogos . &&\
    echo "**** change permissions ****" && \
      chown -R vdr:vdr /defaults && \
      chown -R vdr:vdr /vdr && \
      chown -R sysllog:sysllog /vdr/log && \
      chmod 4754 /usr/lib/vdr/bin/shutdown-wrapper && \
      chmod 4754 /usr/lib/vdr/bin/vdr-recordingaction && \
      chmod 755 /usr/bin/checkrec && \
      chmod 755 /usr/bin/contenv2env && \
      chmod 755 /usr/bin/vdr-channelids && \
      chown root:root /usr/bin/checkrec && \
      chown root:root /usr/bin/contenv2env && \
      chown root:root /usr/bin/vdr-channelids && \
      chown root:vdr /usr/lib/vdr/bin/shutdown-wrapper && \
      chown vdr:vdr /usr/lib/vdr/bin/vdr-recordingaction && \
    echo "**** mark essential packages ****" && \
      pacman -D --asexplicit \
        vdr \
        shadow && \
    echo "**** Versioning ****" && \
      paru -Gp vdr | grep -i pkgver= | cut -d = -f 2 > /vdr/VERSION && \
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
        pacman-contrib \
        popt \
        pciutils \
        systemd \
        systemd-sysvcompat && \
      pacman --noconfirm -R $(pacman -Qtdq) 2>/dev/null || true && \
      yes | pacman -Scc && \
      find /etc -type f -name "*.pacnew" -delete && \
      find /etc -type f -name "*.pacsave" -delete && \
      find "$buildDir" -mindepth 1 -maxdepth 1 -type d -not -path '*/\.*' -exec rm -rf {} \; && \
    echo "**** install busybox ****" && \
      busybox --install -s

WORKDIR /vdr

LABEL maintainer=$maintainer

EXPOSE 3000 8008 34890

VOLUME ["/vdr/cache", "/vdr/config", "/vdr/recordings", "/vdr/system"]

ENTRYPOINT ["/init"]
