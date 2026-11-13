#!/bin/bash
set -e
echo "=== E2E Test: Client Install, Recovery And Offline Start ==="
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-update-$$"
VOLUME_NAME="dropbox-test-update-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "$VOLUME_NAME" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# The Dropbox CLI ships in the image, so it works without internet access
if ! docker run --rm --entrypoint test "$IMAGE" -s /opt/dropbox.py -a -x /usr/bin/dropbox; then
  echo "FAIL: Dropbox CLI is not part of the image"
  exit 1
fi
echo "PASS: Dropbox CLI is in the image"

run_container "$CONTAINER_NAME" -v "$VOLUME_NAME:/opt/dropbox"
wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
docker rm -f "$CONTAINER_NAME" > /dev/null

# A broken install (e.g. an update interrupted by a full disk) used to stop
# the container from ever starting again: VERSION said up to date while the
# client itself was missing.
docker run --rm -v "$VOLUME_NAME:/opt/dropbox" --entrypoint rm "$IMAGE" -f /opt/dropbox/bin/dropboxd
run_container "$CONTAINER_NAME" -v "$VOLUME_NAME:/opt/dropbox"
wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
if ! docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Installed: Not installed"; then
  echo "FAIL: A broken install was not detected"
  docker logs "$CONTAINER_NAME" 2>&1 | head -20
  exit 1
fi
echo "PASS: Broken install detected and repaired"
docker rm -f "$CONTAINER_NAME" > /dev/null

# Without internet access, an installed client must still start promptly
docker run -d --name "$CONTAINER_NAME" --network none -v "$VOLUME_NAME:/opt/dropbox" "$IMAGE" > /dev/null
wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready" 90
if ! docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Could not determine the latest Dropbox version"; then
  echo "FAIL: Offline start didn't skip the update check"
  docker logs "$CONTAINER_NAME" 2>&1 | head -20
  exit 1
fi
if ! docker exec "$CONTAINER_NAME" gosu dropbox dropbox status > /dev/null; then
  echo "FAIL: Dropbox CLI doesn't work offline"
  exit 1
fi
echo "PASS: Offline start uses the installed client and the CLI works"

docker stop -t 10 "$CONTAINER_NAME" > /dev/null
if [ "$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME")" != "0" ]; then
  echo "FAIL: Offline container did not stop cleanly"
  exit 1
fi
echo "PASS: Clean stop"

docker rm -f "$CONTAINER_NAME" > /dev/null

# DROPBOX_VERSION installs the named client instead of the latest one,
# replacing whatever is installed, and keeps it on the next start.
PINNED=276.4.5325
run_container "$CONTAINER_NAME" -e DROPBOX_VERSION="$PINNED" -v "$VOLUME_NAME:/opt/dropbox"
wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
installed=$(docker exec "$CONTAINER_NAME" cat /opt/dropbox/bin/VERSION)
if [ "$installed" != "$PINNED" ]; then
  echo "FAIL: DROPBOX_VERSION=$PINNED installed '$installed'"
  docker logs "$CONTAINER_NAME" 2>&1 | head -20
  exit 1
fi
if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Checking for latest Dropbox version"; then
  echo "FAIL: A pinned version still looked up the latest version"
  exit 1
fi
echo "PASS: DROPBOX_VERSION installs the named client"
docker rm -f "$CONTAINER_NAME" > /dev/null

run_container "$CONTAINER_NAME" -e DROPBOX_VERSION="$PINNED" -e DROPBOX_SKIP_UPDATE=1 -v "$VOLUME_NAME:/opt/dropbox"
wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
if ! docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Dropbox is up-to-date" \
   || docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Downloading Dropbox"; then
  echo "FAIL: The pinned client was downloaded again"
  docker logs "$CONTAINER_NAME" 2>&1 | head -20
  exit 1
fi
echo "PASS: The pinned client is kept on restart"
docker rm -f "$CONTAINER_NAME" > /dev/null

# Anything but a version number is refused, so the setting can't be used
# to fetch something else.
run_container "$CONTAINER_NAME" -e "DROPBOX_VERSION=276.4.5325/../x" -v "$VOLUME_NAME:/opt/dropbox"
wait_for_log "$CONTAINER_NAME" "is not a Dropbox client version" 60
for _ in $(seq 1 15); do
  [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" = "false" ] && break
  sleep 1
done
if [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" != "false" ]; then
  echo "FAIL: An invalid DROPBOX_VERSION did not stop the container"
  exit 1
fi
echo "PASS: An invalid DROPBOX_VERSION is refused"

echo "=== Update tests passed ==="
