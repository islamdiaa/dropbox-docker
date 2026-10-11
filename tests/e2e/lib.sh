#!/bin/bash
# Shared helpers for the E2E tests. Source this file from a test script.

IMAGE="${TEST_IMAGE:-dropbox-test:e2e}"

# Extra `docker run` arguments, e.g. E2E_DOCKER_ARGS="--network host" when
# the containers need a host-local proxy to reach dropbox.com.
read -ra EXTRA_RUN_ARGS <<< "${E2E_DOCKER_ARGS:-}"

# The capability set documented for `cap_drop: ALL` in README.md and
# docker-compose.yml.
# shellcheck disable=SC2034  # used by the test scripts that source this file
HARDENED_CAPS=(
  --cap-drop ALL
  --cap-add CHOWN --cap-add SETUID --cap-add SETGID
  --cap-add FOWNER --cap-add DAC_OVERRIDE
)

# run_container NAME [docker run options...]
run_container() {
  local name="$1"
  shift
  docker run -d --name "$name" "${EXTRA_RUN_ARGS[@]}" "$@" "$IMAGE" > /dev/null
}

# wait_for_log CONTAINER PATTERN [TIMEOUT]
# Waits until PATTERN (grep -E) appears in the container's logs.
wait_for_log() {
  local container="$1" pattern="$2" timeout="${3:-180}" elapsed=0
  until docker logs "$container" 2>&1 | grep -qE "$pattern"; do
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "FAIL: '$pattern' not found in logs after ${timeout}s"
      docker logs "$container" 2>&1 | tail -30
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

# count_daemons CONTAINER
# Prints how many Dropbox daemon processes are running in the container.
count_daemons() {
  docker exec "$1" pgrep -c -f '^/opt/dropbox/bin/dropbox-lnx[^ ]*/dropbox' || true
}

# daemon_pid CONTAINER
daemon_pid() {
  docker exec "$1" pgrep -o -f '^/opt/dropbox/bin/dropbox-lnx[^ ]*/dropbox'
}
