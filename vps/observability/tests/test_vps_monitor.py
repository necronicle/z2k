"""Monitor rules use live counters; missing data and resets are not traffic."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('monitor', Path(__file__).absolute().parents[1] / 'monitor.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def snapshot(ok=1000, fail=0, sessions=1800):
    return {'a': m.parse_metrics(f'relay_sessions {sessions}\nrelay_dial_total{{result="ok"}} {ok}\nrelay_dial_total{{result="fail"}} {fail}\n')}


class MonitorTest(unittest.TestCase):
    def test_missing_gauge_is_unknown_zero_is_valid(self):
        self.assertIsNone(m.gauge({}, 'relay_sessions'))
        self.assertIsNone(m.gauge({'a': {}}, 'relay_sessions'))
        self.assertEqual(m.gauge(snapshot(sessions=0), 'relay_sessions'), 0)

    def test_dial_failure_detected_without_stream_open_events(self):
        prev = m.evaluate(1000, snapshot(), [], {})
        result = m.evaluate(1060, snapshot(1100, 10), [], prev)
        self.assertIn('dial_fail', result['alerts'])
        self.assertEqual(result['dial_window']['ok'], 100)
        self.assertEqual(result['dial_window']['fail'], 10)

    def test_first_sample_reset_missing_and_long_gap_do_not_invent_deltas(self):
        base = m.evaluate(1000, snapshot(9000, 9000), [], {})
        self.assertNotIn('dial_fail', base['alerts'])
        for now, snap in [(1060, snapshot(1, 1)), (1060, {}), (1500, snapshot(10000, 10000))]:
            result = m.evaluate(now, snap, [], base)
            self.assertNotIn('dial_fail', result['alerts'])
            self.assertIsNone(result['dial_window'])
            self.assertTrue(result['dial_coverage']['partial'])

    def test_observed_zero_is_distinct_from_no_counter_coverage(self):
        base = m.evaluate(1000, snapshot(), [], {})
        observed = m.evaluate(1060, snapshot(), [], base)
        missing = m.evaluate(1060, {'a': {'relay_sessions': 1800}}, [], base)
        self.assertEqual(observed['dial_window'], dict(ok=0, fail=0, throttle=0))
        self.assertIsNone(missing['dial_window'])
        self.assertEqual(missing['dial_coverage']['reasons']['a'], 'missing_counters')

    def test_endpoint_switch_never_subtracts_different_instances(self):
        base = m.evaluate(1000, snapshot(), [], {})
        result = m.evaluate(1060, {'b': snapshot(10000, 1000)['a']}, [], base)
        self.assertNotIn('dial_fail', result['alerts'])
        self.assertEqual(result['sessions'], 1800)

    def test_missing_metrics_reported_without_false_mass_close(self):
        events = [{'ts_epoch': 995, 'ev': 'session_close'}] * 30
        result = m.evaluate(1000, {}, events, {})
        self.assertIn('metrics_unavailable', result['alerts'])
        self.assertNotIn('mass_close', result['alerts'])

    def test_target_failure_not_diluted_by_fleet_success(self):
        events = [{'ts_epoch': 995, 'ev': 'dial_fail', 'reason': 'dial_error', 'detail': '91.105.192.100:443', 'install': str(i % 5)} for i in range(20)]
        result = m.evaluate(1000, snapshot(99999999), events, {})
        self.assertIn('dial_target', result['alerts'])
        self.assertEqual(result['dial_targets'][0]['installs'], 5)

    def test_future_and_old_events_ignored(self):
        events = [{'ts_epoch': t, 'ev': 'auth_reject'} for t in [1001, 1] for _ in range(100)]
        self.assertEqual(m.evaluate(1000, snapshot(), events, {})['alerts'], {})

    def test_live_socket_rates_do_not_use_closed_session_totals(self):
        before = m.socket_counters('0 0 10.0.0.1:443 198.51.100.1:80 ino:7\n bbr bytes_sent:100 bytes_received:20\n')
        after = m.socket_counters('0 0 10.0.0.1:443 198.51.100.1:80 ino:7\n bbr bytes_sent:1100 bytes_received:520\n0 0 10.0.0.1:443 198.51.100.2:80 ino:8\n bbr bytes_sent:999999 bytes_received:9999\n')
        result = m.socket_rates(after, before, 10)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['peer'], '198.51.100.1')
        self.assertEqual(result[0]['down_mbps'], .0008)
        self.assertEqual(result[0]['up_mbps'], .0004)
        self.assertEqual(m.socket_rates(before, after, 10), [])
        self.assertEqual(m.socket_rates(after, before, 300), [])

    def test_kernel_counters_use_deltas_and_ignore_resets(self):
        alerts = {}
        old = {'time': 1000, 'node': {'counters': {'ListenDrops': 9, 'TCPReqQFullDrop': 2}}}
        node = {'counters': {'ListenDrops': 12, 'TCPReqQFullDrop': 0}, 'memory_available_ratio': .7, 'disk_free_ratio': .8}
        m.node_rules(1060, node, old, alerts)
        self.assertIn('kernel_drops', alerts)
        self.assertEqual(node['delta']['ListenDrops'], 3)
        self.assertIsNone(node['delta']['TCPReqQFullDrop'])

    def test_whatsapp_dns_errors_distinguished_from_peer_resets(self):
        lines = ['2026/09/30 18:00:00 [error] g.whatsapp.net could not be resolved (110: Operation timed out)',
                 '2026/09/30 18:00:01 [error] recv() failed (104: Connection reset by peer)',
                 '2026/09/30 18:00:02 [error] other.test could not be resolved (110: Operation timed out)']
        import datetime
        now = datetime.datetime(2026, 9, 30, 18, 1).timestamp()
        result = m.nginx_errors(lines, now)
        self.assertEqual(result['whatsapp_dns_timeout'], 1)
        self.assertEqual(result['upstream_reset'], 1)

    def test_uncompressed_rotation_takes_precedence(self):
        import gzip
        import json
        import datetime
        now = 100000
        date = datetime.datetime.fromtimestamp(now - 86400, datetime.timezone.utc).strftime('%Y-%m-%d')
        line = json.dumps({'ts': '1970-01-01T23:59:00Z', 'ev': 'session_close'}) + '\n'
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / f'events-{date}.jsonl'
            file.write_text(line)
            with gzip.open(str(file) + '.gz', 'wt') as f:
                f.write(line)
            self.assertEqual(len(list(m.read_events(Path(directory), now))), 1)


if __name__ == '__main__':
    unittest.main()
