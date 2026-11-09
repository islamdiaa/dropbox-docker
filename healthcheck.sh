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

# Bounded well under Docker's 10s healthcheck timeout: a busy daemon answers
# slowly, and that must not turn a running container unhealthy.
gosu dropbox timeout 6 dropbox status 2>/dev/null | head -1
exit 0
