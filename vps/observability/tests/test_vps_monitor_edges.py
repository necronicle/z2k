"""Boundaries of every monitor rule: windows, thresholds and parsers."""
import datetime as dt
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

SCRIPT = Path(__file__).absolute().parents[1] / 'monitor.py'
spec = importlib.util.spec_from_file_location('monitor', SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
OK, FAIL, THR = m.DIAL_KEYS
NOW = 100000


def ev(age, kind, **kw):
    return dict(ts_epoch=NOW - age, ev=kind, **kw)


class Parsers(unittest.TestCase):
    def test_parse_metrics_keeps_finite_non_negative_pairs_only(self):
        text = '#x 5\n# HELP y z\nfoo 1 2\nneg -1\ninf inf\nbad x\nzero 0\nok 3.9\n'
        self.assertEqual(m.parse_metrics(text), {'zero': 0, 'ok': 3})

    def test_tcp_ext_ignores_a_trailing_header_without_values(self):
        self.assertEqual(m.tcp_ext_counters('IpExt: a\nIpExt: 1\nTcpExt: ListenDrops'), {})
        self.assertEqual(m.tcp_ext_counters('TcpExt: ListenDrops X\nTcpExt: 4 9\n'), {'ListenDrops': 4})

    def test_socket_header_needs_two_numeric_queues_and_inode(self):
        text = ('0 0 192.0.2.1:443 198.51.100.7:5 ino:3 sk:1\n'
                '7 cubic wscale:7,7 rto:204 bytes_sent:11 bytes_received:22\n'
                '0 x 192.0.2.1:443 198.51.100.8:5 ino:4\n'
                ' bytes_sent:99\n'
                '0 0 192.0.2.1:443 198.51.100.9:5 ino:5\n')
        result = m.socket_counters(text)
        self.assertEqual(result['192.0.2.1:443/198.51.100.7:5/3'], {'peer': '198.51.100.7', 'sent': 99, 'received': 22})
        self.assertEqual(result['192.0.2.1:443/198.51.100.9:5/5'], {'peer': '198.51.100.9', 'sent': 0, 'received': 0})
        self.assertEqual(len(result), 2)

    def test_read_events_uses_today_and_yesterday_and_gz_fallback(self):
        midnight = 86400 * 20000
        today = dt.datetime.fromtimestamp(midnight, dt.timezone.utc).strftime('%Y-%m-%d')
        yday = dt.datetime.fromtimestamp(midnight - 86400, dt.timezone.utc).strftime('%Y-%m-%d')
        line = json.dumps({'ts': '2024-01-01T00:00:00Z', 'ev': 'x'}) + '\n'
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / f'events-{today}.jsonl').write_text(line + '{broken\n')
            with gzip.open(Path(d) / f'events-{yday}.jsonl.gz', 'wt') as f:
                f.write(line * 2)
            events = list(m.read_events(Path(d), midnight))
        self.assertEqual(len(events), 3)
        self.assertEqual(events[0]['ts_epoch'], dt.datetime(2024, 1, 1, tzinfo=dt.timezone.utc).timestamp())


