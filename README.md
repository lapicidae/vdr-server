[![vdr](https://raw.githubusercontent.com/lapicidae/vdr-server/master/vdr-logo.svg)](http://www.tvdr.de/)

The Video Disk Recorder ([VDR](http://www.tvdr.de/)) is a free, non-commercial project from Klaus Schmidinger to create a digital video recorder using standard PC components. It is possible to receive, record and playback digital TV broadcasts compatible with the DVB standard.


# [lapicidae/vdr-server](https://github.com/lapicidae/vdr-server)

[![GitHub Stars](https://img.shields.io/github/stars/lapicidae/vdr-server.svg?color=3c0e7b&labelColor=555555&logoColor=ffffff&style=for-the-badge&logo=github)](https://github.com/lapicidae/vdr-server)
[![Docker Pulls](https://img.shields.io/docker/pulls/lapicidae/vdr-server.svg?color=3c0e7b&labelColor=555555&logoColor=ffffff&style=for-the-badge&label=pulls&logo=docker)](https://hub.docker.com/r/lapicidae/vdr-server)
[![Docker Stars](https://img.shields.io/docker/stars/lapicidae/vdr-server.svg?color=3c0e7b&labelColor=555555&logoColor=ffffff&style=for-the-badge&label=stars&logo=docker)](https://hub.docker.com/r/lapicidae/vdr-server)

Image based on [Arch Linux](https://hub.docker.com/_/archlinux), [VDR4Arch](https://github.com/VDR4Arch/vdr4arch), [s6-overlay](https://github.com/just-containers/s6-overlay) and [socklog-overlay](https://github.com/just-containers/socklog-overlay).


## Features

* regular and timely application updates
* easy user mappings (PGID, PUID)
* regular security updates
* plugin [ciplus](https://github.com/ciminus/vdr-plugin-ciplus) and [ddci2](https://github.com/jasmin-j/vdr-plugin-ddci2) support
* msmtprc - a very simple and easy to use SMTP client with fairly complete sendmail compatibility

### Note
The image is automatically rebuilt when any of the following sources receive an update:

* [Arch Linux](https://hub.docker.com/_/archlinux) Official Docker Image - latest
* [VDR4Arch](https://github.com/VDR4Arch) GitHub repository


## Application Setup

Please read the [VDR Wiki](http://www.vdr-wiki.de/).

Webui can be found at `http://<your-ip>:8008`.  
Most VDR settings can be edited via the webui remote.


## Usage
Here are some example snippets to help you get started creating a container.

### docker-compose (recommended)

Compatible with docker-compose v2 schemas.
```yaml
version: "2.1"
services:
  vdr-server:
    image: lapicidae/vdr-server
    container_name: vdr-server
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Berlin
      - PLUGINS=epgsearch live streamdev-server vnsiserver #optional
    volumes:
      - /path/to/system:/vdr/system
      - /path/to/config:/vdr/config
      - /path/to/recordings:/vdr/recordings
      - /path/to/cache:/vdr/cache
      - /opt/vc/lib:/vdr/timeshift #optional
    ports:
      - 8008:8008
      - 6419:6419 #optional
      - 6419:6419/udp #optional
      - 34890:34890 #optional
    devices:
      - /dev/dvb:/dev/dvb #optional
    restart: unless-stopped
```

### docker cli

```bash
docker run -d \
  --name=vdr-server \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Europe/Berlin \
  -e PLUGINS=epgsearch live streamdev-server vnsiserver `#optional` \
  -p 8008:8008 \
  -p 6419:6419 `#optional` \
  -p 6419:6419/udp `#optional` \
  -p 34890:34890 `#optional` \
  -v /path/to/system:/vdr/system \
  -v /path/to/config:/vdr/config \
  -v /path/to/recordings:/vdr/recordings \
  -v /path/to/cache:/vdr/cache \
  -v /opt/vc/lib:/vdr/timeshift `#optional` \
  --device /dev/dvb:/dev/dvb `#optional` \
  --restart unless-stopped \
  lapicidae/vdr-server
```


## Parameters

Container images are configured using parameters passed at runtime.  
These parameters are separated by a colon and indicate `<external>:<internal>` respectively.  
For example, `-p 8080:80` would expose port `80` from inside the container to be accessible from the host's IP on port `8080` outside the container.

| Parameter | Function |
| :----: | --- |
| `-p 8008` | Http VDR-Live plugin. |
| `-p 8009` | Optional - Https VDR-Live plugin (you need to set up your own certificate). |
| `-p 6419` | Optional - Simple VDR Protocol (SVDRP). |
| `-p 6419/udp` | Optional - SVDRP Peering. |
| `-p 2004` | Optional - Streamdev Server (VDR-to-VDR Streaming). |
| `-p 3000` | Optional - Streamdev Server (HTTP Streaming). |
| `-p 34890` | Optional - VDR-Network-Streaming-Interface (VNSI). |
| `-e PUID=1000` | for UserID - see below for explanation |
| `-e PGID=1000` | for GroupID - see below for explanation |
| `-e TZ=Europe/Berlin` | Specify a timezone to use (e.g. Europe/Berlin). |
| `-e PLUGINS=epgsearch live streamdev-server vnsiserver` | Optional - **Space separated** list of [VDR Plugins](https://github.com/VDR4Arch/vdr4arch/tree/master/plugins) (default: `epgsearch live streamdev-server vnsiserver`). |
| `-v /vdr/system` | Start parameters, recording hooks and msmtprc config. |
| `-v /vdr/config` | Config files (e.g. `setup.conf` or `channels.conf`) |
| `-v /vdr/recordings` | Recording directory (aka video directory). |
| `-v /vdr/cache` | Cache files (e.g. `epgimages` or `cam.data`) |
| `-v /vdr/timeshift` | VNSI Time-Shift Buffer Directory. |
| `--device /dev/dvb` | Only needed if you want to pass through a DVB card to the container. |


## User / Group Identifiers

When using volumes (`-v` flags) permissions issues can arise between the host OS and the container, we avoid this issue by allowing you to specify the user `PUID` and group `PGID`.

Ensure any volume directories on the host are owned by the same user you specify and any permissions issues will vanish like magic.

In this instance `PUID=1000` and `PGID=1000`, to find yours use `id user` as below:

```bash
  $ id username
    uid=1000(dockeruser) gid=1000(dockergroup) groups=1000(dockergroup)
```


## Thanks

* **[Klaus Schmidinger (kls)](http://www.tvdr.de/)**
* **[vdr-portal.de](https://www.vdr-portal.de/)**
* **[VDR4Arch](https://github.com/VDR4Arch)**
* **[just-containers](https://github.com/just-containers)**
* **[linuxserver.io](https://www.linuxserver.io/)**