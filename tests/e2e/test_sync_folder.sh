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
docker rm -f "$CONTAINER_NAME" > /dev/null

# With OWNERSHIP_FIX_MODE=disabled the folder must be left alone, and the
# problem reported loudly instead.
docker volume rm "$VOLUME_NAME" > /dev/null
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

echo "=== Sync folder tests passed ==="
