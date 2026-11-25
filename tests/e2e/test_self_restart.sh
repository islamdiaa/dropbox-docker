#!/bin/bash
set -e
echo "=== E2E Test: Client Restarts Itself ==="
# Regression test for #31: the client can restart itself, e.g. with
# /unlinksuccess after an unlink. The supervisor only tracked the process
# it had started, so it took the old one's exit for a crash and started a
# second client next to it.
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
CONTAINER_NAME="dropbox-test-selfrestart-$$"
BIN_VOLUME="dropbox-test-selfrestart-bin-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
  docker volume rm "$BIN_VOLUME" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# A fake client in a mapped client folder, so nothing is downloaded and no
# account is needed. FAKE_CLIENT says what its first run does: restart
# itself before it is ready (startup) or a few seconds after (running), or
# crash (crash). Later runs keep going, like a client waiting to be linked,
# and stop on SIGTERM after a second, leaving a note that they did.
docker run --rm -i -v "$BIN_VOLUME:/opt/dropbox/bin" --entrypoint bash "$IMAGE" -s <<'SETUP'
set -e
cd /opt/dropbox/bin
echo 1.0.0 > VERSION
mkdir dropbox-lnx.x86_64-1.0.0
printf '#!/bin/bash\nexec /opt/dropbox/bin/dropbox-lnx.x86_64-1.0.0/dropbox "$@"\n' > dropboxd
cat > dropbox-lnx.x86_64-1.0.0/dropbox <<'CLIENT'
#!/bin/bash
cd ~/.dropbox || exit 1
if [[ "$1" != /unlinksuccess ]] && [[ ! -e fake-first-run ]]; then
  touch fake-first-run
  echo $$ > dropbox.pid
  if [[ "${FAKE_CLIENT}" != startup ]]; then
    python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("command_socket")'
    sleep 6
  fi
  if [[ "${FAKE_CLIENT}" != crash ]]; then
    "$0" /unlinksuccess > /dev/null 2>&1 &
  fi
  sleep 1
  kill -9 $$
fi
# The real client is a binary, so its path is what ps and the supervisor see
exec -a "$0" python3 - "$@" <<'PY'
import os, signal, socket, sys, time

def stop(*_):
    time.sleep(1)
    open("fake-stopped", "w").close()
    sys.exit(0)

signal.signal(signal.SIGTERM, stop)
time.sleep(4)
with open("dropbox.pid", "w") as f:
    f.write(str(os.getpid()))
if os.path.exists("command_socket"):
    os.unlink("command_socket")
socket.socket(socket.AF_UNIX).bind("command_socket")
while True:
    time.sleep(60)
PY
CLIENT
chmod 755 dropboxd dropbox-lnx.x86_64-1.0.0/dropbox
SETUP

# start_fake MODE [docker run options...]
start_fake() {
  local mode="$1"
  shift
  docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
  run_container "$CONTAINER_NAME" "$@" \
    -v "$BIN_VOLUME:/opt/dropbox/bin" \
    -e DROPBOX_SKIP_UPDATE=1 \
    -e FAKE_CLIENT="$mode" \
    -e DROPBOX_RESTART_DELAY=3 \
    -e POLLING_INTERVAL=2
  wait_for_log "$CONTAINER_NAME" "Starting dropboxd" 60
}

fail() {
  echo "FAIL: $1"
  docker exec "$CONTAINER_NAME" ps -eo pid,ppid,user,args 2>/dev/null || true
  docker logs "$CONTAINER_NAME" 2>&1 | tail -20
  exit 1
}

# expect_clients RESTARTS: exactly one client runs, restarted RESTARTS times
expect_clients() {
  local daemons restarts
  daemons=$(count_daemons "$CONTAINER_NAME")
  restarts=$(docker exec "$CONTAINER_NAME" cat /run/dropbox-docker/restart_count || true)
  if [ "$daemons" != "1" ] || [ "$restarts" != "$1" ]; then
    fail "$daemons clients running after $restarts restarts, expected 1 after $1"
  fi
}

# `docker stop` must stop the client cleanly within Docker's default timeout
expect_clean_stop() {
  local start elapsed
  start=$(date +%s)
  docker stop -t 10 "$CONTAINER_NAME" > /dev/null
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -ge 10 ] \
     || [ "$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME")" != "0" ] \
     || ! docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Dropbox daemon stopped"; then
    fail "Container did not stop cleanly (took ${elapsed}s)"
  fi
  if ! docker cp "$CONTAINER_NAME:/opt/dropbox/.dropbox/fake-stopped" - > /dev/null 2>&1; then
    fail "The client was killed instead of stopped"
  fi
}

for mode in startup running; do
  if [ "$mode" = running ]; then
    # Also without CAP_KILL, where the client is signalled as its own user
    start_fake "$mode" "${HARDENED_CAPS[@]}"
  else
    start_fake "$mode"
  fi
  sleep 20
  LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
  if echo "$LOGS" | grep -qE "Restart attempt|exited during startup" \
     || ! echo "$LOGS" | grep -q "Dropbox restarted itself"; then
    fail "Restart while $mode was taken for a crash"
  fi
  expect_clients 0
  echo "PASS: Restart while $mode: the new client is followed, no second client started"
  expect_clean_stop
  echo "PASS: Restart while $mode: the followed client is stopped cleanly"
done

# A real crash, with no new client, is still restarted
start_fake crash
wait_for_log "$CONTAINER_NAME" "Restarted Dropbox daemon" 60
sleep 6
if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Dropbox restarted itself"; then
  fail "A crash was taken for a restart"
fi
expect_clients 1
echo "PASS: A crash is still restarted"
expect_clean_stop
echo "PASS: The restarted client is stopped cleanly"

echo "=== Self-restart tests passed ==="
