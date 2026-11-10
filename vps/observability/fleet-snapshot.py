#!/usr/bin/env python3
"""Read-only relay baseline. Run on the VPS; credentials and identities stay local."""
import argparse
import collections
import datetime
import json
import hashlib
from pathlib import Path
import subprocess
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--unit', default='z2k-relay@b')
args = parser.parse_args()
properties = subprocess.check_output(
    ['systemctl', 'show', args.unit, '-p', 'MainPID', '-p', 'NRestarts',
     '-p', 'ActiveState', '-p', 'ExecMainStartTimestamp'], text=True)
unit = dict(line.split('=', 1) for line in properties.splitlines() if '=' in line)
pid = int(unit['MainPID'])
if pid <= 0 or unit.get('ActiveState') != 'active':
    raise SystemExit('Selected relay is not active')
proc = Path('/proc') / str(pid)
argv = (proc / 'cmdline').read_bytes().decode().split('\0')
environ = dict(item.split('=', 1) for item in
               (proc / 'environ').read_bytes().decode().split('\0') if '=' in item)

def flag(name, default=''):
    for i, value in enumerate(argv):
        for prefix in ('--' + name, '-' + name):
            if value.startswith(prefix + '='):
                return value.split('=', 1)[1]
            if value == prefix and i + 1 < len(argv):
                return argv[i + 1]
    return default

address = flag('admin-addr')
if not address.startswith(('127.0.0.1:', '[::1]:')):
    raise SystemExit('Expected loopback admin endpoint')
credential = flag('admin-token')
if credential.startswith('env:'):
    credential = environ[credential[4:]]
request = urllib.request.Request('http://' + address + '/admin/installs',
                                 headers={'X-Z2K-Admin': credential})
with urllib.request.urlopen(request, timeout=10) as response:
    installs = json.load(response)
with urllib.request.urlopen('http://' + address + '/metrics', timeout=10) as response:
    metrics = response.read().decode()
rows = installs['installs']
live = [row for row in rows if row['Live'] > 0]
memory = {}
for line in Path('/proc/meminfo').read_text().splitlines():
    key, value = line.split(':', 1)
    if key in ('MemTotal', 'MemAvailable', 'SwapTotal', 'SwapFree'):
        memory[key + '_KiB'] = int(value.split()[0])
status = (proc / 'status').read_text().splitlines()
rss = next(int(line.split()[1]) for line in status if line.startswith('VmRSS:'))
network = {}
for line in Path('/proc/net/dev').read_text().splitlines()[2:]:
    name, values = line.split(':', 1)
    fields = values.split()
    if name.strip() != 'lo':
        network[name.strip()] = {'rx_bytes': int(fields[0]), 'tx_bytes': int(fields[8])}
print(json.dumps({
    'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'unit': unit, 'memory': memory, 'relay_rss_KiB': rss,
    'loadavg': Path('/proc/loadavg').read_text().strip(), 'network': network,
    'live_installations': len(live),
    'live_installation_fingerprints': sorted(hashlib.sha256(row['ID'].encode()).hexdigest()[:16] for row in live), 'authenticated_sessions': installs['live_now'],
    'session_count_histogram_per_live_installation': dict(collections.Counter(str(row['Live']) for row in live)),
    'per_install_session_limit': installs['max_sessions'],
    'metrics_prometheus': metrics,
    'coverage_notes': [
        'Installations and TCP/relay sessions are not counts of people.',
        'Build/architecture inventory is not exposed by the current admin API.',
        'Counters are cumulative; compare deltas only within the same process lifetime.',
        'This baseline is not proof that a new client version works across the fleet.'
    ]
}, ensure_ascii=False, indent=2))
