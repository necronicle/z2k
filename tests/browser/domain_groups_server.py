# Fixture server for tests/browser/domain_groups.mjs. /state and /pools are
# canned (the engine is not running here); /domain-groups goes through the real
# webpanel/cgi/api.sh against a temporary lists directory, never the router's.
import http.server,os,pathlib,subprocess,urllib.parse,tempfile,json,time,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
DATA=pathlib.Path(tempfile.mkdtemp(prefix='z2k-ug-'))
(DATA/'domain-groups.txt').write_text('# Мои сервисы\n[Discord]\ndiscord.com\ndiscord.media\ndiscordapp.net\n\n[YouTube]\nyoutube.com\ngooglevideo.com\nytimg.com\n')
NOW=int(time.time())
def e(k,h,s,age,m='auto',sni=''):
  d={'key':k,'host':h,'strategy':str(s),'ts':NOW-age,'mode':m}
  if sni:d['sni']=sni
  return d
ENTRIES=[e('rkn_tcp','discord.com|4',3,120),e('rkn_tcp','gateway.discord.com|4',3,300),e('rkn_tcp','cdn.discordapp.net|4',1,900,'frozen'),
 e('rkn_tcp','finland10000.discord.media|4',2,50),e('rkn_tcp','finland10001.discord.media|4',2,80),e('quic','latency.discord.media|4',4,600),
 e('gv_tcp','rr1---sn-4g5e6nzz.googlevideo.com|4',7,30),e('gv_tcp','rr2---sn-4g5e6nzz.googlevideo.com|4',7,60),e('rkn_tcp','www.youtube.com|4',5,3600),e('rkn_tcp','i.ytimg.com|4',5,4000),
 e('rkn_tcp','as.gryphline.com|4',2,400), e('rkn_tcp','ef-webview.gryphline.com|4',2,500), e('rkn_tcp','game-config.gryphline.com|4',2,450), e('rkn_tcp','game-hub.gryphline.com|4',3,420), e('rkn_tcp','launcher.gryphline.com|4',2,800), e('rkn_tcp','u8.gryphline.com|4',2,610), e('rkn_tcp','beyond-euandus.gryphline.com|4',4,300), e('rkn_tcp','beyond-asiapacific.gryphline.com|4',4,320), e('rkn_tcp','beyond.hg-cdn.com|4',1,700), e('rkn_tcp','gl-utils-public.hg-cdn.com|4',1,720), e('rkn_tcp','web-static.hg-cdn.com|4',1,740), e('rkn_tcp','pc.crashsight.wetest.net|4',5,900), e('rkn_tcp','down.anticheatexpert.com|4',3,950), e('rkn_tcp','ngx.download.nvidia.com|4',1,990),
 e('rkn_tcp','chatgpt.com|4',1,7200),e('rkn_tcp','chatgpt.com|6',2,7200),e('rkn_tcp','gs-loc.apple.com|4',1,9000),e('rkn_tcp','api.apple.com|4',1,9500),e('rkn_tcp','rutracker.org|4',6,86400,'frozen'),e('rkn_tcp','1.2.3.4|4',1,100)]
