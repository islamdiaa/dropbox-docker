from argparse import ArgumentParser
from enum import Enum
from functools import partial
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import logging
import os
import re
import signal
import subprocess
from threading import Thread, Event
from time import time
from typing import Optional

from prometheus_client import start_http_server, Enum as EnumMetric, Gauge  # type: ignore


class Metric(Enum):
    NUM_SYNCING = "num_syncing"
    NUM_DOWNLOADING = "num_downloading"
    NUM_UPLOADING = "num_uploading"


class State(Enum):
    STARTING = "starting"
    SYNCING = "syncing"
    INDEXING = "indexing"
    UP_TO_DATE = "up to date"
    SYNC_ERROR = "sync_error"
    NOT_RUNNING = "not running"
    UNKNOWN = "unknown"


class DropboxInterface:
    """
    This can be mocked for testing as needed
    """

    def __init__(self, logger: logging.Logger) -> None:
        self.logger = logger

    def query_status(self) -> Optional[str]:
        try:
            result = subprocess.run(
                ["dropbox", "status"], capture_output=True, text=True
            )
            if result.stderr:
                self.logger.warning("Dropbox status returned error: %s", result.stderr)
                return None
            elif not result.stdout:
                self.logger.warning("Dropbox status did not produce results")
                return None
            else:
                self.logger.debug("Got result from Dropbox: %s", result.stdout)
                return result.stdout
        except:
            self.logger.exception("Failed to invoke Dropbox")
            return None

    def query_account_info(self) -> Optional[dict]:
        """Read account info from Dropbox's info.json."""
        try:
            info_path = "/opt/dropbox/.dropbox/info.json"
            if os.path.exists(info_path):
                with open(info_path) as f:
                    return json.load(f)
        except:
            pass
        return None

    def query_exclude_list(self) -> Optional[list]:
        """Get the list of excluded (selective sync) folders."""
        try:
            result = subprocess.run(
                ["dropbox", "exclude", "list"], capture_output=True, text=True
            )
            if result.stdout:
                lines = result.stdout.strip().splitlines()
                # First line is header like "Excluded:"
                return [l.strip() for l in lines[1:] if l.strip()] if len(lines) > 1 else []
        except:
            pass
        return None

    def query_version(self) -> Optional[str]:
        """Read the daemon version from VERSION file."""
        try:
            version_path = "/opt/dropbox/bin/VERSION"
            if os.path.exists(version_path):
                with open(version_path) as f:
                    return f.read().strip()
        except:
            pass
        return None


