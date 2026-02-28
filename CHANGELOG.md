# Changelog

All notable changes to this project will be documented in this file.

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
