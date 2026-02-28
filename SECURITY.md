# Security

## Reporting vulnerabilities

If you find a security issue, please open a [GitHub issue](https://github.com/islamdiaa/dropbox-docker/issues). For sensitive disclosures, reach out privately before posting publicly.

## Supported versions

Use the latest image. Older tags are not patched.

| Tag | Supported |
|---|---|
| `latest` | Yes |
| Dated tags (e.g., `20260222`) | Best-effort |
| Older tags | No |

## What this project controls

This container downloads and runs the official Dropbox daemon binary from `dropbox.com`. We do not modify the daemon itself. Security of the Dropbox sync protocol and client is Dropbox's responsibility.

What we control:
- The base image and its system packages
- The entrypoint script (process management, permissions, signal handling)
- The monitoring script (Prometheus metrics, JSON status API)
- The CI pipeline (linting, scanning, publishing)

The CI pipeline runs Trivy vulnerability scans on every build and fails on CRITICAL/HIGH findings.

## Trust model

### Runtime binary downloads

The container downloads two files from Dropbox at startup:

1. **Dropbox daemon** — downloaded from `https://www.dropbox.com/download?plat=lnx.x86_64` via HTTPS
2. **Dropbox CLI script** — downloaded from `https://www.dropbox.com/download?dl=packages/dropbox.py` via HTTPS

Dropbox does not publish checksums or GPG signatures for their Linux client. This means we cannot verify the integrity of the downloaded binary beyond the HTTPS transport security. If `dropbox.com` or its CDN is compromised, a malicious binary could be installed.

**Mitigations:**
- Downloads use HTTPS with certificate verification (`curl -fsSL`)
- The daemon runs as a non-root user (via `gosu`), limiting the blast radius of a compromised binary
- Setting `DROPBOX_SKIP_UPDATE` pins the binary to whatever version is already installed, avoiding re-downloads
- Trivy scans the base image for known vulnerabilities on every build

### Container privileges

- The entrypoint runs as root (required for UID/GID remapping via `usermod`/`groupadd`)
- The Dropbox daemon runs as the unprivileged `dropbox` user via `gosu`
- The container does not require `--privileged` or `docker.sock`
- Recommended: use `cap_drop: ALL` with minimal `cap_add` (see docker-compose.yml)

### Input validation

All user-supplied environment variables are validated:
- `TZ` — checked against a character allowlist before use in file paths
- `DROPBOX_UID` / `DROPBOX_GID` — validated as numeric integers
- `POLLING_INTERVAL` — validated as a positive integer

### Monitoring endpoints

When `ENABLE_MONITORING=true`, two HTTP servers bind to `0.0.0.0`:
- Port 8000: Prometheus metrics (sync counts, memory, restart count)
- Port 8001: JSON status API (`/status`, `/health`)

These endpoints are **unauthenticated** and intended for LAN/homelab use. They do not expose account email, display name, or other PII. If you need to restrict access, use firewall rules or bind to a specific interface via Docker networking.

### CI/CD security

- Docker Hub and GHCR credentials stored as GitHub Actions secrets (never in code)
- Trivy vulnerability scanner fails builds on CRITICAL/HIGH findings
- ShellCheck enforced on the entrypoint script
- hadolint enforced on the Dockerfile
- Dependabot monitors base image and GitHub Actions dependencies daily
- Third-party actions pinned to specific versions (not floating tags)
