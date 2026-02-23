#!/bin/bash
set -e
echo "=== E2E Test: Permissions ==="
CONTAINER_NAME="dropbox-test-perms-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# Test SKIP_SET_PERMISSIONS=true (default)
docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  dropbox-test:e2e

sleep 5

LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
if echo "$LOGS" | grep -q "Skipping recursive permission check"; then
  echo "PASS: Skip permissions mode works"
else
  echo "FAIL: Skip permissions message not found"
  echo "$LOGS" | head -10
  exit 1
fi

echo "=== Permissions tests passed ==="
