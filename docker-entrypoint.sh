#!/bin/bash
set -euo pipefail

# ============================================================================
# Dropbox Docker Entrypoint
# ============================================================================
#
# This script is PID 1 inside the container. It runs as root because it needs
# to remap UID/GID at runtime (usermod, groupadd, chown). The actual Dropbox
# daemon is launched as an unprivileged user via gosu.
#
# Flow:
#   1. Validate and configure timezone, UID/GID
#   2. Clean stale files from previous runs
#   3. Block Dropbox telemetry (prevents a known Rust panic crash)
#   4. Download/update the Dropbox daemon binary
#   5. Launch dropboxd as the dropbox user
#   6. Wait for readiness, then enter supervision loop
#   7. On SIGTERM/SIGINT: forward signal to daemon, wait, exit cleanly
#
# Only CHOWN, SETUID, SETGID, FOWNER and DAC_OVERRIDE are needed, so the
# container also works with `cap_drop: ALL`. In particular nothing here may
# rely on CAP_KILL: root can't signal the dropbox user's processes without it.
#
# Environment variables: see README.md for full documentation.
# ============================================================================

IMAGE_REVISION="${IMAGE_REVISION:-unknown}"
echo "dropbox-docker ${IMAGE_VERSION:-dev} (revision ${IMAGE_REVISION:0:7})"

# --- Timezone Configuration ---
if [ -z "${TZ:-}" ]; then
  TZ="$(cat /etc/timezone 2>/dev/null || echo 'UTC')"
  export TZ
else
  # Validate TZ to prevent path traversal (e.g. ../../etc/shadow)
  if [[ ! "${TZ}" =~ ^[A-Za-z_]+(/[A-Za-z_0-9+-]+)*$ ]]; then
    echo "WARNING: Timezone '${TZ}' contains invalid characters, using UTC"
    export TZ="UTC"
  elif [ ! -f "/usr/share/zoneinfo/${TZ}" ]; then
    echo "WARNING: Timezone '${TZ}' is unavailable, using UTC"
    export TZ="UTC"
  else
    echo "${TZ}" > /etc/timezone
    ln -fs "/usr/share/zoneinfo/${TZ}" /etc/localtime
  fi
fi
echo "Timezone: ${TZ} ($(date +%H:%M:%S) local time)"

# --- UID/GID Configuration ---
if [ -z "${DROPBOX_UID:-}" ]; then
  DROPBOX_UID=$(/usr/bin/id -u dropbox)
  export DROPBOX_UID
  echo "DROPBOX_UID not specified, defaulting to ${DROPBOX_UID}"
fi

if [ -z "${DROPBOX_GID:-}" ]; then
  DROPBOX_GID=$(/usr/bin/id -g dropbox)
  export DROPBOX_GID
  echo "DROPBOX_GID not specified, defaulting to ${DROPBOX_GID}"
fi

