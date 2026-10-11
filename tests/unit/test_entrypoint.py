import subprocess
import re
import os
import pytest


class TestVersionParsing:
    """Test the version extraction logic used in docker-entrypoint.sh"""

    def _extract_version(self, url):
        """Python equivalent of the bash grep used in the entrypoint."""
        match = re.search(r'x86_64-(\d+\.\d+\.\d+)', url)
        return match.group(1) if match else ""

    def test_parse_version_from_url(self):
        url = "https://edge.dropboxstatic.com/dbx-releng/client/dropbox-lnx.x86_64-242.4.5815.tar.gz"
        assert self._extract_version(url) == "242.4.5815"

    def test_parse_version_different_format(self):
        url = "https://edge.dropboxstatic.com/dbx-releng/client/dropbox-lnx.x86_64-100.1.1.tar.gz"
        assert self._extract_version(url) == "100.1.1"

    def test_parse_version_no_match(self):
        url = "https://example.com/some-file.tar.gz"
        assert self._extract_version(url) == ""

    def test_parse_version_with_trailing_content(self):
        url = "https://cdn.dropbox.com/dropbox-lnx.x86_64-300.0.1.tar.gz?dl=1"
        assert self._extract_version(url) == "300.0.1"


class TestEntrypointSyntax:
    """Test that the entrypoint script has valid bash syntax"""

    def test_syntax_check(self):
        repo_root = os.path.join(os.path.dirname(__file__), '..', '..')
        result = subprocess.run(
            ["bash", "-n", "docker-entrypoint.sh"],
            capture_output=True, text=True,
            cwd=repo_root
        )
        assert result.returncode == 0, f"Syntax error: {result.stderr}"


class TestEntrypointRegressions:
    """Static guards for bugs that are easy to reintroduce."""

    def _script(self):
        path = os.path.join(os.path.dirname(__file__), '..', '..', 'docker-entrypoint.sh')
        with open(path) as f:
            return f.read()

    def test_no_kill_zero_liveness_check(self):
        # `kill -0` on the daemon (another UID) needs CAP_KILL, so under
        # `cap_drop: ALL` a running daemon looked dead and got duplicated (#11).
        code = [line for line in self._script().splitlines()
                if not line.lstrip().startswith('#')]
        assert not any("kill -0" in line for line in code)

    def test_config_dir_created_before_analytics_lockdown(self):
        # lock_analytics creates ~/.dropbox as root if it doesn't exist yet,
        # which made the daemon crash-loop on a fresh volume.
        script = self._script()
        create = script.index('install -d -o "${DROPBOX_UID}" -g "${DROPBOX_GID}" /opt/dropbox/.dropbox')
        first_lock = script.index('\nlock_analytics\n')
        assert create < first_lock
