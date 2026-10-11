import logging
import pytest
from unittest.mock import MagicMock
import monitoring
from monitoring import DropboxMonitor, DropboxInterface, State, Metric


@pytest.fixture
def logger():
    return logging.getLogger("test")


@pytest.fixture
def mock_dropbox(logger):
    dropbox = MagicMock(spec=DropboxInterface)
    dropbox.query_daemon_pid.return_value = 1234
    dropbox.query_daemon_memory_bytes.return_value = 256 * 1024 * 1024
    dropbox.query_restart_count.return_value = 0
    return dropbox


@pytest.fixture
def monitor(mock_dropbox, logger):
    return DropboxMonitor(
        dropbox=mock_dropbox,
        min_poll_interval_sec=5,
        logger=logger,
        prom_port=9999,
    )


class TestParseOutput:
    def test_up_to_date(self, monitor):
        monitor.parse_output("Up to date\n")
        assert monitor.num_syncing == 0
        assert monitor.num_downloading == 0
        assert monitor.num_uploading == 0

    def test_not_running(self, monitor):
        monitor.parse_output("Dropbox isn't running!\n")
        assert monitor.num_syncing is None

    def test_syncing_multiple_files(self, monitor):
        monitor.parse_output("Syncing 176 files\n")
        assert monitor.num_syncing == 176

    def test_downloading_multiple_files(self, monitor):
        monitor.parse_output("Downloading 82 files (2,457 KB/sec, 2 secs)\n")
        assert monitor.num_downloading == 82

    def test_uploading_multiple_files(self, monitor):
        monitor.parse_output("Uploading 10 files\n")
        assert monitor.num_uploading == 10

    def test_syncing_single_file(self, monitor):
        monitor.parse_output('Syncing "test.txt"\n')
        assert monitor.num_syncing == 1

    def test_downloading_single_file(self, monitor):
        monitor.parse_output('Downloading "test.txt"\n')
        assert monitor.num_downloading == 1

    def test_indexing(self, monitor):
        monitor.parse_output("Indexing 1 file...\n")
        assert monitor.num_syncing is None

    def test_starting(self, monitor):
        monitor.parse_output("Starting...\n")
        assert monitor.num_syncing is None

    def test_sync_error(self, monitor):
        monitor.parse_output('Can\'t sync "file.txt" (access denied)\n')
        assert monitor.num_syncing is None

    def test_sync_error_records_last_error(self, monitor):
        monitor.parse_output('Can\'t sync "file.txt" (access denied)\n')
        assert monitor.last_error is not None
        assert "file.txt" in monitor.last_error

    def test_unknown_line(self, monitor):
        monitor.parse_output("Some unknown status\n")
        assert monitor.num_syncing is None

    def test_empty_input(self, monitor):
        monitor.parse_output("")
        assert monitor.num_syncing is None

    def test_commas_in_numbers(self, monitor):
        monitor.parse_output("Downloading 1,234 files\n")
        assert monitor.num_downloading == 1234

    def test_up_to_date_does_not_fall_through_to_not_running(self, monitor):
        """Regression test: 'Up to date' should not be overridden by 'Dropbox isn't running!' check"""
        monitor.parse_output("Up to date\n")
        assert monitor.num_syncing == 0

    def test_up_to_date_records_last_sync_time(self, monitor):
        assert monitor.last_sync_time is None
        monitor.parse_output("Up to date\n")
        assert monitor.last_sync_time is not None

    def test_state_is_tracked(self, monitor):
        monitor.parse_output("Syncing 10 files\n")
        assert monitor.state == State.SYNCING
        monitor.parse_output("Up to date\n")
        assert monitor.state == State.UP_TO_DATE

    def test_raw_status_stored(self, monitor, mock_dropbox):
        mock_dropbox.query_status.return_value = "Syncing 5 files\n"
        monitor.get_status(Metric.NUM_SYNCING)
        assert "Syncing 5 files" in monitor.raw_status


class TestGetStatus:
    def test_respects_polling_interval(self, monitor, mock_dropbox):
        mock_dropbox.query_status.return_value = "Up to date\n"

        # First call should query
        monitor.get_status(Metric.NUM_SYNCING)
        assert mock_dropbox.query_status.call_count == 1

        # Immediate second call should NOT query (within interval)
        monitor.get_status(Metric.NUM_SYNCING)
        assert mock_dropbox.query_status.call_count == 1

    def test_returns_zero_for_none(self, monitor):
        result = monitor.get_status(Metric.NUM_SYNCING)
        assert result == 0

    def test_invalid_metric_raises(self, monitor):
        with pytest.raises(ValueError):
            monitor.get_status("invalid")


