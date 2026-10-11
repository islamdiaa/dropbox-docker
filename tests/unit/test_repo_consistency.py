"""Keep the image, its documentation and the Unraid template in sync."""
import os
import re
import xml.etree.ElementTree as ET

import pytest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")

# Set by the image for its own use, not settings users configure
INTERNAL_ENV = {"LANG", "LC_ALL", "IMAGE_VERSION", "IMAGE_REVISION"}


def read(name):
    with open(os.path.join(ROOT, name)) as f:
        return f.read()


def dockerfile_settings():
    names = re.findall(r"^ENV\s+([A-Z_]+)=", read("Dockerfile"), re.MULTILINE)
    return sorted(set(names) - INTERNAL_ENV)


def template():
    return ET.parse(os.path.join(ROOT, "unraid-template.xml")).getroot()


def template_variables():
    return [c.get("Target") for c in template().findall("Config") if c.get("Type") == "Variable"]


@pytest.mark.parametrize("name", dockerfile_settings())
class TestSettingsDocumented:
    def test_in_readme(self, name):
        assert f"`{name}`" in read("README.md"), f"{name} is not documented in README.md"

    def test_in_env_example(self, name):
        assert re.search(rf"^#?\s*{name}=", read(".env.example"), re.MULTILINE), \
            f"{name} is missing from .env.example"

    def test_used_by_entrypoint(self, name):
        assert name in read("docker-entrypoint.sh"), f"{name} is set but never read"


@pytest.mark.parametrize("name", template_variables())
def test_template_variable_is_real(name):
    assert name in read("docker-entrypoint.sh"), f"Template sets {name}, which the entrypoint ignores"
    assert f"`{name}`" in read("README.md"), f"Template variable {name} is not documented"


class TestUnraidTemplate:
    """Community Applications requires these to be present and sensible."""

    @pytest.mark.parametrize("tag", [
        "Name", "Repository", "Registry", "Support", "Project", "Overview",
        "Category", "WebUI", "TemplateURL", "Icon", "Changes",
    ])
    def test_required_fields(self, tag):
        element = template().find(tag)
        assert element is not None and (element.text or "").strip(), f"<{tag}> is empty"

    def test_support_is_forum_thread(self):
        assert template().findtext("Support").startswith("https://forums.unraid.net/topic/")

    def test_webui_matches_status_port(self):
        assert template().findtext("WebUI") == "http://[IP]:[PORT:8001]/"
        ports = {c.get("Target") for c in template().findall("Config") if c.get("Type") == "Port"}
        assert "8001" in ports

    def test_template_url_points_at_main(self):
        assert template().findtext("TemplateURL") == \
            "https://raw.githubusercontent.com/islamdiaa/dropbox-docker/main/unraid-template.xml"

    def test_changes_lists_latest_release(self):
        latest = re.search(r"^## (\d+\.\d+\.\d+) ", read("CHANGELOG.md"), re.MULTILINE).group(1)
        assert latest in template().findtext("Changes")


def test_changelog_versions_are_semver_and_descending():
    versions = re.findall(r"^## (\S+) — \d{4}-\d{2}-\d{2}$", read("CHANGELOG.md"), re.MULTILINE)
    assert versions, "CHANGELOG.md has no '## X.Y.Z — YYYY-MM-DD' headings"
    parsed = [tuple(int(p) for p in v.split(".")) for v in versions]
    assert all(len(p) == 3 for p in parsed)
    assert parsed == sorted(parsed, reverse=True)


def test_exposed_ports_documented():
    for port in re.findall(r"^EXPOSE (\d+)", read("Dockerfile"), re.MULTILINE):
        assert port in read("README.md")
