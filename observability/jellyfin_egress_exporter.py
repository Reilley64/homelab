from __future__ import annotations

import ipaddress
import json
import threading
from collections import defaultdict
from dataclasses import dataclass

PUBLIC_ROUTER = "jellyfin@docker"


def normalize_address(value: str) -> str | None:
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


class MappingCache:
    def __init__(self, ttl_seconds: float):
        self.ttl_seconds = ttl_seconds
        self._entries: dict[str, tuple[str, float, str]] = {}
        self._lock = threading.Lock()

    def observe_sessions(self, sessions: list[dict], now: float) -> None:
        with self._lock:
            for session in sessions:
                if not session.get("NowPlayingItem"):
                    continue
                username = session.get("UserName")
                client_ip = normalize_address(session.get("RemoteEndPoint", ""))
                if isinstance(username, str) and username and client_ip:
                    session_id = str(session.get("Id", ""))
                    self._entries[client_ip] = (username, now, session_id)

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
