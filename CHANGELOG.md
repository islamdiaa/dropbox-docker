# Changelog

All notable changes to this project will be documented in this file.

## 1.4.0 — 2026-10-20

### Security

- **Root no longer follows symlinks the Dropbox user can plant.** Before every daemon restart, the entrypoint (as root) emptied and chmodded analytics folders inside `~/.dropbox`. The Dropbox user owns that folder, so a compromised client could replace one with a symlink and make root delete or chmod whatever it pointed to, e.g. your synced files. Cleanup now runs as the Dropbox user, and the locked folders are recreated with a plain `mkdir`, which never follows a symlink.
- The ownership repair changes each file from inside its own folder (`find -execdir`), so swapping a parent folder for a symlink mid-walk can't redirect it. Root never touches `/opt/dropbox/Dropbox` when it is a symlink.
- Files unpacked from the Dropbox download don't keep their owner or setuid bits.

### Fixes

- **Startup no longer downloads the whole client just to check its version.** Every start fetched about 90 MB to read the version from the download URL; now it reads the redirect (a few hundred bytes).
- **An interrupted update can't break the container any more.** The new client is unpacked next to the old one and swapped in with renames; an incomplete install is detected and replaced on the next start instead of failing forever.
- **Network calls at startup have timeouts**, and `docker stop` works while the client downloads. A stalled connection used to hang startup indefinitely.
- The Dropbox CLI is part of the image instead of being downloaded at startup, so status, health and the status page work even when dropbox.com is unreachable when the container starts.
- `.dropbox.cache`, Dropbox's own cache of partial downloads in the sync folder, is no longer deleted on every start.
- No more `Dropbox isn't running!` right after start: the container waits for the daemon's command socket instead of `info.json`, which survives restarts.
- `Dropbox isn't responding!` (the CLI's 5-second timeout while the daemon is busy) is no longer logged on every poll; the log warns only if it lasts 5 minutes. The status page keeps showing the last known state meanwhile.
- The status page server handles requests in parallel and drops clients that never finish a request; CLI calls have timeouts and the excluded folder list is cached.
- Six crashes over the container's whole lifetime made it give up; the count now resets once the daemon has run for 10 minutes. `/status` and the metrics still report the total.
- `POLLING_INTERVAL=0` spun the CPU; intervals now have minimums.

### Changed

- **Ownership repair runs at startup, when Dropbox reports a file it can't sync, and daily** (`OWNERSHIP_FIX_INTERVAL` now defaults to 86400 instead of 360). Each pass reads every file's metadata, so running it every 6 minutes kept large Dropbox folders' disks busy and Unraid array disks awake.
- The log warns when the host's inotify watch limit is too low for large accounts. README guidance for raising it is updated (Unraid: Tips and Tweaks plugin).

## 1.3.0 — 2026-10-11

### Added

- **Status page.** With `ENABLE_MONITORING=true`, port 8001 serves a web page with the sync state, files syncing, downloading and uploading, account link, Dropbox version, memory and restarts. The Unraid template now enables monitoring, maps port 8001 and opens the page from the container's WebUI menu.
- Prometheus metrics `dropbox_daemon_up`, `dropbox_daemon_memory_bytes` and `dropbox_daemon_restarts`.
- The first log line shows the image version and revision, e.g. `dropbox-docker 1.3.0 (revision c50898d)`.

### Fixes

- **The Docker healthcheck works.** It used to pass whatever happened; it now reports unhealthy when the Dropbox daemon isn't running.
- `/health` returns HTTP 503 and `{"healthy": false}` when the daemon isn't running, instead of always `{"ok": true}` (the `ok` key is kept for compatibility).
- `/status` reports the daemon's memory, not the monitoring script's, and the real restart count instead of always 0.
- The ownership repair pass runs in the background at idle CPU and disk priority, so walking a large folder no longer pauses supervision.
- Issue templates no longer assign new issues to an unrelated GitHub user.

### CI/CD and security

- Releases are automatic: when `main` gets a new version section at the top of this changelog, CI publishes `X.Y.Z` and `X.Y` image tags, tags the commit and creates a GitHub release with that section as its notes. Pushing a `vX.Y.Z` tag works too.
- CodeQL analysis of the Python code and workflows, and an OpenSSF Scorecard check of the repository.
- Workflows are linted with actionlint, superseded pull request builds are cancelled, and checkouts no longer keep credentials.
- Unit tests keep the README, `.env.example`, Unraid template and Dockerfile in sync. New E2E tests cover the healthcheck, status page, JSON API and metrics; unit test coverage is reported.
- The image's Python dependencies moved to `requirements.txt`, so Dependabot keeps them updated. Dependabot no longer manages the Ubuntu base image (it proposed the end-of-life 24.10); the monthly build pulls the latest 24.04 instead.

### Documentation

- README rewritten: quick starts for Unraid, Compose and `docker run`, status page screenshots, a full configuration reference and an FAQ.
- Issue forms, a contributing guide with the release process, and a security policy with private reporting.

## 1.2.0 — 2026-10-11

### Fixes

- **Works with `cap_drop: ALL` again** ([#11](https://github.com/islamdiaa/dropbox-docker/issues/11)). The supervisor checked the daemon with `kill -0`, which needs `CAP_KILL` to probe another user's process. Without it a healthy daemon looked dead, so the container kept starting new instances (each with a new link URL) until it gave up. It now reads `/proc` instead, and sends signals as the dropbox user when root can't.
- **No more crash loop on first start.** On a fresh volume the analytics lockdown created `~/.dropbox` as root, so the daemon panicked with `unable to open database file: /opt/dropbox/.dropbox/apex.sqlite3` until the container was restarted.
- **Sync folder is made writable** ([#12](https://github.com/islamdiaa/dropbox-docker/issues/12)). When Docker creates the sync folder (e.g. on Unraid), it's owned by root and the daemon could link but never write a file. The container now fixes the top-level folder's owner at startup, and logs an error if it still isn't writable.
- **Clean shutdown with long polling intervals.** Signals were only handled after the current `sleep`, so with `POLLING_INTERVAL=30` (the Unraid template's value) `docker stop` hit its 10s timeout and SIGKILLed the daemon. Shutdown is now immediate and exits with code 0.
- A failed Dropbox download keeps the installed version instead of crash-looping the container.
- A failed download of the Dropbox CLI script no longer leaves an empty script behind that is never retried.
- The ownership fixer no longer follows symlinks (`chown -h`).

### Added

- **`OWNERSHIP_FIX_MODE`** (`full`, `group-only`, `disabled`) for shared NAS setups where files are owned by several users ([#10](https://github.com/islamdiaa/dropbox-docker/issues/10)), and **`OWNERSHIP_FIX_INTERVAL`** (default 360s). Previously the interval depended on `POLLING_INTERVAL`.
- Startup warnings when the sync folder or config is on a FUSE filesystem such as Unraid's `/mnt/user`.
- After linking, the log shows where each account syncs to, and warns when that isn't the mapped `/opt/dropbox/Dropbox` folder (e.g. Dropbox Business team folders).
- `dropbox status` is logged when it changes rather than on every poll.

### CI/CD

- **Fixed the monthly build**, which has failed every month since April 2026: `aquasecurity/trivy-action@0.28.0` no longer exists after the March 2026 Trivy supply-chain compromise. Images were still published, but never scanned. Now pinned to `0.35.0`, the release that compromise did not touch.
- All actions are pinned to commit SHAs, and updated (setup-python 6, setup-buildx 4, login 4, build-push 7).
- E2E tests and the vulnerability scan now run on pull requests too, and **before** an image is published. Previously the image was pushed first.
- New E2E tests for the bugs above (`cap_drop: ALL`, first run, sync folder permissions, shutdown timing), and existing tests fail on errors instead of printing warnings.
- Scheduled builds skip the layer cache so they pick up Ubuntu security updates.
- A failed scheduled build opens a GitHub issue.
- Dependabot groups action updates and no longer proposes Ubuntu major upgrades (26.04 doesn't build as-is).

### Documentation

- README: Dropbox Business / team folders, shared NAS permissions (TrueNAS example), troubleshooting, and corrected Unraid paths.

## 1.1.0 — 2026-02-28

### Security

- **Removed `POLLING_CMD`** — eliminated arbitrary command injection risk (ran as root via `eval`). If you were using this variable, it no longer has any effect.
- **Redacted PII from `/status` endpoint** — account email and display name are no longer returned. Only `{"linked": true/false}` is exposed.
- **Removed `Access-Control-Allow-Origin: *`** from monitoring responses to prevent cross-origin data access.
- **Added input validation** for `TZ`, `DROPBOX_UID`, and `DROPBOX_GID` environment variables (prevents path traversal and injection).
- **Fixed `grep` to use `-F`** (fixed string) for GID lookup, preventing regex metacharacter issues.
- **Added `cap_drop: ALL` + minimal `cap_add`** to docker-compose.yml for least-privilege operation.

### CI/CD

- **ShellCheck now fails the build** — removed `|| true` suppression.
- **Trivy scanner now fails on CRITICAL/HIGH** — changed `exit-code` from `0` to `1`.
- **Pinned Trivy action** to `v0.28.0` instead of floating `@master` tag (supply-chain hardening).

### Fixes

- **Bare `except:` → `except Exception:`** in monitoring.py — preserves `KeyboardInterrupt`/`SystemExit` propagation.
- **Scoped `/tmp` cleanup** to `dropbox*` directories only, instead of all directories older than 1 day.

### Documentation

- Added "What makes this different" section to README (telemetry fix, ownership auto-fix, stale cleanup).
- Added monitoring API documentation with example `/status` response and Prometheus scrape config.
- Added Security section to README with trust model explanation.
- Updated "How it works" section with all 11 startup steps.
- Updated SECURITY.md with binary download trust model documentation.

## 1.0.0 — 2026-02-22

Initial release.

### Highlights

- Runs the latest official Dropbox headless daemon inside Docker
- Built on Ubuntu 24.04 LTS
- Automatic daemon restart on crash (configurable via `DROPBOX_MAX_RESTARTS`)
- Built-in Docker HEALTHCHECK with startup grace period
- Waits for daemon readiness instead of blind sleep
- Proper SIGTERM/SIGINT handling for clean `docker stop`
- Optional Prometheus metrics (sync status, file counts)
- Optimized for large accounts (1M+ files) — no recursive `chown` by default
- CI/CD pipeline with monthly rebuilds, linting, and vulnerability scanning
- Published to Docker Hub and GitHub Container Registry
- Comprehensive test suite (unit + E2E)
