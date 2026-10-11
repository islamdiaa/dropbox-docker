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

Maintainers release by tagging:

1. Make sure `CHANGELOG.md` has a `## X.Y.Z — YYYY-MM-DD` section for the release, and update `<Changes>` in `unraid-template.xml`.
2. Tag the commit on `main` and push the tag:
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
3. CI builds, tests and scans the image, publishes `X.Y.Z` and `X.Y` tags to Docker Hub and GHCR, and creates a GitHub release from the changelog section.

Every push to `main` also publishes `latest`, and a scheduled build on the 1st of each month picks up Ubuntu security updates. If a scheduled build fails, CI opens an issue.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
