# Jellyfin User Egress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add exact public Jellyfin response-body egress totals grouped by the most recently observed Jellyfin username for each client IP.

**Architecture:** Traefik writes a minimal JSON access log containing router, client address, and response bytes. A stdlib-only Python exporter polls Jellyfin sessions for the latest IP-to-username mapping, tails that log, and exposes labelled Prometheus counters; a separate small Python service bounds log retention. Grafana adds per-user totals, rates, and IP attribution while retaining Traefik's aggregate panels for reconciliation.

**Tech Stack:** Terraform, Docker, Traefik v3, Python 3.13 standard library, Prometheus, Grafana.

**Spec:** `docs/superpowers/specs/2026-08-09-jellyfin-user-egress-design.md`

## Global Constraints

- All containers use `modules/service`; do not add raw `docker_container` resources.
- Persistent host paths remain under `/home/${var.username}/appdata/<service>/`.
- Count only access-log entries whose `RouterName` is exactly `jellyfin@docker`; exclude `jellyfinlocal@docker`.
- Egress is Traefik `DownstreamContentSize`: HTTP response-body bytes, excluding request bytes and network/TLS overhead.
- A shared IP belongs to the most recently observed active Jellyfin username. Wrong-user assignment is accepted; do not add a `shared` state.
- IP mappings expire 600 seconds after their last observation; expired or absent mappings use username `unknown`.
- Never log authorization headers, cookies, query parameters, or Jellyfin API tokens.
- The Jellyfin API key is sensitive, belongs only in `.auto.tfvars`, and must not be committed.
- Use only the Python 3.13 standard library; do not add a package manager or dependency file.
- Exporter unit tests use `python3 -m unittest`; infrastructure checks use `terraform fmt -check` and `terraform validate` before any plan or apply.
- Review every Terraform plan before applying. An unexpected replacement or unrelated resource change is a stop condition.
- Live verification must prove Jellyfin `RemoteEndPoint` and Traefik `ClientHost` normalize to the same address before username attribution is accepted.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `observability/jellyfin_egress_exporter.py` | Create | Address normalization, mapping cache, access-log parsing, checkpointed tailing, Jellyfin polling, Prometheus rendering, HTTP endpoint |
| `observability/test_jellyfin_egress_exporter.py` | Create | Unit tests for all exporter behaviour |
| `observability/traefik_access_log_rotator.py` | Create | Size-based gzip rotation with bounded retention and copy-truncate semantics |
| `observability/test_traefik_access_log_rotator.py` | Create | Unit tests for rotation threshold, retention, and file continuity |
| `variables.tf` | Modify | Declare sensitive `jellyfin_api_key` |
| `traefik.tf` | Modify | Enable safe JSON access logging and mount the shared log directory |
| `observability.tf` | Modify | Run the exporter and rotator through `modules/service` |
| `observability/prometheus.yml` | Modify | Scrape the exporter on port 9101 |
| `observability/jellyfin-dashboard.json.tftpl` | Modify | Add per-user total, rate, and user/IP panels |

The exporter file remains one deployable module, but its units have explicit interfaces and are tested separately. The rotator is a separate file and service because it owns write access to log retention, while the exporter receives the log mount read-only.

---

### Task 1: Implement deterministic attribution primitives

**Files:**
- Create: `observability/jellyfin_egress_exporter.py`
- Create: `observability/test_jellyfin_egress_exporter.py`

**Interfaces:**
- Consumes: Traefik JSON fields `RouterName`, `ClientHost`, and `DownstreamContentSize`; Jellyfin session fields `UserName`, `RemoteEndPoint`, and `NowPlayingItem`.
- Produces:
  - `normalize_address(value: str) -> str | None`
  - `AccessEvent(client_ip: str, byte_count: int)`
  - `parse_access_line(line: str) -> AccessEvent | None`
  - `MappingCache(ttl_seconds: float)` with `observe_sessions(sessions: list[dict], now: float)` and `lookup(client_ip: str, now: float) -> str`
  - `MetricState.apply(event: AccessEvent, username: str)` and `MetricState.render() -> str`

- [ ] **Step 1: Write failing tests for address normalization and router filtering**

Create `observability/test_jellyfin_egress_exporter.py` with:

