#!/bin/bash
set -e
echo "=== E2E Test: Monitoring, Status Page And Metrics ==="
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-monitoring-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

run_container "$CONTAINER_NAME" \
  -e ENABLE_MONITORING=true \
  -e SKIP_SET_PERMISSIONS=true

wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
wait_for_log "$CONTAINER_NAME" "Monitoring started" 30

# fetch PATH: request a URL inside the container, retrying while it starts
fetch() {
  local attempt
  for attempt in $(seq 1 15); do
    if docker exec "$CONTAINER_NAME" curl -fsS "http://127.0.0.1:$1" 2>/dev/null; then
      return 0
    fi
    [ "$attempt" -lt 15 ] && sleep 2
  done
  echo "FAIL: Could not fetch $1" >&2
  docker logs "$CONTAINER_NAME" 2>&1 | tail -20 >&2
  return 1
}

HEALTH=$(fetch 8001/health)
if ! echo "$HEALTH" | grep -q '"healthy": true'; then
  echo "FAIL: /health did not report healthy: $HEALTH"
  exit 1
fi
echo "PASS: /health reports the running daemon"

STATUS=$(fetch 8001/status)
if ! echo "$STATUS" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["healthy"] is True, data
assert data["account"] == {"linked": False}, data
assert data["daemon"]["version"], data
assert data["daemon"]["memory_mb"] and data["daemon"]["memory_mb"] > 10, data
assert data["daemon"]["restart_count"] == 0, data
'; then
  echo "FAIL: /status is missing expected fields: $STATUS"
  exit 1
fi
echo "PASS: /status reports daemon version, memory and restarts"

PAGE=$(fetch 8001/)
if ! echo "$PAGE" | grep -q '<script src="app.js"'; then
  echo "FAIL: Status page not served"
  exit 1
fi
fetch 8001/app.js > /dev/null
fetch 8001/style.css > /dev/null
echo "PASS: Status page and assets served"

METRICS=$(fetch 8000/metrics)
for metric in dropbox_status dropbox_daemon_up dropbox_daemon_memory_bytes dropbox_daemon_restarts; do
  if ! echo "$METRICS" | grep -q "^$metric"; then
    echo "FAIL: Prometheus metric $metric missing"
    exit 1
  fi
done
if ! echo "$METRICS" | grep -q "^dropbox_daemon_up 1.0"; then
  echo "FAIL: dropbox_daemon_up is not 1"
  exit 1
fi
echo "PASS: Prometheus metrics exported"

echo "=== Monitoring tests passed ==="
