# Changelog

All notable changes to this project will be documented in this file.

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
