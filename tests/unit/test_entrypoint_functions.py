"""Tests for shell functions and structure in docker-entrypoint.sh."""

import os
import re
import subprocess

import pytest

REPO_ROOT = os.path.join(os.path.dirname(__file__), '..', '..')
ENTRYPOINT = os.path.join(REPO_ROOT, 'docker-entrypoint.sh')


def _read_entrypoint():
    with open(ENTRYPOINT) as f:
        return f.read()


class TestShellFunctions:
    """Verify expected shell functions are defined in the entrypoint."""

    def test_clean_stale_files_defined(self):
        content = _read_entrypoint()
        assert re.search(r'^clean_stale_files\(\)', content, re.MULTILINE), \
            "clean_stale_files() function not defined"

    def test_lock_analytics_defined(self):
        content = _read_entrypoint()
        assert re.search(r'^lock_analytics\(\)', content, re.MULTILINE), \
            "lock_analytics() function not defined"

    def test_cleanup_defined(self):
        content = _read_entrypoint()
        assert re.search(r'^cleanup\(\)', content, re.MULTILINE), \
            "cleanup() function not defined"

    def test_clean_stale_files_called_at_startup(self):
        """clean_stale_files should be called during startup (outside the restart loop)."""
        content = _read_entrypoint()
        lines = content.splitlines()
        # Find the first call to clean_stale_files (should be in the startup section)
        for i, line in enumerate(lines):
            if line.strip() == "clean_stale_files" and not line.strip().startswith("#"):
                # Verify it's in the startup section (before the supervision loop)
                preceding = "\n".join(lines[:i])
                assert "while true" not in preceding or "Clean Stale Files" in preceding
                return
        pytest.fail("clean_stale_files not called during startup")

    def test_clean_stale_files_called_in_restart(self):
        """clean_stale_files should be called during daemon restart."""
        content = _read_entrypoint()
        lines = content.splitlines()
        in_restart_section = False
        for line in lines:
            if "Daemon crashed" in line:
                in_restart_section = True
            if in_restart_section and line.strip() == "clean_stale_files":
                return
        pytest.fail("clean_stale_files not called in the restart section")


class TestSignalHandling:
    def test_trap_includes_sigterm(self):
        content = _read_entrypoint()
        trap_line = [l for l in content.splitlines() if l.startswith("trap cleanup")]
        assert len(trap_line) == 1, "Expected exactly one trap line"
        assert "SIGTERM" in trap_line[0]

    def test_trap_includes_sigint(self):
        content = _read_entrypoint()
        trap_line = [l for l in content.splitlines() if l.startswith("trap cleanup")]
        assert "SIGINT" in trap_line[0]

    def test_cleanup_kills_monitoring_pid(self):
        """cleanup() should terminate the monitoring process when set."""
        content = _read_entrypoint()
        # Find the cleanup function body
        in_cleanup = False
        cleanup_body = []
        for line in content.splitlines():
            if re.match(r'^cleanup\(\)', line):
                in_cleanup = True
                continue
            if in_cleanup:
                if line.startswith("}"):
                    break
                cleanup_body.append(line)

        body = "\n".join(cleanup_body)
        assert "MONITORING_PID" in body, \
            "cleanup() should reference MONITORING_PID for graceful shutdown"

    def test_monitoring_pid_initialized(self):
        """MONITORING_PID should be initialized before the trap is set."""
        content = _read_entrypoint()
        lines = content.splitlines()
        monitoring_pid_line = None
        trap_line = None
        for i, line in enumerate(lines):
            if 'MONITORING_PID=""' in line and monitoring_pid_line is None:
                monitoring_pid_line = i
            if line.startswith("trap cleanup") and trap_line is None:
                trap_line = i
        assert monitoring_pid_line is not None, "MONITORING_PID not initialized"
        assert trap_line is not None, "trap not set"
        assert monitoring_pid_line < trap_line, \
            "MONITORING_PID must be initialized before trap is set"


class TestEntrypointStructure:
    def test_set_euo_pipefail(self):
        """Script should use strict mode."""
        content = _read_entrypoint()
        assert "set -euo pipefail" in content

    def test_telemetry_block_is_idempotent(self):
        """Telemetry blocking should check before appending to /etc/hosts."""
        content = _read_entrypoint()
        assert "grep -q" in content and "telemetry.dropbox.com" in content, \
            "Telemetry block should use grep -q check for idempotency"

    def test_eval_has_security_warning(self):
        """eval of POLLING_CMD should have a security warning comment."""
        content = _read_entrypoint()
        lines = content.splitlines()
        for i, line in enumerate(lines):
            if "eval" in line and "POLLING_CMD" in line:
                # Check surrounding lines for warning (eval may be inside an if block)
                preceding = "\n".join(lines[max(0, i - 10):i + 1])
                assert "WARNING" in preceding or "warning" in preceding.lower(), \
                    "eval of POLLING_CMD should have a security warning comment"
                return
        pytest.fail("eval POLLING_CMD not found in script")

    def test_find_uses_batch_exec(self):
        """find commands for .so files should use {} + (batched) not {} \\;"""
        content = _read_entrypoint()
        for line in content.splitlines():
            if '*.so' in line and '-exec' in line:
                assert '{} +' in line or '{}+' in line, \
                    f"find .so command should use batched exec: {line.strip()}"
