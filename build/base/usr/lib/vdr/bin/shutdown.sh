#!/bin/bash

## http://www.vdr-wiki.de/wiki/index.php/C%27t-VDR_-_Hooks#shutdown-hooks
#Run through shutdown-hooks
for file in /etc/vdr/shutdown-hooks/*; do
  if [ -x "$file" ]; then
    MESSAGE=$($file)
    # shellcheck disable=SC2181
    if [ $? != '0' ]; then
      MESSAGE=$(echo "$MESSAGE" | sed -rn '0,/ABORT_MESSAGE/s/^ABORT_MESSAGE="?([^"]+).*/\1/p')
      svdrpsend MESG "$MESSAGE"
      exit 1
    fi
  fi
done
