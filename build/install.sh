#!/bin/bash

## exit when any command fails
set -e


## Ideally, change these variables via 'docker build-arg'
# e.g.: docker build --tag vdr-server --build-arg miniVers=true .
buildOptimize=${buildOptimize:-"false"}
inVM=${inVM:-"false"}
maintainer=${maintainer:-"lapicidae <github.com/lapicidae>"}
miniVers=${miniVers:-"false"}   # build without ffmpeg & vdr-live
S6VER=${S6VER:-"none"}


## Do not change!
pacinst="sudo -u builduser paru --failfast --nouseask --removemake --cleanafter --noconfirm --clonedir /var/cache/paru -S"
pacdown="sudo -u builduser paru --getpkgbuild --noprogressbar --clonedir /var/cache/paru"
pacbuild="sudo -u builduser makepkg --clean --install --noconfirm --noprogressbar --syncdeps"
buildDir="/var/cache/paru"
buildOptimize="true"


## colored notifications
_ntfy() {
    printf '\e[36;1;2m**** %-6s ****\e[m\n' "$@"
}


## error messages before exiting
trap 'printf "\n\e[35;1;2m%s\e[m\n" "KILLED!"; exit 130' INT
trap 'printf "\n\e[31;1;2m> %s\nCommand terminated with exit code %s.\e[m\n" "$BASH_COMMAND" "$?"' ERR


## Profit!
_ntfy 'prepare pacman'
sed -i '/NoExtract.*=.*[^\n]*/,$!b;//{x;//p;g};//!H;$!d;x;s//&\nNoExtract   = !usr\/share\/locale\/*\/LC_MESSAGES\/vdr*/' /etc/pacman.conf
sed -i 's|!usr/share/\*locales/en_??|!usr/share/\*locales/*|g' /etc/pacman.conf
if [ "$buildOptimize" = "true" ]; then
    # shellcheck disable=SC2016
	sed -i '/^#MAKEFLAGS=.*/a MAKEFLAGS="-j$(nproc)"' '/etc/makepkg.conf'
fi
sed -i "/^#PACKAGER=.*/a PACKAGER=\"$maintainer\"" '/etc/makepkg.conf'
pacman-key --init
pacman-key --populate archlinux
pacman -Sy archlinux-keyring --noprogressbar --noconfirm

_ntfy 'system update'
pacman -Su --noprogressbar --noconfirm

_ntfy 'timezone and locale'
pacman -S glibc --overwrite=* --noconfirm
rm -f /etc/localtime
ln -s /usr/share/zoneinfo/"$TZ" /etc/localtime
echo "$TZ" > /etc/timezone
curl -o /etc/locale.gen 'https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=localedata/SUPPORTED;hb=HEAD'
sed -i -e '1,3d' -e 's|/| |g' -e 's|\\| |g' -e 's|^|#|g' /etc/locale.gen
sed -i '/#  /d' /etc/locale.gen
sed -i '/en_US.UTF-8/s/^# *//' /etc/locale.gen
sed -i "/$LANG/s/^# *//" /etc/locale.gen
echo "LANG=$LANG" > /etc/locale.conf
locale-gen

_ntfy 'bash tweaks'
echo -e '\n[ -r /usr/local/bin/contenv2env ] && . /usr/local/bin/contenv2env' >> /etc/bash.bashrc
echo -e '\n[ -r /etc/bash.aliases ] && . /etc/bash.aliases' >> /etc/bash.bashrc

_ntfy 'install build packages'
pacman -S --noconfirm --needed \
    base-devel \
    git \
    pacman-contrib \
    sudo

_ntfy 'add builduser'
useradd --system --create-home --no-user-group --home-dir $buildDir/.user --shell /bin/false builduser
echo -e "root ALL=(ALL) ALL\nbuilduser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers
sudo -u builduser git config --global --add safe.directory '*'

