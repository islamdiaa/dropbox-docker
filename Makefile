.PHONY: build test test-unit test-e2e lint clean push

IMAGE_NAME ?= islamdiaa/dropbox-docker
IMAGE_TAG  ?= dev

# Build the Docker image
build:
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

# Run all tests
test: test-unit test-e2e

# Run unit tests only (no Docker required)
test-unit:
	pip install -q -r tests/requirements-test.txt 2>/dev/null || pip install -q --break-system-packages -r tests/requirements-test.txt
	python3 -m pytest tests/unit/ -v

# Run E2E tests (requires Docker)
test-e2e: build
	bash tests/run_tests.sh

# Lint Dockerfile and shell scripts
lint:
	@command -v hadolint >/dev/null 2>&1 && hadolint Dockerfile || echo "hadolint not installed, skipping Dockerfile lint"
	@command -v shellcheck >/dev/null 2>&1 && shellcheck docker-entrypoint.sh || echo "shellcheck not installed, skipping shell lint"

# Remove test containers and images
clean:
	docker rm -f $$(docker ps -a --filter "name=dropbox-test" -q) 2>/dev/null || true
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
	docker rmi dropbox-test:e2e 2>/dev/null || true

# Push to Docker Hub (requires docker login)
push: build
	docker push $(IMAGE_NAME):$(IMAGE_TAG)
