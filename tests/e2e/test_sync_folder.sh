#!/bin/bash
set -e
echo "=== E2E Test: Sync Folder Permissions ==="
# Regression test for #12: a sync folder created by Docker is owned by root,
# so the daemon linked fine but could never write a file.
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-syncdir-$$"
VOLUME_NAME="dropbox-test-syncdir-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "$VOLUME_NAME" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# A new named volume's root directory is root:root 755, just like a bind
# mount source that Docker creates on the host. Use Unraid's nobody:users.
run_container "$CONTAINER_NAME" \
  -v "$VOLUME_NAME:/opt/dropbox/Dropbox" \
  -e DROPBOX_UID=99 \
  -e DROPBOX_GID=100

wait_for_log "$CONTAINER_NAME" "Starting dropboxd"

if ! docker exec "$CONTAINER_NAME" gosu dropbox touch /opt/dropbox/Dropbox/.write-test; then
  echo "FAIL: Sync folder is not writable by the dropbox user"
  docker logs "$CONTAINER_NAME" 2>&1 | head -20
  exit 1
fi
echo "PASS: Sync folder is writable by the dropbox user"

# Dropbox's own cache in the sync folder must survive a restart
docker exec "$CONTAINER_NAME" gosu dropbox mkdir -p /opt/dropbox/Dropbox/.dropbox.cache/partial
# A file created by root while the container is down gets fixed at startup
docker exec "$CONTAINER_NAME" touch /opt/dropbox/Dropbox/created-by-root
# A folder Dropbox can already write to keeps its mode: shares are often
# group- or world-writable on the host, and resetting them locks others out.
docker exec "$CONTAINER_NAME" chmod 2775 /opt/dropbox/Dropbox
docker restart "$CONTAINER_NAME" > /dev/null
# The log keeps the first run's lines; wait for the second start
for _ in $(seq 1 60); do
  [ "$(docker logs "$CONTAINER_NAME" 2>&1 | grep -c "Dropbox daemon is ready")" -ge 2 ] && break
  sleep 2
done
sleep 5
if ! docker exec "$CONTAINER_NAME" test -d /opt/dropbox/Dropbox/.dropbox.cache/partial; then
  echo "FAIL: .dropbox.cache was deleted on restart"
  exit 1
fi
echo "PASS: .dropbox.cache kept across restarts"
OWNER=$(docker exec "$CONTAINER_NAME" stat -c '%u' /opt/dropbox/Dropbox/created-by-root)
if [ "$OWNER" != "99" ]; then
  echo "FAIL: Root-owned file was not repaired at startup (owner $OWNER)"
  exit 1
fi
echo "PASS: Ownership repaired at startup"
MODE=$(docker exec "$CONTAINER_NAME" stat -c '%a' /opt/dropbox/Dropbox)
if [ "$MODE" != "2775" ]; then
  echo "FAIL: Writable sync folder's mode was changed from 2775 to $MODE on restart"
  exit 1
fi
echo "PASS: Writable sync folder keeps its mode across restarts"
docker rm -f "$CONTAINER_NAME" > /dev/null

# With OWNERSHIP_FIX_MODE=disabled the folder must be left alone, and the
# problem reported loudly instead.
docker volume rm "$VOLUME_NAME" > /dev/null
# A file owned by the image's built-in dropbox UID: usermod used to re-own
# such files across the whole sync folder when it changed the user's UID.
IMAGE_UID=$(docker run --rm -v "$VOLUME_NAME:/opt/dropbox/Dropbox" --entrypoint bash "$IMAGE" -c \
  'touch /opt/dropbox/Dropbox/owned-by-image-uid && chown dropbox:dropbox /opt/dropbox/Dropbox/owned-by-image-uid && id -u dropbox')
run_container "$CONTAINER_NAME" \
  -v "$VOLUME_NAME:/opt/dropbox/Dropbox" \
  -e DROPBOX_UID=99 \
  -e DROPBOX_GID=100 \
  -e OWNERSHIP_FIX_MODE=disabled

wait_for_log "$CONTAINER_NAME" "Starting dropboxd"
OWNER=$(docker exec "$CONTAINER_NAME" stat -c '%u:%g' /opt/dropbox/Dropbox)
if [ "$OWNER" != "0:0" ]; then
  echo "FAIL: OWNERSHIP_FIX_MODE=disabled changed the sync folder owner to $OWNER"
  exit 1
fi
if ! docker logs "$CONTAINER_NAME" 2>&1 | grep -q "is not writable by UID 99"; then
  echo "FAIL: Unwritable sync folder was not reported"
  exit 1
fi
echo "PASS: OWNERSHIP_FIX_MODE=disabled leaves ownership alone and reports the problem"
OWNER=$(docker exec "$CONTAINER_NAME" stat -c '%u' /opt/dropbox/Dropbox/owned-by-image-uid)
if [ "$OWNER" != "$IMAGE_UID" ]; then
  echo "FAIL: A file in the sync folder was re-owned from $IMAGE_UID to $OWNER with OWNERSHIP_FIX_MODE=disabled"
  exit 1
fi
echo "PASS: Changing the dropbox user's UID does not re-own files in the sync folder"

echo "=== Sync folder tests passed ==="