```python
import json
import unittest

from jellyfin_egress_exporter import normalize_address, parse_access_line


class NormalizeAddressTests(unittest.TestCase):
    def test_normalizes_ipv4_ports_and_mapped_ipv6(self):
        self.assertEqual(normalize_address("203.0.113.8:44321"), "203.0.113.8")
        self.assertEqual(normalize_address("::ffff:203.0.113.8"), "203.0.113.8")

    def test_normalizes_bracketed_ipv6(self):
        self.assertEqual(normalize_address("[2001:db8::8]:44321"), "2001:db8::8")

    def test_rejects_empty_or_invalid_addresses(self):
        self.assertIsNone(normalize_address(""))
        self.assertIsNone(normalize_address("not-an-address"))


class ParseAccessLineTests(unittest.TestCase):
    def make_line(self, **overrides):
        entry = {
            "RouterName": "jellyfin@docker",
            "ClientHost": "203.0.113.8",
            "DownstreamContentSize": 4096,
        }
        entry.update(overrides)
        return json.dumps(entry)

    def test_returns_public_jellyfin_event(self):
        event = parse_access_line(self.make_line())
        self.assertEqual(event.client_ip, "203.0.113.8")
        self.assertEqual(event.byte_count, 4096)

    def test_ignores_lan_and_other_routers(self):
        self.assertIsNone(parse_access_line(self.make_line(RouterName="jellyfinlocal@docker")))
        self.assertIsNone(parse_access_line(self.make_line(RouterName="grafana@docker")))

    def test_rejects_negative_or_non_integer_bytes(self):
        with self.assertRaises(ValueError):
            parse_access_line(self.make_line(DownstreamContentSize=-1))
        with self.assertRaises(ValueError):
            parse_access_line(self.make_line(DownstreamContentSize="4096"))
```

- [ ] **Step 2: Run the focused tests and confirm the import fails**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter.NormalizeAddressTests \
  observability.test_jellyfin_egress_exporter.ParseAccessLineTests
```

Expected: `ModuleNotFoundError: No module named 'jellyfin_egress_exporter'`.

- [ ] **Step 3: Implement address normalization and access-log parsing**

Create `observability/jellyfin_egress_exporter.py` beginning with:

```python
from __future__ import annotations

import ipaddress
import json
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
```

- [ ] **Step 4: Run the focused tests and confirm they pass**

Run the command from Step 2.

Expected: 6 tests pass with `OK`.

- [ ] **Step 5: Write failing tests for latest-user-wins mapping and TTL**

Append to the test file:

```python
from jellyfin_egress_exporter import MappingCache


class MappingCacheTests(unittest.TestCase):
    def test_observes_only_active_playback_sessions(self):
        cache = MappingCache(ttl_seconds=600)
        cache.observe_sessions([
            {"UserName": "alice", "RemoteEndPoint": "203.0.113.8:5000", "NowPlayingItem": {"Id": "1"}},
            {"UserName": "idle", "RemoteEndPoint": "203.0.113.9:5000", "NowPlayingItem": None},
        ], now=1000)
        self.assertEqual(cache.lookup("203.0.113.8", now=1001), "alice")
        self.assertEqual(cache.lookup("203.0.113.9", now=1001), "unknown")

    def test_latest_observation_for_shared_ip_wins(self):
        cache = MappingCache(ttl_seconds=600)
        cache.observe_sessions([
            {"UserName": "alice", "RemoteEndPoint": "203.0.113.8", "NowPlayingItem": {"Id": "1"}},
            {"UserName": "bob", "RemoteEndPoint": "203.0.113.8", "NowPlayingItem": {"Id": "2"}},
        ], now=1000)
        self.assertEqual(cache.lookup("203.0.113.8", now=1001), "bob")

    def test_mapping_expires_after_ttl(self):
        cache = MappingCache(ttl_seconds=600)
        cache.observe_sessions([
            {"UserName": "alice", "RemoteEndPoint": "203.0.113.8", "NowPlayingItem": {"Id": "1"}},
        ], now=1000)
        self.assertEqual(cache.lookup("203.0.113.8", now=1600), "alice")
        self.assertEqual(cache.lookup("203.0.113.8", now=1600.001), "unknown")
```

- [ ] **Step 6: Run the mapping tests and confirm `MappingCache` is missing**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter.MappingCacheTests
```

Expected: import failure for `MappingCache`.

- [ ] **Step 7: Implement the mapping cache**

Add these imports and class to the exporter:

```python
import threading


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
```

- [ ] **Step 8: Run all current exporter tests**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_jellyfin_egress_exporter
```

Expected: 9 tests pass with `OK`.

- [ ] **Step 9: Write failing tests for counters and Prometheus escaping**

Append:

```python
from jellyfin_egress_exporter import AccessEvent, MetricState


class MetricStateTests(unittest.TestCase):
    def test_accumulates_by_user_and_ip(self):
        state = MetricState()
        event = AccessEvent("203.0.113.8", 4096)
        state.apply(event, "alice")
        state.apply(event, "alice")
        rendered = state.render(active_mappings=1)
        self.assertIn('jellyfin_user_egress_bytes_total{user="alice",client_ip="203.0.113.8"} 8192', rendered)
        self.assertIn("jellyfin_egress_active_ip_mappings 1", rendered)

    def test_unknown_bytes_have_a_diagnostic_counter(self):
        state = MetricState()
        state.apply(AccessEvent("203.0.113.9", 512), "unknown")
        self.assertIn("jellyfin_egress_unattributed_bytes_total 512", state.render(active_mappings=0))

    def test_escapes_prometheus_label_values(self):
        state = MetricState()
        state.apply(AccessEvent("203.0.113.8", 1), 'a"b\\c')
        self.assertIn('user="a\\"b\\\\c"', state.render(active_mappings=1))
```

- [ ] **Step 10: Run the metric tests and confirm `MetricState` is missing**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter.MetricStateTests
```

