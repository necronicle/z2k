#!/usr/bin/env python3
"""Execute shipped builders/cleanup with real transaction helpers and stateful iptables."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
fam = '6' if '6' in pathlib.Path(sys.argv[0]).name else '4'
p = pathlib.Path(os.environ['STATE'] + fam)
rules = json.loads(p.read_text()) if p.exists() else []
cp = pathlib.Path(str(p) + '.chains')
chains = json.loads(cp.read_text()) if cp.exists() else []
a = sys.argv[1:]
if '-save' in sys.argv[0]:
    for c in chains: print(':' + c + ' - [0:0]')
    for r in rules:
        print('-A ' + ' '.join('"'+v+'"' if v == 'z2k-inbound-mss' else v for v in r))
    sys.exit(0)
a = [v for v in a if v != '-w']
if '-t' in a:
    i = a.index('-t'); del a[i:i+2]
op = a.pop(0)
if 'comment' in a and os.environ.get('NO_COMMENT') == '1': sys.exit(2)
if op == '-C': sys.exit(0 if a in rules else 1)
if op == '-D':
    if a not in rules: sys.exit(1)
    rules.remove(a)
elif op in ('-I', '-A'):
    if 'TCPMSS' in a and os.environ.get('NO_MSS') == '1': sys.exit(2)
    if op == '-I': rules.insert(0, a)
    else: rules.append(a)
elif op == '-N':
    if a[0] in chains: sys.exit(1)
    chains.append(a[0])
elif op == '-F':
    rules = [r for r in rules if r[0] != a[0]]
elif op == '-X':
    if a[0] not in chains: sys.exit(1)
    if any(r[0] == a[0] or r[-1] == a[0] for r in rules): sys.exit(2)
    chains.remove(a[0])
else: sys.exit(3)
p.write_text(json.dumps(rules))
cp.write_text(json.dumps(chains))
'''


def function(name):
    text = (ROOT / 'files/S99zapret2.new').read_text()
    start = text.index(name + '()\n')
    return text[start:text.index('\n}', start) + 2] + '\n'


class InboundMSS(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        for cmd in ('iptables', 'ip6tables', 'iptables-save', 'ip6tables-save'):
            p = self.base / cmd
            p.write_text(MOCK.replace('/usr/bin/env python3', os.sys.executable))
            p.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.base) + ':' + os.environ['PATH'],
                        STATE=str(self.base / 'state'),
                        Z2K_IPT_LOCK=str(self.base / 'lock'))
        self.prefix = f'. "{ROOT}/common/ipt.sh"\n' + '''
on_off_function() { local add="$1" del="$2" on="$3"; shift 3; if [ "$on" = 1 ]; then "$add" "$@"; else "$del" "$@"; fi; }
ipt_print_op() { :; }
logger() { printf '%s\\n' "$*" >> "$STATE.log"; }
DISABLE_IPV4=0 DISABLE_IPV6=0 Z2K_CONNMARK_OK4=0 Z2K_CONNMARK_OK6=0
FW_EXTRA_PRE= FW_EXTRA_POST= IPSET_EXCLUDE= IPSET_EXCLUDE6= QNUM=200
z2k_wan_ifaces() { echo ppp1; }
''' + ''.join(function(n) for n in (
            'z2k_inbound_forward_tx', 'z2k_inbound_forward', '_fw_nfqws_pre4',
            '_fw_nfqws_pre6', 'z2k_sweep_stale_wan_nfqueue',
            'z2k_sweep_orphan_nfqueue', 'stop_fw'))
        # Only unrelated platform operations are stubbed; stop_fw and its sweep run.
        self.prefix += '\n'.join(n + '() { :; }' for n in (
            'linux_fwtype', 'z2k_rst_filter_purge', 'z2k_connmark_init',
            'z2k_gvsub_fw_stop', 'z2k_udp_masquerade_fix_stop',
            'z2k_policy_connmark_stop', 'z2k_conntrack_tune_stop',
            'zapret_unapply_firewall')) + '\nZAPRET2_DIR=/nonexistent\n'

    def run_shell(self, script):
        subprocess.run(['sh', '-c', self.prefix + script], env=self.env,
                       check=True, capture_output=True, text=True)

    def rules(self, fam):
        return json.loads((self.base / ('state' + str(fam))).read_text())

    def apply(self):
        return '''for fam in 4 6; do
_fw_nfqws_pre$fam 1 '-p tcp --dport 443' 200 'ppp0 ppp1'
_fw_nfqws_pre$fam 1 '-p tcp --dport 80' 200 'ppp0 ppp1'
_fw_nfqws_pre$fam 1 '-p udp --dport 443' 200 'ppp0 ppp1'
done\n'''

    def check_order(self, fam):
        rows = self.rules(fam)
        for iface in ('ppp0', 'ppp1'):
            clamp = [i for i, r in enumerate(rows) if r[0] == 'FORWARD' and iface in r and r[-1] == 'Z2K_MSS']
            queues = [i for i, r in enumerate(rows) if r[0] == 'FORWARD' and iface in r and 'tcp' in r and 'NFQUEUE' in r]
            self.assertEqual(len(clamp), 1)
            self.assertEqual(len(queues), 2)
            self.assertLess(clamp[0], min(queues))
            clamps = [r for r in rows if r[0] == 'Z2K_MSS' and iface in r and 'TCPMSS' in r]
            self.assertEqual(len(clamps), 1)
            self.assertEqual(clamps[0][clamps[0].index('--tcp-flags') + 1:][:2], ['SYN,RST', 'SYN'])
        self.assertFalse(any('TCPMSS' in r and r[0] != 'Z2K_MSS' for r in rows))

    def test_order_repeat_and_partial_hook_repair(self):
        self.run_shell(self.apply())
        for fam in (4, 6):
            self.check_order(fam)
        old = {f: sorted(self.rules(f)) for f in (4, 6)}
        self.run_shell(self.apply())
        for fam in (4, 6):
            self.check_order(fam)
            self.assertEqual(old[fam], sorted(self.rules(fam)))
            # Firmware removed TCP queues while leaving the existing clamp.
            p = self.base / ('state' + str(fam))
            p.write_text(json.dumps([r for r in self.rules(fam) if not ('NFQUEUE' in r and 'tcp' in r)]))
        self.run_shell(self.apply())
        for fam in (4, 6):
            self.check_order(fam)

    def test_stop_and_stale_wan_preserve_native_rules(self):
        self.run_shell(self.apply() + '''
iptables -I FORWARD -p tcp -j TCPMSS --clamp-mss-to-pmtu
ip6tables -I FORWARD -p tcp -j TCPMSS --clamp-mss-to-pmtu
z2k_sweep_stale_wan_nfqueue
''')
        for fam in (4, 6):
            self.assertFalse(any('ppp0' in r for r in self.rules(fam)))
            self.assertTrue(any(r[-1] == 'Z2K_MSS' and 'ppp1' in r for r in self.rules(fam)))
        self.run_shell('stop_fw\nstop_fw\n')
        for fam in (4, 6):
            self.assertEqual(self.rules(fam), [['FORWARD', '-p', 'tcp', '-j', 'TCPMSS', '--clamp-mss-to-pmtu']])

    def test_no_comment_fallback_stop_and_native_rules(self):
        native4 = [
            ['FORWARD', '-i', 'ppp0', '-p', 'tcp', '--tcp-flags', 'SYN,RST', 'SYN', '-j', 'TCPMSS', '--clamp-mss-to-pmtu'],
            ['FORWARD', '-o', 'ppp0', '-p', 'tcp', '--tcp-flags', 'SYN,RST', 'SYN', '-j', 'TCPMSS', '--clamp-mss-to-pmtu'],
        ]
        native6 = [['FORWARD', '-p', 'tcp', '--tcp-flags', 'SYN,RST', 'SYN', '-j', 'TCPMSS', '--clamp-mss-to-pmtu']]
        for fam, rows in ((4, native4), (6, native6)):
            (self.base / ('state' + str(fam))).write_text(json.dumps(rows))
        self.env['NO_COMMENT'] = '1'
        self.run_shell(self.apply() + self.apply())
        for fam, native in ((4, native4), (6, native6)):
            rows = self.rules(fam)
            for iface in ('ppp0', 'ppp1'):
                jumps = [i for i, r in enumerate(rows) if r[0] == 'FORWARD' and iface in r and r[-1] == 'Z2K_MSS']
                queues = [i for i, r in enumerate(rows) if r[0] == 'FORWARD' and iface in r and 'tcp' in r and 'NFQUEUE' in r]
                self.assertEqual(len(jumps), 1)
                self.assertLess(jumps[0], min(queues))
                clamps = [r for r in rows if r[0] == 'Z2K_MSS' and iface in r and 'TCPMSS' in r]
                self.assertEqual(len(clamps), 1)
                self.assertNotIn('comment', clamps[0])
            self.assertEqual([r for r in rows if r[0] == 'FORWARD' and 'TCPMSS' in r], native)
        self.assertFalse((self.base / 'state.log').exists())
        self.run_shell('z2k_sweep_stale_wan_nfqueue\n')
        for fam in (4, 6):
            self.assertFalse(any('ppp0' in r and (r[0] == 'Z2K_MSS' or r[-1] == 'Z2K_MSS') for r in self.rules(fam)))
        self.run_shell('stop_fw\nstop_fw\n')
        self.assertEqual(self.rules(4), native4)
        self.assertEqual(self.rules(6), native6)
        for fam in (4, 6):
            self.assertEqual(json.loads((self.base / ('state' + str(fam) + '.chains')).read_text()), [])

    def test_no_comment_explicit_delete(self):
        self.env['NO_COMMENT'] = '1'
        self.run_shell(self.apply() + '''for fam in 4 6; do
_fw_nfqws_pre$fam 0 '-p tcp --dport 443' 200 'ppp0 ppp1'
_fw_nfqws_pre$fam 0 '-p tcp --dport 80' 200 'ppp0 ppp1'
done
''')
        for fam in (4, 6):
            self.assertFalse(any('TCPMSS' in r or 'Z2K_MSS' in r or 'tcp' in r for r in self.rules(fam)))
            self.assertEqual(json.loads((self.base / ('state' + str(fam) + '.chains')).read_text()), [])

    def test_upgrade_sweep_removes_legacy_marked_forward_clamp(self):
        self.run_shell('''for fam in iptables ip6tables; do
$fam -I FORWARD -i ppp0 -p tcp --tcp-flags SYN,RST SYN -m comment --comment z2k-inbound-mss -j TCPMSS --clamp-mss-to-pmtu
done
''' + self.apply() + 'z2k_sweep_orphan_nfqueue\n')
        for fam in (4, 6):
            self.assertEqual(self.rules(fam), [])

    def test_no_tcpmss_is_nonfatal_and_logged(self):
        self.env['NO_MSS'] = '1'
        self.run_shell('''
_fw_nfqws_pre4 1 '-p tcp --dport 443' 200 ppp0 || exit 10
_fw_nfqws_pre6 1 '-p tcp --dport 443' 200 ppp0 || exit 11
''')
        for fam in (4, 6):
            self.assertEqual(sum('NFQUEUE' in r for r in self.rules(fam)), 2)
            self.assertFalse(any('TCPMSS' in r for r in self.rules(fam)))
        self.assertEqual(len((self.base / 'state.log').read_text().splitlines()), 2)

    def test_udp_only_and_explicit_delete(self):
        self.run_shell('''
for fam in 4 6; do
_fw_nfqws_pre$fam 1 '-p udp --dport 443' 200 ppp0
done
''')
        for fam in (4, 6):
            self.assertFalse(any('TCPMSS' in r for r in self.rules(fam)))
        self.run_shell(self.apply() + '''
for fam in 4 6; do
_fw_nfqws_pre$fam 0 '-p tcp --dport 443' 200 'ppp0 ppp1'
_fw_nfqws_pre$fam 0 '-p tcp --dport 80' 200 'ppp0 ppp1'
done
''')
        for fam in (4, 6):
            self.assertFalse(any('TCPMSS' in r or 'tcp' in r for r in self.rules(fam)))


if __name__ == '__main__':
    unittest.main(verbosity=2)