# Validate UID/GID are numeric
if [[ ! "${DROPBOX_UID}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: DROPBOX_UID '${DROPBOX_UID}' is not a valid number"
  exit 1
fi
if [[ ! "${DROPBOX_GID}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: DROPBOX_GID '${DROPBOX_GID}' is not a valid number"
  exit 1
fi

# Look for existing group, if not found create dropbox with specified GID
if ! grep -qF ":${DROPBOX_GID}:" /etc/group; then
  usermod -g users dropbox
  groupdel dropbox
  groupadd -g "${DROPBOX_GID}" dropbox
fi

# Validate numeric settings, falling back to their defaults
declare -A NUMERIC_DEFAULTS=(
  [POLLING_INTERVAL]=5
  [DROPBOX_MAX_RESTARTS]=5
  [DROPBOX_RESTART_DELAY]=10
  [DROPBOX_STARTUP_TIMEOUT]=300
  [OWNERSHIP_FIX_INTERVAL]=360
)
for var in "${!NUMERIC_DEFAULTS[@]}"; do
  if [[ ! "${!var:-}" =~ ^[0-9]+$ ]]; then
    if [[ -n "${!var:-}" ]]; then
      echo "${var} not set to a valid number, defaulting to ${NUMERIC_DEFAULTS[$var]}"
    fi
    printf -v "${var}" '%s' "${NUMERIC_DEFAULTS[$var]}"
    export "${var?}"
  fi
done

# Validate ownership repair mode
OWNERSHIP_FIX_MODE=$(echo "${OWNERSHIP_FIX_MODE:-full}" | tr '[:upper:]' '[:lower:]' | tr -d " ")
case "${OWNERSHIP_FIX_MODE}" in
  full|group-only|disabled) ;;
  *)
    echo "WARNING: OWNERSHIP_FIX_MODE '${OWNERSHIP_FIX_MODE}' is not one of full, group-only, disabled. Using full."
    OWNERSHIP_FIX_MODE="full"
    ;;
esac
export OWNERSHIP_FIX_MODE

# Set dropbox account's UID/GID
usermod -u "${DROPBOX_UID}" -g "${DROPBOX_GID}" --non-unique dropbox > /dev/null 2>&1

# --- Permissions ---
SKIP_PERMS=$(echo "${SKIP_SET_PERMISSIONS:-true}" | tr '[:upper:]' '[:lower:]' | tr -d " ")
if [[ "$SKIP_PERMS" == "true" ]]; then
  echo "Skipping recursive permission check (SKIP_SET_PERMISSIONS=true)"
  chown "${DROPBOX_UID}:${DROPBOX_GID}" /opt/dropbox
  [[ -d /opt/dropbox/.dropbox ]] && chown -R "${DROPBOX_UID}:${DROPBOX_GID}" /opt/dropbox/.dropbox
  [[ -d /opt/dropbox/bin ]]      && chown -R "${DROPBOX_UID}:${DROPBOX_GID}" /opt/dropbox/bin
else
  echo "Setting permissions on all files (this may take a long time for large folders)..."
  echo "Set SKIP_SET_PERMISSIONS=true to skip this step."
  chown -R "${DROPBOX_UID}:${DROPBOX_GID}" /opt/dropbox
fi

# The daemon keeps its config and databases in ~/.dropbox. On a fresh volume
# it doesn't exist yet: create it as the dropbox user, otherwise
# lock_analytics below creates it as root and the daemon crash-loops with
# "unable to open database file: /opt/dropbox/.dropbox/apex.sqlite3".
if [[ ! -d /opt/dropbox/.dropbox ]]; then
  install -d -o "${DROPBOX_UID}" -g "${DROPBOX_GID}" /opt/dropbox/.dropbox
fi

# --- Sync Folder ---
echo "Ownership repair mode: ${OWNERSHIP_FIX_MODE}"
if [[ -d /opt/dropbox/Dropbox ]]; then
  [[ "${OWNERSHIP_FIX_MODE}" == "full" ]] && chmod 755 /opt/dropbox/Dropbox

  # Docker creates a missing bind-mount source as root:root 755. The account
  # then links fine but the daemon can't write a single file, so nothing ever
  # syncs. Fix the top-level folder only; its contents are left alone.
  if ! gosu dropbox test -w /opt/dropbox/Dropbox; then
    case "${OWNERSHIP_FIX_MODE}" in
      full)
        chown "${DROPBOX_UID}:${DROPBOX_GID}" /opt/dropbox/Dropbox
        echo "Sync folder was not writable by UID ${DROPBOX_UID}; changed its owner to ${DROPBOX_UID}:${DROPBOX_GID}"
        ;;
      group-only)
        chgrp "${DROPBOX_GID}" /opt/dropbox/Dropbox
        chmod g+rwx /opt/dropbox/Dropbox
        echo "Sync folder was not writable by UID ${DROPBOX_UID}; gave group ${DROPBOX_GID} write access"
        ;;
    esac
  fi
  if gosu dropbox test -w /opt/dropbox/Dropbox; then
    echo "Sync folder: /opt/dropbox/Dropbox (writable by UID ${DROPBOX_UID})"
  else
    echo "ERROR: Sync folder /opt/dropbox/Dropbox is not writable by UID ${DROPBOX_UID}."
    echo "ERROR: Dropbox will link but cannot sync. Fix the folder's permissions on the host,"
    echo "ERROR: or set DROPBOX_UID/DROPBOX_GID to match its owner."
  fi