class EventRules(unittest.TestCase):
    def alerts(self, events, sessions=100):
        snap = {'a': {'relay_sessions': sessions}} if sessions is not None else {}
        return m.evaluate(NOW, snap, events, {})['alerts']

    def test_auth_rejects_counted_within_the_last_minute_above_fifty(self):
        self.assertNotIn('auth_reject', self.alerts([ev(0, 'auth_reject')] * 50))
        self.assertIn('auth_reject', self.alerts([ev(0, 'auth_reject')] * 51))
        self.assertIn('auth_reject', self.alerts([ev(60, 'auth_reject')] * 51))
        self.assertNotIn('auth_reject', self.alerts([ev(61, 'auth_reject')] * 51))
        self.assertNotIn('auth_reject', self.alerts([ev(0, 'session_close')] * 51))

    def test_mass_close_needs_twenty_and_a_tenth_of_live_sessions(self):
        self.assertEqual(self.alerts([ev(0, 'session_close')] * 20)['mass_close'],
                         'за минуту закрылось 20 сессий, живых 100; ASN: [(0, 20)]')
        self.assertNotIn('mass_close', self.alerts([ev(0, 'session_close')] * 19))
        self.assertNotIn('mass_close', self.alerts([ev(0, 'session_close')] * 29, sessions=300))
        self.assertIn('mass_close', self.alerts([ev(0, 'session_close')] * 30, sessions=300))
        self.assertNotIn('mass_close', self.alerts([ev(0, 'auth_reject')] * 30))
        self.assertNotIn('mass_close', self.alerts([ev(0, 'session_close')] * 30, sessions=None))

    def test_five_minute_window_includes_both_ends_only(self):
        fails = lambda age: [ev(age, 'dial_fail', reason='dial_error', detail='t', install=str(i % 5)) for i in range(20)]
        self.assertIn('dial_target', self.alerts(fails(300)))
        self.assertIn('dial_target', self.alerts(fails(0)))
        self.assertNotIn('dial_target', self.alerts(fails(301)))
        self.assertNotIn('dial_target', self.alerts(fails(-1)))

    def test_event_breakdown_rows(self):
        window = ([ev(0, 'dial_fail', reason='dial_error', detail='t1', install='a')] * 2 +
                  [ev(0, 'dial_fail', reason='dial_error', detail='t1', install='')] +
                  [ev(0, 'dial_fail', reason='dial_error', install='b')] +
                  [ev(0, 'dial_fail', reason='other', detail='t9', install='a')] +
                  [ev(0, 'stream_open', reason='dial_error', detail='t8', install='a')] +
                  [ev(0, 'x', reason='stream_limit', install='a')] * 3 +
                  [ev(0, 'x', reason='udp_protocol', install='c')] +
                  [ev(0, 'x', reason='stream_limit', install='')])
        targets, offenders = m.event_breakdown(window)
        self.assertEqual(targets, [dict(target='t1', failures=3, installs=1), dict(target='unknown', failures=1, installs=1)])
        self.assertEqual(offenders, [dict(install='a', reason='stream_limit', count=3), dict(install='c', reason='udp_protocol', count=1)])

    def test_breakdown_alert_thresholds(self):
        row = lambda f, i: [dict(target='t', failures=f, installs=i)]
        self.assertIn('dial_target', m.breakdown_alerts(row(20, 5), []))
        self.assertEqual(m.breakdown_alerts(row(19, 5), []), {})
        self.assertEqual(m.breakdown_alerts(row(20, 4), []), {})
        self.assertIn('install_errors', m.breakdown_alerts([], [dict(install='a', reason='r', count=20)]))
        self.assertEqual(m.breakdown_alerts([], [dict(install='a', reason='r', count=19)]), {})


class DialRules(unittest.TestCase):
    def test_dial_alert_thresholds(self):
        t = lambda ok, fail, thr=0: m.dial_alerts(dict(ok=ok, fail=fail, throttle=thr))
        self.assertEqual(t(95, 5), {})
        self.assertEqual(t(94, 6)['dial_fail'], '6 ошибок на 100 попыток за наблюдаемую часть последних 5 минут')
        self.assertEqual(t(93, 6), {})
        self.assertEqual(t(0, 0, 49), {})
        self.assertEqual(t(0, 0, 50)['dial_throttle'], '50 отказов ограничителя дозвона за последние 5 минут')

    def test_endpoint_delta_reasons(self):
        s = {'relay_sessions': 1, OK: 5}
        self.assertEqual(m.endpoint_delta(s, None), (None, 'new_endpoint'))
        self.assertEqual(m.endpoint_delta({OK: 5}, s), (None, 'missing_gauge'))
        self.assertEqual(m.endpoint_delta(s, {OK: 5}), (None, 'missing_gauge'))
        self.assertEqual(m.endpoint_delta({'relay_sessions': 1}, s), (None, 'missing_counters'))
        self.assertEqual(m.endpoint_delta(s, {'relay_sessions': 1}), (None, 'missing_counters'))
        self.assertEqual(m.endpoint_delta({'relay_sessions': 1, OK: 4}, s), (None, 'counter_reset'))
        self.assertEqual(m.endpoint_delta(dict(s, **{FAIL: 2}), s), ([0, 2, 0], None))

    def test_sample_gap_bounds_and_reasons(self):
        snap = {'a': {'relay_sessions': 1, OK: 10}}
        prev = lambda age: dict(time=NOW - age, snapshots={'a': {'relay_sessions': 1, OK: 4}})
        self.assertEqual(m.dial_history(NOW, snap, prev(90))[0][0]['ok'], 6)
        self.assertEqual(m.dial_history(NOW, snap, prev(91)), ([], {'a': 'sample_gap'}))
        self.assertEqual(m.dial_history(NOW, snap, prev(0)), ([], {'a': 'sample_gap'}))
        self.assertEqual(m.dial_history(NOW, snap, {}), ([], {'a': 'first_sample'}))
        self.assertEqual(m.dial_history(NOW, {}, prev(30))[1], {'a': 'endpoint_unavailable'})

    def test_history_keeps_intervals_inside_the_last_five_minutes(self):
        keep = [dict(start=NOW - 300, end=NOW - 300), dict(start=NOW - 10, end=NOW)]
        drop = [dict(start=NOW - 301, end=NOW - 200), dict(start=NOW - 10, end=NOW + 1), dict(start=NOW - 5, end=NOW - 6)]
        history, _ = m.observed_deltas(NOW, {}, dict(time=NOW - 30, dial_history=keep + drop))
        self.assertEqual(history, keep)

    def test_covered_seconds_merges_overlaps(self):
        self.assertEqual(m.covered_seconds([dict(start=0, end=60), dict(start=30, end=90), dict(start=100, end=110)]), 100)
        self.assertEqual(m.covered_seconds([dict(start=10, end=20)]), 10)
        self.assertEqual(m.covered_seconds([]), 0)

    def test_coverage_is_partial_below_five_minutes_or_with_reasons(self):
        def coverage(span):
            prev = dict(time=NOW - 30, snapshots={'a': {'relay_sessions': 1, OK: 1}},
                        dial_history=[dict(endpoint='a', start=NOW - span, end=NOW - 30, ok=0, fail=0, throttle=0)])
            return m.evaluate(NOW, {'a': {'relay_sessions': 1, OK: 1}}, [], prev)['dial_coverage']
        self.assertEqual(coverage(300)['observed_seconds'], 300)
        self.assertFalse(coverage(300)['partial'])
        self.assertTrue(coverage(299)['partial'])


