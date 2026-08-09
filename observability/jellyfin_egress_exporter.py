from __future__ import annotations

import ipaddress
import json
import os
import sys
import threading
import time
from collections import defaultdict
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib import request

PUBLIC_ROUTER = "jellyfin@docker"


def normalize_address(value: str) -> str | None:
    if not isinstance(value, str):
        return None
    candidate = value.strip()
    if not candidate:
        return None
    if candidate.startswith("["):
        close = candidate.find("]")
        if close == -1:
            return None
        candidate = candidate[1:close]
    else:
        try:
            return _canonical_ip(candidate)
        except ValueError:
            host, separator, port = candidate.rpartition(":")
            if not separator or not port.isdigit():
                return None
            candidate = host
    try:
        return _canonical_ip(candidate)
    except ValueError:
        return None


def _canonical_ip(value: str) -> str:
    address = ipaddress.ip_address(value)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        return str(address.ipv4_mapped)
    return address.compressed


@dataclass(frozen=True)
class AccessEvent:
    client_ip: str
    byte_count: int


@dataclass(frozen=True)
class Checkpoint:
    inode: int
    offset: int


def parse_access_line(line: str) -> AccessEvent | None:
    entry = json.loads(line)
    if not isinstance(entry, dict):
        raise ValueError("access log entry must be a JSON object")
    if entry.get("RouterName") != PUBLIC_ROUTER:
        return None
    byte_count = entry.get("DownstreamContentSize")
    if type(byte_count) is not int or byte_count < 0:
        raise ValueError("DownstreamContentSize must be a non-negative integer")
    client_ip = normalize_address(entry.get("ClientHost", ""))
    if client_ip is None:
        raise ValueError("ClientHost must be an IP address")
    return AccessEvent(client_ip=client_ip, byte_count=byte_count)


