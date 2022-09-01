FROM archlinux:latest

ARG LANGUAGE="en_US:en_GB:en" \
    pacinst="sudo -u builduser paru --failfast --nouseask --removemake --cleanafter --noconfirm --clonedir /var/cache/paru -S" \
    pacdown="sudo -u builduser paru --getpkgbuild --noprogressbar --clonedir /var/cache/paru" \
    pacbuild="sudo -u builduser makepkg --clean --install --noconfirm --noprogressbar --syncdeps" \
    buildDir="/var/cache/paru" \
    buildOptimize="true" \
    maintainer="lapicidae <github.com/lapicidae>" \
    S6VER="3.1.2.1"

ENV PATH="$PATH:/command:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl"
ENV LANG="en_US.UTF-8" \
    TZ="Europe/London" \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME="0" \
    S6_VERBOSITY="1"

ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/s6-overlay-noarch.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/s6-overlay-x86_64.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v$S6VER/syslogd-overlay-noarch.tar.xz /tmp

COPY build/ /

RUN echo "**** configure pacman ****" && \
      sed -i '/NoExtract.*=.*[^\n]*/,$!b;//{x;//p;g};//!H;$!d;x;s//&\nNoExtract   = !usr\/share\/locale\/*\/LC_MESSAGES\/vdr*/' /etc/pacman.conf && \
      sed -i 's|!usr/share/\*locales/en_??|!usr/share/\*locales/*|g' /etc/pacman.conf && \
      if [ "${buildOptimize:="false"}" = "true" ]; then sed -i '/^#MAKEFLAGS=.*/a MAKEFLAGS="-j$(nproc)"' "/etc/makepkg.conf"; fi && \
      sed -i "/^#PACKAGER=.*/a PACKAGER=\"$maintainer\"" "/etc/makepkg.conf" && \
      pacman-key --init && \
      pacman-key --populate archlinux && \
      pacman -Sy archlinux-keyring --noprogressbar --noconfirm && \
      pacman -Su --noprogressbar --noconfirm && \
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
      echo -e "\n[ -r /usr/local/bin/contenv2env ] && . /usr/local/bin/contenv2env" >> /etc/bash.bashrc && \
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
      tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
      tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz && \
    echo "**** syslogd-overlay ($S6VER) ****" && \
      tar -C / -Jxpf /tmp/syslogd-overlay-noarch.tar.xz && \
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
      pacman --noconfirm -R vdr-examples 2>/dev/null || true && \
    echo "**** install VDR tools ****" && \
      $pacinst \
        vdrctl && \
      cd $buildDir && \
      $pacdown vdr-checkts && \
      sed -i "s/projects.vdr-developer.org\/git/github.com\/vdr-projects/g" vdr-checkts/PKGBUILD && \
      chown -R builduser:users vdr-checkts && \
      cd vdr-checkts && \
      $pacbuild && \
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
      cd $buildDir && \
      $pacdown cxxtools && \
      curl -LJ -o cxxtools/timer.patch "https://github.com/maekitalo/cxxtools/files/9257147/cxxtools-3.0-timer.txt" && \
      cd cxxtools && \
      sed -i "s/pkgrel=.*/pkgrel=3/g" PKGBUILD && \
      sed -i "/^        .*$pkgname-char-trivial-class.patch.*/i \ \ \ \ \ \ \ \ 'timer.patch'" PKGBUILD && \
      sed -i "/patch -p1.*/i \ \ # BuildFix\n \ patch -i \"\$srcdir/timer.patch\" \"src/timer.cpp\" \n" PKGBUILD && \
      sudo -u builduser updpkgsums && \
      sudo -u builduser makepkg --printsrcinfo > .SRCINFO && \
      chown -R builduser:users . && \
      $pacbuild && \
      $pacinst \
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
      ln -s /var/cache/vdr/epgimages /srv/http/epgimages && \
      ln -s /var/lib/vdr /vdr/config && \
      ln -s /vdr/channellogos /srv/http/channellogos && \
      ln -s /vdr/channellogos /usr/share/vdr/channel-logos && \
      ln -s /vdr/pkgbuild /etc/PKGBUILD.d && \
    echo "**** vdr config ****" && \
      mv /etc/vdr/conf.avail/50-ddci2.conf /etc/vdr/conf.avail/10-ddci2.conf && \
      mv /etc/vdr/conf.avail/50-dvbapi.conf /etc/vdr/conf.avail/20-dvbapi.conf && \
      mv /etc/vdr/conf.avail/50-ciplus.conf /etc/vdr/conf.avail/30-ciplus.conf && \
    echo "**** busybox crond ****" && \
      mkdir -p /var/spool/cron/crontabs && \
      touch /var/spool/cron/crontabs/root && \
      echo -e 'root\nvdr' >> /var/spool/cron/crontabs/cron.update && \
      chmod 600 /var/spool/cron/crontabs/* && \
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
    echo "**** get png channellogos ****" && \
      curl -s https://api.github.com/repos/lapicidae/svg-channellogos/releases/latest | \
        grep "browser_download_url" | \
        grep -Eo 'https://[^\"]*' | \
        grep -v 'nolinks' | \
        grep -e 'light.*square' | \
        xargs curl -s -L -o /defaults/channellogos.tar.xz && \
      curl -o /usr/local/bin/picon https://raw.githubusercontent.com/lapicidae/svg-channellogos/master/tools/picon && \
    echo "**** change permissions ****" && \
      chown -R vdr:vdr /defaults && \
      chown -R vdr:vdr /vdr && \
      chown -R sysllog:sysllog /vdr/log && \
      chmod 4754 /usr/lib/vdr/bin/shutdown-wrapper && \
      chmod 4754 /usr/lib/vdr/bin/vdr-recordingaction && \
      chmod 755 /usr/local/bin/checkrec && \
      chmod 755 /usr/local/bin/contenv2env && \
      chmod 755 /usr/local/bin/naludumper && \
      chmod 755 /usr/local/bin/naludumper-cron && \
      chmod 755 /usr/local/bin/picon && \
      chmod 755 /usr/local/bin/vdr-channelids && \
      chmod 600 /var/spool/cron/crontabs/* && \
      chown root:root /usr/local/bin/checkrec && \
      chown root:root /usr/local/bin/contenv2env && \
      chown root:root /usr/local/bin/naludumper && \
      chown root:root /usr/local/bin/naludumper-cron && \
      chown root:root /usr/local/bin/picon && \
      chown root:root /usr/local/bin/vdr-channelids && \
      chown root:vdr /usr/lib/vdr/bin/shutdown-wrapper && \
      chown vdr:vdr /usr/lib/vdr/bin/vdr-recordingaction && \
    echo "**** mark essential packages ****" && \
      pacman -D --asexplicit \
        vdr \
        shadow && \
    echo "**** Versioning ****" && \
      paru -Gp vdr | grep -i pkgver= | cut -d = -f 2 > /vdr/VERSION && \
    echo "**** CleanUp ****" && \
      if [ "${buildOptimize:="false"}" = "true" ]; then sed -i 's/^MAKEFLAGS=.*/#&/' "/etc/makepkg.conf"; fi && \
      rm -rf \
        /tmp/* \
        /var/tmp/* && \
      pacman -R --noconfirm \
        argon2 \
        base \
        cryptsetup \
        dbus \
        device-mapper \
        iproute2 \
        iptables \
        kbd \
        kmod \
        libmnl \
        libnetfilter_conntrack \
        libnfnetlink \
        libnftnl \
        libnl \
        libpcap \
        pacman-contrib \
        pciutils \
        popt \
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
