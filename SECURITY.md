# Security

## Reporting a vulnerability

Please report security issues **privately** through [GitHub's private vulnerability reporting](https://github.com/islamdiaa/dropbox-docker/security/advisories/new) (Security tab → Report a vulnerability), not as a public issue. The aim is to respond within a week and release a fix or mitigation as soon as practical, with credit to you unless you prefer otherwise.

If that form isn't available, contact the maintainer privately through [itayar.com](https://itayar.com) instead.

Problems in the Dropbox client itself should go to [Dropbox's bug bounty program](https://hackerone.com/dropbox).

## Supported versions

Only the latest release gets fixes. Use `latest` or the newest `X.Y.Z` tag.

| Tag | Supported |
|---|---|
| `latest`, newest `X.Y.Z` / `X.Y` | Yes |
| Older version tags, dated tags (e.g. `20261001`), commit tags | No |

## What this project controls

This container downloads and runs the official Dropbox daemon from `dropbox.com`, unmodified. The security of the Dropbox client and sync protocol is Dropbox's responsibility.

What we control:

- The base image (Ubuntu 24.04 LTS) and its packages
- The entrypoint (settings, permissions, process supervision, signal handling)
- The healthcheck
- The monitoring service: status page, JSON API and Prometheus metrics
- The CI pipeline that builds, tests, scans and publishes the image

## Trust model

### Runtime downloads

At startup the container downloads two files from Dropbox over HTTPS:

1. **The Dropbox daemon** from `https://www.dropbox.com/download?plat=lnx.x86_64`
2. **The Dropbox CLI script** from `https://www.dropbox.com/download?dl=packages/dropbox.py`

Dropbox doesn't publish checksums or signatures for its Linux client, so integrity can't be verified beyond TLS. If `dropbox.com` or its CDN were compromised, a malicious client could be installed.

Mitigations:

- Downloads use HTTPS with certificate verification (`curl -fsSL`).
- The daemon runs as an unprivileged user (via `gosu`), limiting what a compromised client could do.
- `DROPBOX_SKIP_UPDATE` keeps the installed client instead of downloading a new one.

### Container privileges

- The entrypoint runs as root, which it needs to map UID/GID and fix permissions. The Dropbox daemon and the monitoring service run as the unprivileged `dropbox` user.
- No `--privileged`, no `docker.sock`, no host networking.
- The container works with `cap_drop: ALL` plus `CHOWN`, `SETUID`, `SETGID`, `FOWNER` and `DAC_OVERRIDE` (see `docker-compose.yml`). It doesn't need `KILL`.
- The ownership repair pass changes symlinks themselves (`chown -h`), never their targets.

### Input validation

Every setting is validated before use:

- `TZ` is checked against a character allowlist before it's used in a file path.
- `DROPBOX_UID`, `DROPBOX_GID` and all interval, timeout and count settings must be numbers.
- `OWNERSHIP_FIX_MODE` must be one of the documented values.
- Nothing from the environment is passed to `eval` or a shell.

### Monitoring endpoints

With `ENABLE_MONITORING=true`, two HTTP servers listen on all interfaces inside the container:

- Port 8001: status page, `/status` and `/health`
- Port 8000: Prometheus `/metrics`

They're **unauthenticated** and meant for a trusted LAN. They don't expose your email or name, but they do show excluded folder names and the file named in the last sync error. The status page sends a strict Content-Security-Policy, `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`, loads nothing from other sites, and never shows the account link URL. Don't publish these ports to the internet; use a reverse proxy with authentication if you need remote access.

### Supply chain and CI

- Every image is built, tested end to end and scanned with Trivy (CRITICAL/HIGH with a fix available fail the build) **before** it's published. Pull requests run the same checks.
- CodeQL analyzes the Python code and the workflows; OpenSSF Scorecard checks the repository.
- All GitHub Actions are pinned to commit SHAs, workflows have read-only permissions by default, and checkouts don't keep credentials.
- Dependabot updates actions and Python packages weekly; the monthly build pulls the latest Ubuntu 24.04 base image.
- Registry credentials are GitHub Actions secrets and are never used by pull request builds.
