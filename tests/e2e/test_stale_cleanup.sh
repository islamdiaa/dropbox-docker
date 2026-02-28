#!/bin/bash
set -e
echo "=== E2E Test: Stale File Cleanup ==="
CONTAINER_NAME="dropbox-test-stale-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# Create a container with a named volume so we can pre-populate stale files
VOLUME_NAME="dropbox-test-stale-vol-$$"
docker volume create "$VOLUME_NAME" > /dev/null

# Extend cleanup to also remove the volume
cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "$VOLUME_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# Pre-populate the volume with stale files using a temporary container
docker run --rm -v "$VOLUME_NAME":/opt/dropbox alpine sh -c '
  mkdir -p /opt/dropbox/.dropbox
  touch /opt/dropbox/.dropbox/command_socket
  touch /opt/dropbox/.dropbox/iface_socket
  touch /opt/dropbox/.dropbox/dropbox.pid
'

# Verify stale files exist
BEFORE=$(docker run --rm -v "$VOLUME_NAME":/opt/dropbox alpine ls -la /opt/dropbox/.dropbox/ 2>&1)
if echo "$BEFORE" | grep -q "command_socket"; then
  echo "SETUP: Stale command_socket exists before startup"
else
  echo "FAIL: Could not create stale files for test"
  exit 1
fi

# Start the real container with the pre-populated volume
docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  -v "$VOLUME_NAME":/opt/dropbox \
  dropbox-test:e2e

sleep 8

# Verify stale files were cleaned up
if docker exec "$CONTAINER_NAME" test -e /opt/dropbox/.dropbox/command_socket 2>/dev/null; then
  echo "FAIL: Stale command_socket was not cleaned up"
  exit 1
else
  echo "PASS: Stale command_socket cleaned up"
fi

if docker exec "$CONTAINER_NAME" test -e /opt/dropbox/.dropbox/iface_socket 2>/dev/null; then
  echo "FAIL: Stale iface_socket was not cleaned up"
  exit 1
else
  echo "PASS: Stale iface_socket cleaned up"
fi

if docker exec "$CONTAINER_NAME" test -e /opt/dropbox/.dropbox/dropbox.pid 2>/dev/null; then
  echo "FAIL: Stale dropbox.pid was not cleaned up"
  exit 1
else
  echo "PASS: Stale dropbox.pid cleaned up"
fi

echo "=== Stale file cleanup tests passed ==="