Expected: import failure for `MetricState`.

- [ ] **Step 11: Implement the metric state**

Add:

```python
from collections import defaultdict


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
```

- [ ] **Step 12: Run all exporter tests and commit the attribution core**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_jellyfin_egress_exporter
git add observability/jellyfin_egress_exporter.py observability/test_jellyfin_egress_exporter.py
git commit -m "Add Jellyfin egress attribution core"
```

Expected: 12 tests pass before the commit.

---

### Task 2: Add checkpointed tailing, Jellyfin polling, and metrics serving

**Files:**
- Modify: `observability/jellyfin_egress_exporter.py`
- Modify: `observability/test_jellyfin_egress_exporter.py`

**Interfaces:**
- Consumes: Task 1's `parse_access_line`, `MappingCache`, and `MetricState`.
- Produces:
  - `Checkpoint(inode: int, offset: int)`
  - `load_checkpoint(path: str) -> Checkpoint | None`
  - `save_checkpoint(path: str, checkpoint: Checkpoint) -> None`
  - `process_available(log_path, checkpoint_path, cache, state, now) -> int`
  - `fetch_sessions(base_url: str, api_key: str, timeout: float = 10) -> list[dict]`
  - HTTP `GET /metrics` on `METRICS_PORT`, default 9101.

- [ ] **Step 1: Write failing checkpoint and tail tests**

Append imports and tests:

```python
import os
import tempfile

from jellyfin_egress_exporter import (
    Checkpoint,
    MappingCache,
    MetricState,
    process_available,
    save_checkpoint,
)


class TailerTests(unittest.TestCase):
    def test_processes_new_lines_once_and_resumes_from_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            log_path = os.path.join(directory, "access.json")
            checkpoint_path = os.path.join(directory, "checkpoint.json")
            line = json.dumps({
                "RouterName": "jellyfin@docker",
                "ClientHost": "203.0.113.8",
                "DownstreamContentSize": 100,
            })
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write(line + "\n")
            save_checkpoint(
                checkpoint_path,
                Checkpoint(os.stat(log_path).st_ino, 0),
            )
            cache = MappingCache(600)
            cache.observe_sessions([
                {"UserName": "alice", "RemoteEndPoint": "203.0.113.8", "NowPlayingItem": {"Id": "1"}},
            ], now=1000)
            state = MetricState()
            self.assertEqual(process_available(log_path, checkpoint_path, cache, state, now=1001), 1)
            self.assertEqual(process_available(log_path, checkpoint_path, cache, state, now=1002), 0)
            self.assertIn('} 100', state.render(active_mappings=1))

    def test_counts_malformed_line_and_continues(self):
        with tempfile.TemporaryDirectory() as directory:
            log_path = os.path.join(directory, "access.json")
            checkpoint_path = os.path.join(directory, "checkpoint.json")
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write("not-json\n")
                handle.write(json.dumps({
                    "RouterName": "jellyfin@docker",
                    "ClientHost": "203.0.113.8",
                    "DownstreamContentSize": 10,
                }) + "\n")
            save_checkpoint(
                checkpoint_path,
                Checkpoint(os.stat(log_path).st_ino, 0),
            )
            state = MetricState()
            processed = process_available(log_path, checkpoint_path, MappingCache(600), state, now=1000)
            self.assertEqual(processed, 1)
            self.assertEqual(state.access_log_errors, 1)

    def test_detects_copy_truncate_and_restarts_at_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            log_path = os.path.join(directory, "access.json")
            checkpoint_path = os.path.join(directory, "checkpoint.json")
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write(" " * 500 + "\n")
            process_available(log_path, checkpoint_path, MappingCache(600), MetricState(), now=1000)
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({
                    "RouterName": "jellyfin@docker",
                    "ClientHost": "203.0.113.8",
                    "DownstreamContentSize": 25,
                }) + "\n")
            state = MetricState()
            self.assertEqual(process_available(log_path, checkpoint_path, MappingCache(600), state, now=1001), 1)
            self.assertEqual(state.checkpoint_discontinuities, 1)

    def test_first_start_begins_at_end_of_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            log_path = os.path.join(directory, "access.json")
            checkpoint_path = os.path.join(directory, "checkpoint.json")
            existing = json.dumps({
                "RouterName": "jellyfin@docker",
                "ClientHost": "203.0.113.8",
                "DownstreamContentSize": 100,
            })
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write(existing + "\n")
            state = MetricState()
            cache = MappingCache(600)
            self.assertEqual(process_available(log_path, checkpoint_path, cache, state, now=1000), 0)
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write(existing.replace("100", "25") + "\n")
            self.assertEqual(process_available(log_path, checkpoint_path, cache, state, now=1001), 1)
            self.assertIn('} 25', state.render(active_mappings=0))
```

- [ ] **Step 2: Run the tail tests and confirm `process_available` is missing**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter.TailerTests
```

Expected: import failure for `process_available`.

- [ ] **Step 3: Implement atomic checkpoints and available-line processing**

Add imports and implementation:

