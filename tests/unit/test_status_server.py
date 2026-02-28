"""Integration tests for the StatusHandler HTTP server and start_status_server."""

import json
import logging
import urllib.request
import urllib.error
from http.server import HTTPServer
from threading import Thread
from unittest.mock import MagicMock

import pytest

from monitoring import (
    DropboxInterface,
    DropboxMonitor,
    StatusHandler,
    start_status_server,
    State,
)


@pytest.fixture
def logger():
    return logging.getLogger("test_status_server")


@pytest.fixture
def mock_dropbox():
    mock = MagicMock(spec=DropboxInterface)
    mock.query_status.return_value = "Up to date\n"
    mock.query_account_info.return_value = {
        "personal": {"email": "user@test.com", "display_name": "Test"}
    }
    mock.query_exclude_list.return_value = []
    mock.query_version.return_value = "200.0.0"
    return mock


@pytest.fixture
def monitor(mock_dropbox, logger):
    return DropboxMonitor(
        dropbox=mock_dropbox,
        min_poll_interval_sec=1,
        logger=logger,
        prom_port=19999,  # unused port, we don't call start() here
    )


@pytest.fixture
def status_server(monitor, logger):
    """Start a real HTTP status server on an ephemeral port and return its base URL."""
    StatusHandler.monitor = monitor
    server = HTTPServer(("127.0.0.1", 0), StatusHandler)
    port = server.server_address[1]
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{port}"
    server.shutdown()


class TestStatusEndpoint:
    def test_status_returns_200(self, status_server):
        resp = urllib.request.urlopen(f"{status_server}/status")
        assert resp.status == 200

    def test_status_returns_json(self, status_server):
        resp = urllib.request.urlopen(f"{status_server}/status")
        content_type = resp.headers.get("Content-Type")
        assert content_type == "application/json"

    def test_status_body_has_required_keys(self, status_server):
        resp = urllib.request.urlopen(f"{status_server}/status")
        data = json.loads(resp.read())
        assert "status" in data
        assert "sync" in data
        assert "account" in data
        assert "daemon" in data
        assert "last_sync" in data
        assert "last_error" in data
        assert "excluded_folders" in data

    def test_status_reflects_monitor_state(self, status_server):
        resp = urllib.request.urlopen(f"{status_server}/status")
        data = json.loads(resp.read())
        assert data["status"] == "up to date"
        assert data["sync"]["syncing"] == 0
        assert data["account"]["email"] == "user@test.com"
        assert data["daemon"]["version"] == "200.0.0"

    def test_status_has_cors_header(self, status_server):
        resp = urllib.request.urlopen(f"{status_server}/status")
        assert resp.headers.get("Access-Control-Allow-Origin") == "*"

    def test_status_trailing_slash(self, status_server):
        resp = urllib.request.urlopen(f"{status_server}/status/")
        assert resp.status == 200
        data = json.loads(resp.read())
        assert "status" in data


class TestHealthEndpoint:
    def test_health_returns_200(self, status_server):
        resp = urllib.request.urlopen(f"{status_server}/health")
        assert resp.status == 200

    def test_health_returns_ok(self, status_server):
        resp = urllib.request.urlopen(f"{status_server}/health")
        data = json.loads(resp.read())
        assert data == {"ok": True}

    def test_health_trailing_slash(self, status_server):
        resp = urllib.request.urlopen(f"{status_server}/health/")
        assert resp.status == 200


class TestUnknownRoute:
    def test_unknown_path_returns_404(self, status_server):
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            urllib.request.urlopen(f"{status_server}/nonexistent")
        assert exc_info.value.code == 404

    def test_root_returns_404(self, status_server):
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            urllib.request.urlopen(f"{status_server}/")
        assert exc_info.value.code == 404


class TestStartStatusServer:
    def test_start_status_server_serves_requests(self, monitor, logger):
        """Test the start_status_server helper function end-to-end."""
        # Use port 0 via manual setup since start_status_server binds to a fixed port.
        # Instead, verify the function sets the class variable correctly.
        StatusHandler.monitor = None
        start_status_server(monitor, 18999, logger)
        assert StatusHandler.monitor is monitor

        # Actually hit the server started by start_status_server
        resp = urllib.request.urlopen("http://127.0.0.1:18999/health")
        assert resp.status == 200
