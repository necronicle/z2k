import json, os, pathlib, subprocess, sys, tempfile, fcntl
root=pathlib.Path(sys.argv[1])
script=root/'files/z2k-redirector-ip-refresh.sh'
if not script.exists():
 print('[FAIL] redirector refresher is missing');sys.exit(1)
with tempfile.TemporaryDirectory() as td:
 p=pathlib.Path(td);(p/'bin').mkdir();(p/'lists').mkdir()
 (p/'lists/google-ranges.txt').write_text('142.250.0.0/15\n192.178.0.0/15\n')
 (p/'config').write_text('Z2K_RESOLVE_SECRET=test\n')
 (p/'bin/curl').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_DIR/curl-log"\n[ "$FETCH_FAIL" = 1 ] && exit 22\ncat "$TEST_DIR/response"\n')
 (p/'bin/ndmc').write_text('''#!/usr/bin/env python3
import os,sys,json,pathlib
p=pathlib.Path(os.environ['TEST_DIR']); f=p/'records'; data=json.loads(f.read_text());cmd=sys.argv[2].split()
with (p/'commands').open('a') as out:out.write(' '.join(cmd)+'\\n')
if cmd==['show','running-config']:
 for host,ips in data.items():
  for ip in ips:print('ip host',host,ip)
elif cmd[:2]==['ip','host']:
 if os.environ.get('FAIL_IP')==cmd[3]:sys.exit(1)
 if cmd[3] not in data.setdefault(cmd[2],[]):data[cmd[2]].append(cmd[3])
elif cmd[:3]==['no','ip','host']:
 if os.environ.get('FAIL_DELETE')==cmd[4]:sys.exit(1)
 if cmd[4] in data.get(cmd[3],[]):data[cmd[3]].remove(cmd[4])
elif cmd==['system','configuration','save'] and os.environ.get('FAIL_SAVE')=='1':
 if not (p/'save-failed').exists():(p/'save-failed').touch();sys.exit(1)
f.write_text(json.dumps(data))
''')
 (p/'bin/flock').write_text("#!/usr/bin/env python3\nimport fcntl,sys\ntry:fcntl.flock(int(sys.argv[2]),fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError:sys.exit(1)\n")
 for f in (p/'bin').iterdir():f.chmod(0o755)
 env=dict(os.environ,Z2K_STUB_PATH=str(p/'bin'),TEST_DIR=td,ZAPRET2_DIR=td,CONFIG_FILE=str(p/'config'))
 host='redirector.googlevideo.com';initial={host:['142.251.1.1'],'other.example':['1.1.1.1']}
 def run(response,extra=None,rc=0,reset=True,args=()):
  if reset:(p/'records').write_text(json.dumps(initial))
  (p/'response').write_text(response);(p/'commands').write_text('');(p/'curl-log').write_text('')
  result=subprocess.run(['sh',str(script),*args],env=dict(env,**(extra or {})),capture_output=True)
  assert result.returncode==rc, (result.returncode,rc,result.stderr.decode())
  return json.loads((p/'records').read_text())
 ips=['142.251.13.'+str(i) for i in range(100,124)]
 valid=json.dumps({'results':{host:ips}})
 assert run(valid)=={host:ips,'other.example':['1.1.1.1']},'must apply all24 without probing'
 assert len((p/'curl-log').read_text().splitlines())==1,'must fetch only, never probe redirector'
 assert run(valid,reset=False)=={host:ips,'other.example':['1.1.1.1']}
 assert all(line.startswith('show ') for line in (p/'commands').read_text().splitlines()),'idempotent run mutated config'
 for bad in ['{"results":{"redirector.googlevideo.com":["142.\n251.13.100"]}}',json.dumps({'results':{host:['142.251.13. 100']}}), '', '{}',json.dumps({'results':{host:[]}}),json.dumps({'results':{host:['1.1.1.1']}}),json.dumps({'results':{host:['142.251.0.999']}}),json.dumps({'results':{'evil.test':ips}}),json.dumps({'results':{host:ips+['142.251.2.'+str(i) for i in range(20)]}})]:
  assert run(bad,rc=1)==initial,'invalid response changed records: '+bad
 assert run(valid,{'FETCH_FAIL':'1'},rc=1)==initial,'failed fetch changed records'
 assert run(valid,{'FAIL_IP':ips[3]},rc=1)==initial,'partial add not rolled back'
 assert run(valid,{'FAIL_DELETE':initial[host][0]},rc=1)==initial,'delete failure not rolled back'
 assert run(valid,{'FAIL_SAVE':'1'},rc=1)==initial,'save failure not rolled back'
 with (p/'.redirector-refresh.flock').open('w') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  assert run(valid)==initial and not (p/'curl-log').read_text(),'live lock ignored'
 assert run(valid)=={host:ips,'other.example':['1.1.1.1']},'released lock not recovered'
 (p/'bin/sleep').write_text('#!/bin/sh\n[ "$MARK_SUCCESS" = 1 ] && printf "p-test\\n" > "$TEST_DIR/tag"\nexit 0\n')
 (p/'bin/sleep').chmod(0o755)
 (p/'tag').write_text('p-old')
 assert run(valid,args=('--after-update','p-test',str(p/'tag')))==initial and not (p/'curl-log').read_text(),'failed update mutated DNS'
 assert run(valid,{'MARK_SUCCESS':'1'},args=('--after-update','p-test',str(p/'tag')))=={host:ips,'other.example':['1.1.1.1']},'successful update did not activate DNS'
 (p/'config').write_text('Z2K_REDIRECTOR_DNS=0\n')
 assert run(valid)==initial and not (p/'curl-log').read_text(),'opt out ignored'
 print('[PASS] redirector24, no probes, validation, retention, rollback, opt-out')