```python
import os
from pathlib import Path


@dataclass(frozen=True)
class Checkpoint:
    inode: int
    offset: int


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
    temporary.write_text(json.dumps({"inode": checkpoint.inode, "offset": checkpoint.offset}), encoding="utf-8")
    os.replace(temporary, destination)


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
            try:
                event = parse_access_line(line)
                if event is not None:
                    state.apply(event, cache.lookup(event.client_ip, now))
                    processed += 1
            except (json.JSONDecodeError, TypeError, ValueError):
                state.access_log_errors += 1
            save_checkpoint(checkpoint_path, Checkpoint(stat.st_ino, handle.tell()))
    return processed
```

- [ ] **Step 4: Run the tail tests and confirm they pass**

Run the command from Step 2.

Expected: 4 tailer tests pass, including the first-start-at-EOF test.

- [ ] **Step 5: Write failing tests for the Jellyfin API request**

Use `unittest.mock.patch` to assert that `fetch_sessions` sends `X-Emby-Token`, parses a
JSON list, rejects a non-list response, and uses the supplied timeout:

```python
from unittest.mock import MagicMock, patch

from jellyfin_egress_exporter import fetch_sessions


class FetchSessionsTests(unittest.TestCase):
    @patch("jellyfin_egress_exporter.request.urlopen")
    def test_fetches_sessions_with_token(self, urlopen):
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b'[{"UserName":"alice"}]'
        urlopen.return_value = response
        sessions = fetch_sessions("http://jellyfin:8096", "secret", timeout=4)
        self.assertEqual(sessions, [{"UserName": "alice"}])
        sent_request = urlopen.call_args.args[0]
        self.assertEqual(sent_request.get_header("X-emby-token"), "secret")
        self.assertEqual(urlopen.call_args.kwargs["timeout"], 4)

    @patch("jellyfin_egress_exporter.request.urlopen")
    def test_rejects_non_list_response(self, urlopen):
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b'{}'
        urlopen.return_value = response
        with self.assertRaises(ValueError):
            fetch_sessions("http://jellyfin:8096", "secret")
```

- [ ] **Step 6: Run the API tests and confirm `fetch_sessions` is missing**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter.FetchSessionsTests
```

Expected: import failure for `fetch_sessions`.

- [ ] **Step 7: Implement the Jellyfin API request**

Add:

```python
from urllib import request


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
```

- [ ] **Step 8: Run all exporter tests**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_jellyfin_egress_exporter
```

Expected: all tests pass.

- [ ] **Step 9: Add the runtime loops and metrics HTTP handler**

Add a `Runtime` object holding the cache and metrics state, a polling thread that calls
`fetch_sessions` every 15 seconds, a tailing thread that calls `process_available` every
second, and a `ThreadingHTTPServer` handler. Read these exact environment variables:

```text
JELLYFIN_URL=http://jellyfin:8096
JELLYFIN_API_KEY=<sensitive value>
ACCESS_LOG_PATH=/logs/access.json
CHECKPOINT_PATH=/state/checkpoint.json
MAPPING_TTL_SECONDS=600
SESSION_POLL_SECONDS=15
METRICS_PORT=9101
```

Add the following runtime types and functions. Extend the exporter imports with:

```python
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
```

Then add:

```python
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
```

API/network/JSON failures increment `state.api_failures` and leave existing mappings
untouched. Unexpected tail-loop exceptions increment `state.access_log_errors` and the
loop continues after one second.

- [ ] **Step 10: Add handler and configuration tests**

Append these imports and tests. They deliberately avoid thread timing assertions:

```python
import threading
from urllib import error as urlerror
from urllib import request as urlrequest

from jellyfin_egress_exporter import (
    MetricsHandler,
    Runtime,
    Settings,
    read_settings,
)


class RuntimeTests(unittest.TestCase):
    def make_runtime(self):
        settings = Settings(
            jellyfin_url="http://jellyfin:8096",
            api_key="secret",
            access_log_path="/tmp/access.json",
            checkpoint_path="/tmp/checkpoint.json",
            mapping_ttl_seconds=600,
            session_poll_seconds=15,
            metrics_port=0,
        )
        return Runtime(settings, MappingCache(600), MetricState())

    def test_metrics_handler_serves_prometheus_text(self):
        MetricsHandler.runtime = self.make_runtime()
        server = ThreadingHTTPServer(("127.0.0.1", 0), MetricsHandler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            with urlrequest.urlopen(
                f"http://127.0.0.1:{server.server_port}/metrics"
            ) as response:
                body = response.read().decode()
            self.assertIn("jellyfin_egress_active_ip_mappings 0", body)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_metrics_handler_returns_404_for_other_paths(self):
        MetricsHandler.runtime = self.make_runtime()
        server = ThreadingHTTPServer(("127.0.0.1", 0), MetricsHandler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            with self.assertRaises(urlerror.HTTPError) as raised:
                urlrequest.urlopen(f"http://127.0.0.1:{server.server_port}/health")
            self.assertEqual(raised.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    @patch.dict(os.environ, {}, clear=True)
    def test_api_key_is_required(self):
        with self.assertRaisesRegex(SystemExit, "JELLYFIN_API_KEY is required"):
            read_settings()
```

