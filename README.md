# dropbox-docker

[![CI](https://github.com/islamdiaa/dropbox-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/islamdiaa/dropbox-docker/actions/workflows/ci.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/islamdiaa/dropbox-docker)](https://hub.docker.com/r/islamdiaa/dropbox-docker)

A Docker container that runs the official Dropbox headless daemon on Linux. Built for homelabs and self-hosted setups that need reliable, hands-off Dropbox sync — especially large accounts with hundreds of thousands of files.

The image pulls the latest Dropbox client binary on every startup, so you never need to manually update. If the daemon crashes, it restarts automatically. If you stop the container, it shuts down cleanly.

## Why this exists

Every Dropbox Docker image I found was either abandoned, crashing on large accounts, or missing basic things like health checks and graceful shutdown. I needed something that could handle 1M+ files on an Unraid server without falling over, so I built this.

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
| `POLLING_CMD` | _(empty)_ | An optional shell command to run on each poll cycle. Handy for custom notifications or logging. |

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
- Map `/opt/dropbox/Dropbox` to your actual sync location (e.g., `/mnt/disk1/Dropbox`)
- Set `DROPBOX_UID=99` and `DROPBOX_GID=100` (Unraid's `nobody:users`)
- If your sync folder is large, make sure Docker's image file has enough space

## How it works

On startup, the container:

1. Sets up timezone and user/group mapping
2. Cleans up stale socket files from any previous unclean shutdown
3. Downloads the latest official Dropbox daemon (unless `DROPBOX_SKIP_UPDATE` is set)
4. Installs the Dropbox CLI tool
5. Launches `dropboxd` as a non-root user
6. Waits for the daemon to signal readiness (or times out)
7. Enters a supervision loop — if the daemon dies, it restarts (up to `DROPBOX_MAX_RESTARTS` times)

The container has a `HEALTHCHECK` that runs `dropbox status` every 60 seconds with a 2-minute startup grace period.

Signal handling: `docker stop` sends `SIGTERM`, which the entrypoint catches and forwards to the daemon for a clean shutdown.

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
