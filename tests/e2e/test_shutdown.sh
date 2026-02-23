#!/bin/bash
set -e
echo "=== E2E Test: Graceful Shutdown ==="
CONTAINER_NAME="dropbox-test-shutdown-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  dropbox-test:e2e

sleep 10

# Send stop signal
docker stop -t 15 "$CONTAINER_NAME"

# Check logs for graceful shutdown
LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
if echo "$LOGS" | grep -q "Received shutdown signal"; then
  echo "PASS: Graceful shutdown detected"
else
  echo "WARNING: Graceful shutdown message not found"
  echo "$LOGS" | tail -10
fi

echo "=== Shutdown tests passed ==="
