import subprocess
import re
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
        result = subprocess.run(
            ["bash", "-n", "docker-entrypoint.sh"],
            capture_output=True, text=True,
            cwd="/Users/islamdiaa/Desktop/pwork/homeserver/dropbox/dropbox-docker"
        )
        assert result.returncode == 0, f"Syntax error: {result.stderr}"
