# Build local packages
If you want to (re)build or patch packages by yourself.  
[ArchWiki](https://wiki.archlinux.org/title/PKGBUILD)

## Howto
> Place a directory containing a valid PKGBUILD file (and others) in `/vdr/pkgbuild`  
> Start / Restart container

## Features
  * changes in the dir are detected and a rebuild begins when the container starts
  * if a file named `rebuild` is found in the dir, the package is rebuilt at startup
  * if a file named `vdrplug-PLUGINNAME` is found, the VDR plugin will be activated at container start.

### VDR Plugin Example:
```bash
cd /vdr/pkgbuild
git clone https://aur.archlinux.org/vdr-eepg.git vdr-eepg
touch vdr-eepg/vdrplug-eepg `# VDR plugin "eepg" activation`
```