#!/bin/bash
set -euo pipefail

# ============================================================================
# Dropbox Docker Entrypoint
# ============================================================================

# --- Timezone Configuration ---
if [ -z "${TZ:-}" ]; then
  export TZ="$(cat /etc/timezone 2>/dev/null || echo 'UTC')"
else
  if [ ! -f "/usr/share/zoneinfo/${TZ}" ]; then
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
  export DROPBOX_UID=$(/usr/bin/id -u dropbox)
  echo "DROPBOX_UID not specified, defaulting to ${DROPBOX_UID}"
fi

if [ -z "${DROPBOX_GID:-}" ]; then
  export DROPBOX_GID=$(/usr/bin/id -g dropbox)
  echo "DROPBOX_GID not specified, defaulting to ${DROPBOX_GID}"
fi

# Look for existing group, if not found create dropbox with specified GID
if [ -z "$(grep ":${DROPBOX_GID}:" /etc/group)" ]; then
  usermod -g users dropbox
  groupdel dropbox
  groupadd -g "${DROPBOX_GID}" dropbox
fi

# Validate polling interval
if [[ ! "${POLLING_INTERVAL}" =~ ^[0-9]+$ ]]; then
  echo "POLLING_INTERVAL not set to a valid number, defaulting to 5"
  export POLLING_INTERVAL=5
fi

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

[[ -d /opt/dropbox/Dropbox ]] && chmod 755 /opt/dropbox/Dropbox

# --- Clean Stale Files ---
rm -f /opt/dropbox/.dropbox/command_socket \
      /opt/dropbox/.dropbox/iface_socket \
      /opt/dropbox/.dropbox/unlink.db \
      /opt/dropbox/.dropbox/dropbox.pid

# --- Block Dropbox Telemetry ---
# The Dropbox daemon has a known Rust panic in its analytics/telemetry code
# ("publish_queue.len() > 0 so to_publish cannot be empty") that crashes
# the daemon during indexing of large accounts. Blocking the telemetry
# endpoint prevents this crash without affecting sync functionality.
if ! grep -q "telemetry.dropbox.com" /etc/hosts 2>/dev/null; then
  echo "127.0.0.1 telemetry.dropbox.com" >> /etc/hosts
fi

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
        curl -fsSL "$DL" | tar xzf - -C "$tmpdir"
        echo "Installing new version..."
        rm -rf /opt/dropbox/bin/*
        mv "$tmpdir"/.dropbox-dist/* /opt/dropbox/bin/
        rm -rf "$tmpdir"
        find /opt/dropbox/bin/ -type f -name "*.so" -exec chown "${DROPBOX_UID}:${DROPBOX_GID}" {} \; -exec chmod a+rx {} \;
        echo "Dropbox updated to v$Latest"
      else
        echo "Dropbox is up-to-date"
      fi
    fi
  fi
fi

# --- Install CLI Script ---
if [[ ! -f /opt/dropbox.py ]]; then
  wget -q -O /opt/dropbox.py "https://www.dropbox.com/download?dl=packages/dropbox.py" 2>/dev/null || echo "WARNING: Could not download Dropbox CLI script"
  echo "#!/bin/bash" > /usr/bin/dropbox
  echo 'python3 /opt/dropbox.py "$@"' >> /usr/bin/dropbox
  chmod +x /usr/bin/dropbox
fi

echo ""

# Set umask
umask 002

# --- Signal Handler ---
DROPBOX_PID=""
cleanup() {
  echo "Received shutdown signal. Stopping Dropbox daemon (PID: ${DROPBOX_PID})..."
  kill -SIGTERM "${DROPBOX_PID}" 2>/dev/null
  wait "${DROPBOX_PID}" 2>/dev/null
  echo "Dropbox daemon stopped."
  exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP SIGQUIT

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
  if ! kill -0 "${DROPBOX_PID}" 2>/dev/null; then
    echo "WARNING: Dropbox daemon exited during startup"
    break
  fi
  sleep 2
  STARTUP_ELAPSED=$((STARTUP_ELAPSED + 2))
done
if [[ $STARTUP_ELAPSED -ge ${DROPBOX_STARTUP_TIMEOUT} ]]; then
  echo "WARNING: Startup timeout reached (${DROPBOX_STARTUP_TIMEOUT}s). Continuing anyway..."
fi

# --- Main Supervision Loop ---
RESTART_COUNT=0
while true; do
  if kill -0 "${DROPBOX_PID}" 2>/dev/null; then
    # Daemon is running
    if [[ -f "/opt/dropbox/.dropbox/info.json" ]]; then
      gosu dropbox dropbox status 2>/dev/null || true
    fi

    # Clean old temp files
    /usr/bin/find /tmp/ -maxdepth 1 -type d -mtime +1 ! -path /tmp/ -exec rm -rf {} \; 2>/dev/null || true

    # Execute optional polling command
    if [[ -n "${POLLING_CMD}" ]]; then
      eval "${POLLING_CMD}" 2>/dev/null || true
    fi

    sleep "${POLLING_INTERVAL}"
  else
    # Daemon crashed
    RESTART_COUNT=$((RESTART_COUNT + 1))
    if [[ ${RESTART_COUNT} -gt ${DROPBOX_MAX_RESTARTS} ]]; then
      echo "ERROR: Dropbox daemon crashed ${RESTART_COUNT} times. Giving up."
      exit 1
    fi
    echo "WARNING: Dropbox daemon exited. Restart attempt ${RESTART_COUNT}/${DROPBOX_MAX_RESTARTS} in ${DROPBOX_RESTART_DELAY}s..."
    sleep "${DROPBOX_RESTART_DELAY}"

    # Clean stale sockets before restart
    rm -f /opt/dropbox/.dropbox/command_socket \
          /opt/dropbox/.dropbox/iface_socket \
          /opt/dropbox/.dropbox/unlink.db \
          /opt/dropbox/.dropbox/dropbox.pid

    gosu dropbox "$@" & DROPBOX_PID="$!"
    echo "Restarted Dropbox daemon (PID: ${DROPBOX_PID})"
    sleep 5
  fi
done