class DropboxMonitor:
    def __init__(
        self,
        dropbox: DropboxInterface,
        min_poll_interval_sec: int,
        logger: logging.Logger,
        prom_port: int,
    ) -> None:
        self.dropbox = dropbox
        self.min_poll_interval_sec = min_poll_interval_sec
        self.logger = logger
        self.prom_port = prom_port
        self.status_matcher = re.compile(
            "(Syncing|Downloading|Uploading|Indexing) (\\d+) files"
        )
        self.status_matcher_with_file = re.compile(
            '(Syncing|Downloading|Uploading|Indexing) ".+"'
        )

        self.last_query_time = 0
        self.num_syncing = None  # type: Optional[int]
        self.num_downloading = None  # type: Optional[int]
        self.num_uploading = None  # type: Optional[int]
        self.state = State.STARTING
        self.raw_status = ""
        self.last_error = None  # type: Optional[str]
        self.last_sync_time = None  # type: Optional[float]
        self.start_time = time()
        self.restart_count = 0

        self.num_syncing_gauge = Gauge(
            "dropbox_num_syncing",
            "Number of files currently syncing",
        )

        self.num_downloading_gauge = Gauge(
            "dropbox_num_downloading",
            "Number of files currently downloading",
        )

        self.num_uploading_gauge = Gauge(
            "dropbox_num_uploading",
            "Number of files currently uploading",
        )

        self.status_enum = EnumMetric(
            "dropbox_status",
            "Status reported by Dropbox client",
            states=[state.value for state in State.__members__.values()],
        )

    def start(self) -> None:
        self.status_enum.state(State.STARTING.value)
        self.num_syncing_gauge.set_function(
            partial(self.get_status, Metric.NUM_SYNCING)
        )
        self.num_downloading_gauge.set_function(
            partial(self.get_status, Metric.NUM_DOWNLOADING)
        )
        self.num_uploading_gauge.set_function(
            partial(self.get_status, Metric.NUM_UPLOADING)
        )

        start_http_server(self.prom_port)
        self.logger.info("Started Prometheus server on port %d", self.prom_port)

    def get_status(self, metric: Metric) -> int:
        now = time()
        if now - self.last_query_time > self.min_poll_interval_sec:
            self.last_query_time = now
            dropbox_result = self.dropbox.query_status()
            if dropbox_result:
                self.raw_status = dropbox_result.strip()
                self.parse_output(dropbox_result)
            else:
                self.status_enum.state(State.UNKNOWN.value)
                self.num_syncing = None
                self.num_downloading = None
                self.num_uploading = None

        if metric == Metric.NUM_SYNCING:
            return self.num_syncing or 0
        elif metric == Metric.NUM_DOWNLOADING:
            return self.num_downloading or 0
        elif metric == Metric.NUM_UPLOADING:
            return self.num_uploading or 0
        else:
            raise ValueError(metric)

    def get_json_status(self) -> dict:
        """Build a JSON-serializable status dict for the /status endpoint."""
        # Trigger a refresh if stale
        self.get_status(Metric.NUM_SYNCING)

        # Account info
        account = {}
        info = self.dropbox.query_account_info()
        if info:
            personal = info.get("personal", {})
            account = {
                "email": personal.get("email"),
                "display_name": personal.get("display_name"),
                "linked": True,
            }
        else:
            account = {"linked": False}

        # Excluded folders
        excluded = self.dropbox.query_exclude_list()

        # Version
        version = self.dropbox.query_version()

        # Memory usage from /proc
        memory_mb = None
        try:
            with open("/proc/self/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        memory_mb = int(line.split()[1]) / 1024
                        break
        except:
            pass

        # Uptime
        uptime_seconds = int(time() - self.start_time)

        return {
            "status": self.state.value,
            "raw_status": self.raw_status,
            "sync": {
                "syncing": self.num_syncing or 0,
                "downloading": self.num_downloading or 0,
                "uploading": self.num_uploading or 0,
            },
            "account": account,
            "daemon": {
                "version": version,
                "uptime_seconds": uptime_seconds,
                "memory_mb": round(memory_mb, 1) if memory_mb else None,
                "restart_count": self.restart_count,
            },
            "last_sync": self.last_sync_time,
            "last_error": self.last_error,
            "excluded_folders": excluded or [],
        }

    def parse_output(self, results: str) -> None:
        """
        Observed messages from `dropbox status`

        Up to date
        Syncing...
        Indexing...
        Syncing 176 files • 6 secs
        Downloading 176 files (6 secs)
        Dropbox isn't running!
        Indexing 1 file...
        Can't sync "monitoring.txt" (access denied)
        Syncing "none" • 1 sec
        Downloading 82 files (2,457 KB/sec, 2 secs)
        """
        state = State.UNKNOWN
        num_syncing = None  # type: Optional[int]
        num_downloading = None  # type: Optional[int]
        num_uploading = None  # type: Optional[int]

        for line in results.splitlines():
            try:
                if line.startswith("Up to date"):
                    state = State.UP_TO_DATE
                    num_syncing = 0
                    num_downloading = 0
                    num_uploading = 0
                    self.last_sync_time = time()
                elif line == "Dropbox isn't running!":
                    state = State.NOT_RUNNING
                elif line:
                    # Hack: remove commas; simplifies the regex
                    line = line.replace(',', '')

                    status_match = self.status_matcher.match(line)
                    status_match_with_file = self.status_matcher_with_file.match(line)
                    if status_match:
                        state = State.SYNCING
                        action, num_files_str = status_match.groups()
                        num_files = int(num_files_str)
                        if action == "Syncing":
                            num_syncing = num_files
                        elif action == "Downloading":
                            num_downloading = num_files
                        elif action == "Uploading":
                            num_uploading = num_files
                    elif status_match_with_file:
                        state = State.SYNCING
                        action = status_match_with_file.groups()[0]
                        if action == "Syncing":
                            num_syncing = 1
                        elif action == "Downloading":
                            num_downloading = 1
                        elif action == "Uploading":
                            num_uploading = 1
                    elif line.startswith("Starting"):
                        state = State.STARTING
                    elif line.startswith("Syncing"):
                        state = State.SYNCING
                    elif line.startswith("Indexing"):
                        state = State.INDEXING
                    elif line.startswith("Can't sync"):
                        state = State.SYNC_ERROR
                        self.last_error = line
                    else:
                        self.logger.debug("Ignoring line '%s'", line)
            except:
                self.logger.exception("Failed to parse status line '%s'", line)

        self.state = state
        self.status_enum.state(state.value)
        if state in (State.SYNCING, State.UP_TO_DATE):
            self.num_syncing = num_syncing
            self.num_downloading = num_downloading
            self.num_uploading = num_uploading
        else:
            self.num_syncing = None
            self.num_downloading = None
            self.num_uploading = None


class StatusHandler(BaseHTTPRequestHandler):
    """HTTP handler for the /status JSON endpoint."""

    monitor = None  # type: Optional[DropboxMonitor]

    def do_GET(self):
        if self.path == "/status" or self.path == "/status/":
            data = self.monitor.get_json_status()
            payload = json.dumps(data, indent=2)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.write(payload.encode())
        elif self.path == "/health" or self.path == "/health/":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.write(b'{"ok":true}')
        else:
            self.send_response(404)
            self.end_headers()

    def write(self, data: bytes):
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass

    def log_message(self, format, *args):
        """Suppress default request logging."""
        pass


def start_status_server(monitor: DropboxMonitor, port: int, logger: logging.Logger):
    """Start the JSON status HTTP server in a background thread."""
    StatusHandler.monitor = monitor
    server = HTTPServer(("0.0.0.0", port), StatusHandler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    logger.info("Started status API server on port %d", port)


if __name__ == "__main__":
    parser = ArgumentParser(
        description="Runs monitoring servers for Dropbox status (Prometheus + JSON API)"
    )
    parser.add_argument(
        "-i",
        "--min_poll_interval_sec",
        help="minimum interval for polling Dropbox (in seconds)",
        default=5,
    )
    parser.add_argument("-p", "--port", help="Prometheus port", default=8000)
    parser.add_argument("--status-port", help="JSON status API port", default=8001)
    parser.add_argument("--log_level", default="INFO")
    parser.add_argument("--global_log_level", default="INFO")
    args = parser.parse_args()

    log_level = logging.getLevelName(args.log_level)
    global_log_level = logging.getLevelName(args.global_log_level)
    logging.basicConfig(
        format="[MONITORING %(levelname)s]: %(message)s", level=global_log_level
    )
    logger = logging.getLogger("dropbox_monitor")
    logger.setLevel(log_level)

    dropbox = DropboxInterface(logger)
    monitor = DropboxMonitor(
        dropbox=dropbox,
        min_poll_interval_sec=int(args.min_poll_interval_sec),
        logger=logger,
        prom_port=args.port,
    )
    monitor.start()

    # Start JSON status API
    start_status_server(monitor, int(args.status_port), logger)

    exit_event = Event()
    signal.signal(signal.SIGHUP, lambda _s, _f: exit_event.set())
    signal.signal(signal.SIGINT, lambda _s, _f: exit_event.set())
    signal.signal(signal.SIGTERM, lambda _s, _f: exit_event.set())

    exit_event.wait()
    logger.info("Stopped gracefully")
