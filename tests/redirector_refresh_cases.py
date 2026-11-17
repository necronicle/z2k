"""Exercise retirement of the shell worker with a recording NDM boundary."""
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
script = root / 'files/z2k-redirector-ip-refresh.sh'
host = 'redirector.googlevideo.com'
with tempfile.TemporaryDirectory() as td:
    p = pathlib.Path(td)
    (p / 'bin').mkdir()
    (p / 'lists').mkdir()
    (p / 'lists/google-ranges.txt').write_text('142.250.0.0/15\n')
    initial = {host: ['142.251.14.100', '142.251.20.100', '2001:4860::1'],
               'scontent.cdninstagram.com': ['57.144.112.192'],
               'other.googlevideo.com': ['142.251.1.2'],
               host + '.example': ['192.0.2.1']}
    (p / 'bin/ndmc').write_text('''#!/usr/bin/env python3
import os,sys,json,pathlib
p=pathlib.Path(os.environ['TEST_DIR']);f=p/'records';data=json.loads(f.read_text());cmd=sys.argv[2].split()
with (p/'commands').open('a') as out:out.write(' '.join(cmd)+'\\n')
if cmd==['show','running-config']:
 if os.environ.get('FAIL_READ')=='1':sys.exit(1)
 if os.environ.get('EMPTY_READ')=='1':sys.exit(0)
 print('system')
 for h,ips in data.items():
  for ip in ips:print('ip host',h,ip)
elif cmd[:2]==['ip','host']:
 if cmd[3] not in data.setdefault(cmd[2],[]):data[cmd[2]].append(cmd[3])
elif cmd[:3]==['no','ip','host']:
 if os.environ.get('FAIL_DELETE')==cmd[4]:sys.exit(1)
 if cmd[4] in data.get(cmd[3],[]):data[cmd[3]].remove(cmd[4])
elif cmd==['system','configuration','save'] and os.environ.get('FAIL_SAVE')=='1':
 if not (p/'save-failed').exists():(p/'save-failed').touch();sys.exit(1)
else:
 if cmd!=['system','configuration','save']:sys.exit(2)
f.write_text(json.dumps(data))
''')
    (p / 'bin/flock').write_text('''#!/usr/bin/env python3
import fcntl,sys
try:fcntl.flock(int(sys.argv[-1]),fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:sys.exit(1)
''')
    for tool in ['curl', 'openssl', 'opkg']:
        (p / 'bin' / tool).write_text('#!/bin/sh\necho unexpected >> "$TEST_DIR/network"\nexit 90\n')
    for f in (p / 'bin').iterdir():
        f.chmod(0o755)
    env = dict(os.environ, Z2K_STUB_PATH=str(p/'bin'), TEST_DIR=td,
               ZAPRET2_DIR=td, CONFIG_FILE=str(p/'config'),
               Z2K_AU_LOG_FILE=str(p/'log'))
    def run(extra=None, rc=0, reset=True, args=()):
        if reset:
            (p/'records').write_text(json.dumps(initial))
        (p/'commands').write_text('')
        result = subprocess.run(['sh', str(script), *args], env=dict(env, **(extra or {})),
                                capture_output=True, text=True)
        assert not (p/'network').exists(), 'retirement must not fetch, probe or install packages'
        assert result.returncode == rc, (result.returncode, rc, result.stdout, result.stderr)
        return json.loads((p/'records').read_text())
    expected = dict(initial, **{host: []})
    for flag in ['', 'Z2K_REDIRECTOR_DNS=0\n', 'Z2K_REDIRECTOR_DNS=1\n']:
        (p/'config').write_text(flag)
        assert run() == expected, 'remove legacy redirector records regardless of old toggle'
        assert 'system configuration save' in (p/'commands').read_text()
        assert run(reset=False) == expected
        assert 'system configuration save' not in (p/'commands').read_text(), 'repeat must not save'
    for extra in [{'FAIL_READ':'1'}, {'EMPTY_READ':'1'},
                  {'FAIL_DELETE':initial[host][1]}, {'FAIL_SAVE':'1'}]:
        restored = run(extra, rc=1)
        assert {h: set(ips) for h, ips in restored.items()} == {h: set(ips) for h, ips in initial.items()}, \
            ('failed cleanup must preserve or restore every record', extra, restored)
    with (p/'.redirector-refresh.flock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX|fcntl.LOCK_NB)
        assert run(rc=1) == initial, 'legacy writer lock must protect cleanup'
    (p/'bin/sleep').write_text('#!/bin/sh\n[ "$MARK_SUCCESS" = 1 ] && printf "p-test\\n" > "$TEST_DIR/tag"\nexit 0\n')
    (p/'bin/sleep').chmod(0o755)
    (p/'tag').write_text('p-old')
    assert run(args=('--after-update','p-test',str(p/'tag'))) == initial
    assert not (p/'commands').read_text(), 'rollback must not mutate DNS'
    assert run({'MARK_SUCCESS':'1'}, args=('--after-update','p-test',str(p/'tag'))) == expected
    print('[PASS] redirector retirement: exact host, old toggles, no network, rollback, lock, update marker')
