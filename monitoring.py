from argparse import ArgumentParser
from enum import Enum
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
import re
import signal
import subprocess
from threading import Event, Lock, Thread
from time import time
from typing import Optional

from prometheus_client import start_http_server, Enum as EnumMetric, Gauge  # type: ignore

# The daemon's executable, as launched by /opt/dropbox/bin/dropboxd
DAEMON_PATH_RE = re.compile(r"^/opt/dropbox/bin/dropbox-lnx[^/]*/dropbox$")
# The CLI itself gives up on the daemon after 5 seconds; this only guards
# against the CLI process hanging
CLI_TIMEOUT_SEC = 15
# The excluded folder list changes rarely; don't ask the daemon on every request
EXCLUDE_LIST_TTL_SEC = 60
NOT_RESPONDING = "Dropbox isn't responding!"
# Written by docker-entrypoint.sh each time it restarts the daemon
RESTART_COUNT_FILE = "/run/dropbox-docker/restart_count"
WEBUI_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "webui")
WEBUI_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
}


def find_daemon_pid(proc_root: str = "/proc") -> Optional[int]:
    """Return the PID of the Dropbox daemon, or None if it isn't running."""
    try:
        entries = os.listdir(proc_root)
    except OSError:
        return None
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            with open(os.path.join(proc_root, entry, "cmdline"), "rb") as f:
                argv0 = f.read().split(b"\0", 1)[0].decode(errors="replace")
        except OSError:
            continue
        if DAEMON_PATH_RE.match(argv0):
            return int(entry)
    return None


