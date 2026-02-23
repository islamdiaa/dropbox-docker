#!/bin/bash
set -e
echo "=== E2E Test: Healthcheck ==="
CONTAINER_NAME="dropbox-test-health-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  dropbox-test:e2e

# Check that healthcheck exists and container starts in 'starting' state
sleep 5
HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "none")
if [ "$HEALTH" = "starting" ] || [ "$HEALTH" = "healthy" ]; then
  echo "PASS: Healthcheck is active (status: $HEALTH)"
else
  echo "FAIL: Healthcheck status unexpected: $HEALTH"
  exit 1
fi

echo "=== Healthcheck tests passed ==="
