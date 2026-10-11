#!/bin/bash
set -e
echo "=== E2E Test: Docker Build ==="
cd "$(dirname "$0")/../.."
docker build -t dropbox-test:e2e .
echo "PASS: Image built successfully"
docker image inspect dropbox-test:e2e --format "{{json .Config.Healthcheck}}" | grep -q "healthcheck.sh"
echo "PASS: Healthcheck configured"
echo "=== All build tests passed ==="