fi

# Dropbox doesn't support FUSE filesystems such as Unraid's /mnt/user share
# layer: the sync folder fails outright, and SQLite databases in the config
# folder are unreliable there.
if [[ -d /opt/dropbox/Dropbox ]] && \
   [[ "$(findmnt -n -o FSTYPE -T /opt/dropbox/Dropbox 2>/dev/null || true)" == fuse* ]]; then
  echo "WARNING: The sync folder is on a FUSE filesystem ($(findmnt -n -o FSTYPE -T /opt/dropbox/Dropbox))."
  echo "WARNING: Dropbox does not support this and will not sync. On Unraid, use a direct path"
  echo "WARNING: such as /mnt/disk1/Dropbox or /mnt/cache/Dropbox instead of /mnt/user/Dropbox."
fi
if [[ "$(findmnt -n -o FSTYPE -T /opt/dropbox/.dropbox 2>/dev/null || true)" == fuse* ]]; then
  echo "WARNING: The Dropbox config folder is on a FUSE filesystem ($(findmnt -n -o FSTYPE -T /opt/dropbox/.dropbox))."
  echo "WARNING: If Dropbox asks you to link again after restarts, move it to a direct path,"
  echo "WARNING: e.g. /mnt/cache/appdata/dropbox instead of /mnt/user/appdata/dropbox on Unraid."
fi

# --- Clean Stale Files ---
rm -f /opt/dropbox/.dropbox/command_socket \
      /opt/dropbox/.dropbox/iface_socket \
      /opt/dropbox/.dropbox/unlink.db \
      /opt/dropbox/.dropbox/dropbox.pid

# Remove stale .dropbox directories from sync folder
# These are leftover from previous installations and block the daemon
# from writing its .dropbox marker file (PermissionDenied on unlinkat)
if [[ -d /opt/dropbox/Dropbox/.dropbox ]]; then
  rm -rf /opt/dropbox/Dropbox/.dropbox
  echo "Removed stale .dropbox directory from sync folder"
fi
if [[ -d /opt/dropbox/Dropbox/.dropbox-dist ]]; then
  rm -rf /opt/dropbox/Dropbox/.dropbox-dist
  echo "Removed stale .dropbox-dist directory from sync folder"
fi
if [[ -d /opt/dropbox/Dropbox/.dropbox.cache ]]; then
  rm -rf /opt/dropbox/Dropbox/.dropbox.cache
  echo "Removed stale .dropbox.cache directory from sync folder"
fi

# --- Block Dropbox Telemetry ---
# The Dropbox daemon has a known Rust panic in its analytics/telemetry code
# ("publish_queue.len() > 0 so to_publish cannot be empty") that crashes
# the daemon during indexing of large accounts. Blocking the telemetry
# endpoint prevents this crash without affecting sync functionality.
if ! grep -q "telemetry.dropbox.com" /etc/hosts 2>/dev/null; then
  echo "127.0.0.1 telemetry.dropbox.com" >> /etc/hosts
fi

# Function to lock down analytics directories. Called at startup and
# before each daemon restart, since the daemon recreates these dirs.
lock_analytics() {
  for analytics_root in /opt/dropbox/.dropbox /opt/dropbox/.dropbox/.dropbox; do
    # Only the analytics folders themselves may be root-owned; the daemon
    # must still be able to write everything else under analytics_root.
    if [[ ! -d "${analytics_root}" ]]; then
      install -d -o "${DROPBOX_UID}" -g "${DROPBOX_GID}" "${analytics_root}"
    fi
    for dir in events ssa_events sentry_exceptions; do
      rm -rf "${analytics_root:?}/${dir:?}/"* 2>/dev/null
      mkdir -p "${analytics_root}/${dir}"
      chown root:root "${analytics_root}/${dir}"
      chmod 555 "${analytics_root}/${dir}"
    done
    rm -f "${analytics_root}/metrics/store.bin" 2>/dev/null
  done
}