- [ ] **Step 11: Run the full exporter suite and syntax check**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_jellyfin_egress_exporter
python3 -m py_compile observability/jellyfin_egress_exporter.py
```

Expected: all tests pass and `py_compile` exits 0.

- [ ] **Step 12: Commit the deployable exporter**

```bash
git add observability/jellyfin_egress_exporter.py observability/test_jellyfin_egress_exporter.py
git commit -m "Add checkpointed Jellyfin egress exporter"
```

---

### Task 3: Implement bounded Traefik access-log rotation

**Files:**
- Create: `observability/traefik_access_log_rotator.py`
- Create: `observability/test_traefik_access_log_rotator.py`

**Interfaces:**
- Consumes: `/logs/access.json` written by Traefik.
- Produces: `/logs/access.json.1.gz` through `/logs/access.json.7.gz`; preserves the active file inode using copy-truncate.
- Public function: `rotate_if_needed(path: str, max_bytes: int, copies: int) -> bool`.

- [ ] **Step 1: Write failing rotation tests**

Create `observability/test_traefik_access_log_rotator.py`:

```python
import gzip
import os
import tempfile
import unittest

from traefik_access_log_rotator import rotate_if_needed


class RotationTests(unittest.TestCase):
    def test_does_not_rotate_below_threshold(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "access.json")
            open(path, "wb").write(b"small")
            self.assertFalse(rotate_if_needed(path, max_bytes=10, copies=2))
            self.assertFalse(os.path.exists(path + ".1.gz"))

    def test_compresses_and_truncates_without_changing_inode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "access.json")
            open(path, "wb").write(b"0123456789")
            inode = os.stat(path).st_ino
            self.assertTrue(rotate_if_needed(path, max_bytes=10, copies=2))
            self.assertEqual(os.stat(path).st_ino, inode)
            self.assertEqual(os.path.getsize(path), 0)
            with gzip.open(path + ".1.gz", "rb") as handle:
                self.assertEqual(handle.read(), b"0123456789")

    def test_shifts_and_bounds_retained_copies(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "access.json")
            for payload in (b"first", b"second", b"third"):
                open(path, "wb").write(payload)
                rotate_if_needed(path, max_bytes=1, copies=2)
            with gzip.open(path + ".1.gz", "rb") as handle:
                self.assertEqual(handle.read(), b"third")
            with gzip.open(path + ".2.gz", "rb") as handle:
                self.assertEqual(handle.read(), b"second")
            self.assertFalse(os.path.exists(path + ".3.gz"))
```

- [ ] **Step 2: Run tests and confirm the module is missing**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_traefik_access_log_rotator
```

Expected: `ModuleNotFoundError: No module named 'traefik_access_log_rotator'`.

- [ ] **Step 3: Implement rotation and its service loop**

Create `observability/traefik_access_log_rotator.py` with:

```python
from __future__ import annotations

import gzip
import os
import shutil
import sys
import time


def rotate_if_needed(path: str, max_bytes: int, copies: int) -> bool:
    try:
        if os.path.getsize(path) < max_bytes:
            return False
    except FileNotFoundError:
        return False
    oldest = f"{path}.{copies}.gz"
    if os.path.exists(oldest):
        os.unlink(oldest)
    for index in range(copies - 1, 0, -1):
        source = f"{path}.{index}.gz"
        if os.path.exists(source):
            os.replace(source, f"{path}.{index + 1}.gz")
    with open(path, "rb") as source, gzip.open(f"{path}.1.gz", "wb") as destination:
        shutil.copyfileobj(source, destination)
    with open(path, "r+b") as active:
        active.truncate(0)
    return True


def positive_integer(name: str, default: str) -> int:
    value = int(os.environ.get(name, default))
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


def main() -> None:
    path = os.environ.get("ACCESS_LOG_PATH", "/logs/access.json")
    max_bytes = positive_integer("LOG_MAX_BYTES", "104857600")
    copies = positive_integer("LOG_COPIES", "7")
    interval = positive_integer("ROTATION_CHECK_SECONDS", "60")
    while True:
        try:
            rotate_if_needed(path, max_bytes, copies)
        except Exception as error:
            print(f"access-log rotation failed: {error}", file=sys.stderr, flush=True)
        time.sleep(interval)


if __name__ == "__main__":
    main()
```

The executable loop reads:

```text
ACCESS_LOG_PATH=/logs/access.json
LOG_MAX_BYTES=104857600
LOG_COPIES=7
ROTATION_CHECK_SECONDS=60
```

The implementation validates all three numeric values as positive integers and prints
exceptions without including access-log content.

