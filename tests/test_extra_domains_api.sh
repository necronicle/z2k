#!/bin/sh
# Exercise real CGI modes, including old panels without a mode parameter.
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
export ROOT
python3 - <<'PY'
import json, os, pathlib, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
with tempfile.TemporaryDirectory() as td:
    data = pathlib.Path(td)
    target = data / 'extra-domains.txt'
    rkn = data / 'extra_strats/TCP/RKN/List.txt'
    rkn.parent.mkdir(parents=True)
    rkn.write_text('mediafire.com\n')
    (data / 'whitelist.txt').write_text('excluded.example\n')
    env = dict(os.environ, ZAPRET2_DIR=td, LISTS_DIR=td,
               EXTRA_DOMAINS_FILE=str(target), WHITELIST_FILE=str(data/'whitelist.txt'),
               CONFIG_FILE=str(data/'config'), HTTP_HOST='127.0.0.1', HTTP_X_Z2K_PANEL='1')
    def request(method='GET', query='', body=''):
        raw = body.encode()
        e = dict(env, REQUEST_METHOD=method, PATH_INFO='/extra-domains'+('/save' if method=='POST' else ''),
                 QUERY_STRING=query, CONTENT_LENGTH=str(len(raw)), CONTENT_TYPE='text/plain')
        r = subprocess.run(['sh', str(root/'webpanel/cgi/api.sh')], input=raw, env=e, capture_output=True)
        header, payload = r.stdout.replace(b'\r\n', b'\n').split(b'\n\n',1)
        status = next((int(line.split()[1]) for line in header.splitlines() if line.startswith(b'Status:')),200)
        return status, json.loads(payload)
    def save(body, mode='', revision=None):
        if revision is None: revision = request()[1]['revision']
        return request('POST', 'revision='+revision+('&mode='+mode if mode else ''), body)
    for mode in ['', 'import']:
        target.write_text('# keep\nmacbb.org\n')
        for repeat in range(2):
            status, result = save('# keep\nmacbb.org\nmacbb.org\nmediafire.com\nworkupload.com\n', mode)
            assert status == 200, (mode, status, result)
            assert target.read_text() == '# keep\nmacbb.org\nworkupload.com\n'
            assert result['notice'].endswith('1.'), result
    before = target.read_bytes()
    assert save('mediafire.com\n', 'add')[0] == 400
    assert target.read_bytes() == before
    # A prior record must survive save even when coverage changed afterwards.
    target.write_text('# covered user entry\nmediafire.com\nmacbb.org\n')
    previous = target.read_text()
    assert save(previous+'new.example\n')[0] == 200
    assert target.read_text() == previous+'new.example\n'
    stale = request()[1]['revision']
    assert save('macbb.org\n')[0] == 200
    assert save(previous, 'restore', stale)[0] == 409
    assert save(previous, 'restore')[0] == 200
    assert target.read_text() == previous, 'undo must restore covered entries too'
    for mode in ['', 'import', 'add', 'restore']:
        before = target.read_bytes()
        assert save('good.example\nbad domain\n', mode)[0] == 400
        assert target.read_bytes() == before
    assert save('new.example\n', 'typo')[0] == 400
    assert (data/'whitelist.txt').read_text() == 'excluded.example\n'
print('PASS: real CGI bulk defaults/import/add/restore, coverage, duplicate import, undo, syntax and CAS')
PY
