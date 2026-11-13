"""Privileged Linux NFQUEUE acceptance; run in the archived Docker fixture.

Inputs are generated encrypted Initials, including a two-datagram ClientHello.
This checks delivery/attribution, not acceptance by an Internet QUIC server.
"""
import json
from pathlib import Path
import re
import socket
import subprocess as sp
import time

from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection
from scapy.all import IP, IPv6, UDP, rdpcap

ROOT = Path('/rig/z2k')
FORK = Path('/rig/fork')
OUT = Path('/rig/results')
OUT.mkdir(exist_ok=True)


def run(*args):
    return sp.check_output(args, text=True, stderr=sp.STDOUT)


def setup():
    for ns, iface, peer, net, n in [('lan', 'br0', 'cl', '10.77.1', 1),
                                     ('wan', 'ppp0', 'sv', '10.77.2', 2)]:
        run('ip', 'netns', 'add', ns)
        run('ip', 'link', 'add', iface, 'type', 'veth', 'peer', 'name', peer)
        run('ip', 'link', 'set', peer, 'netns', ns)
        run('ip', 'link', 'set', iface, 'up')
        run('ip', 'addr', 'add', net+'.1/24', 'dev', iface)
        run('ip', '-6', 'addr', 'add', f'fd77:{n}::1/64', 'dev', iface, 'nodad')
        for cmd in [('link', 'set', 'lo', 'up'), ('link', 'set', peer, 'up'),
                    ('addr', 'add', net+'.2/24', 'dev', peer),
                    ('route', 'add', 'default', 'via', net+'.1')]:
            run('ip', '-n', ns, *cmd)
        run('ip', '-n', ns, '-6', 'addr', 'add', f'fd77:{n}::2/64', 'dev', peer, 'nodad')
        run('ip', '-n', ns, '-6', 'route', 'add', 'default', 'via', f'fd77:{n}::1')
    run('sysctl', '-w', 'net.ipv4.ip_forward=1', 'net.ipv6.conf.all.forwarding=1')
    # No real endpoint is contacted. NAT mirrors the router's forwarding path.
    run('iptables', '-t', 'nat', '-A', 'POSTROUTING', '-o', 'ppp0', '-j', 'MASQUERADE')
    for ipt in ['iptables', 'ip6tables']:
        run(ipt, '-t', 'mangle', '-A', 'FORWARD', '-p', 'udp', '--dport', '443',
            '-j', 'NFQUEUE', '--queue-num', '200')


def initials(two):
    config = QuicConfiguration(is_client=True, server_name='www.google.com',
                               alpn_protocols=['h3'], quantum_readiness_test=two)
    q = QuicConnection(configuration=config)
    q.connect(('10.77.2.2', 443), now=time.time())
    data = [p for p, _ in q.datagrams_to_send(now=time.time())]
    assert len(data) == (2 if two else 1), [len(p) for p in data]
    return data


def base_args():
    args = [str(FORK/'nfq2/nfqws2'), '--qnum=200', '--debug=1']
    for lib in ['zapret-lib.lua', 'zapret-antidpi.lua', 'zapret-auto.lua']:
        args.append('--lua-init=@'+str(FORK/'lua'/lib))
    args.append('--lua-init=@'+str(ROOT/'files/lua/z2k-quic-silence.lua'))
    for name, filename in [('quic_google', 'quic_initial_www_google_com.bin'),
                           ('quic1', 'quic_1.bin'), ('quic4', 'quic_4.bin'),
                           ('quic5', 'quic_5.bin'), ('quic6', 'quic_6.bin')]:
        args.append('--blob='+name+':@'+str(ROOT/'files/fake'/filename))
    return args + ['--filter-udp=443', '--in-range=a', '--out-range=a']


def send(data, family, port):
    target = 'fd77:2::2' if family == 6 else '10.77.2.2'
    code = ('import socket,time; s=socket.socket(socket.AF_INET6 if '+str(family)+
            '==6 else socket.AF_INET,socket.SOCK_DGRAM); s.bind(("",'+str(port)+')); '+
            '; '.join('s.sendto(bytes.fromhex('+repr(p.hex())+'),('+repr(target)+',443)); time.sleep(.05)' for p in data))
    run('ip', 'netns', 'exec', 'lan', 'python3', '-c', code)


def payloads_of(packets):
    payloads = []
    for packet in packets:
        ip = packet[IP] if IP in packet else packet[IPv6] if IPv6 in packet else None
        if ip is not None and isinstance(ip.payload, UDP) and ip.payload.dport == 443:
            payloads.append(bytes(ip.payload.payload))
    return payloads


