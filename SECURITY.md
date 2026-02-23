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
- The monitoring script (Prometheus metrics)
- The CI pipeline (linting, scanning, publishing)

The CI pipeline runs Trivy vulnerability scans on every build.
