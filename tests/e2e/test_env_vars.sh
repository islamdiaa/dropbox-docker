#!/bin/bash
set -e
echo "=== E2E Test: Environment Variables ==="
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-env-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# Test timezone
run_container "$CONTAINER_NAME" \
  -e TZ=America/New_York \
  -e SKIP_SET_PERMISSIONS=true

sleep 5

LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
if echo "$LOGS" | grep -q "America/New_York"; then
  echo "PASS: Timezone set correctly"
else
  echo "FAIL: Timezone not set"
  echo "$LOGS" | head -5
  exit 1
fi

echo "=== Environment variable tests passed ==="
