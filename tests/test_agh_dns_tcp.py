#!/usr/bin/env python3
"""Execute the production shell wire codec; nc fixture replaces only the socket.
The sandbox forbids bind(), so actual localhost transport is a live-test item.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'files/z2k-agh-sync.sh').read_text()
function = source[source.index('    tcp_query() {'):source.index('    query() {')]
NC = r'''#!/usr/bin/python3
import os, socket, struct, sys
assert sys.argv[1:] == ['-w', '3', '127.0.0.1', '5300'], sys.argv
packet = sys.stdin.buffer.read()
length = struct.unpack('!H', packet[:2])[0]
request = packet[2:]
assert length == len(request) == 26, packet
assert request[12:] == b'\x03www\x04test\x00\x00\x01\x00\x01', request
addresses = [] if os.environ['CASE'] == 'nxdomain' else ['1.2.3.4', '5.6.7.8']
rcode = 3 if os.environ['CASE'] == 'nxdomain' else 0
answers = b''.join(b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 60, 4)
                   + socket.inet_aton(ip) for ip in addresses)
reply = request[:2] + struct.pack('!HHHHH', 0x8180 | rcode, 1, len(addresses), 0, 0) + request[12:] + answers
wire = struct.pack('!H', len(reply)) + reply
sys.stdout.buffer.write(wire[:-1] if os.environ['CASE'] == 'truncated' else wire)
'''
with tempfile.TemporaryDirectory() as tmp:
    nc = Path(tmp) / 'nc'
    nc.write_text(NC)
    nc.chmod(0o755)
    script = Path(tmp) / 'query.sh'
    script.write_text(function + '\ntcp_query www.test\n')
    for case in ('multi', 'nxdomain', 'truncated'):
        result = subprocess.run([os.environ.get('Z2K_TEST_SH', 'sh'), str(script)],
                                env={**os.environ, 'PATH': tmp + ':' + os.environ['PATH'],
                                     'addr': '127.0.0.1', 'port': '5300', 'CASE': case},
                                text=True, capture_output=True, timeout=10)
        if case == 'truncated':
            assert result.returncode != 0, result
        else:
            assert result.returncode == 0, (case, result)
            expected = {'1.2.3.4', '5.6.7.8'} if case == 'multi' else set()
            assert set(result.stdout.splitlines()) == expected, result
print('PASS: TCP DNS request, compressed multi-A, NXDOMAIN and truncated reply')
