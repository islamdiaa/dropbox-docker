#!/bin/bash
set -e
echo "=== E2E Test: Graceful Shutdown ==="
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-shutdown-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# A long polling interval (the Unraid template uses 30s) must not delay
# shutdown past the `docker stop` timeout, or the daemon gets SIGKILLed.
run_container "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  -e POLLING_INTERVAL=60

wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
sleep 5

START=$(date +%s)
docker stop -t 10 "$CONTAINER_NAME" > /dev/null
ELAPSED=$(( $(date +%s) - START ))

LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
EXIT_CODE=$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME")
if ! echo "$LOGS" | grep -q "Received shutdown signal"; then
  echo "FAIL: Shutdown signal was not handled"
  echo "$LOGS" | tail -10
  exit 1
fi
if [ "$EXIT_CODE" != "0" ] || ! echo "$LOGS" | grep -q "Dropbox daemon stopped"; then
  echo "FAIL: Container did not stop cleanly (exit code $EXIT_CODE, took ${ELAPSED}s)"
  echo "$LOGS" | tail -10
  exit 1
fi
echo "PASS: Graceful shutdown in ${ELAPSED}s with exit code 0"

echo "=== Shutdown tests passed ==="
