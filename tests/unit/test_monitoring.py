import logging
import pytest
from unittest.mock import MagicMock
from monitoring import DropboxMonitor, DropboxInterface, State, Metric


@pytest.fixture
def logger():
    return logging.getLogger("test")


@pytest.fixture
def mock_dropbox(logger):
    return MagicMock(spec=DropboxInterface)


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
        assert result["account"]["email"] == "test@example.com"
        assert result["account"]["display_name"] == "Test User"
        assert result["account"]["linked"] is True
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
