#!/bin/bash
set -e
echo "=== E2E Test: Client Install, Recovery And Offline Start ==="
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-update-$$"
VOLUME_NAME="dropbox-test-update-$$"
BIN_VOLUME="dropbox-test-update-bin-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm "$VOLUME_NAME" "$BIN_VOLUME" > /dev/null 2>&1 || true
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
docker rm -f "$CONTAINER_NAME" > /dev/null

# wait_for_exit CONTAINER: waits up to 15s for the container to stop
wait_for_exit() {
  for _ in $(seq 1 15); do
    [ "$(docker inspect --format '{{.State.Running}}' "$1")" = "false" ] && return 0
    sleep 1
  done
  return 1
}

# A mapped client folder that holds anything else is refused instead of
# emptied, e.g. a config folder mapped to /opt/dropbox/bin by mistake.
docker run --rm -v "$BIN_VOLUME:/opt/dropbox/bin" --entrypoint touch "$IMAGE" /opt/dropbox/bin/keep-me
run_container "$CONTAINER_NAME" -v "$BIN_VOLUME:/opt/dropbox/bin"
wait_for_log "$CONTAINER_NAME" "holds other files" 60
if ! wait_for_exit "$CONTAINER_NAME"; then
  echo "FAIL: A client folder with other files did not stop the container"
  exit 1
fi
if ! docker run --rm -v "$BIN_VOLUME:/opt/dropbox/bin" --entrypoint test "$IMAGE" -e /opt/dropbox/bin/keep-me; then
  echo "FAIL: Files in the mapped client folder were deleted"
  exit 1
fi
echo "PASS: A client folder with other files is left alone"
docker rm -f "$CONTAINER_NAME" > /dev/null
docker volume rm "$BIN_VOLUME" > /dev/null

# With only the client folder mapped, the client survives a new container
# but /opt/dropbox doesn't: the self-update lock must come back anyway.
run_container "$CONTAINER_NAME" -v "$BIN_VOLUME:/opt/dropbox/bin"
wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
docker rm -f "$CONTAINER_NAME" > /dev/null
run_container "$CONTAINER_NAME" -v "$BIN_VOLUME:/opt/dropbox/bin"
wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Installed: Not installed"; then
  echo "FAIL: The mapped client folder did not keep the client"
  exit 1
fi
lock=$(docker exec "$CONTAINER_NAME" stat -c '%U %a' /opt/dropbox/.dropbox-dist 2>/dev/null || true)
if [ "$lock" != "root 0" ]; then
  echo "FAIL: Self-update lock missing after a new container (got '${lock:-nothing}')"
  exit 1
fi
echo "PASS: Self-update lock is restored when only the client folder is kept"
docker rm -f "$CONTAINER_NAME" > /dev/null

# Changing versions in a mapped client folder replaces only the client's
# own files.
run_container "$CONTAINER_NAME" -e DROPBOX_VERSION="$PINNED" -v "$BIN_VOLUME:/opt/dropbox/bin"
wait_for_log "$CONTAINER_NAME" "Dropbox daemon is ready"
contents=$(docker exec "$CONTAINER_NAME" ls -A /opt/dropbox/bin | tr '\n' ' ')
if [ "$contents" != "VERSION dropbox-lnx.x86_64-$PINNED dropboxd " ]; then
  echo "FAIL: Unexpected client folder contents after switching versions: $contents"
  exit 1
fi
echo "PASS: Switching versions in a mapped client folder replaces the client"

echo "=== Update tests passed ==="