# Clear stale analytics caches that can grow to multiple GB and trigger
# Rust panics ("queue size is inconsistent") in the analytics subsystem.
# Lock directories as root-owned and read-only so the daemon (running as
# the dropbox user) cannot write new analytics data. This covers both the
# primary path and the nested .dropbox/.dropbox path the daemon creates.
lock_analytics

# --- Update Dropbox ---
if [[ -z "${DROPBOX_SKIP_UPDATE:-}" ]] || [[ ! -f /opt/dropbox/bin/VERSION ]]; then
  echo "Checking for latest Dropbox version..."

  # Get download URL by following redirects
  DL=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://www.dropbox.com/download?plat=lnx.x86_64" 2>/dev/null || echo "")

  if [[ -z "$DL" ]]; then
    echo "WARNING: Could not resolve Dropbox download URL. Skipping update."
  else
    # Extract version from URL
    Latest=$(echo "$DL" | grep -oP 'x86_64-\K[0-9]+\.[0-9]+\.[0-9]+' || echo "")

    if [[ -z "$Latest" ]]; then
      echo "WARNING: Could not parse version from URL: $DL"
    else
      # Get current version
      if [[ -f /opt/dropbox/bin/VERSION ]]; then
        Current=$(cat /opt/dropbox/bin/VERSION)
      else
        Current="Not installed"
      fi

      echo "Latest   : $Latest"
      echo "Installed: $Current"

      if [[ "$Current" != "$Latest" ]]; then
        # Prevent Dropbox self-updates
        if [[ ! -d /opt/dropbox/bin ]]; then
          mkdir -p /opt/dropbox/bin/ /tmp
          install -dm0 /opt/dropbox/.dropbox-dist
          chmod u-w /opt/dropbox/.dropbox-dist
          chmod o-w /tmp
          chmod g-w /tmp
        fi

        echo "Downloading Dropbox $Latest..."
        tmpdir=$(mktemp -d)
        if curl -fsSL "$DL" | tar xzf - -C "$tmpdir"; then
          echo "Installing new version..."
          rm -rf /opt/dropbox/bin/*
          mv "$tmpdir"/.dropbox-dist/* /opt/dropbox/bin/
          find /opt/dropbox/bin/ -type f -name "*.so" -exec chown "${DROPBOX_UID}:${DROPBOX_GID}" {} \; -exec chmod a+rx {} \;
          echo "Dropbox updated to v$Latest"
        else
          echo "WARNING: Download of Dropbox $Latest failed. Keeping installed version ($Current)."
        fi
        rm -rf "$tmpdir"
      else
        echo "Dropbox is up-to-date"
      fi
    fi
  fi
fi

if [[ ! -x /opt/dropbox/bin/dropboxd ]]; then
  echo "ERROR: Dropbox is not installed and could not be downloaded. Check the container's internet access."
  exit 1
fi

# --- Install CLI Script ---
# Download to a temporary file so a failed download doesn't leave an empty
# script behind that is never retried.
if [[ ! -s /opt/dropbox.py ]]; then
  if wget -q -O /opt/dropbox.py.tmp "https://www.dropbox.com/download?dl=packages/dropbox.py" 2>/dev/null \
     && [[ -s /opt/dropbox.py.tmp ]]; then
    mv /opt/dropbox.py.tmp /opt/dropbox.py
  else
    rm -f /opt/dropbox.py.tmp
    echo "WARNING: Could not download Dropbox CLI script"
  fi
fi
if [[ ! -x /usr/bin/dropbox ]]; then
  echo "#!/bin/bash" > /usr/bin/dropbox
  echo 'python3 /opt/dropbox.py "$@"' >> /usr/bin/dropbox
  chmod +x /usr/bin/dropbox
fi

echo ""

# Set umask
umask 002

# --- Process Helpers ---
DROPBOX_PID=""

# Whether the daemon is still running. Reads /proc instead of using
# `kill -0`, which fails with EPERM when root lacks CAP_KILL (e.g. with
# `cap_drop: ALL`) and made a healthy daemon look dead (#11).
daemon_running() {
  local stat
  [[ -n "${DROPBOX_PID}" ]] || return 1
  { read -r stat < "/proc/${DROPBOX_PID}/stat"; } 2>/dev/null || return 1
  # The state field follows the parenthesised command name; Z is a zombie.
  stat="${stat##*) }"
  [[ "${stat:0:1}" != "Z" ]]
}

# Send a signal to the daemon. Without CAP_KILL root can't signal another
# UID, so fall back to sending it as the dropbox user.
signal_daemon() {
  kill -s "$1" "${DROPBOX_PID}" 2>/dev/null \
    || gosu dropbox kill -s "$1" "${DROPBOX_PID}" 2>/dev/null \
    || true
}

# Sleep without blocking signal handling: bash runs traps only after a
# foreground command finishes, which could delay shutdown past the
# `docker stop` timeout and get the daemon SIGKILLed.
pause() {
  sleep "$1" &
  wait $! || true
}

# --- Signal Handler ---
cleanup() {
  echo "Received shutdown signal. Stopping Dropbox daemon (PID: ${DROPBOX_PID})..."
  signal_daemon TERM
  wait "${DROPBOX_PID}" 2>/dev/null || true
  echo "Dropbox daemon stopped."
  exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP SIGQUIT

# Log each linked account's sync folder once, and warn if Dropbox chose a
# folder other than the mapped /opt/dropbox/Dropbox (e.g. a Dropbox Business
# team folder), since those files would end up inside the config volume.
report_sync_folders() {
  python3 - <<'EOF' || true
import json
import sys

try:
    with open("/opt/dropbox/.dropbox/info.json") as f:
        info = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
for kind, account in info.items():
    if not isinstance(account, dict):
        continue
    path = account.get("path", "unknown")
    team = " (team)" if account.get("is_team") else ""
    print(f"Dropbox {kind} account{team} syncs to: {path}")
    if path != "/opt/dropbox/Dropbox":
        print(f"WARNING: {path} is not the mapped sync folder /opt/dropbox/Dropbox, so these files")
        print("WARNING: are stored in the /opt/dropbox volume. To keep them on your own storage,")
        print("WARNING: map /opt/dropbox itself to a host folder (see README: Dropbox Business).")
EOF
}

# Repair ownership of files in the sync folder that the daemon may not be
# able to sync (e.g. created by root over SSH). Symlinks are changed
# themselves (-h), never their targets. Walking a large folder takes a
# while, so this runs at idle CPU/IO priority in the background.
OWNERSHIP_FIX_PID=""
fix_ownership() {
  [[ -d /opt/dropbox/Dropbox ]] || return 0
  # Don't start a new pass while the previous one is still walking the tree
  if [[ -n "${OWNERSHIP_FIX_PID}" ]] && [[ -e "/proc/${OWNERSHIP_FIX_PID}" ]]; then
    return 0
  fi
  case "${OWNERSHIP_FIX_MODE}" in
    full)
      nice -n 19 ionice -c 3 find /opt/dropbox/Dropbox -not -user "${DROPBOX_UID}" \
        -exec chown -h "${DROPBOX_UID}:${DROPBOX_GID}" {} + 2>/dev/null &
      ;;
    group-only)
      nice -n 19 ionice -c 3 find /opt/dropbox/Dropbox -not -group "${DROPBOX_GID}" \
        -exec chgrp -h "${DROPBOX_GID}" {} + 2>/dev/null &
      ;;
    *)
      return 0
      ;;
  esac
  OWNERSHIP_FIX_PID=$!
}

# Shared with monitoring.py, which reports it on /status and /metrics
STATE_DIR=/run/dropbox-docker
mkdir -p "${STATE_DIR}"
record_restarts() {
  echo "$1" > "${STATE_DIR}/restart_count"
}
record_restarts 0

# --- Start Dropbox ---
echo "Starting dropboxd ($(cat /opt/dropbox/bin/VERSION 2>/dev/null || echo 'unknown'))..."
gosu dropbox "$@" & DROPBOX_PID="$!"

# --- Start Monitoring (Optional) ---
if [[ $(echo "${ENABLE_MONITORING:-false}" | tr '[:upper:]' '[:lower:]' | tr -d " ") == "true" ]]; then
  echo "Starting Prometheus metrics on port 8000 and status API on port 8001..."
  gosu dropbox python3 /monitoring.py -i "${POLLING_INTERVAL}" --status-port 8001 &
  echo "Monitoring started (PID: $!)"
fi

# --- Wait for Daemon Startup ---
echo "Waiting for Dropbox daemon to initialize (timeout: ${DROPBOX_STARTUP_TIMEOUT}s)..."
STARTUP_ELAPSED=0
while [[ $STARTUP_ELAPSED -lt ${DROPBOX_STARTUP_TIMEOUT} ]]; do
  if [[ -f "/opt/dropbox/.dropbox/info.json" ]] || \
     [[ -S "/opt/dropbox/.dropbox/command_socket" ]]; then
    echo "Dropbox daemon is ready (took ${STARTUP_ELAPSED}s)"
    break
  fi
  if ! daemon_running; then
    echo "WARNING: Dropbox daemon exited during startup"
    break
  fi
  pause 2
  STARTUP_ELAPSED=$((STARTUP_ELAPSED + 2))
done
if [[ $STARTUP_ELAPSED -ge ${DROPBOX_STARTUP_TIMEOUT} ]]; then
  echo "WARNING: Startup timeout reached (${DROPBOX_STARTUP_TIMEOUT}s). Continuing anyway..."
fi

# --- Main Supervision Loop ---
RESTART_COUNT=0
LAST_OWNERSHIP_FIX=${SECONDS}
LAST_STATUS=""
SYNC_FOLDERS_REPORTED=false
while true; do
  if daemon_running; then
    # Daemon is running. Log its status when it changes rather than on
    # every poll, so the log stays readable.
    if [[ -f "/opt/dropbox/.dropbox/info.json" ]]; then
      if [[ "${SYNC_FOLDERS_REPORTED}" == "false" ]]; then
        report_sync_folders
        SYNC_FOLDERS_REPORTED=true
      fi
      STATUS=$(gosu dropbox dropbox status 2>/dev/null || true)
      if [[ -n "${STATUS}" ]] && [[ "${STATUS}" != "${LAST_STATUS}" ]]; then
        echo "${STATUS}"
        LAST_STATUS="${STATUS}"
      fi
    fi

    # Fix ownership on the Dropbox folder periodically (OWNERSHIP_FIX_INTERVAL,
    # default 6 min). Files created by other users (e.g. root via SSH) won't
    # sync until the dropbox user can access them.
    if [[ "${OWNERSHIP_FIX_MODE}" != "disabled" ]] && \
       [[ $((SECONDS - LAST_OWNERSHIP_FIX)) -ge ${OWNERSHIP_FIX_INTERVAL} ]]; then
      fix_ownership
      LAST_OWNERSHIP_FIX=${SECONDS}
    fi

    # Clean old temp files (scoped to dropbox temp dirs only)
    /usr/bin/find /tmp/ -maxdepth 1 -type d -name 'dropbox*' -mtime +1 -exec rm -rf {} \; 2>/dev/null || true

    pause "${POLLING_INTERVAL}"
  else
    # Daemon crashed
    RESTART_COUNT=$((RESTART_COUNT + 1))
    if [[ ${RESTART_COUNT} -gt ${DROPBOX_MAX_RESTARTS} ]]; then
      echo "ERROR: Dropbox daemon crashed ${RESTART_COUNT} times. Giving up."
      exit 1
    fi
    echo "WARNING: Dropbox daemon exited. Restart attempt ${RESTART_COUNT}/${DROPBOX_MAX_RESTARTS} in ${DROPBOX_RESTART_DELAY}s..."
    pause "${DROPBOX_RESTART_DELAY}"

    # Clean stale sockets before restart
    rm -f /opt/dropbox/.dropbox/command_socket \
          /opt/dropbox/.dropbox/iface_socket \
          /opt/dropbox/.dropbox/unlink.db \
          /opt/dropbox/.dropbox/dropbox.pid

    # Re-lock analytics directories (daemon recreates them on crash)
    lock_analytics

    gosu dropbox "$@" & DROPBOX_PID="$!"
    echo "Restarted Dropbox daemon (PID: ${DROPBOX_PID})"
    record_restarts "${RESTART_COUNT}"
    LAST_STATUS=""
    pause 5
  fi
done