class NodeRules(unittest.TestCase):
    def test_counter_deltas_bounds(self):
        node = {'counters': {'ListenDrops': 5, 'ListenOverflows': 3}}
        prev = lambda age: dict(time=NOW - age, node={'counters': {'ListenDrops': 5}})
        self.assertEqual(m.counter_deltas(NOW, node, prev(90)), {'ListenDrops': 0, 'ListenOverflows': None})
        self.assertEqual(m.counter_deltas(NOW, node, prev(91)), {})
        self.assertEqual(m.counter_deltas(NOW, node, prev(0)), {})

    def test_node_floor_and_drop_rules(self):
        def alerts(node, prev=None):
            out = {}
            m.node_rules(NOW, dict(node), prev or {}, out)
            return out
        self.assertEqual(alerts({'counters': {}, 'memory_available_ratio': .1, 'disk_free_ratio': .1}), {})
        self.assertEqual(sorted(alerts({'counters': {}, 'memory_available_ratio': .09, 'disk_free_ratio': .09})), ['disk_low', 'memory_low'])
        self.assertEqual(alerts({'counters': {}}), {})
        same = dict(time=NOW - 60, node={'counters': {'ListenDrops': 5}})
        self.assertEqual(alerts({'counters': {'ListenDrops': 5}}, same), {})
        self.assertIn('kernel_drops', alerts({'counters': {'ListenDrops': 6}}, same))


