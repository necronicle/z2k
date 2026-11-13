"""Retirement must remove exactly one generated profile, across flag combinations."""
import pathlib, subprocess, itertools, tempfile, re, difflib
repo=pathlib.Path.cwd()
with tempfile.TemporaryDirectory() as td:
 root=pathlib.Path(td)
 old=root/'old.sh';old.write_bytes(subprocess.check_output(['git','show','db733f16:lib/config_official.sh']))
 for sub,key in [('TCP/YT','yt_tcp'),('TCP/YT_GV','gv_tcp'),('TCP/RKN','rkn_tcp'),('UDP/YT','quic')]:
  p=root/'extra_strats'/sub;p.mkdir(parents=True)
  (p/'List.txt').write_text('youtube.com\ngooglevideo.com\nexample.org\n')
  (p/'Strategy.txt').write_text(f'--filter-{"udp" if sub.startswith("UDP") else "tcp"}=443 --lua-desync=circular:key={key}:fails=2 --lua-desync=fake:strategy=1\n')
 (root/'lists').mkdir();(root/'lua').mkdir()
 helper=subprocess.check_output(['awk','/^safe_config_read\(\)/,/^}/','lib/utils.sh'],text=True)
 def generate(src):
  p=subprocess.run(['sh'],input=helper+f'\n. "{src}"\nZAPRET2_DIR="{root}"\ngenerate_nfqws2_opt_from_strategies\n',capture_output=True,text=True)
  assert p.returncode==0,p.stderr
  return p.stdout
 count=0;diff=''
 for vals in itertools.product([0,1],repeat=6):
  keys=['Z2K_CATEGORY_YOUTUBE','Z2K_CATEGORY_RKN','Z2K_CATEGORY_DISCORD_VOICE','Z2K_REFACTOR_PHASE3','Z2K_NFQWS2_TEMPLATES']
  cfg=''.join(f'{k}={v}\n' for k,v in zip(keys,vals))
  (root/'config').write_text(cfg+'Z2K_UDP_MISC=1\n')
  before=generate(old)
  # All built-in circular instances other than the removed block are named.
  for block in before.split('--new'):
   if 'key=udp_misc' not in block:
    assert not re.search(r'--lua-desync=circular(?=\s|:)(?![^\s]*:key=)',block),block
  expected='\n'.join(line for line in before.split('\n') if 'key=udp_misc' not in line)
  for flag in ['0','1','ignored','']:
   (root/'config').write_text(cfg+(f'Z2K_UDP_MISC={flag}\n' if flag else ''))
   after=generate(repo/'lib/config_official.sh')
   assert 'key=udp_misc' not in after and '--filter-udp=590-600' not in after, f'profile still generated: {vals}, legacy={flag}'
   assert after==expected, ''.join(difflib.unified_diff(expected.splitlines(True),after.splitlines(True)))
   count+=1
  if all(vals):diff=''.join(difflib.unified_diff(before.replace(str(root),'$BASE').splitlines(True),after.replace(str(root),'$BASE').splitlines(True),fromfile='before',tofile='after'))
 evidence=repo/'specs/remove-broad-udp/evidence'
 if evidence.is_dir():(evidence/'generation.diff').write_text(diff)
 print(f'{count} generations: only broad UDP removed; all other built-in circular pools named')
# Public UI and toggle registry cannot offer the retired feature.
for path in ['lib/menu.sh','webpanel/www/js/pages/toggles.js']:
 assert 'UDP_MISC' not in (repo/path).read_text(),path
p=subprocess.check_output(['sh','-c','. lib/config_official.sh; z2k_toggle_defaults'],text=True)
assert 'Z2K_UDP_MISC' not in p,'retired toggle remains in registry'
print('menu/panel/registry: retired toggle absent')
