#!/bin/sh
# Exercise shipped defaults and the real generator without touching /opt.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-openai.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
export HERE
python3 - "$TMP" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ['HERE'])
tmp = Path(sys.argv[1])
expected = {'chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com',
            'oaistatsig.com', 'cdn.openaimerge.com', 'sora.com'}
for name in ('lib/config.sh', 'lib/menu.sh'):
    text = (root / name).read_text()
    default = text.split('# Whitelist -', 1)[1].split('\nEOF', 1)[0]
    entries = set(default.splitlines())
    assert expected <= entries, (name, 'missing OpenAI defaults', expected - entries)
    assert '# === OpenAI / ChatGPT ===' in default, name
print('PASS: both shipped default templates contain OpenAI suffixes')

# Execute installation defaults, then simulate the owner's removal and rerun.
base = tmp / 'base'
create = 'ZAPRET2_DIR="$2"; CONFIG_DIR="$2/etc"; LISTS_DIR="$2/lists"; WORK_DIR="$2/work"; . "$1/lib/utils.sh"; . "$1/lib/config.sh"; create_base_config'
subprocess.check_output(['sh', '-c', create, 'openai-base', str(root), str(base)])
base_wl = base / 'lists/whitelist.txt'
assert expected <= set(base_wl.read_text().splitlines())
base_wl.write_text('\n'.join(d for d in base_wl.read_text().splitlines() if d not in expected) + '\nowner.example\n')
subprocess.check_output(['sh', '-c', create, 'openai-base', str(root), str(base)])
assert not expected.intersection(base_wl.read_text().splitlines())
assert 'owner.example' in base_wl.read_text().splitlines()
print('PASS: real default creation includes OpenAI; rerun preserves owner removals and additions')

for rel in ('TCP/YT', 'TCP/YT_GV', 'TCP/RKN', 'UDP/YT'):
    d = tmp / 'extra_strats' / rel
    d.mkdir(parents=True)
    (d / 'List.txt').write_text('oaistatic.com\nchatgpt.com\nyoutube.com\n')
    proto = '--filter-udp=443 --filter-l7=quic' if rel.startswith('UDP') else '--filter-tcp=443 --filter-l7=tls'
    (d / 'Strategy.txt').write_text(proto + ' --lua-desync=fake:blob=0x00:repeats=1\n')
(tmp / 'lua').symlink_to(root / 'files/lua', target_is_directory=True)
(tmp / 'lists').mkdir()
wl = tmp / 'lists/whitelist.txt'
wl.write_text('\n'.join(sorted(expected)) + '\n')
for name in ('extra-domains.txt', 'discovered-domains.txt'):
    (tmp / 'lists' / name).write_text('api.openai.com\nfiles.oaiusercontent.com\n')
(tmp / 'extra_strats/TCP_Discord.txt').write_text('ws.chatgpt.com\n')
for templates in (0, 1):
    for quic_off in (0, 1):
        (tmp / 'config').write_text(f'Z2K_NFQWS2_TEMPLATES={templates}\nZ2K_QUIC_OFF={quic_off}\nZ2K_AUTOHOSTLIST=1\n')
        cmd = '. "$1/lib/utils.sh"; ZAPRET2_DIR="$2"; LISTS_DIR="$2/lists"; . "$1/lib/config_official.sh"; generate_nfqws2_opt_from_strategies'
        output = subprocess.check_output(['sh', '-c', cmd, 'openai-test', str(root), str(tmp)], text=True)
        profiles = output.split('--new')
        seen_tcp = seen_quic = False
        for p in profiles:
            if '--lua-desync=' not in p:
                continue
            if '--filter-l7=quic' in p or ('--filter-tcp=' in p and '--hostlist=' in p):
                assert f'--hostlist-exclude={wl}' in p, p
                seen_tcp |= '--filter-tcp=' in p
                seen_quic |= '--filter-l7=quic' in p
        assert seen_tcp and seen_quic, output
        shield = next(i for i, p in enumerate(profiles)
                      if f'--hostlist={wl}' in p and '--filter-udp=1-65535' in p)
        assert '--lua-desync=' not in profiles[shield]
        for i, p in enumerate(profiles):
            if 'key=udp_misc' in p or 'key=discord_udp' in p:
                assert shield < i, p
print('PASS: real TCP/QUIC generator excludes whitelist, including QUIC drop; UDP shield precedes hostless handlers')
PY