def load_checkpoint(path: str) -> Checkpoint | None:
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
        return Checkpoint(inode=int(value["inode"]), offset=int(value["offset"]))
    except (FileNotFoundError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None


def save_checkpoint(path: str, checkpoint: Checkpoint) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(
        json.dumps({"inode": checkpoint.inode, "offset": checkpoint.offset}),
        encoding="utf-8",
    )
    os.replace(temporary, destination)


def fetch_sessions(base_url: str, api_key: str, timeout: float = 10) -> list[dict]:
    api_request = request.Request(
        base_url.rstrip("/") + "/Sessions",
        headers={"X-Emby-Token": api_key, "Accept": "application/json"},
    )
    with request.urlopen(api_request, timeout=timeout) as response:
        sessions = json.loads(response.read())
    if not isinstance(sessions, list):
        raise ValueError("Jellyfin /Sessions did not return a list")
    return sessions


class MappingCache:
    def __init__(self, ttl_seconds: float):
        self.ttl_seconds = ttl_seconds
        self._entries: dict[str, tuple[str, float, str]] = {}
        self._lock = threading.Lock()

    def observe_sessions(self, sessions: list[dict], now: float) -> None:
        updates: dict[str, tuple[str, float, str]] = {}
        for session in sessions:
            if not isinstance(session, dict):
                raise ValueError("Jellyfin session must be an object")
            if not session.get("NowPlayingItem"):
                continue
            username = session.get("UserName")
            remote_endpoint = session.get("RemoteEndPoint", "")
            if not isinstance(remote_endpoint, str):
                raise ValueError("Jellyfin RemoteEndPoint must be a string")
            client_ip = normalize_address(remote_endpoint)
            if isinstance(username, str) and username and client_ip:
                session_id = str(session.get("Id", ""))
                updates[client_ip] = (username, now, session_id)
        with self._lock:
            self._entries.update(updates)

    def lookup(self, client_ip: str, now: float) -> str:
        with self._lock:
            entry = self._entries.get(client_ip)
            if entry is None:
                return "unknown"
            username, observed_at, _session_id = entry
            if now - observed_at > self.ttl_seconds:
                del self._entries[client_ip]
                return "unknown"
            return username

    def active_count(self, now: float) -> int:
        with self._lock:
            expired = [ip for ip, (_, seen, _) in self._entries.items() if now - seen > self.ttl_seconds]
            for ip in expired:
                del self._entries[ip]
            return len(self._entries)


def _escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


class MetricState:
    def __init__(self):
        self._egress: dict[tuple[str, str], int] = defaultdict(int)
        self.access_log_errors = 0
        self.api_failures = 0
        self.unattributed_bytes = 0
        self.checkpoint_discontinuities = 0
        self._lock = threading.Lock()

    def apply(self, event: AccessEvent, username: str) -> None:
        with self._lock:
            self._egress[(username, event.client_ip)] += event.byte_count
            if username == "unknown":
                self.unattributed_bytes += event.byte_count

    def render(self, active_mappings: int) -> str:
        with self._lock:
            lines = [
                "# TYPE jellyfin_user_egress_bytes_total counter",
            ]
            for (username, client_ip), value in sorted(self._egress.items()):
                lines.append(
                    'jellyfin_user_egress_bytes_total{user="%s",client_ip="%s"} %d'
                    % (_escape_label(username), _escape_label(client_ip), value)
                )
            lines.extend([
                "# TYPE jellyfin_egress_access_log_errors_total counter",
                f"jellyfin_egress_access_log_errors_total {self.access_log_errors}",
                "# TYPE jellyfin_egress_jellyfin_api_failures_total counter",
                f"jellyfin_egress_jellyfin_api_failures_total {self.api_failures}",
                "# TYPE jellyfin_egress_unattributed_bytes_total counter",
                f"jellyfin_egress_unattributed_bytes_total {self.unattributed_bytes}",
                "# TYPE jellyfin_egress_checkpoint_discontinuities_total counter",
                f"jellyfin_egress_checkpoint_discontinuities_total {self.checkpoint_discontinuities}",
                "# TYPE jellyfin_egress_active_ip_mappings gauge",
                f"jellyfin_egress_active_ip_mappings {active_mappings}",
            ])
            return "\n".join(lines) + "\n"


def process_available(
    log_path: str,
    checkpoint_path: str,
    cache: MappingCache,
    state: MetricState,
    now: float,
) -> int:
    try:
        stat = os.stat(log_path)
    except FileNotFoundError:
        return 0
    checkpoint = load_checkpoint(checkpoint_path)
    if checkpoint is None:
        start_offset = stat.st_size
        save_checkpoint(checkpoint_path, Checkpoint(stat.st_ino, start_offset))
    elif checkpoint.inode != stat.st_ino or checkpoint.offset > stat.st_size:
        start_offset = 0
        state.checkpoint_discontinuities += 1
    else:
        start_offset = checkpoint.offset
    processed = 0
    with open(log_path, encoding="utf-8") as handle:
        handle.seek(start_offset)
        while True:
            line = handle.readline()
            if not line:
                break
            if not line.endswith("\n"):
                break
            try:
                event = parse_access_line(line)
                if event is not None:
                    state.apply(event, cache.lookup(event.client_ip, now))
                    processed += 1
            except (json.JSONDecodeError, TypeError, ValueError):
                state.access_log_errors += 1
            save_checkpoint(checkpoint_path, Checkpoint(stat.st_ino, handle.tell()))
    return processed


@dataclass(frozen=True)
class Settings:
    jellyfin_url: str
    api_key: str
    access_log_path: str
    checkpoint_path: str
    mapping_ttl_seconds: float
    session_poll_seconds: float
    metrics_port: int


@dataclass
class Runtime:
    settings: Settings
    cache: MappingCache
    state: MetricState


def read_settings() -> Settings:
    api_key = os.environ.get("JELLYFIN_API_KEY", "")
    if not api_key:
        raise SystemExit("JELLYFIN_API_KEY is required")
    return Settings(
        jellyfin_url=os.environ.get("JELLYFIN_URL", "http://jellyfin:8096"),
        api_key=api_key,
        access_log_path=os.environ.get("ACCESS_LOG_PATH", "/logs/access.json"),
        checkpoint_path=os.environ.get("CHECKPOINT_PATH", "/state/checkpoint.json"),
        mapping_ttl_seconds=float(os.environ.get("MAPPING_TTL_SECONDS", "600")),
        session_poll_seconds=float(os.environ.get("SESSION_POLL_SECONDS", "15")),
        metrics_port=int(os.environ.get("METRICS_PORT", "9101")),
    )


def poll_sessions_forever(runtime: Runtime) -> None:
    while True:
        try:
            sessions = fetch_sessions(runtime.settings.jellyfin_url, runtime.settings.api_key)
            runtime.cache.observe_sessions(sessions, time.time())
        except Exception as error:
            with runtime.state._lock:
                runtime.state.api_failures += 1
            print(f"Jellyfin session poll failed: {error}", file=sys.stderr, flush=True)
        time.sleep(runtime.settings.session_poll_seconds)


def tail_access_log_forever(runtime: Runtime) -> None:
    while True:
        try:
            process_available(
                runtime.settings.access_log_path,
                runtime.settings.checkpoint_path,
                runtime.cache,
                runtime.state,
                time.time(),
            )
        except Exception as error:
            with runtime.state._lock:
                runtime.state.access_log_errors += 1
            print(f"access-log tail failed: {error}", file=sys.stderr, flush=True)
        time.sleep(1)


class MetricsHandler(BaseHTTPRequestHandler):
    runtime: Runtime

    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = self.runtime.state.render(
            active_mappings=self.runtime.cache.active_count(time.time())
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


def main() -> None:
    settings = read_settings()
    runtime = Runtime(
        settings=settings,
        cache=MappingCache(settings.mapping_ttl_seconds),
        state=MetricState(),
    )
    MetricsHandler.runtime = runtime
    threading.Thread(target=poll_sessions_forever, args=(runtime,), daemon=True).start()
    threading.Thread(target=tail_access_log_forever, args=(runtime,), daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", settings.metrics_port), MetricsHandler).serve_forever()


if __name__ == "__main__":
    main()
