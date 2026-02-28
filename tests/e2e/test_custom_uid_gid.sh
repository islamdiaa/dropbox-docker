#!/bin/bash
set -e
echo "=== E2E Test: Custom UID/GID ==="
CONTAINER_NAME="dropbox-test-uid-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

CUSTOM_UID=1234
CUSTOM_GID=5678

docker run -d --name "$CONTAINER_NAME" \
  -e SKIP_SET_PERMISSIONS=true \
  -e DROPBOX_UID=$CUSTOM_UID \
  -e DROPBOX_GID=$CUSTOM_GID \
  dropbox-test:e2e

sleep 5

# Verify the dropbox user has the custom UID
ACTUAL_UID=$(docker exec "$CONTAINER_NAME" id -u dropbox)
if [ "$ACTUAL_UID" = "$CUSTOM_UID" ]; then
  echo "PASS: Dropbox user UID is $CUSTOM_UID"
else
  echo "FAIL: Dropbox user UID is $ACTUAL_UID (expected $CUSTOM_UID)"
  exit 1
fi

# Verify the dropbox group has the custom GID
ACTUAL_GID=$(docker exec "$CONTAINER_NAME" id -g dropbox)
if [ "$ACTUAL_GID" = "$CUSTOM_GID" ]; then
  echo "PASS: Dropbox user GID is $CUSTOM_GID"
else
  echo "FAIL: Dropbox user GID is $ACTUAL_GID (expected $CUSTOM_GID)"
  exit 1
fi

# Verify /opt/dropbox is owned by the custom UID/GID
DIR_OWNER=$(docker exec "$CONTAINER_NAME" stat -c '%u:%g' /opt/dropbox)
if [ "$DIR_OWNER" = "${CUSTOM_UID}:${CUSTOM_GID}" ]; then
  echo "PASS: /opt/dropbox owned by ${CUSTOM_UID}:${CUSTOM_GID}"
else
  echo "FAIL: /opt/dropbox owned by $DIR_OWNER (expected ${CUSTOM_UID}:${CUSTOM_GID})"
  exit 1
fi

# Verify container is running
STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
if [ "$STATUS" = "running" ]; then
  echo "PASS: Container is running with custom UID/GID"
else
  echo "FAIL: Container is not running (status: $STATUS)"
  docker logs "$CONTAINER_NAME" | tail -10
  exit 1
fi

echo "=== Custom UID/GID tests passed ==="
