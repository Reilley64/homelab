import json
import os
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import threading
from http.server import ThreadingHTTPServer
from urllib import error as urlerror
from urllib import request as urlrequest

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


from jellyfin_egress_exporter import Checkpoint, process_available, save_checkpoint


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


from jellyfin_egress_exporter import MetricsHandler, Runtime, Settings, read_settings


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
            raised.exception.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    @patch.dict(os.environ, {}, clear=True)
    def test_api_key_is_required(self):
        with self.assertRaisesRegex(SystemExit, "JELLYFIN_API_KEY is required"):
            read_settings()
