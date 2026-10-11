#!/bin/bash
set -e
echo "=== E2E Test: First Run On A Fresh Volume ==="
# Regression test: the analytics lockdown used to create ~/.dropbox as root on
# a fresh volume, so the daemon crash-looped on its first start.
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-firstrun-$$"
VOLUME_NAME="dropbox-test-firstrun-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "$VOLUME_NAME" > /dev/null 2>&1 || true
}
trap cleanup EXIT

run_container "$CONTAINER_NAME" \
  -v "$VOLUME_NAME:/opt/dropbox" \
  -e DROPBOX_UID=1000 \
  -e DROPBOX_GID=1000

wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
sleep 10

LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
if echo "$LOGS" | grep -qE "bootstrap panic|unable to open database|Dropbox daemon exited"; then
  echo "FAIL: Daemon failed on first run"
  echo "$LOGS" | tail -20
  exit 1
fi
echo "PASS: Daemon started cleanly on a fresh volume"

OWNER=$(docker exec "$CONTAINER_NAME" stat -c '%u:%g' /opt/dropbox/.dropbox)
if [ "$OWNER" != "1000:1000" ]; then
  echo "FAIL: /opt/dropbox/.dropbox is owned by $OWNER, expected 1000:1000"
  exit 1
fi
echo "PASS: Config folder is owned by the dropbox user"

if ! docker exec "$CONTAINER_NAME" test -f /opt/dropbox/.dropbox/apex.sqlite3; then
  echo "FAIL: Daemon did not create its database"
  exit 1
fi
echo "PASS: Daemon database created"

echo "=== First run tests passed ==="