class Nginx(unittest.TestCase):
    def test_error_window_includes_both_ends(self):
        now = dt.datetime(2026, 10, 29, 18, 0).timestamp()
        line = lambda age: dt.datetime.fromtimestamp(now - age).strftime('%Y/%m/%d %H:%M:%S') + ' limiting connections by zone'
        self.assertEqual(m.nginx_errors([line(0), line(300), line(301), line(-1), 'junk'], now)['per_ip_limit'], 2)

    def test_tail_of_exactly_the_limit_is_whole(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'e.log'
            f.write_text('a\nb\n')
            self.assertEqual(m.read_tail(str(f), 4), (['a', 'b'], False))
            self.assertEqual(m.read_tail(str(f), 3), (['b'], True))


class Publish(unittest.TestCase):
    def test_first_report_at_exactly_half_hour_and_utf8_on_disk(self):
        with tempfile.TemporaryDirectory() as d:
            out = io.StringIO()
            with redirect_stdout(out):
                m.publish_status(Path(d), {'alerts': {'r': 'тревога'}, 'reported': {}}, 1800)
            self.assertEqual(out.getvalue(), 'z2k relay: r — тревога\n')
            self.assertIn('тревога', (Path(d) / 'status.json').read_text(encoding='utf-8'))

    def test_main_creates_nested_state_and_reruns_cleanly(self):
        with tempfile.TemporaryDirectory() as d:
            state = Path(d) / 'x' / 'y'
            env = dict(os.environ, METRICS_B='', Z2K_MONITOR_NODE='0')
            for _ in range(2):
                run = subprocess.run([sys.executable, str(SCRIPT), d, (Path(d) / 'none').as_uri(), str(state)],
                                     env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue((state / 'status.json').exists())


class Rates(unittest.TestCase):
    def sock(self, peer, sent, received):
        return {'peer': peer, 'sent': sent, 'received': received}

    def test_interval_bounds(self):
        cur, old = {'k': self.sock('p', 900, 900)}, {'k': self.sock('p', 0, 0)}
        self.assertEqual(len(m.socket_rates(cur, old, 1)), 1)
        self.assertEqual(len(m.socket_rates(cur, old, 90)), 1)
        self.assertEqual(m.socket_rates(cur, old, 0), [])

    def test_idle_socket_counts_as_zero_rate(self):
        same = {'k': self.sock('p', 5, 5)}
        self.assertEqual(m.socket_rates(same, same, 10), [dict(peer='p', down_mbps=0.0, up_mbps=0.0)])

    def test_peers_sorted_by_total_rate(self):
        cur = {'a': self.sock('A', 1000000, 0), 'b': self.sock('B', 600000, 600000), 'c': self.sock('C', 1, 0)}
        old = {k: self.sock(v['peer'], 0, 0) for k, v in cur.items()}
        self.assertEqual([r['peer'] for r in m.socket_rates(cur, old, 8)], ['B', 'A', 'C'])


class Edges(unittest.TestCase):
    def test_one_second_interval_is_contiguous(self):
        snap = {'a': {'relay_sessions': 1, OK: 10}}
        prev = dict(time=NOW - 1, snapshots={'a': {'relay_sessions': 1, OK: 4}}, node={'counters': {'ListenDrops': 1}})
        self.assertEqual(len(m.dial_history(NOW, snap, prev)[0]), 1)
        self.assertEqual(m.counter_deltas(NOW, {'counters': {'ListenDrops': 3}}, prev), {'ListenDrops': 2})

    def test_nested_interval_adds_nothing(self):
        self.assertEqual(m.covered_seconds([dict(start=0, end=100), dict(start=10, end=20)]), 100)

    def test_socket_header_needs_numeric_first_field(self):
        text = '0 0 192.0.2.1:443 198.51.100.7:5 ino:3\nx 0 192.0.2.1:443 198.51.100.8:5 ino:4\n bytes_sent:5\n'
        self.assertEqual(m.socket_counters(text), {'192.0.2.1:443/198.51.100.7:5/3': {'peer': '198.51.100.7', 'sent': 5, 'received': 0}})


class External(unittest.TestCase):
    def test_curl_returns_body_or_none(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'm.prom'
            f.write_text('relay_sessions 3\n')
            self.assertEqual(m.curl(f.as_uri()), 'relay_sessions 3\n')
            self.assertIsNone(m.curl((Path(d) / 'none').as_uri()))
        with patch.object(m.subprocess, 'run', side_effect=m.subprocess.TimeoutExpired('curl', 8)):
            self.assertIsNone(m.curl('http://x'))

    def test_traffic_snapshot_rates_against_previous_sockets(self):
        from unittest.mock import patch
        out = '0 0 192.0.2.1:443 198.51.100.7:5 ino:3\n bytes_sent:2000000 bytes_received:1000000\n'
        prev = {'time': NOW - 8, 'traffic': {'sockets': {'192.0.2.1:443/198.51.100.7:5/3': {'peer': '198.51.100.7', 'sent': 0, 'received': 0}}}}
        done = m.subprocess.CompletedProcess([], 0, stdout=out)
        with patch.object(m.subprocess, 'run', return_value=done) as run:
            snap = m.traffic_snapshot(NOW, prev)
        self.assertIn('state', run.call_args[0][0])
        self.assertEqual(snap['top_peers'], [dict(peer='198.51.100.7', down_mbps=2.0, up_mbps=1.0)])
        with patch.object(m.subprocess, 'run', side_effect=FileNotFoundError):
            self.assertTrue(m.traffic_snapshot(NOW, prev)['unavailable'])


class RealSs(unittest.TestCase):
    @unittest.skipUnless(__import__('shutil').which('ss'), 'ss is Linux-only')
    def test_real_ss_output_is_parsed(self):
        snap = m.traffic_snapshot(NOW, {})
        self.assertNotIn('unavailable', snap)
        self.assertIsInstance(snap['sockets'], dict)
        self.assertEqual(snap['top_peers'], [])


if __name__ == '__main__':
    unittest.main()
