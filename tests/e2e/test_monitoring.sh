#!/bin/bash
set -e
echo "=== E2E Test: Monitoring Server ==="
CONTAINER_NAME="dropbox-test-monitoring-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  -e ENABLE_MONITORING=true \
  -e POLLING_INTERVAL=2 \
  -p 18001:8001 \
  dropbox-test:e2e

sleep 10

# Verify container is running
STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
if [ "$STATUS" != "running" ]; then
  echo "FAIL: Container is not running (status: $STATUS)"
  docker logs "$CONTAINER_NAME" | tail -20
  exit 1
fi
echo "PASS: Container is running"

# Verify monitoring started message in logs
LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
if echo "$LOGS" | grep -q "Monitoring started"; then
  echo "PASS: Monitoring process started"
else
  echo "FAIL: Monitoring started message not found in logs"
  echo "$LOGS" | tail -15
  exit 1
fi

# Test JSON status API endpoint
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18001/status 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  echo "PASS: /status endpoint returns 200"
else
  echo "FAIL: /status endpoint returned $HTTP_CODE (expected 200)"
  exit 1
fi

# Verify /status response is valid JSON with expected structure
RESPONSE=$(curl -s http://localhost:18001/status 2>/dev/null)
if echo "$RESPONSE" | python3 -c "import sys, json; d = json.load(sys.stdin); assert 'status' in d and 'sync' in d and 'daemon' in d" 2>/dev/null; then
  echo "PASS: /status returns valid JSON with expected structure"
else
  echo "FAIL: /status response is not valid JSON or missing keys"
  echo "$RESPONSE"
  exit 1
fi

# Test /health endpoint
HEALTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18001/health 2>/dev/null || echo "000")
if [ "$HEALTH_CODE" = "200" ]; then
  echo "PASS: /health endpoint returns 200"
else
  echo "FAIL: /health endpoint returned $HEALTH_CODE (expected 200)"
  exit 1
fi

# Verify /health returns {"ok": true}
HEALTH_RESPONSE=$(curl -s http://localhost:18001/health 2>/dev/null)
if echo "$HEALTH_RESPONSE" | python3 -c "import sys, json; d = json.load(sys.stdin); assert d.get('ok') is True" 2>/dev/null; then
  echo "PASS: /health returns {\"ok\": true}"
else
  echo "FAIL: /health response unexpected: $HEALTH_RESPONSE"
  exit 1
fi

# Test 404 for unknown path
NOT_FOUND_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18001/nonexistent 2>/dev/null || echo "000")
if [ "$NOT_FOUND_CODE" = "404" ]; then
  echo "PASS: Unknown path returns 404"
else
  echo "FAIL: Unknown path returned $NOT_FOUND_CODE (expected 404)"
  exit 1
fi

echo "=== Monitoring server tests passed ==="
