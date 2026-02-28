# dropbox-docker

[![CI](https://github.com/islamdiaa/dropbox-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/islamdiaa/dropbox-docker/actions/workflows/ci.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/islamdiaa/dropbox-docker?v=2)](https://hub.docker.com/r/islamdiaa/dropbox-docker)
[![Docker Image](https://img.shields.io/docker/image-size/islamdiaa/dropbox-docker/latest)](https://hub.docker.com/r/islamdiaa/dropbox-docker)

A Docker container that runs the official Dropbox headless daemon on Linux. Built for homelabs and self-hosted setups that need reliable, hands-off Dropbox sync — especially large accounts with hundreds of thousands of files.

The image pulls the latest Dropbox client binary on every startup, so you never need to manually update. If the daemon crashes, it restarts automatically. If you stop the container, it shuts down cleanly.

## Why this exists

Every Dropbox Docker image I found was either abandoned, crashing on large accounts, or missing basic things like health checks and graceful shutdown. I needed something that could handle 1M+ files on an Unraid server without falling over, so I built this.

### What makes this different

- **Telemetry crash fix.** The Dropbox daemon has a known Rust panic in its analytics code that crashes the daemon during indexing of large accounts. This container blocks the telemetry endpoint and locks down analytics directories to prevent the crash entirely — no patches, no hacks, just isolation.
- **File ownership auto-fix.** Files created by other users (root, SSH, scripts) inside the Dropbox folder are automatically chowned to the Dropbox user every ~6 minutes, so they actually get synced.
- **Stale file cleanup.** Leftover `.dropbox` directories from previous installations are cleaned on startup, preventing `PermissionDenied` errors that block the daemon.
- **Proper process supervision.** Bounded restarts, signal forwarding, graceful shutdown, startup readiness detection — not just `dropboxd &` and hope.
- **Optional monitoring.** Prometheus metrics and a JSON status API for integrating with your existing monitoring stack.

## Getting started

```bash
docker run -d \
  --name dropbox \
  --restart unless-stopped \
  -v dropbox-config:/opt/dropbox \
  -v /your/sync/folder:/opt/dropbox/Dropbox \
  islamdiaa/dropbox-docker
```

Check the logs for a link to connect your Dropbox account:

```bash
docker logs -f dropbox
```

Open the link in a browser, sign in, and sync starts automatically.

## Compose

```yaml
services:
  dropbox:
    image: islamdiaa/dropbox-docker:latest
    container_name: dropbox
    restart: unless-stopped
    volumes:
      - dropbox-config:/opt/dropbox
      - /srv/dropbox:/opt/dropbox/Dropbox
    environment:
      TZ: Europe/London
      DROPBOX_UID: "1000"
      DROPBOX_GID: "1000"
    ports:
      - "17500:17500"  # LAN sync discovery
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - FOWNER
      - DAC_OVERRIDE

volumes:
  dropbox-config:
```

## Configuration

All configuration is through environment variables. None are required — defaults work out of the box.

### Identity

| Variable | Default | What it does |
|---|---|---|
| `DROPBOX_UID` | `1000` | User ID the daemon runs as. Match this to the owner of your sync folder. |
| `DROPBOX_GID` | `1000` | Group ID. Same idea. |
| `TZ` | `UTC` | Timezone for log timestamps. |

### Behavior

| Variable | Default | What it does |
|---|---|---|
| `SKIP_SET_PERMISSIONS` | `true` | When `true`, skips the recursive `chown` on `/opt/dropbox` at startup. Turn this off only if you need ownership fixed — it takes forever on large folders. |
| `DROPBOX_SKIP_UPDATE` | _(unset)_ | Set to anything to skip pulling the latest Dropbox binary on start. Useful if you want to lock a specific version. |
| `POLLING_INTERVAL` | `5` | How often (in seconds) to poll `dropbox status` and clean up temp files. |

### Reliability

| Variable | Default | What it does |
|---|---|---|
| `DROPBOX_MAX_RESTARTS` | `5` | How many times to restart the daemon if it crashes before giving up. |
| `DROPBOX_RESTART_DELAY` | `10` | Seconds to wait between restart attempts. |
| `DROPBOX_STARTUP_TIMEOUT` | `300` | How long to wait for the daemon to finish initializing. Large accounts need more time here. |

### Monitoring

| Variable | Default | What it does |
|---|---|---|
| `ENABLE_MONITORING` | `false` | Enables Prometheus metrics (port 8000) and JSON status API (port 8001). |

When enabled, the container exposes:

| Port | Endpoint | What it returns |
|---|---|---|
| 8000 | `/metrics` | Prometheus metrics (sync status, file counts, restart count, memory) |
| 8001 | `/status` | JSON with sync state, account link status, version, excluded folders, errors |
| 8001 | `/health` | `{"healthy": true/false}` — for health checks and load balancers |

**Example `/status` response:**
```json
{
  "status": "Up to date",
  "account": {"linked": true},
  "sync": {"syncing": false, "files_remaining": 0},
  "version": "211.4.5660",
  "memory_mb": 245,
  "restart_count": 0,
  "excluded_folders": ["Unraid-Backup"],
  "last_error": null
}
```

**Example Prometheus scrape config:**
```yaml
scrape_configs:
  - job_name: dropbox
    static_configs:
      - targets: ['dropbox:8000']
```

## Handling large accounts

If you have a lot of files (500K+), a few things help:

1. **Give it memory.** The Dropbox daemon builds an in-memory index. `--memory 4g` is a reasonable starting point.

2. **Increase the startup timeout.** Initial indexing can take a while:
   ```
   DROPBOX_STARTUP_TIMEOUT=600
   ```

3. **Bump inotify watchers on the host.** The kernel default (8192) is too low:
   ```bash
   echo "fs.inotify.max_user_watches=1048576" >> /etc/sysctl.conf
   sysctl -p
   ```

4. **Keep `SKIP_SET_PERMISSIONS=true`** (the default). Running `chown -R` over a million files on every container start is a recipe for pain.

5. **Use a longer polling interval** to reduce CPU:
   ```
   POLLING_INTERVAL=30
   ```

## Running on Unraid

Works well on Unraid. A few notes:

- Map `/opt/dropbox` to somewhere on appdata (e.g., `/mnt/user/appdata/dropbox`)
- Map `/opt/dropbox/Dropbox` to a **direct disk path** (e.g., `/mnt/disk1/Dropbox`) — do NOT use `/mnt/user/Dropbox`
- Set `DROPBOX_UID=99` and `DROPBOX_GID=100` (Unraid's `nobody:users`)
- If your sync folder is large, make sure Docker's image file has enough space

**Important: Set the Dropbox share to `Use cache: No`** in Unraid's share settings. If caching is enabled, files written via `/mnt/user/Dropbox/` land on the cache drive first, but the container mounts the disk path directly and won't see those files until the mover runs. Setting cache to No ensures all writes go directly to the disk where the container can detect and sync them immediately.

**File ownership:** Files created by root (e.g., via SSH) inside the Dropbox folder are automatically fixed by the container. A background process runs every ~6 minutes to chown any files not owned by the Dropbox user, ensuring they get synced.

## How it works

On startup, the container:

1. Validates timezone, UID/GID inputs
2. Sets up user/group mapping
3. Cleans stale socket files and leftover `.dropbox` directories from previous runs
4. Blocks Dropbox telemetry endpoint (prevents a known Rust panic crash)
5. Locks analytics directories as root-owned read-only (prevents 2GB+ cache growth)
6. Downloads the latest official Dropbox daemon (unless `DROPBOX_SKIP_UPDATE` is set)
7. Installs the Dropbox CLI tool
8. Launches `dropboxd` as a non-root user via `gosu`
9. Waits for the daemon to signal readiness (or times out)
10. Enters a supervision loop — if the daemon dies, it restarts (up to `DROPBOX_MAX_RESTARTS` times)
11. Periodically fixes file ownership on the sync folder so files from other users get synced

The container has a `HEALTHCHECK` that runs `dropbox status` every 60 seconds with a 2-minute startup grace period.

Signal handling: `docker stop` sends `SIGTERM`, which the entrypoint catches and forwards to the daemon for a clean shutdown.

## Security

- The entrypoint runs as root (needed for UID/GID remapping) but the Dropbox daemon runs as an unprivileged user via `gosu`
- All user inputs (TZ, UID, GID) are validated before use
- The monitoring endpoints do not expose account email or PII
- No `docker.sock` mount required
- Runs in bridge networking mode (not host)
- The Dropbox binary is downloaded from `dropbox.com` over HTTPS at runtime — Dropbox does not publish checksums for their Linux client, so integrity verification is not possible. See [SECURITY.md](SECURITY.md) for details.

## Building from source

```bash
git clone https://github.com/islamdiaa/dropbox-docker.git
cd dropbox-docker
docker build -t dropbox-docker .
```

## Tests

```bash
# Unit tests (no Docker needed)
pip install -r tests/requirements-test.txt
pytest tests/unit/ -v

# Everything including E2E (needs Docker)
bash tests/run_tests.sh
```

## Acknowledgments

Originally inspired by [otherguy/docker-dropbox](https://github.com/otherguy/docker-dropbox) and [janeczku/dropbox](https://github.com/janeczku/dropbox). This project is a ground-up rewrite with a focus on reliability for large-scale sync.

## Author

[Islam ElTayar](https://itayar.com) — built this for my own homelab, sharing it in case it helps yours.

## License

MIT. See [LICENSE.md](LICENSE.md).
