# Contributing

Contributions are welcome. Here's how to get started.

## Reporting bugs

Open an issue. Include:
- What you expected to happen
- What actually happened
- Container logs (`docker logs dropbox`)
- Your environment (OS, Docker version, Dropbox account size if relevant)

## Submitting changes

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Run the test suite: `bash tests/run_tests.sh`
4. Open a pull request with a clear description of what changed and why

## Development setup

```bash
git clone https://github.com/islamdiaa/dropbox-docker.git
cd dropbox-docker

# Run unit tests
pip install -r tests/requirements-test.txt
pytest tests/unit/ -v

# Build and run locally
docker build -t dropbox-docker:dev .
docker run --rm -it dropbox-docker:dev
```

## Style

- Shell scripts: follow existing style, pass ShellCheck
- Python: standard formatting, pass existing pytest suite
- Dockerfile: pass hadolint
- Keep it simple. This project should stay small and focused.
