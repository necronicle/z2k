import http.server,os,pathlib,subprocess,urllib.parse,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
FIXTURE=tempfile.TemporaryDirectory(prefix='z2k-whitelist-browser-')
DATA=pathlib.Path(FIXTURE.name)
(DATA/'whitelist.txt').write_text('# my sites\na.example\nb.example\nc.example\nkeep.example\n')
(DATA/'extra_strats/TCP/RKN').mkdir(parents=True)
(DATA/'extra_strats/TCP/RKN/List.txt').write_text('mediafire.com\n')
class Handler(http.server.SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw):super().__init__(*a,directory=str(ROOT/'webpanel/www'),**kw)
 def do_GET(self):
  if self.path.startswith('/cgi-bin/api'):return self.api()
  if self.path in ('/test','/test-extra'):
   b=b'''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/style.css"><main id="app" style="max-width:1040px;margin:24px auto;padding:0 16px"></main><div id="toast-stack"></div><script type="module">import {renderExcludeDomains} from '/js/pages/exclude.js';renderExcludeDomains();</script>'''
   if self.path=='/test-extra':b=b.replace(b'renderExcludeDomains',b'renderExtraDomains').replace(b'/js/pages/exclude.js',b'/js/pages/extra-domains.js')
   self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(b);return
  super().do_GET()
 def do_POST(self):self.api()
 def api(self):
  u=urllib.parse.urlsplit(self.path);body=self.rfile.read(int(self.headers.get('Content-Length',0)))
  env=dict(os.environ,WHITELIST_FILE=str(DATA/'whitelist.txt'),EXTRA_DOMAINS_FILE=str(DATA/'extra-domains.txt'),LISTS_DIR=str(DATA),ZAPRET2_DIR=str(DATA),CONFIG_FILE=str(DATA/'config'),REQUEST_METHOD=self.command,PATH_INFO=u.path.removeprefix('/cgi-bin/api'),QUERY_STRING=u.query,CONTENT_LENGTH=str(len(body)),CONTENT_TYPE=self.headers.get('Content-Type',''),HTTP_HOST=self.headers.get('Host',''),HTTP_X_Z2K_PANEL=self.headers.get('X-Z2K-Panel',''),HTTP_SEC_FETCH_SITE=self.headers.get('Sec-Fetch-Site',''))
  r=subprocess.run(['sh',str(ROOT/'webpanel/cgi/api.sh')],input=body,capture_output=True,env=env)
  headers,sep,data=r.stdout.partition(b'\r\n\r\n')
  if not sep:headers,sep,data=r.stdout.partition(b'\n\n')
  status=200
  for line in headers.decode().splitlines():
   if line.startswith('Status:'):status=int(line.split()[1])
  self.send_response(status);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(data)
  if r.stderr:print(r.stderr.decode(),flush=True)
 def log_message(self,*a):pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(os.environ.get('Z2K_PANEL_TEST_PORT','18786'))),Handler).serve_forever()