- [ ] **Step 4: Run tests and syntax checks**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_traefik_access_log_rotator
python3 -m py_compile observability/traefik_access_log_rotator.py
```

Expected: 3 tests pass and the syntax check exits 0.

- [ ] **Step 5: Commit the rotator**

```bash
git add observability/traefik_access_log_rotator.py observability/test_traefik_access_log_rotator.py
git commit -m "Add bounded Traefik access log rotation"
```

---

### Task 4: Wire access logging, exporter, rotation, and Prometheus in Terraform

**Files:**
- Modify: `variables.tf`
- Modify: `traefik.tf`
- Modify: `observability.tf`
- Modify: `observability/prometheus.yml`

**Interfaces:**
- Consumes: Task 2 exporter, Task 3 rotator, operator-provided `var.jellyfin_api_key`.
- Produces: `jellyfin-egress-exporter:9101/metrics` on `docker_network.observability`; bounded access logs at `/home/${var.username}/appdata/traefik/log`.

- [ ] **Step 1: Confirm the API key prerequisite without displaying it**

Run:

```bash
grep -q '^jellyfin_api_key[[:space:]]*=' .auto.tfvars
```

Expected: exit 0 and no output. If it fails, stop and ask the operator to create a
Jellyfin API key and add `jellyfin_api_key = "..."` to `.auto.tfvars`; never edit or
print that file.

- [ ] **Step 2: Declare the sensitive variable**

Append beside the other API keys in `variables.tf`:

```hcl
variable "jellyfin_api_key" {
  type      = string
  sensitive = true
}
```

- [ ] **Step 3: Enable minimal JSON access logging in Traefik**

Add these flags to `module "traefik"`'s `command` list:

```hcl
    "--accesslog=true",
    "--accesslog.filepath=/var/log/traefik/access.json",
    "--accesslog.format=json",
    "--accesslog.fields.defaultmode=drop",
    "--accesslog.fields.names.StartUTC=keep",
    "--accesslog.fields.names.RouterName=keep",
    "--accesslog.fields.names.ClientHost=keep",
    "--accesslog.fields.names.DownstreamContentSize=keep",
    "--accesslog.fields.names.DownstreamStatus=keep",
    "--accesslog.fields.headers.defaultmode=drop",
    "--accesslog.fields.queryparameters.defaultmode=drop",
```

Add this volume after `/letsencrypt`:

```hcl
    {
      container_path = "/var/log/traefik"
      host_path      = "/home/${var.username}/appdata/traefik/log"
    },
```

- [ ] **Step 4: Add the exporter service**

Add to `observability.tf` after `module "alloy"`:

```hcl
module "jellyfin_egress_exporter" {
  source = "./modules/service"

  name     = "jellyfin-egress-exporter"
  image    = "python:3.13-alpine"
  networks = [docker_network.media.id, docker_network.observability.id]

  env = concat(local.shared_env, [
    "JELLYFIN_URL=http://jellyfin:8096",
    "JELLYFIN_API_KEY=${var.jellyfin_api_key}",
    "ACCESS_LOG_PATH=/logs/access.json",
    "CHECKPOINT_PATH=/state/checkpoint.json",
    "MAPPING_TTL_SECONDS=600",
    "SESSION_POLL_SECONDS=15",
    "METRICS_PORT=9101",
  ])

  command = ["python", "/usr/local/bin/jellyfin-egress-exporter.py"]

  uploads = [{
    file    = "/usr/local/bin/jellyfin-egress-exporter.py"
    content = file("${path.module}/observability/jellyfin_egress_exporter.py")
  }]

  volumes = [
    {
      container_path = "/logs"
      host_path      = "/home/${var.username}/appdata/traefik/log"
      read_only      = true
    },
    {
      container_path = "/state"
      host_path      = "/home/${var.username}/appdata/jellyfin-egress-exporter"
    },
  ]
}
```

Do not set `port`: that variable creates a Traefik route, and this exporter is internal
only. Docker networking can still reach its listener on 9101.

- [ ] **Step 5: Add the rotation service**

Add immediately after the exporter:

```hcl
module "traefik_access_log_rotator" {
  source = "./modules/service"

  name     = "traefik-access-log-rotator"
  image    = "python:3.13-alpine"
  networks = []

  env = concat(local.shared_env, [
    "ACCESS_LOG_PATH=/logs/access.json",
    "LOG_MAX_BYTES=104857600",
    "LOG_COPIES=7",
    "ROTATION_CHECK_SECONDS=60",
  ])

  command = ["python", "/usr/local/bin/traefik-access-log-rotator.py"]

  uploads = [{
    file    = "/usr/local/bin/traefik-access-log-rotator.py"
    content = file("${path.module}/observability/traefik_access_log_rotator.py")
  }]

  volumes = [{
    container_path = "/logs"
    host_path      = "/home/${var.username}/appdata/traefik/log"
  }]
}
```

- [ ] **Step 6: Add the Prometheus scrape job**

Insert into `observability/prometheus.yml`:

```yaml
  - job_name: jellyfin-egress
    static_configs:
      - targets: ["jellyfin-egress-exporter:9101"]
```

- [ ] **Step 7: Run local tests and Terraform validation**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter \
  observability.test_traefik_access_log_rotator
terraform fmt -check
terraform validate
```

Expected: all Python tests pass, formatting is clean, and Terraform reports
`Success! The configuration is valid.` If formatting fails, run `terraform fmt`, inspect
its diff, and rerun both Terraform checks.

