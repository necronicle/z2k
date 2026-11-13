#!/usr/bin/env python3
"""Execute shipped upgrade cleanup against stale rules and real lease files."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['STATE'])
s = json.loads(p.read_text())
fam = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
table = a[1]; op = a[2]; chain = a[3]
k = fam + '/' + table
rules = s[k]
if op == '-D':
    rule = a[3:]
    if rule not in rules: sys.exit(1)
    rules.remove(rule)
elif op == '-F':
    rules[:] = [r for r in rules if r[0] != chain]
elif op == '-X':
    if any(r[0] == chain or r[-1] == chain for r in rules): sys.exit(2)
    s['chains'].remove(k + '/' + chain) if k + '/' + chain in s['chains'] else None
else: sys.exit(3)
p.write_text(json.dumps(s))
'''


def function(name):
    text = (ROOT / 'files/S99zapret2.new').read_text()
    start = text.index(name + '()\n')
    return text[start:text.index('\n}', start) + 2] + '\n'


class Retirement(unittest.TestCase):
    def test_upgrade_removes_legacy_rules_and_lease_in_both_families(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            state = {'chains': []}
            native = ['FORWARD', '-p', 'tcp', '-j', 'ACCEPT']
            for fam in ('iptablesw', 'ip6tablesw'):
                p = base / fam
                p.write_text(MOCK.replace('/usr/bin/env python3', os.sys.executable))
                p.chmod(0o755)
                for table, parent, chain in (
                    ('nat', 'PREROUTING', 'Z2K_GVSUB'),
                    ('mangle', 'PREROUTING', 'Z2K_GVSUB'),
                    ('filter', 'FORWARD', 'Z2K_GVSUB_Q'),
                ):
                    key = fam + '/' + table
                    state[key] = [[parent, '-j', chain]] * 2 + [
                        [chain, '-p', 'udp', '-j', 'REJECT'], native]
                    state['chains'].append(key + '/' + chain)
            path = base / 'state'
            path.write_text(json.dumps(state))
            lease = base / 'lease'
            for suffix in ('', '.tmp', '.attempt4', '.attempt6'):
                Path(str(lease) + suffix).write_text('stale')
            script = function('z2k_gvsub_legacy_purge').replace('/tmp/z2k-provider-cache.lease', str(lease))
            script += function('z2k_gvsub_fw_stop')
            script += '''
Z2K_GVSUB_CHAIN=Z2K_GVSUB
DISABLE_IPV6=1
z2k_gvsub_dns_rule() { return 1; }
z2k_gvsub_fw_stop
z2k_gvsub_fw_stop
'''
            subprocess.run(['sh', '-eu', '-c', script], check=True,
                           env=dict(os.environ, PATH=tmp + ':' + os.environ['PATH'], STATE=str(path)))
            final = json.loads(path.read_text())
            self.assertEqual(final.pop('chains'), [])
            self.assertTrue(all(rows == [native] for rows in final.values()))
            self.assertFalse(list(base.glob('lease*')))


if __name__ == '__main__':
    unittest.main(verbosity=2)
