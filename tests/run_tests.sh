#!/bin/bash
set -e
echo "========================================"
echo "  Dropbox Docker - Test Suite"
echo "========================================"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Unit Tests ---
echo "--- Running Unit Tests ---"
cd "$PROJECT_DIR"
pip3 install -q -r tests/requirements-test.txt 2>/dev/null || pip install -q -r tests/requirements-test.txt 2>/dev/null
python3 -m pytest tests/unit/ -v --tb=short
echo ""

# --- E2E Tests ---
echo "--- Running E2E Tests ---"
echo "(Requires Docker)"
echo ""

# Build first
bash "$SCRIPT_DIR/e2e/test_build.sh"
echo ""

# Run each e2e test
for test_file in "$SCRIPT_DIR"/e2e/test_*.sh; do
  if [ "$test_file" = "$SCRIPT_DIR/e2e/test_build.sh" ]; then
    continue  # Already ran
  fi
  echo ""
  bash "$test_file"
done

echo ""
echo "========================================"
echo "  All Tests Passed!"
echo "========================================"
