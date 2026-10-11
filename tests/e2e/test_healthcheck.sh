#!/bin/bash
set -e
echo "=== E2E Test: Healthcheck ==="
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-health-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" --format '{{json .Config.Healthcheck}}' | grep -q "healthcheck.sh"; then
  echo "FAIL: Healthcheck is not configured"
  exit 1
fi
echo "PASS: Healthcheck configured"

# Without a running daemon the check must fail
if docker run --rm --entrypoint /healthcheck.sh "$IMAGE" > /dev/null; then
  echo "FAIL: Healthcheck passed without a running daemon"
  exit 1
fi
echo "PASS: Healthcheck fails without a running daemon"

run_container "$CONTAINER_NAME" \
  --health-interval 5s \
  --health-start-period 5s \
  -e SKIP_SET_PERMISSIONS=true

wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"

HEALTH=""
for _ in $(seq 1 20); do
  HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME")
  [ "$HEALTH" = "healthy" ] && break
  sleep 3
done
if [ "$HEALTH" != "healthy" ]; then
  echo "FAIL: Container did not become healthy (status: $HEALTH)"
  docker inspect --format '{{json .State.Health}}' "$CONTAINER_NAME"
  exit 1
fi
echo "PASS: Container is healthy"

echo "=== Healthcheck tests passed ==="
