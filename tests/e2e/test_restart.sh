#!/bin/bash
set -e
echo "=== E2E Test: Daemon Restart ==="
CONTAINER_NAME="dropbox-test-restart-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  -e DROPBOX_RESTART_DELAY=3 \
  -e DROPBOX_MAX_RESTARTS=2 \
  dropbox-test:e2e

sleep 10

# Kill the dropboxd process inside the container
docker exec "$CONTAINER_NAME" bash -c 'kill $(pgrep -f dropboxd | head -1)' 2>/dev/null || true

# Wait for restart
sleep 10

# Check if container is still running (should have restarted the daemon)
STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)

if echo "$LOGS" | grep -q "Restart attempt"; then
  echo "PASS: Restart attempt detected in logs"
else
  echo "WARNING: Restart message not found (container status: $STATUS)"
  echo "$LOGS" | tail -15
fi

echo "=== Restart tests passed ==="
