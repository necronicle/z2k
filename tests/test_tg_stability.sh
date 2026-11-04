#!/bin/sh
# Execute the real hook/watchdog branches with isolated OS boundaries.
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
export ROOT
python3 - <<'PY'
import http.server, os, subprocess, tempfile, threading
from pathlib import Path
root=Path(os.environ['ROOT'])
wd=(root/'files/z2k-tg-watchdog.sh').read_text()
hook=(root/'files/ndm/90-z2k-tg-redirect.sh').read_text()
passed=failed=0
def check(name, condition, detail=''):
 global passed,failed
 if condition: passed+=1; print('[PASS]',name)
 else: failed+=1; print('[FAIL]',name,detail)
def run(script, env=None):
 return subprocess.run(['sh','-c',script],capture_output=True,text=True,env=env)
with tempfile.TemporaryDirectory() as td:
 p=Path(td)
 # The network boundary models v4 present/missing, v6 missing, and live flows.
 stub='''z2k_tg_udp_down() { :; }
z2k_tg_rule_present() { test "$V4" = present; }
z2k_tg_rule6_present() { return 1; }
z2k_tg_ensure_rules6() { echo REPAIR6; }
z2k_tg_ensure_rules() { echo REPAIR4; z2k_tg_ensure_rules6; }
z2k_tg_remove_legacy_rules() { :; }
z2k_tg_flush_conntrack() { echo DELETE_LIVE_FLOWS; }
logger() { :; }
'''
 (p/'lib').write_text(stub)
 block=wd[wd.index('TG_REDIR_LIB='):wd.index('# 2) Active end-to-end probe')]
 block=block.replace('/opt/zapret2/z2k-tg-redirect.sh',str(p/'lib'))
 for v4 in ['present','missing']:
  r=run('V4='+v4+'\n'+block)
  check('watchdog repairs IPv6 with IPv4 '+v4, r.returncode==0 and 'REPAIR6' in r.stdout,r.stderr+r.stdout)
  check('watchdog preserves live flows with IPv4 '+v4,'DELETE_LIVE_FLOWS' not in r.stdout,r.stdout)
 body=hook.split('. "$LIB"',1)[1]
 for v4 in ['present','missing']:
  r=run(stub+'\nV4='+v4+'\n'+body)
  check('NDM repair preserves live flows with IPv4 '+v4,r.returncode==0 and 'DELETE_LIVE_FLOWS' not in r.stdout,r.stdout+r.stderr)
 # Exercise curl itself: HTTP failure is different from a broken transport.
 class Handler(http.server.BaseHTTPRequestHandler):
  code=403
  def do_GET(self): self.send_response(self.code); self.end_headers()
  def log_message(self,*args): pass
 server=http.server.HTTPServer(('127.0.0.1',0),Handler)
 threading.Thread(target=server.serve_forever,daemon=True).start()
 probe=wd[wd.index('# 2) Active end-to-end probe'):]
 env=os.environ.copy(); env['NO_PROXY']='127.0.0.1'; env['no_proxy']='127.0.0.1'
 setup=f'''STATE='{p}/failures'
RSTATE='{p}/restarts'
PROBE_RESOLVE_IP=127.0.0.1
PROBE_URL=http://127.0.0.1:{server.server_port}/
restart_tunnel() {{ echo RESTART >> '{p}/called'; }}
logger() {{ :; }}
'''
 for code in [200,403,500]:
  Handler.code=code
  (p/'failures').write_text('2\n'); (p/'restarts').write_text('2 1\n')
  r=run(setup+probe,env)
  check('HTTP '+str(code)+' keeps tunnel and resets failures',r.returncode==0 and (p/'failures').read_text().strip()=='0' and not (p/'called').exists() and not (p/'restarts').exists(),r.stderr+r.stdout)
 server.shutdown(); server.server_close()
 (p/'called').unlink(missing_ok=True); (p/'failures').write_text('0\n')
 for n in range(1,4):
  r=run(setup+probe,env)
  check('transport failure '+str(n)+' respects three-failure threshold',(p/'called').exists()==(n==3),r.stderr+r.stdout)
print(f'\nPASSED: {passed}\nFAILED: {failed}')
raise SystemExit(bool(failed))
PY
