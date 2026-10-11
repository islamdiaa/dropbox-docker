#!/bin/bash
set -e
echo "=== E2E Test: Daemon Restart ==="
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-restart-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

run_container "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  -e DROPBOX_RESTART_DELAY=3 \
  -e DROPBOX_MAX_RESTARTS=2 \
  -e POLLING_INTERVAL=2

wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"

# Kill the daemon as its own user, simulating a crash
PID=$(daemon_pid "$CONTAINER_NAME")
docker exec -u "$(docker exec "$CONTAINER_NAME" id -u dropbox)" "$CONTAINER_NAME" kill -9 "$PID"

wait_for_log "$CONTAINER_NAME" "Restarted Dropbox daemon" 60
echo "PASS: Restart attempt detected in logs"

sleep 10
STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
if [ "$STATUS" != "running" ]; then
  echo "FAIL: Container is not running after daemon restart (status: $STATUS)"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -15
  exit 1
fi
DAEMONS=$(count_daemons "$CONTAINER_NAME")
if [ "$DAEMONS" != "1" ]; then
  echo "FAIL: Expected 1 Dropbox daemon after restart, found $DAEMONS"
  exit 1
fi
echo "PASS: Daemon restarted, exactly one instance running"

echo "=== Restart tests passed ==="