def pool():
    ini = (ROOT/'quic_strats.ini').read_text().split('[quic_autocircular]')[1]
    tokens = re.search(r'^args=(.*)', ini, re.M)[1].split()
    results = []
    for family in [4, 6]:
        for two in [False, True]:
            data = initials(two)
            for arm in range(1, 21):
                name = f'pool-{family}-{int(two)+1}-{arm}'
                actions = [re.sub(r':strategy=\d+$', '', t) for t in tokens
                           if t.endswith(':strategy='+str(arm))]
                logfile = OUT/(name+'.log')
                with logfile.open('w') as log:
                    p = sp.Popen(base_args()+['--payload=quic_initial']+actions,
                                 stdout=log, stderr=sp.STDOUT)
                    time.sleep(.15)
                    assert p.poll() is None, logfile.read_text()
                    cap = sp.Popen(['ip', 'netns', 'exec', 'wan', 'tcpdump', '--immediate-mode', '-U', '-ni', 'sv',
                                    '-w', str(OUT/(name+'.pcap'))],
                                   stdout=sp.DEVNULL, stderr=sp.DEVNULL)
                    time.sleep(.15)
                    try:
                        send(data, family, 20000+arm+100*int(two)+1000*(family==6))
                        time.sleep(.4)
                    finally:
                        p.terminate(); p.wait(3)
                        cap.terminate(); cap.wait(3)
                packets = rdpcap(str(OUT/(name+'.pcap')))
                payloads = payloads_of(packets)
                # udplen extends the original; IPv4 ipfrag is reassembled below.
                if family == 4 and arm == 19:
                    from scapy.layers.inet import defragment
                    packets = defragment(packets)
                    payloads = payloads_of(packets)
                if family == 6 and arm == 19:
                    from scapy.layers.inet6 import IPv6ExtHdrFragment, defragment6
                    fragments = {}
                    whole = []
                    for x in packets:
                        if IPv6ExtHdrFragment in x:
                            fragments.setdefault(x[IPv6ExtHdrFragment].id, []).append(x[IPv6])
                        else:
                            whole.append(x)
                    packets = whole + [IPv6(bytes(defragment6(v))) for v in fragments.values()]
                    payloads = payloads_of(packets)
                assert all(any(v.startswith(d) for v in payloads) for d in data), name+' original missing'
                assert any(not any(v.startswith(d) for d in data) for v in payloads), name+' fake missing'
                if arm == 20:
                    assert payloads.count(b'\x40'+b'\0'*619) == 6, name+' differs from nfqws1 default'
                if arm == 7:
                    ttls = [x[IPv6].hlim if IPv6 in x else x[IP].ttl for x in packets
                            if UDP in x and bytes(x[UDP].payload) not in data]
                    assert ttls and all(t <= 8 for t in ttls), (name, ttls)
                results.append({'case': name, 'packets': len(packets), 'ok': True})
                print(name, 'PASS', flush=True)
                (OUT/'pool.json').write_text(json.dumps(results, indent=2))


def attribution():
    results = []
    path = Path('/tmp/z2k-gvsub.json.neutral')
    for family in [4, 6]:
        key = socket.inet_pton(socket.AF_INET6 if family == 6 else socket.AF_INET,
                               'fd77:2::2' if family == 6 else '10.77.2.2').hex()
        for kind in ['silence', 'bad', 'reject', 'late-bad', 'late-reject']:
            path.write_text((kind+' '+key+'\n') if kind in ['bad', 'reject'] else '')
            name = f'attribution-{family}-{kind}'
            logfile = OUT/(name+'.log')
            ipt = 'ip6tables' if family == 6 else 'iptables'
            target = 'fd77:2::2' if family == 6 else '10.77.2.2'
            rule = ['-p', 'udp', '-d', target, '--dport', '443', '-j', 'REJECT',
                    '--reject-with', 'icmp6-port-unreachable' if family == 6 else 'icmp-port-unreachable']
            rejecting = False
            if kind == 'reject':
                run(ipt, '-A', 'FORWARD', *rule)
                rejecting = True
            with logfile.open('w') as log:
                args = base_args()+['--payload=all', '--lua-desync=circular:key=quic:fails=3:time=60:nld=2:failure_detector=z2k_fail_quic_silence',
                                    '--lua-desync=pass:strategy=1', '--lua-desync=pass:strategy=2']
                p = sp.Popen(args, stdout=log, stderr=sp.STDOUT)
                time.sleep(.2)
                assert p.poll() is None, logfile.read_text()
                cap = sp.Popen(['tcpdump', '--immediate-mode', '-U', '-ni', 'br0',
                                '-w', str(OUT/(name+'.pcap'))], stdout=sp.DEVNULL, stderr=sp.DEVNULL)
                time.sleep(.15)
                try:
                    send(initials(False), family, 30000+len(results))
                    if kind == 'late-reject':
                        run(ipt, '-A', 'FORWARD', *rule)
                        rejecting = True
                        send(initials(False), family, 30000+len(results))
                    if kind.startswith('late-'):
                        path.write_text(kind[5:]+' '+key+'\n')
                    time.sleep(5.3)
                finally:
                    p.terminate(); p.wait(3)
                    cap.terminate(); cap.wait(3)
                    if rejecting:
                        run(ipt, '-D', 'FORWARD', *rule)
            if rejecting:
                from scapy.layers.inet import ICMP
                from scapy.layers.inet6 import ICMPv6DestUnreach
                capture = rdpcap(str(OUT/(name+'.pcap')))
                assert any(ICMP in x or ICMPv6DestUnreach in x for x in capture), name+' no local ICMP reject'
            text = logfile.read_text()
            votes = len(re.findall(r'automate: failure counter [1-9]', text))
            # Keep the complete core log as evidence of exact vote accounting.
            if kind == 'silence':
                assert votes == 1, name+' did not produce exactly one vote'
            else:
                assert 'failure counter' not in text, name+' counted a neutral failure'
            results.append({'case': name, 'ok': True, 'votes': votes})
            (OUT/'attribution.json').write_text(json.dumps(results, indent=2))
            print(name, 'PASS', flush=True)
    path.unlink(missing_ok=True)


if __name__ == '__main__':
    setup()
    sink = sp.Popen(['ip', 'netns', 'exec', 'wan', 'python3', '-c',
        'import socket,select; a=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); a.bind(("10.77.2.2",443)); '
        'b=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM); b.bind(("fd77:2::2",443)); '
        'exec("while True:\n for s in select.select([a,b],[],[])[0]: s.recvfrom(65535)")'])
    time.sleep(.1)
    try:
        pool()
        attribution()
    finally:
        sink.terminate(); sink.wait(3)
