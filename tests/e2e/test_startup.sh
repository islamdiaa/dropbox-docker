#!/bin/bash
set -e
echo "=== E2E Test: Container Startup ==="
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-startup-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

run_container "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true

wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
echo "PASS: Daemon started"

sleep 10

# Check container is still running
STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
if [ "$STATUS" != "running" ]; then
  echo "FAIL: Container is not running (status: $STATUS)"
  docker logs "$CONTAINER_NAME"
  exit 1
fi
echo "PASS: Container is running"

if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Dropbox daemon exited"; then
  echo "FAIL: Daemon exited after startup"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -20
  exit 1
fi
echo "PASS: Daemon stayed up"

echo "=== Startup tests passed ==="
