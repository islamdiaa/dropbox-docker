#!/bin/bash
set -e
echo "=== E2E Test: Analytics Directory Locking ==="
CONTAINER_NAME="dropbox-test-analytics-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  dropbox-test:e2e

sleep 5

# Verify analytics directories exist and are owned by root with 555 permissions
for dir in events ssa_events sentry_exceptions; do
  OWNER=$(docker exec "$CONTAINER_NAME" stat -c '%U' "/opt/dropbox/.dropbox/$dir" 2>/dev/null || echo "missing")
  PERMS=$(docker exec "$CONTAINER_NAME" stat -c '%a' "/opt/dropbox/.dropbox/$dir" 2>/dev/null || echo "missing")

  if [ "$OWNER" = "root" ]; then
    echo "PASS: /opt/dropbox/.dropbox/$dir is owned by root"
  else
    echo "FAIL: /opt/dropbox/.dropbox/$dir owner is '$OWNER' (expected root)"
    exit 1
  fi

  if [ "$PERMS" = "555" ]; then
    echo "PASS: /opt/dropbox/.dropbox/$dir has 555 permissions"
  else
    echo "FAIL: /opt/dropbox/.dropbox/$dir perms are '$PERMS' (expected 555)"
    exit 1
  fi
done

# Verify the dropbox user cannot write to locked analytics directories
WRITE_TEST=$(docker exec "$CONTAINER_NAME" gosu dropbox touch /opt/dropbox/.dropbox/events/test_file 2>&1 || true)
if echo "$WRITE_TEST" | grep -qi "permission denied\|read-only\|cannot touch"; then
  echo "PASS: Dropbox user cannot write to locked analytics directory"
else
  # Check if the file was actually created
  if docker exec "$CONTAINER_NAME" test -f /opt/dropbox/.dropbox/events/test_file 2>/dev/null; then
    echo "FAIL: Dropbox user was able to write to locked analytics directory"
    exit 1
  else
    echo "PASS: Dropbox user cannot write to locked analytics directory"
  fi
fi

echo "=== Analytics locking tests passed ==="
