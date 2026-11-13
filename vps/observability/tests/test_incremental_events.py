"""Executable regression for bounded monitoring over append-only multi-GB logs."""
import datetime as dt
import gzip
import importlib.util
import json
import os
import resource
import subprocess
import sys
import time
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('monitor', Path(__file__).resolve().parents[1] / 'monitor.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
NOW = int(dt.datetime(2026, 11, 12, 0, 2, tzinfo=dt.timezone.utc).timestamp())


def line(now=NOW, **extra):
    return (json.dumps(dict(ts=dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat(),
                            ev='auth_reject', **extra)) + '\n').encode()


class IncrementalEvents(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.path = self.root / 'events-2026-11-12.jsonl'

    def read(self, now=NOW, limit=4096):
        return m.incremental_events(self.root, now, self.state, limit=limit)

    def test_multigigabyte_bootstrap_and_followup_are_bounded(self):
        with self.path.open('wb') as f:
            f.seek(3 * 1024 ** 3)
            f.write(b'\n' + line())
        events, limited = self.read()
        self.assertTrue(limited)
        self.assertEqual(len(events), 1)
        cursor = json.loads((self.state / 'events-state.json').read_text())
        self.assertLessEqual(cursor['bytes_read'], 4096)
        with self.path.open('ab') as f:
            f.write(line(NOW + 1))
        events, _ = self.read(NOW + 1)
        self.assertEqual(len(events), 2)
        cursor = json.loads((self.state / 'events-state.json').read_text())
        self.assertLessEqual(cursor['bytes_read'], len(line(NOW + 1)) + 64)

    def test_real_process_finishes_with_three_gb_log(self):
        now = int(time.time())
        path = self.root / ('events-' + dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime('%Y-%m-%d') + '.jsonl')
        with path.open('wb') as f:
            f.seek(3 * 1024 ** 3)
            f.write(b'\n' + line(now))
        metrics = self.root / 'metrics'
        metrics.write_text('relay_sessions 100\n')
        script = os.environ.get('MONITOR_TEST_SCRIPT', str(Path(m.__file__)))
        def memory_limit():
            # The old implementation tries to allocate the entire sparse line.
            resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 ** 2, 256 * 1024 ** 2))
        out = subprocess.run([sys.executable, script, str(self.root), metrics.as_uri(), str(self.state)],
                             env=dict(os.environ, METRICS_B='', Z2K_MONITOR_NODE='0'),
                             capture_output=True, text=True, timeout=3,
                             preexec_fn=memory_limit if sys.platform == 'linux' else None)
        self.assertEqual(out.returncode, 0, out.stderr)
        status = json.loads((self.state / 'status.json').read_text())
        self.assertGreaterEqual(status['time'], now)
        self.assertIn('events_limited', status['alerts'])

    def test_dense_cold_start_and_reboot_under_service_memory_budget(self):
        # Sparse files do not exercise the Python-object expansion of real JSONL.
        now = int(time.time())
        path = self.root / ('events-' + dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime('%Y-%m-%d') + '.jsonl')
        record = line(now, detail='x' * 100, install='a' * 32, asn=12389)
        path.write_bytes(record * 150000)
        metrics = self.root / 'metrics'
        metrics.write_text('relay_sessions 100\n')
        def memory_limit():
            resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 ** 2, 64 * 1024 ** 2))
        for boot in range(2):
            # New interpreter, empty volatile runtime; persistent state survives.
            runtime = self.root / 'run'
            runtime.mkdir(exist_ok=True)
            (runtime / 'boot-id').write_text(str(boot))
            out = subprocess.run([sys.executable, m.__file__, str(self.root), metrics.as_uri(), str(self.state)],
                                 env=dict(os.environ, METRICS_B='', Z2K_MONITOR_NODE='0', TMPDIR=str(runtime)),
                                 capture_output=True, text=True, timeout=2,
                                 preexec_fn=memory_limit if sys.platform == 'linux' else None)
            self.assertEqual(out.returncode, 0, out.stderr)
            cursor = json.loads((self.state / 'events-state.json').read_text())
            self.assertLessEqual(cursor['bytes_read'], 8 * 1024 ** 2)
            if boot:
                self.assertLessEqual(cursor['bytes_read'], len(record) + 64)
            self.assertEqual(cursor['cursors'][path.name]['offset'], path.stat().st_size)
            self.assertLess((self.state / 'events-state.json').stat().st_size, 2 * 1024 ** 2)
            status = json.loads((self.state / 'status.json').read_text())
            self.assertGreaterEqual(status['time'], now)
            self.assertIn('events_limited', status['alerts'])
            (runtime / 'boot-id').unlink()
            runtime.rmdir()
            with path.open('ab') as f:
                f.write(record)

    def test_partial_utf8_line_is_read_once_after_completion(self):
        data = line(detail='ошибка')
        self.path.write_bytes(data[:-3])
        self.assertEqual(self.read()[0], [])
        with self.path.open('ab') as f:
            f.write(data[-3:])
        self.assertEqual(len(self.read()[0]), 1)
        self.assertEqual(len(self.read()[0]), 1)
        self.assertEqual(self.read(NOW + 301)[0], [])

    def test_midnight_and_compression_do_not_duplicate(self):
        yesterday = self.root / 'events-2026-11-11.jsonl'
        yesterday.write_bytes(line(NOW - 121))
        self.path.write_bytes(line())
        self.assertEqual(len(self.read()[0]), 2)
        with gzip.open(str(yesterday) + '.gz', 'wb') as f:
            f.write(yesterday.read_bytes() + line(NOW - 120))
        yesterday.unlink()
        self.assertEqual(len(self.read()[0]), 3)
        self.assertEqual(len(self.read()[0]), 3)

    def test_replaced_inode_and_copytruncate(self):
        self.path.write_bytes(line())
        self.assertEqual(len(self.read()[0]), 1)
        self.path.rename(self.path.with_suffix('.old'))
        self.path.write_bytes(line(NOW + 1))
        self.assertEqual(len(self.read(NOW + 1)[0]), 2)
        self.path.write_bytes(b'{}\n')
        self.read(NOW + 2)
        with self.path.open('ab') as f:
            f.write(line(NOW + 3))
        self.assertEqual(len(self.read(NOW + 3)[0]), 3)

    def test_copytruncate_regrown_beyond_previous_offset(self):
        self.path.write_bytes(line())
        self.assertEqual(len(self.read()[0]), 1)
        self.assertEqual(len(self.read()[0]), 1)  # idle sample retains anchor
        self.path.write_bytes(line(NOW + 1) + line(NOW + 2))
        self.assertEqual(len(self.read(NOW + 2)[0]), 3)

    def test_gzip_bomb_is_bounded_and_reports_gap(self):
        archive = self.root / 'events-2026-11-11.jsonl.gz'
        with gzip.open(archive, 'wb') as f:
            f.write(b' ' * (1024 * 1024) + b'\n' + line())
        events, limited = self.read()
        self.assertTrue(limited)
        self.assertEqual(events, [])
        self.assertLessEqual(json.loads((self.state / 'events-state.json').read_text())['bytes_read'], 4096)

    def test_oversized_gzip_header_is_rejected_before_decoding(self):
        archive = self.root / 'events-2026-11-11.jsonl.gz'
        # A legal gzip FNAME header may be arbitrarily long.
        data = gzip.compress(line())
        archive.write_bytes(data[:3] + bytes([data[3] | 8]) + data[4:10] + b'x' * 100000 + b'\0' + data[10:])
        events, limited = self.read()
        self.assertTrue(limited)
        self.assertEqual(events, [])
        self.assertLessEqual(json.loads((self.state / 'events-state.json').read_text())['bytes_read'], 4096)

    def test_small_gzip_plain_preference_and_malformed_records(self):
        yesterday = self.root / 'events-2026-11-11.jsonl'
        yesterday.write_bytes(line(NOW - 121))
        with gzip.open(str(yesterday) + '.gz', 'wb') as f:
            f.write(line(NOW - 122))
        self.path.write_bytes(b'[]\nnull\n{}\ninvalid\n' + line())
        self.assertEqual(len(self.read()[0]), 2)
        yesterday.unlink()
        # Compression of the same logical day must not count the stale copy.
        self.assertEqual(len(self.read()[0]), 2)


if __name__ == '__main__':
    unittest.main()
