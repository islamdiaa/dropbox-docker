# Changelog

All notable changes to this project will be documented in this file.

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
