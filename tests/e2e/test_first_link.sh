#!/bin/bash
set -e
echo "=== E2E Test: First Link Into A Mapped Sync Folder ==="
# Regression test for #31: on its first link the client moves a ~/Dropbox
# that isn't the account's Dropbox folder aside to "Dropbox (Old)". A mapped
# sync folder is a mount point, so that rename failed with EBUSY and the
# client hung on "Starting..." for good.
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-firstlink-$$"
VOLUME_NAME="dropbox-test-firstlink-$$"
LIB=/usr/local/lib/keep_sync_folder.so
WARNING="The sync folder has files in it"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "$VOLUME_NAME" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Moves the sync folder aside the way the client does, with the library
# preloaded. Exits 0 if the rename is reported as done, else its errno.
try_rename() {
  docker exec "$CONTAINER_NAME" gosu dropbox env LD_PRELOAD="$LIB" python3 -c '
import os, sys
try:
    os.rename("/opt/dropbox/Dropbox", sys.argv[1])
except OSError as e:
    sys.exit(e.errno)' "$1"
}

run_container "$CONTAINER_NAME" \
  -v "$VOLUME_NAME:/opt/dropbox/Dropbox" \
  -e DROPBOX_UID=99 \
  -e DROPBOX_GID=100

wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"

# The library has to reach the client itself, which runs as the dropbox user
if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "cannot be preloaded"; then
  echo "FAIL: The dynamic loader could not load $LIB"
  docker logs "$CONTAINER_NAME" 2>&1 | grep "cannot be preloaded" | head -1
  exit 1
fi
PID=$(daemon_pid "$CONTAINER_NAME")
if ! docker exec -u dropbox "$CONTAINER_NAME" grep -qF "$LIB" "/proc/$PID/maps"; then
  echo "FAIL: $LIB is not loaded into the Dropbox client"
  exit 1
fi
echo "PASS: The library is loaded into the Dropbox client"

if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "$WARNING"; then
  echo "FAIL: Warned about files in an empty sync folder"
  exit 1
fi
echo "PASS: No warning for an empty sync folder"

# Empty mount point: the move is reported as done and the folder stays put
rc=0
OUTPUT=$(try_rename "/opt/dropbox/Dropbox (Old)" 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: Moving the empty mounted sync folder aside was not reported as done (errno $rc)"
  echo "$OUTPUT"
  exit 1
fi
if ! echo "$OUTPUT" | grep -q "keeping it as the sync folder"; then
  echo "FAIL: Keeping the mounted sync folder was not logged"
  exit 1
fi
if ! docker exec "$CONTAINER_NAME" mountpoint -q /opt/dropbox/Dropbox; then
  echo "FAIL: The mounted sync folder is gone"
  exit 1
fi
echo "PASS: An empty mounted sync folder is kept instead of moved aside"

# Any other move of the folder fails as it did before
rc=0
try_rename /opt/dropbox/elsewhere 2>/dev/null || rc=$?
if [ "$rc" -ne 16 ]; then
  echo "FAIL: Moving the mounted sync folder elsewhere returned errno $rc, expected EBUSY (16)"
  exit 1
fi
echo "PASS: Other moves of the mounted sync folder still fail"

# A folder with files in it is not taken over: syncing it in place would
# upload files that may belong to another account
docker exec "$CONTAINER_NAME" gosu dropbox touch /opt/dropbox/Dropbox/existing-file
rc=0
OUTPUT=$(try_rename "/opt/dropbox/Dropbox (Old)" 2>&1) || rc=$?
if [ "$rc" -ne 16 ]; then
  echo "FAIL: A mounted sync folder with files in it was taken over (errno $rc, expected EBUSY)"
  exit 1
fi
if ! echo "$OUTPUT" | grep -q "ERROR: Dropbox wants to move /opt/dropbox/Dropbox aside"; then
  echo "FAIL: Refusing a sync folder with files in it was not explained"
  echo "$OUTPUT"
  exit 1
fi
echo "PASS: A mounted sync folder with files in it is refused, with an explanation"

# The entrypoint warns about it before the link is opened
docker restart "$CONTAINER_NAME" > /dev/null
for _ in $(seq 1 60); do
  [ "$(docker logs "$CONTAINER_NAME" 2>&1 | grep -c "Starting dropboxd")" -ge 2 ] && break
  sleep 2
done
if ! docker logs "$CONTAINER_NAME" 2>&1 | grep -q "$WARNING"; then
  echo "FAIL: No warning for an unlinked sync folder with files in it"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -20
  exit 1
fi
echo "PASS: The entrypoint warns about files in an unlinked sync folder"

echo "=== First link tests passed ==="
