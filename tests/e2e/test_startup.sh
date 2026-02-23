#!/bin/bash
set -e
echo "=== E2E Test: Container Startup ==="
CONTAINER_NAME="dropbox-test-startup-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  dropbox-test:e2e

sleep 10

# Check container is still running
STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
if [ "$STATUS" != "running" ]; then
  echo "FAIL: Container is not running (status: $STATUS)"
  docker logs "$CONTAINER_NAME"
  exit 1
fi
echo "PASS: Container is running"

# Check logs for auth URL or successful start
LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
if echo "$LOGS" | grep -qE "dropbox.com/cli_link|Starting dropboxd|Dropbox updated"; then
  echo "PASS: Daemon started (auth URL or start message found)"
else
  echo "WARNING: Expected startup messages not found in logs"
  echo "$LOGS" | tail -20
fi

echo "=== Startup tests passed ==="
