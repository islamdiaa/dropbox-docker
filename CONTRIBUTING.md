# Contributing

Contributions are welcome: bug reports, fixes, docs and features. This project stays small and focused on running the official Dropbox client reliably, so please open an issue to discuss larger changes first.

## Reporting bugs

Use the [bug report form](https://github.com/islamdiaa/dropbox-docker/issues/new/choose). The most useful things to include are the image version (the first log line) and the container log from the start. Remove any `cli_link_nonce` link from the log before posting it.

Security issues should be reported privately; see [SECURITY.md](SECURITY.md).

## Project layout

| Path | What it is |
|---|---|
| `Dockerfile` | The image |
| `docker-entrypoint.sh` | PID 1: settings, permissions, Dropbox download, supervision, shutdown |
| `healthcheck.sh` | Docker `HEALTHCHECK` |
| `monitoring.py` | Status page, JSON API and Prometheus metrics (`ENABLE_MONITORING=true`) |
| `webui/` | The status page's HTML, CSS and JavaScript (no build step, no external resources) |
| `unraid-template.xml` | Unraid template |
| `tests/unit/` | pytest: monitoring, entrypoint guards, docs/template consistency |
| `tests/e2e/` | Shell tests that start real containers |
| `docs/images/` | README screenshots |

## Development

You need Docker, Python 3.12, [ShellCheck](https://www.shellcheck.net/) and optionally [hadolint](https://github.com/hadolint/hadolint).

```bash
git clone https://github.com/islamdiaa/dropbox-docker.git
cd dropbox-docker

make lint        # ShellCheck and hadolint
make test-unit   # pytest, no Docker needed
make build       # build islamdiaa/dropbox-docker:dev
make test        # unit tests, then build dropbox-test:e2e and run every E2E test
```

The E2E tests start containers from `dropbox-test:e2e` and download the Dropbox client, so they need internet access. To run a single test, build the image once with `docker build -t dropbox-test:e2e .`, then run e.g. `bash tests/e2e/test_monitoring.sh`. If containers can only reach the internet through a proxy on the host, pass extra `docker run` options with `E2E_DOCKER_ARGS="--network host"`.

To try the status page without linking an account, run the image with `ENABLE_MONITORING=true -p 8001:8001` and open <http://localhost:8001>.

## Making changes

- **Shell:** follow the existing style and pass `shellcheck -x`. The entrypoint must keep working with `cap_drop: ALL` plus the five documented capabilities: never rely on `CAP_KILL` (no `kill -0` on the daemon).
- **Python:** keep `monitoring.py` dependency-light and covered by unit tests.
- **Status page:** plain HTML, CSS and JavaScript with no external resources; it has to work offline and under the Content-Security-Policy set in `monitoring.py`.
- **New settings:** add the `ENV` default to the Dockerfile, and document it in the README, `.env.example` and, if Unraid users need it, `unraid-template.xml`. The unit tests check that these stay in sync.
- **Tests:** a bug fix should come with a test that fails without it. E2E tests should fail loudly (`exit 1`), not print warnings.
- **Changelog:** add a line to `CHANGELOG.md` under the next version.

Open a pull request against `main`. CI runs lint, unit tests, the E2E suite, a Trivy scan and CodeQL; all must pass.

## Releases

Releases are automatic. To release a version:

1. In a pull request, add a `## X.Y.Z — YYYY-MM-DD` section at the top of `CHANGELOG.md` with the changes since the last release, and the same version in `<Changes>` in `unraid-template.xml` (a unit test checks this).
2. Merge it to `main`.

CI notices that the newest changelog version has no tag yet. After the image is built, tested and scanned, it publishes `latest`, `X.Y.Z` and `X.Y` to Docker Hub and GHCR, tags the commit `vX.Y.Z` and creates a GitHub release with the changelog section as its notes. Pushing a `vX.Y.Z` tag by hand does the same.

Every push to `main` publishes `latest`, and a scheduled build on the 1st of each month picks up Ubuntu security updates. If a scheduled build fails, CI opens an issue.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