_ntfy 'install paru-bin'
cd $buildDir || exit 1
git clone 'https://aur.archlinux.org/paru-bin.git' paru-bin
chown -R builduser:users paru-bin
cd paru-bin || exit
$pacbuild
sed -i "/^\[options\].*/a SkipReview" /etc/paru.conf
sed -i "/^\[options\].*/a CloneDir = /var/cache/paru" /etc/paru.conf
sed -i "/CleanAfter/s/^# *//" /etc/paru.conf
sed -i "/RemoveMake/s/^# *//" /etc/paru.conf
chmod 775 $buildDir
chgrp users $buildDir
cd /tmp || exit 1

_ntfy "s6-overlay ($S6VER)"
cd /tmp || exit 1
tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz
tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz

_ntfy "syslogd-overlay ($S6VER)"
tar -C / -Jxpf /tmp/syslogd-overlay-noarch.tar.xz
patch /etc/s6-overlay/s6-rc.d/syslogd-log/run /tmp/syslogd-log_run.patch
useradd --system --no-create-home --shell /bin/false syslog
useradd --system --no-create-home --shell /bin/false sysllog

_ntfy "detect envivroment"
$pacinst virt-what
mapfile -t virtWhat < <(virt-what)
if [ ${#virtWhat[@]} -gt 0 ]; then
    inVM='true'
    printf '\e[95;1;5mCurrently running in a VM!\e[m\n'
fi

_ntfy 'install dependencies & tools'
$pacinst \
    busybox \
    libdvbcsa \
    ttf-vdrsymbols \
    naludump
if [ "$miniVers" != 'true' ]; then
    $pacinst \
        libva-headless \
        ffmpeg-headless
fi

_ntfy 'install VDR'
$pacinst vdr

_ntfy 'install VDR tools'
$pacinst \
    vdrctl
cd $buildDir || exit 1
$pacdown vdr-checkts
sed -i "s/projects.vdr-developer.org\/git/github.com\/vdr-projects/g" vdr-checkts/PKGBUILD
chown -R builduser:users vdr-checkts
cd vdr-checkts || exit 1
$pacbuild

_ntfy 'install VDR plugins'
$pacinst --batchinstall \
    vdr-ddci2 \
    vdr-dvbapi \
    vdr-epgsearch \
    vdr-streamdev-server \
    vdr-vnsiserver

_ntfy 'install VDR plugin ciplus'
cd $buildDir || exit 1
git clone 'https://github.com/lmaresch/vdr-ciplus.git' vdr-ciplus
sed -i "s/vdr-api=/vdr-api>=/g" vdr-ciplus/PKGBUILD
cp /tmp/addlib.patch $buildDir/vdr-ciplus
awk '1;/prepare()/{c=2}c&&!--c{print "  patch -p1 < ../../addlib.patch"}' vdr-ciplus/PKGBUILD > tmp && mv tmp vdr-ciplus/PKGBUILD
chown -R builduser:users vdr-ciplus
cd vdr-ciplus || exit 1
$pacbuild
if [ "$miniVers" != 'true' ]; then
    _ntfy 'install VDR plugin live'
    $pacinst \
        cxxtools \
        tntnet
    $pacinst --mflags --skipinteg vdr-live
fi

_ntfy 'folders and symlinks'
mkdir -p \
    /vdr/channellogos \
    /vdr/log \
    /vdr/pkgbuild \
    /vdr/timeshift
ln -s /etc/vdr /vdr/system
ln -s /srv/vdr/video /vdr/recordings
ln -s /usr/lib/vdr/bin/shutdown-wrapper /usr/bin/shutdown-wrapper
ln -s /usr/lib/vdr/bin/vdr-recordingaction /usr/bin/vdr-recordingaction
ln -s /var/cache/vdr /vdr/cache
ln -s /var/cache/vdr/channels.m3u /srv/http/channels.m3u
ln -s /var/cache/vdr/epg.xmltv /srv/http/epg.xmltv
ln -s /var/cache/vdr/epgimages /srv/http/epgimages
ln -s /var/lib/vdr /vdr/config
ln -s /vdr/channellogos /srv/http/channellogos
ln -s /vdr/channellogos /usr/share/vdr/channel-logos
ln -s /vdr/pkgbuild /etc/PKGBUILD.d

_ntfy 'vdr config'
mv /etc/vdr/conf.avail/50-ddci2.conf /etc/vdr/conf.avail/10-ddci2.conf
mv /etc/vdr/conf.avail/50-dvbapi.conf /etc/vdr/conf.avail/20-dvbapi.conf
mv /etc/vdr/conf.avail/50-ciplus.conf /etc/vdr/conf.avail/30-ciplus.conf

_ntfy 'busybox crond'
mkdir -p /var/spool/cron/crontabs
touch /var/spool/cron/crontabs/root
echo -e 'root\nvdr' >> /var/spool/cron/crontabs/cron.update
chmod 600 /var/spool/cron/crontabs/*

_ntfy 'SMTP client'
$pacinst msmtp-mta
curl -o /etc/msmtprc 'https://git.marlam.de/gitweb/?p=msmtp.git;a=blob_plain;f=doc/msmtprc-system.example'
chmod 640 /etc/msmtprc

_ntfy 'backup default files'
mkdir -p /defaults/config
mkdir -p /defaults/system
cp -Ran /var/lib/vdr/* /defaults/config
cp -Ran /etc/vdr/* /defaults/system

_ntfy 'move provided files'
find /base -type d -exec chmod 755 {} \;
cp -Rlf /base/* /
rm -rf /base

_ntfy 'copy provided settings'
cp -Rlf /defaults/config/* /var/lib/vdr
cp -Rlf /defaults/system/* /etc/vdr

_ntfy 'get png channellogos'
curl -s 'https://api.github.com/repos/lapicidae/svg-channellogos/releases/latest' | \
    grep "browser_download_url" | \
    grep -Eo 'https://[^\"]*' | \
    grep -v 'nolinks' | \
    grep -e 'light.*square' | \
    xargs curl -s -L -o /defaults/channellogos.tar.xz
curl -o /usr/local/bin/picon 'https://raw.githubusercontent.com/lapicidae/svg-channellogos/master/tools/picon'

_ntfy 'change permissions'
chown -R vdr:vdr \
    /defaults \
    /vdr
chown -R sysllog:sysllog /vdr/log
chmod 4754 \
    /usr/lib/vdr/bin/shutdown-wrapper \
    /usr/lib/vdr/bin/vdr-recordingaction
chmod 755 \
    /usr/local/bin/checkrec \
    /usr/local/bin/contenv2env \
    /usr/local/bin/healthy \
    /usr/local/bin/naludumper \
    /usr/local/bin/naludumper-cron \
    /usr/local/bin/picon \
    /usr/local/bin/vdr-channelids
chmod 600 /var/spool/cron/crontabs/*
chown root:root \
    /usr/local/bin/checkrec \
    /usr/local/bin/contenv2env \
    /usr/local/bin/healthy \
    /usr/local/bin/naludumper \
    /usr/local/bin/naludumper-cron \
    /usr/local/bin/picon \
    /usr/local/bin/vdr-channelids
chown root:vdr /usr/lib/vdr/bin/shutdown-wrapper
chown vdr:vdr /usr/lib/vdr/bin/vdr-recordingaction

_ntfy 'mark essential packages'
pacman -D --asexplicit \
    vdr \
    shadow

_ntfy 'Versioning'
paru -Gp vdr | grep -i pkgver= | cut -d = -f 2 > /vdr/VERSION

_ntfy 'CleanUp'
if [ "$buildOptimize" = "true" ]; then
    sed -i 's/^MAKEFLAGS=.*/#&/' "/etc/makepkg.conf"
fi
rm -rf \
    /tmp/* \
    /var/tmp/*
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
    systemd-sysvcompat
pacman --noconfirm -R "$(pacman -Qtdq)" 2>/dev/null || true
yes | pacman -Scc
find /etc -type f -name "*.pacnew" -delete
find /etc -type f -name "*.pacsave" -delete
find "$buildDir" -mindepth 1 -maxdepth 1 -type d -not -path '*/\.*' -exec rm -rf {} \;

_ntfy 'install busybox'
busybox --install -s


## Delete this script if it is running in a Docker container
if [ -f '/.dockerenv' ] || [ "$inVM" = 'true' ]; then
    _ntfy "delete this installer ($0)"
    rm -- "$0"
fi

_ntfy 'all done'
printf '\e[32;1;2m>>> DONE! <<<\e[m\n'