class TestJsonStatus:
    def test_json_status_structure(self, monitor, mock_dropbox):
        mock_dropbox.query_status.return_value = "Up to date\n"
        mock_dropbox.query_account_info.return_value = {
            "personal": {"email": "test@example.com", "display_name": "Test User"}
        }
        mock_dropbox.query_exclude_list.return_value = ["Backups"]
        mock_dropbox.query_version.return_value = "242.4.5815"

        result = monitor.get_json_status()

        assert result["status"] == "up to date"
        assert result["sync"]["syncing"] == 0
        assert result["sync"]["downloading"] == 0
        assert result["sync"]["uploading"] == 0
        assert result["account"]["linked"] is True
        assert "email" not in result["account"]  # PII redacted for security
        assert "display_name" not in result["account"]
        assert result["daemon"]["version"] == "242.4.5815"
        assert result["daemon"]["uptime_seconds"] >= 0
        assert result["daemon"]["restart_count"] == 0
        assert result["excluded_folders"] == ["Backups"]

    def test_json_status_no_account(self, monitor, mock_dropbox):
        mock_dropbox.query_status.return_value = "Starting...\n"
        mock_dropbox.query_account_info.return_value = None
        mock_dropbox.query_exclude_list.return_value = None
        mock_dropbox.query_version.return_value = None

        result = monitor.get_json_status()

        assert result["status"] == "starting"
        assert result["account"]["linked"] is False
        assert result["daemon"]["version"] is None
        assert result["excluded_folders"] == []

    def test_json_status_with_error(self, monitor, mock_dropbox):
        mock_dropbox.query_status.return_value = 'Can\'t sync "big.zip" (access denied)\n'
        mock_dropbox.query_account_info.return_value = None
        mock_dropbox.query_exclude_list.return_value = None
        mock_dropbox.query_version.return_value = "242.4.5815"

        result = monitor.get_json_status()

        assert result["status"] == "sync_error"
        assert "big.zip" in result["last_error"]


class TestDaemonHealth:
    def test_healthy_when_daemon_running(self, monitor, mock_dropbox):
        mock_dropbox.query_status.return_value = "Up to date\n"
        mock_dropbox.query_account_info.return_value = None
        mock_dropbox.query_exclude_list.return_value = None
        mock_dropbox.query_version.return_value = None
        assert monitor.is_healthy() is True
        assert monitor.get_json_status()["healthy"] is True

    def test_unhealthy_without_daemon(self, monitor, mock_dropbox):
        mock_dropbox.query_daemon_pid.return_value = None
        assert monitor.is_healthy() is False

    def test_reports_daemon_memory_and_restarts(self, monitor, mock_dropbox):
        mock_dropbox.query_status.return_value = "Up to date\n"
        mock_dropbox.query_account_info.return_value = None
        mock_dropbox.query_exclude_list.return_value = None
        mock_dropbox.query_version.return_value = None
        mock_dropbox.query_restart_count.return_value = 3
        result = monitor.get_json_status()
        assert result["daemon"]["memory_mb"] == 256.0
        assert result["daemon"]["restart_count"] == 3

    def test_image_version_from_environment(self, monitor, mock_dropbox, monkeypatch):
        monkeypatch.setenv("IMAGE_VERSION", "1.3.0")
        monkeypatch.setenv("IMAGE_REVISION", "abc1234def")
        mock_dropbox.query_status.return_value = "Up to date\n"
        mock_dropbox.query_account_info.return_value = None
        mock_dropbox.query_exclude_list.return_value = None
        mock_dropbox.query_version.return_value = None
        assert monitor.get_json_status()["image"] == {"version": "1.3.0", "revision": "abc1234def"}