- [ ] **Step 8: Review the Terraform plan before applying**

Run:

```bash
terraform plan -no-color -out=/tmp/jellyfin-egress.tfplan
terraform show -no-color /tmp/jellyfin-egress.tfplan
```

Expected changes:

- replace the Traefik container because command and volumes changed;
- create `jellyfin-egress-exporter` and `traefik-access-log-rotator` images and containers;
- replace Prometheus because its uploaded configuration changed;
- no Grafana dashboard change yet;
- no unrelated service replacement or destruction.

Stop if the plan differs materially. Do not apply a saved plan whose review failed.

- [ ] **Step 9: Apply the reviewed plan and verify service health**

Run:

```bash
terraform apply /tmp/jellyfin-egress.tfplan
curl -fsS -H 'Host: prometheus.localdomain' \
  'http://192.168.86.199/api/v1/targets?state=active'
```

Expected: apply succeeds and the response contains `jellyfin-egress-exporter:9101` with
`"health":"up"`.

- [ ] **Step 10: Verify access-log privacy before generating authenticated traffic**

Generate one unauthenticated public request, then inspect the Traefik container through
the Docker host connection:

```bash
curl -sk -o /dev/null -H 'Host: jellyfin.example.invalid' https://192.168.86.199/
docker --host ssh://reilley@192.168.86.199 exec traefik \
  tail -n 1 /var/log/traefik/access.json | jq .
```

Confirm the JSON object has only `StartUTC`, `RouterName`, `ClientHost`,
`DownstreamContentSize`, and
`DownstreamStatus`. Stop immediately if it contains `Authorization`, `Cookie`, a query
string, or any token.

- [ ] **Step 11: Commit infrastructure wiring**

```bash
git add variables.tf traefik.tf observability.tf observability/prometheus.yml
git commit -m "Deploy Jellyfin user egress collection"
```

---

### Task 5: Add the per-user Grafana panels

**Files:**
- Modify: `observability/jellyfin-dashboard.json.tftpl`

**Interfaces:**
- Consumes: `jellyfin_user_egress_bytes_total{user,client_ip}` from Task 4.
- Produces: three Grafana panels scoped to the dashboard time picker.

- [ ] **Step 1: Add a JSON-template validation command before editing**

Run:

```bash
sed 's/${datasource_uid}/prometheus/g' observability/jellyfin-dashboard.json.tftpl \
  | jq -e . >/dev/null
```

Expected: exit 0. If it fails before editing, stop and diagnose the existing template.

- [ ] **Step 2: Reflow the existing dashboard and add panel 6, Public egress by user**

Move the existing request/latency/status panels down and add a 12-column bar chart at
`gridPos = {"h": 9, "w": 12, "x": 0, "y": 9}` with byte unit `decbytes`. Its target is:

```json
{
  "refId": "A",
  "expr": "sum by (user) (increase(jellyfin_user_egress_bytes_total[$__range]))",
  "legendFormat": "{{user}}",
  "instant": true
}
```

Set the description to: `Exact public response-body bytes attributed to the latest Jellyfin user observed for each client IP.`

- [ ] **Step 3: Add panel 7, Upload rate by user**

Add a 12-column time series beside panel 6 at
`gridPos = {"h": 9, "w": 12, "x": 12, "y": 9}`. Use unit `bps`, minimum 0, and:

```json
{
  "refId": "A",
  "expr": "sum by (user) (rate(jellyfin_user_egress_bytes_total[5m])) * 8",
  "legendFormat": "{{user}}"
}
```

- [ ] **Step 4: Add panel 8, User/IP attribution**

Add a full-width table below the existing panels. Query:

```json
{
  "refId": "A",
  "expr": "sum by (user, client_ip) (increase(jellyfin_user_egress_bytes_total[$__range]))",
  "instant": true,
  "format": "table"
}
```

Use Grafana transformations `labelsToFields` followed by `organize` so the visible
columns are `user`, `client_ip`, and `Value`; rename `Value` to `Egress` and set its unit
to `decbytes`. Do not filter the `unknown` user.

- [ ] **Step 5: Validate JSON and query strings**

Run:

```bash
sed 's/${datasource_uid}/prometheus/g' observability/jellyfin-dashboard.json.tftpl \
  | jq -e '.panels | length == 8' >/dev/null
rg -n 'jellyfin_user_egress_bytes_total|jellyfin@docker|jellyfinlocal@docker' \
  observability/jellyfin-dashboard.json.tftpl
terraform validate
```

Expected: JSON validation exits 0, exactly eight panels exist, all three new expressions
appear, and Terraform validation succeeds.

- [ ] **Step 6: Review and apply the dashboard-only plan**

Run:

```bash
terraform plan -no-color -out=/tmp/jellyfin-dashboard.tfplan
terraform show -no-color /tmp/jellyfin-dashboard.tfplan
```

Expected: only `grafana_dashboard.jellyfin` changes. If so:

```bash
terraform apply /tmp/jellyfin-dashboard.tfplan
```

