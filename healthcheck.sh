#!/bin/bash
# Docker HEALTHCHECK: healthy while the Dropbox daemon process is running.
#
# Checks the process rather than `dropbox status`, which only reports what
# the daemon says and is unavailable until the CLI has been downloaded.
# The status line is still printed so `docker inspect` shows it.

if ! pgrep -f '^/opt/dropbox/bin/dropbox-lnx[^ ]*/dropbox' > /dev/null; then
  echo "Dropbox daemon is not running"
  exit 1
fi

gosu dropbox dropbox status 2>/dev/null | head -1
exit 0
