#!/bin/bash

imageTag=${imageTag:-"vdr-server"}
miniVers=${miniVers:-"false"}

printf -v vdrVersion '%s' "$(curl -s 'https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=vdr' | grep -i '^pkgver' | cut -d = -f 2)"
printf -v dateTime '%s' "$(date +%Y-%m-%dT%H:%M:%S%z)"
printf -v vdrRevision '%s' "$(git ls-remote -t 'git://git.tvdr.de/vdr.git' "${vdrVersion}" | cut -f 1)"
printf -v baseDigest '%s' "$(docker image pull archlinux:latest | grep -i digest | cut -d ' ' -f 2)"

docker build \
    --tag "${imageTag}" \
    --build-arg miniVers="${miniVers}" \
    --build-arg baseDigest="${baseDigest}" \
    --build-arg dateTime="${dateTime}" \
    --build-arg vdrRevision="${vdrRevision}" \
    --build-arg vdrVersion="${vdrVersion}" \
    .