def read_rss_bytes(pid: int, proc_root: str = "/proc") -> Optional[int]:
    """Return the resident memory of a process in bytes."""
    try:
        with open(os.path.join(proc_root, str(pid), "status")) as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        # The process exited between finding it and reading its status
        return None
    return None


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
                ["dropbox", "status"], capture_output=True, text=True,
                timeout=CLI_TIMEOUT_SEC,
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
        except Exception:
            self.logger.exception("Failed to invoke Dropbox")
            return None

    def query_account_info(self) -> Optional[dict]:
        """Read account info from Dropbox's info.json."""
        try:
            info_path = "/opt/dropbox/.dropbox/info.json"
            if os.path.exists(info_path):
                with open(info_path) as f:
                    return json.load(f)
        except Exception:
            pass
        return None

    def query_exclude_list(self) -> Optional[list]:
        """Get the list of excluded (selective sync) folders."""
        try:
            result = subprocess.run(
                ["dropbox", "exclude", "list"], capture_output=True, text=True,
                timeout=CLI_TIMEOUT_SEC,
            )
            if result.stdout:
                lines = result.stdout.strip().splitlines()
                # First line is header like "Excluded:"
                return [l.strip() for l in lines[1:] if l.strip()] if len(lines) > 1 else []
        except Exception:
            pass
        return None

    def query_daemon_pid(self) -> Optional[int]:
        return find_daemon_pid()

    def query_daemon_memory_bytes(self) -> Optional[int]:
        pid = find_daemon_pid()
        return read_rss_bytes(pid) if pid else None

    def query_restart_count(self) -> int:
        """How often the entrypoint has restarted the daemon."""
        try:
            with open(RESTART_COUNT_FILE) as f:
                return int(f.read().strip() or 0)
        except (OSError, ValueError):
            return 0

    def query_version(self) -> Optional[str]:
        """Read the daemon version from VERSION file."""
        try:
            version_path = "/opt/dropbox/bin/VERSION"
            if os.path.exists(version_path):
                with open(version_path) as f:
                    return f.read().strip()
        except Exception:
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
        # Serializes refreshes: the status server handles requests in threads
        self.refresh_lock = Lock()
        self.excluded = None  # type: Optional[list]
        self.excluded_time = 0.0
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

        self.daemon_up_gauge = Gauge(
            "dropbox_daemon_up",
            "Whether the Dropbox daemon process is running (1) or not (0)",
        )

        self.daemon_memory_gauge = Gauge(
            "dropbox_daemon_memory_bytes",
            "Resident memory of the Dropbox daemon",
        )

        self.daemon_restarts_gauge = Gauge(
            "dropbox_daemon_restarts",
            "Times the container has restarted the Dropbox daemon",
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
        self.daemon_up_gauge.set_function(lambda: 1 if self.is_healthy() else 0)
        self.daemon_memory_gauge.set_function(
            lambda: self.dropbox.query_daemon_memory_bytes() or 0
        )
        self.daemon_restarts_gauge.set_function(self.dropbox.query_restart_count)

        start_http_server(self.prom_port)
        self.logger.info("Started Prometheus server on port %d", self.prom_port)

    def get_status(self, metric: Metric) -> int:
        with self.refresh_lock:
            now = time()
            if now - self.last_query_time > self.min_poll_interval_sec:
                self.last_query_time = now
                dropbox_result = self.dropbox.query_status()
                if dropbox_result and dropbox_result.strip() == NOT_RESPONDING:
                    # Busy daemon (e.g. indexing): keep the last known state
                    # instead of flapping between it and "unknown"
                    pass
                elif dropbox_result:
                    self.raw_status = dropbox_result.strip()
                    self.parse_output(dropbox_result)
                else:
                    self.state = State.UNKNOWN
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

    def get_excluded_folders(self) -> Optional[list]:
        with self.refresh_lock:
            if self.excluded is None or time() - self.excluded_time > EXCLUDE_LIST_TTL_SEC:
                excluded = self.dropbox.query_exclude_list()
                if excluded is not None:
                    self.excluded = excluded
                    self.excluded_time = time()
            return self.excluded

    def is_healthy(self) -> bool:
        """Healthy while the daemon process is running."""
        return self.dropbox.query_daemon_pid() is not None

    def get_json_status(self) -> dict:
        """Build a JSON-serializable status dict for the /status endpoint."""
        # Trigger a refresh if stale
        self.get_status(Metric.NUM_SYNCING)

        # Account info (redacted for privacy — no PII in API responses)
        account = {}
        info = self.dropbox.query_account_info()
        if info:
            account = {"linked": True}
        else:
            account = {"linked": False}

        # Excluded folders
        excluded = self.get_excluded_folders()

        # Version
        version = self.dropbox.query_version()

        # Memory usage of the daemon (not of this monitoring process)
        memory_bytes = self.dropbox.query_daemon_memory_bytes()
        memory_mb = memory_bytes / (1024 * 1024) if memory_bytes else None
        self.restart_count = self.dropbox.query_restart_count()

        # Uptime
        uptime_seconds = int(time() - self.start_time)

        return {
            "healthy": self.is_healthy(),
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
            "image": {
                "version": os.environ.get("IMAGE_VERSION") or None,
                "revision": os.environ.get("IMAGE_REVISION") or None,
            },
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
            except Exception:
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
    """HTTP handler for the status page and the /status and /health APIs."""

    monitor = None  # type: Optional[DropboxMonitor]
    webui_dir = WEBUI_DIR
    # Drop clients that open a connection and never finish their request
    timeout = 10

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/status", "/status/"):
            self.send_json(200, self.monitor.get_json_status())
        elif path in ("/health", "/health/"):
            healthy = self.monitor.is_healthy()
            # "ok" is kept for clients of versions before 1.3.0
            self.send_json(200 if healthy else 503, {"healthy": healthy, "ok": healthy})
        elif path in WEBUI_FILES:
            self.send_static(*WEBUI_FILES[path])
        else:
            self.send_body(404, "text/plain; charset=utf-8", b"Not found\n")

    def send_json(self, code: int, data: dict) -> None:
        payload = json.dumps(data, indent=2).encode()
        self.send_body(code, "application/json", payload)

    def send_static(self, name: str, content_type: str) -> None:
        try:
            with open(os.path.join(self.webui_dir, name), "rb") as f:
                body = f.read()
        except OSError:
            self.send_body(404, "text/plain; charset=utf-8", b"Not found\n")
            return
        self.send_body(200, content_type, body)

    def send_body(self, code: int, content_type: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; script-src 'self'; style-src 'self'; "
            "connect-src 'self'; img-src 'self'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.write(body)

    def write(self, data: bytes):
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass

    def log_message(self, format, *args):
        """Suppress default request logging."""
        pass


def make_status_server(monitor: DropboxMonitor, port: int, host: str = "0.0.0.0") -> ThreadingHTTPServer:
    """Create the status page and JSON API server; each request gets a thread."""
    StatusHandler.monitor = monitor
    server = ThreadingHTTPServer((host, port), StatusHandler)
    server.daemon_threads = True
    return server


def start_status_server(monitor: DropboxMonitor, port: int, logger: logging.Logger):
    """Start the status page and JSON API server in a background thread."""
    server = make_status_server(monitor, port)
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
        type=int,
        default=5,
    )
    parser.add_argument("-p", "--port", help="Prometheus port", type=int, default=8000)
    parser.add_argument("--status-port", help="Status page and JSON API port", type=int, default=8001)
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
        min_poll_interval_sec=args.min_poll_interval_sec,
        logger=logger,
        prom_port=args.port,
    )
    monitor.start()

    # Start JSON status API
    start_status_server(monitor, args.status_port, logger)

    exit_event = Event()
    signal.signal(signal.SIGHUP, lambda _s, _f: exit_event.set())
    signal.signal(signal.SIGINT, lambda _s, _f: exit_event.set())
    signal.signal(signal.SIGTERM, lambda _s, _f: exit_event.set())

    exit_event.wait()
    logger.info("Stopped gracefully")
