"""Pins monitor.py as the node runs it: a process with argv, env and files."""
import datetime as dt
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
from unittest.mock import patch

SCRIPT = Path(__file__).absolute().parents[1] / 'monitor.py'
spec = importlib.util.spec_from_file_location('monitor', SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

A = 'relay_sessions 1000\nrelay_streams 40\nrelay_queue_bytes 7\nrelay_dial_total{result="ok"} 500\n'
B = 'relay_sessions 800\nrelay_streams 2\n'


def run(args, env, cwd):
    full = dict(os.environ, **env)
    return subprocess.run([sys.executable, str(SCRIPT), *args], env=full, cwd=cwd,
                          capture_output=True, text=True, timeout=60)


class ProcessPin(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / 'a.prom').write_text(A)
        (self.dir / 'b.prom').write_text(B)
        self.a = (self.dir / 'a.prom').as_uri()
        self.b = (self.dir / 'b.prom').as_uri()

    def tearDown(self):
        self.tmp.cleanup()

    def test_gauges_sum_endpoints_and_mark_missing(self):
        out = run(['--gauges'], {'METRICS': self.a, 'METRICS_B': self.b}, self.dir)
        self.assertEqual(out.stdout, '1800\t42\t7\n')
        out = run(['--gauges'], {'METRICS': (self.dir / 'none').as_uri(), 'METRICS_B': ''}, self.dir)
        self.assertEqual(out.stdout, 'NA\tNA\tNA\n')

    def test_main_writes_status_from_both_endpoints(self):
        state = self.dir / 'state'
        out = run([str(self.dir), self.a, str(state)], {'METRICS_B': self.b, 'Z2K_MONITOR_NODE': '0', 'Z2K_ALERT_SEND': '0'}, self.dir)
        self.assertEqual(out.returncode, 0, out.stderr)
        status = json.loads((state / 'status.json').read_text())
        self.assertEqual(status['sessions'], 1800)
        self.assertEqual(status['streams'], 42)
        self.assertEqual(sorted(status['snapshots']), sorted([self.a, self.b]))
        self.assertEqual(status['alerts'], {})
        self.assertEqual(oct((state / 'status.json').stat().st_mode & 0o777), '0o600')

    def test_main_reports_unavailable_metrics_once_per_half_hour(self):
        state = self.dir / 'state'
        env = {'METRICS_B': '', 'Z2K_MONITOR_NODE': '0'}
        dead = (self.dir / 'none').as_uri()
        first = run([str(self.dir), dead, str(state)], env, self.dir)
        second = run([str(self.dir), dead, str(state)], env, self.dir)
        self.assertIn('z2k relay: metrics_unavailable', first.stdout)
        self.assertEqual(second.stdout, '')
        self.assertIn('metrics_unavailable', json.loads((state / 'status.json').read_text())['reported'])

    def test_main_skips_when_another_run_holds_the_lock(self):
        import fcntl
        state = self.dir / 'state'
        state.mkdir()
        with (state / 'monitor.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            out = run([str(self.dir), self.a, str(state)], {'METRICS_B': '', 'Z2K_MONITOR_NODE': '0'}, self.dir)
        self.assertEqual(out.returncode, 0)
        self.assertFalse((state / 'status.json').exists())


class NodeChecksPin(unittest.TestCase):
    def test_node_probes_raise_their_alerts(self):
        with tempfile.TemporaryDirectory() as d:
            state = Path(d)
            node = {'counters': {}, 'memory_available_ratio': .05, 'disk_free_ratio': .5}
            nginx = {'whatsapp_dns_timeout': 3, 'upstream_connect_timeout': 10}
            with patch.object(m, 'curl', return_value=A), \
                 patch.object(m, 'traffic_snapshot', return_value={'top_peers': []}), \
                 patch.object(m, 'node_snapshot', return_value=node), \
                 patch.object(m, 'nginx_snapshot', return_value=nginx), \
                 patch.dict(os.environ, {'Z2K_MONITOR_NODE': '1', 'METRICS_B': ''}), \
                 patch.object(sys, 'argv', ['monitor.py', d, 'http://a', d]), redirect_stdout(io.StringIO()):
                m.main()
            alerts = json.loads((state / 'status.json').read_text())['alerts']
            self.assertEqual(sorted(alerts), ['memory_low', 'upstream_connect', 'whatsapp_dns'])

    def test_node_probe_thresholds_are_inclusive_minimums(self):
        with tempfile.TemporaryDirectory() as d:
            nginx = {'whatsapp_dns_timeout': 2, 'upstream_connect_timeout': 9}
            with patch.object(m, 'curl', return_value=A), \
                 patch.object(m, 'traffic_snapshot', return_value={}), \
                 patch.object(m, 'node_snapshot', return_value={'counters': {}}), \
                 patch.object(m, 'nginx_snapshot', return_value=nginx), \
                 patch.dict(os.environ, {'Z2K_MONITOR_NODE': '1', 'METRICS_B': ''}), \
                 patch.object(sys, 'argv', ['monitor.py', d, 'http://a', d]), redirect_stdout(io.StringIO()):
                m.main()
            self.assertEqual(json.loads((Path(d) / 'status.json').read_text())['alerts'], {})


class SnapshotsPin(unittest.TestCase):
    def test_nginx_snapshot_reads_both_rotation_sides_and_bounds_the_tail(self):
        now = dt.datetime(2026, 10, 29, 18, 0).timestamp()
        line = '2026/10/29 17:59:00 [error] upstream timed out (110) while connecting to upstream\n'
        with tempfile.TemporaryDirectory() as d:
            old, cur = Path(d) / 'e.log.1', Path(d) / 'e.log'
            old.write_text(line)
            cur.write_text(line * 2)
            result = m.nginx_snapshot(now, (str(old), str(cur)), limit=1 << 20)
            self.assertEqual(result['upstream_connect_timeout'], 3)
            self.assertFalse(result['tail_limited'])
            result = m.nginx_snapshot(now, (str(cur),), limit=len(line) + 5)
            self.assertEqual(result['upstream_connect_timeout'], 1)
            self.assertTrue(result['tail_limited'])
            self.assertEqual(m.nginx_snapshot(now, (str(Path(d) / 'none'),)), {'unavailable': True})

    def test_node_snapshot_reads_kernel_counters_memory_and_disk(self):
        with tempfile.TemporaryDirectory() as d:
            proc = Path(d)
            (proc / 'net').mkdir()
            (proc / 'net/netstat').write_text('TcpExt: SyncookiesSent ListenDrops ListenOverflows\nTcpExt: 1 5 6\n'
                                              'IpExt: InNoRoutes\nIpExt: 0\n')
            (proc / 'meminfo').write_text('MemTotal: 1000 kB\nMemFree: 10 kB\nMemAvailable: 250 kB\n')
            node = m.node_snapshot(proc, d)
            self.assertEqual(node['counters'], {'ListenDrops': 5, 'ListenOverflows': 6})
            self.assertEqual(node['memory_available_ratio'], .25)
            self.assertTrue(0 < node['disk_free_ratio'] <= 1)
            self.assertEqual(len(node['load']), 3)
            self.assertNotIn('unavailable', node)
            self.assertTrue(m.node_snapshot(proc / 'none', d)['unavailable'])

    def test_publish_prints_each_alert_once_per_half_hour_and_never_sends(self):
        with tempfile.TemporaryDirectory() as d:
            status = {'alerts': {'x': 'detail'}, 'reported': {'x': 0}}
            out = io.StringIO()
            with patch.object(m, 'curl', side_effect=AssertionError('no network')), redirect_stdout(out):
                m.publish_status(Path(d), status, 1800)
                m.publish_status(Path(d), status, 3599)
            self.assertEqual(out.getvalue(), 'z2k relay: x — detail\n')
            self.assertEqual(json.loads((Path(d) / 'status.json').read_text())['reported'], {'x': 1800})


if __name__ == '__main__':
    unittest.main()
