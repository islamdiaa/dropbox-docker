#!/bin/bash
set -e
echo "=== E2E Test: Hardened Capabilities (cap_drop: ALL) ==="
# Regression test for #11: without CAP_KILL the entrypoint mistook a running
# daemon for a crashed one and kept starting new instances.
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-caps-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

run_container "$CONTAINER_NAME" "${HARDENED_CAPS[@]}" \
  -e DROPBOX_RESTART_DELAY=3 \
  -e POLLING_INTERVAL=2

wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
# Give the supervision loop several polls to (wrongly) restart the daemon
sleep 20

LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
if echo "$LOGS" | grep -qE "Dropbox daemon exited|Restart attempt"; then
  echo "FAIL: Running daemon was treated as exited"
  echo "$LOGS" | tail -20
  exit 1
fi
echo "PASS: No false restarts"

DAEMONS=$(count_daemons "$CONTAINER_NAME")
if [ "$DAEMONS" != "1" ]; then
  echo "FAIL: Expected 1 Dropbox daemon, found $DAEMONS"
  exit 1
fi
echo "PASS: Exactly one Dropbox daemon running"

docker stop -t 15 "$CONTAINER_NAME" > /dev/null
EXIT_CODE=$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME")
if [ "$EXIT_CODE" != "0" ] || ! docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Dropbox daemon stopped"; then
  echo "FAIL: Daemon was not stopped cleanly without CAP_KILL (exit code $EXIT_CODE)"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -10
  exit 1
fi
echo "PASS: Clean shutdown without CAP_KILL"

echo "=== Hardened capabilities tests passed ==="
