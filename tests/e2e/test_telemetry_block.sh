#!/bin/bash
set -e
echo "=== E2E Test: Telemetry Blocking ==="
CONTAINER_NAME="dropbox-test-telemetry-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  dropbox-test:e2e

sleep 5

# Verify telemetry.dropbox.com is blocked in /etc/hosts
HOSTS=$(docker exec "$CONTAINER_NAME" cat /etc/hosts)
if echo "$HOSTS" | grep -q "127.0.0.1.*telemetry.dropbox.com"; then
  echo "PASS: Telemetry endpoint blocked in /etc/hosts"
else
  echo "FAIL: Telemetry endpoint not blocked"
  echo "$HOSTS"
  exit 1
fi

# Verify the entry appears only once (idempotency check)
COUNT=$(echo "$HOSTS" | grep -c "telemetry.dropbox.com")
if [ "$COUNT" -eq 1 ]; then
  echo "PASS: Telemetry block entry is not duplicated"
else
  echo "FAIL: Telemetry block entry appears $COUNT times (expected 1)"
  exit 1
fi

echo "=== Telemetry blocking tests passed ==="
