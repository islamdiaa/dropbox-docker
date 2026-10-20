#!/bin/bash
set -e
echo "=== E2E Test: Root Never Follows Symlinks Planted By The Dropbox User ==="
# Regression test: before each daemon restart the entrypoint (root) used to
# empty and chmod ~/.dropbox/events by path. The dropbox user owns
# ~/.dropbox, so it could swap that folder for a symlink and have root
# delete and chmod whatever the link pointed at.
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-symlink-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

run_container "$CONTAINER_NAME" \
  -e DROPBOX_UID=1000 \
  -e DROPBOX_GID=1000 \
  -e DROPBOX_RESTART_DELAY=2 \
  -e POLLING_INTERVAL=2

wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"

# As the dropbox user: replace the locked analytics folder with a symlink to
# a folder of our own that has a file in it, then make the daemon "crash".
docker exec -u 1000 "$CONTAINER_NAME" sh -ec '
  mkdir -p /opt/dropbox/victim
  echo keep > /opt/dropbox/victim/file
  rmdir /opt/dropbox/.dropbox/events
  ln -s /opt/dropbox/victim /opt/dropbox/.dropbox/events
'
PID=$(daemon_pid "$CONTAINER_NAME")
docker exec -u 1000 "$CONTAINER_NAME" kill -9 "$PID"
wait_for_log "$CONTAINER_NAME" "Restarted Dropbox daemon" 60
sleep 3

if ! docker exec "$CONTAINER_NAME" test -f /opt/dropbox/victim/file; then
  echo "FAIL: Root deleted files through the planted symlink"
  exit 1
fi
MODE=$(docker exec "$CONTAINER_NAME" stat -c '%a' /opt/dropbox/victim)
if [ "$MODE" = "555" ]; then
  echo "FAIL: Root changed the permissions of the symlink target"
  exit 1
fi
echo "PASS: Symlink target untouched"

if docker exec "$CONTAINER_NAME" test -L /opt/dropbox/.dropbox/events; then
  echo "FAIL: The planted symlink is still in place"
  exit 1
fi
STAT=$(docker exec "$CONTAINER_NAME" stat -c '%U %a' /opt/dropbox/.dropbox/events)
if [ "$STAT" != "root 555" ]; then
  echo "FAIL: events was not recreated as a root-owned read-only folder ($STAT)"
  exit 1
fi
echo "PASS: Analytics folder locked again"

echo "=== Symlink safety tests passed ==="