INITIAL=[dict(e) for e in ENTRIES]
class H(http.server.SimpleHTTPRequestHandler):
 def __init__(s,*a,**kw):super().__init__(*a,directory=str(ROOT/'webpanel/www'),**kw)
 def do_GET(s):
  if s.path.startswith('/cgi-bin/api'):return s.api()
  if s.path.startswith('/test'):
   q=urllib.parse.urlsplit(s.path).query; theme='light' if 'light' in q else 'dark'
   b=f'''<!doctype html><html data-theme="{theme}"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/style.css"><body data-page="state"><main id="app" style="margin:24px auto;padding:0 16px"></main><div id="toast-stack"></div><script type="module">import {{renderState}} from '/js/pages/strategies.js';renderState();</script></body></html>'''.encode()
   s.send_response(200);s.send_header('Content-Type','text/html; charset=utf-8');s.end_headers();s.wfile.write(b);return
  super().do_GET()
 def do_POST(s):s.api()
 def j(s,o):
  b=json.dumps(o).encode();s.send_response(200);s.send_header('Content-Type','application/json');s.end_headers();s.wfile.write(b)
 def api(s):
  u=urllib.parse.urlsplit(s.path);p=u.path.removeprefix('/cgi-bin/api')
  body=s.rfile.read(int(s.headers.get('Content-Length',0)))
  if p=='/state':
   # A slow /state (the router spends seconds on it) is what opens the race
   # between a table refresh and a group save; the test turns it on per step.
   if (DATA/'slow-state').exists():time.sleep(float((DATA/'slow-state').read_text() or '2'))
   return s.j({'ok':True,'entries':ENTRIES})
  if p=='/__test/slow':
   q=urllib.parse.parse_qs(u.query).get('s',['0'])[0]
   if q=='0':(DATA/'slow-state').unlink(missing_ok=True)
   else:(DATA/'slow-state').write_text(q)
   return s.j({'ok':True})
  if p=='/pools':return s.j({'ok':True,'pools':{'rkn_tcp':50,'quic':9,'gv_tcp':22}})
  # The rotator state is mocked in memory with the same contract as the router
  # (set / delete / clear / bulk), so the table's own buttons can be exercised
  # next to the groups. /__test/reset restores the initial rows.
  q=urllib.parse.parse_qs(u.query)
  form=urllib.parse.parse_qs(body.decode()) if s.command=='POST' else {}
  f=lambda k:(form.get(k) or [''])[0]
  find=lambda k,h:[e for e in ENTRIES if e['key']==k and e['host']==h]
  if p=='/state/set':
   rows=find(f('key'),f('host'))
   if rows:rows[0].update(strategy=f('strategy'),mode=f('mode'))
   else:ENTRIES.append({'key':f('key'),'host':f('host'),'strategy':f('strategy'),'mode':f('mode'),'ts':int(time.time())})
   return s.j({'ok':True})
  if p=='/state/delete':
   ENTRIES[:]=[e for e in ENTRIES if not(e['key']==f('key') and e['host']==f('host'))];return s.j({'ok':True})
  if p=='/state/clear':
   ENTRIES.clear();return s.j({'ok':True})
  if p=='/state/bulk':
   key=q.get('key',[''])[0];act=q.get('action',[''])[0];hosts=[h for h in body.decode().split('\n') if h]
   done=0
   for h in hosts:
    rows=find(key,h)
    if not rows:continue
    done+=1
    if act=='delete':ENTRIES.remove(rows[0])
    else:rows[0]['mode']='frozen' if act=='freeze' else 'auto'
   print('BULK',act,key,len(hosts),flush=True)
   return s.j({'ok':True,'done':done,'total':len(hosts)})
  if p=='/__test/reset':
   ENTRIES[:]=[dict(e) for e in INITIAL];return s.j({'ok':True})
  env=dict(os.environ,LISTS_DIR=str(DATA),ZAPRET2_DIR=str(DATA),CONFIG_FILE=str(DATA/'config'),REQUEST_METHOD=s.command,PATH_INFO=p,QUERY_STRING=u.query,CONTENT_LENGTH=str(len(body)),CONTENT_TYPE=s.headers.get('Content-Type',''),HTTP_HOST=s.headers.get('Host',''),HTTP_X_Z2K_PANEL=s.headers.get('X-Z2K-Panel',''),HTTP_SEC_FETCH_SITE=s.headers.get('Sec-Fetch-Site',''))
  r=subprocess.run(['sh',str(ROOT/'webpanel/cgi/api.sh')],input=body,capture_output=True,env=env)
  h,sep,data=r.stdout.partition(b'\r\n\r\n')
  st=200
  for line in h.decode().splitlines():
   if line.startswith('Status:'):st=int(line.split()[1])
  s.send_response(st);s.send_header('Content-Type','application/json');s.end_headers();s.wfile.write(data)
 def log_message(s,*a):pass

http.server.ThreadingHTTPServer(('127.0.0.1',int(os.environ.get('Z2K_PANEL_TEST_PORT','18790'))),H).serve_forever()
