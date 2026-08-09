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