class TestProcHelpers:
    def _proc(self, tmp_path, pid, argv, rss_kb=None):
        d = tmp_path / str(pid)
        d.mkdir()
        (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
        if rss_kb is not None:
            (d / "status").write_text(f"Name:\tdropbox\nVmRSS:\t{rss_kb} kB\n")

    def test_finds_daemon(self, tmp_path):
        self._proc(tmp_path, 10, ["/bin/bash", "/docker-entrypoint.sh"])
        self._proc(tmp_path, 42, ["/opt/dropbox/bin/dropbox-lnx.x86_64-272.4.3798/dropbox"])
        (tmp_path / "self").mkdir()
        assert monitoring.find_daemon_pid(str(tmp_path)) == 42

    def test_ignores_cli_and_launcher(self, tmp_path):
        self._proc(tmp_path, 11, ["/bin/sh", "/opt/dropbox/bin/dropboxd"])
        self._proc(tmp_path, 12, ["python3", "/opt/dropbox.py", "status"])
        assert monitoring.find_daemon_pid(str(tmp_path)) is None

    def test_missing_proc_root(self, tmp_path):
        assert monitoring.find_daemon_pid(str(tmp_path / "nope")) is None

    def test_read_rss(self, tmp_path):
        self._proc(tmp_path, 42, ["x"], rss_kb=2048)
        assert monitoring.read_rss_bytes(42, str(tmp_path)) == 2048 * 1024
        assert monitoring.read_rss_bytes(43, str(tmp_path)) is None

    def test_restart_count_file(self, tmp_path, monkeypatch, logger):
        path = tmp_path / "restart_count"
        monkeypatch.setattr(monitoring, "RESTART_COUNT_FILE", str(path))
        dropbox = DropboxInterface(logger)
        assert dropbox.query_restart_count() == 0
        path.write_text("4\n")
        assert dropbox.query_restart_count() == 4
        path.write_text("garbage")
        assert dropbox.query_restart_count() == 0


class TestPrometheusMetrics:
    def test_daemon_gauges_exported(self, monitor, mock_dropbox, monkeypatch):
        from prometheus_client import REGISTRY, generate_latest
        from prometheus_client.parser import text_string_to_metric_families
        monkeypatch.setattr(monitoring, "start_http_server", lambda port: None)
        mock_dropbox.query_status.return_value = "Up to date\n"
        mock_dropbox.query_restart_count.return_value = 2
        monitor.start()
        samples = {
            sample.name: sample.value
            for family in text_string_to_metric_families(generate_latest(REGISTRY).decode())
            for sample in family.samples
        }
        assert samples["dropbox_daemon_up"] == 1
        assert samples["dropbox_daemon_restarts"] == 2
        assert samples["dropbox_daemon_memory_bytes"] == 256 * 1024 * 1024


class TestStatusServer:
    @pytest.fixture
    def server(self, monitor, mock_dropbox):
        from http.server import HTTPServer
        from threading import Thread
        mock_dropbox.query_status.return_value = "Up to date\n"
        mock_dropbox.query_account_info.return_value = {"personal": {}}
        mock_dropbox.query_exclude_list.return_value = []
        mock_dropbox.query_version.return_value = "272.4.3798"
        monitoring.StatusHandler.monitor = monitor
        httpd = HTTPServer(("127.0.0.1", 0), monitoring.StatusHandler)
        Thread(target=httpd.serve_forever, daemon=True).start()
        yield f"http://127.0.0.1:{httpd.server_address[1]}"
        httpd.shutdown()
        httpd.server_close()

    def _get(self, url):
        import urllib.request
        import urllib.error
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    def test_status_json(self, server):
        import json
        code, headers, body = self._get(server + "/status")
        assert code == 200
        assert headers["Content-Type"] == "application/json"
        data = json.loads(body)
        assert data["status"] == "up to date"
        assert data["account"] == {"linked": True}

    def test_health_ok(self, server):
        code, _, body = self._get(server + "/health")
        assert code == 200
        assert b'"healthy": true' in body

    def test_health_unhealthy(self, server, mock_dropbox):
        mock_dropbox.query_daemon_pid.return_value = None
        code, _, body = self._get(server + "/health")
        assert code == 503
        assert b'"healthy": false' in body

    def test_status_page(self, server):
        code, headers, body = self._get(server + "/")
        assert code == 200
        assert headers["Content-Type"].startswith("text/html")
        assert "script-src 'self'" in headers["Content-Security-Policy"]
        assert headers["X-Content-Type-Options"] == "nosniff"
        assert b'<script src="app.js"' in body

    def test_static_assets(self, server):
        for path, kind in (("/app.js", "text/javascript"), ("/style.css", "text/css")):
            code, headers, body = self._get(server + path)
            assert code == 200
            assert headers["Content-Type"].startswith(kind)
            assert body

    def test_unknown_path_and_traversal(self, server):
        for path in ("/nope", "/../monitoring.py", "/webui/index.html"):
            code, _, _ = self._get(server + path)
            assert code == 404