- [ ] **Step 7: Commit the dashboard**

```bash
git add observability/jellyfin-dashboard.json.tftpl
git commit -m "Show Jellyfin public egress by user"
```

---

### Task 6: Perform the attribution and restart integration gates

**Files:**
- No repository changes expected.

**Interfaces:**
- Consumes: deployed Traefik, Jellyfin, exporter, Prometheus, and Grafana configuration.
- Produces: evidence that address joining, byte attribution, privacy, and checkpoint recovery work on the live host.

- [ ] **Step 1: Capture a clean baseline window**

Query Prometheus for both aggregate and attributed counters immediately before the test.
Use `curl -G --data-urlencode 'query=...'` against the Prometheus HTTP API so braces and
label matchers are encoded correctly. Record timestamps and values without editing the
repository.

- [ ] **Step 2: Start one external Jellyfin stream**

Use a client outside the LAN so requests traverse `jellyfin@docker`. Keep playback
running for at least two Jellyfin session polls and two Prometheus scrapes: 45 seconds is
the minimum useful test window.

- [ ] **Step 3: Prove the address join before accepting attribution**

While the stream is active:

1. Query Jellyfin `/Sessions` from inside the exporter, where the key is already in the
   environment, without printing the key:

```bash
JELLYFIN_SESSION_ENDPOINT="$(docker --host ssh://reilley@192.168.86.199 \
  exec jellyfin-egress-exporter python -c \
  'import json, os, urllib.request; r=urllib.request.Request(os.environ["JELLYFIN_URL"] + "/Sessions", headers={"X-Emby-Token": os.environ["JELLYFIN_API_KEY"]}); sessions=json.loads(urllib.request.urlopen(r, timeout=10).read()); print(next(s["RemoteEndPoint"] for s in sessions if s.get("NowPlayingItem")))')"
```

2. Extract the newest public Jellyfin `ClientHost` from the Traefik log:

```bash
TRAEFIK_CLIENT_HOST="$(docker --host ssh://reilley@192.168.86.199 exec traefik \
  tail -n 200 /var/log/traefik/access.json \
  | jq -r 'select(.RouterName == "jellyfin@docker") | .ClientHost' \
  | tail -n 1)"
```

3. Normalize and compare both values:

```bash
PYTHONPATH=observability python3 -c \
  'from jellyfin_egress_exporter import normalize_address; import sys; a=normalize_address(sys.argv[1]); b=normalize_address(sys.argv[2]); print(f"Jellyfin={a} Traefik={b}"); raise SystemExit(0 if a == b and a is not None else 1)' \
  "$JELLYFIN_SESSION_ENDPOINT" "$TRAEFIK_CLIENT_HOST"
```

The normalized values must match. If they do not, stop. Configure trusted proxy handling
for the actual proxy path and repeat this gate; do not claim username attribution works.

- [ ] **Step 4: Verify attributed metrics and dashboard data**

Query:

```promql
sum by (user, client_ip) (increase(jellyfin_user_egress_bytes_total[5m]))
```

Expected: a positive series for the active username and the normalized client IP. Open
the Jellyfin dashboard and confirm all three new panels show that series.

- [ ] **Step 5: Reconcile with Traefik's aggregate counter**

For the same time window compare:

```promql
sum(increase(jellyfin_user_egress_bytes_total[5m]))
```

and:

```promql
sum(increase(traefik_router_responses_bytes_total{router="jellyfin@docker"}[5m]))
```

The values should be close, with differences limited to scrape boundaries and the small
copy-truncate race documented in the spec. A large persistent gap requires checking the
exporter's error and checkpoint-discontinuity counters before proceeding.

- [ ] **Step 6: Verify checkpoint recovery**

Record the checkpoint file's offset and the current attributed counter, restart only the
`jellyfin-egress-exporter` container through the normal Terraform/Docker administration
path, and wait for two scrapes. Confirm:

- the exporter target returns to `UP`;
- the checkpoint resumes near the recorded offset rather than zero;
- the whole access log is not replayed;
- new traffic increments the counter after the restart.

- [ ] **Step 7: Run the final verification suite**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter \
  observability.test_traefik_access_log_rotator
python3 -m py_compile \
  observability/jellyfin_egress_exporter.py \
  observability/traefik_access_log_rotator.py
terraform fmt -check
terraform validate
git status --short
```

Expected: all tests pass, both modules compile, Terraform checks succeed, and the working
tree contains no task-related uncommitted changes. Existing untracked `.codex/` and
`AGENTS.md` are user files and remain untouched.

---

## Completion Criteria

Implementation is complete only when:

1. All exporter and rotator unit tests pass.
2. Terraform validation succeeds and the final plan is converged.
3. Prometheus reports the exporter target `UP`.
4. Traefik logs contain only the approved safe fields.
5. Jellyfin and Traefik client addresses normalize identically during an external stream.
6. The dashboard shows positive egress for the active username and IP.
7. Per-user totals closely reconcile with Traefik's aggregate public-router total.
8. Exporter restart recovery does not replay the complete log.
