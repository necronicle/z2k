#!/bin/sh
# Exercise startup and the real reinstall restore block with user-owned data.
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
export ROOT
python3 - <<'PY'
import os, pathlib, re, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
init = (root/'files/S99zapret2.new').read_text()
install = (root/'lib/install.sh').read_text()
functions = '\n'.join(re.findall(r'^(?:start_fw|z2k_covering_lists|z2k_prune_extra_domains)\(\)\n\{.*?^\}', init, re.M | re.S))
# Only firewall/kernel boundaries are stubbed. List maintenance runs unchanged.
stubs = '\n'.join(name+'() { :; }' for name in '''linux_fwtype z2k_connmark_init
z2k_conntrack_tune_start z2k_sweep_stale_wan_nfqueue zapret_apply_firewall
z2k_ensure_user_exclude_file z2k_seed_local_exclusions z2k_seed_user_exclusions
z2k_policy_connmark_start z2k_udp_masquerade_fix_start z2k_rst_filter_purge'''.split())
restore = install.split('    # extra-domains.txt: preserve user-added lines across reinstall.', 1)[1].split('    # WARP-списки', 1)[0]
with tempfile.TemporaryDirectory() as td:
    base = pathlib.Path(td)
    tree = base/'router'; (tree/'lists').mkdir(parents=True)
    rkn = tree/'extra_strats/TCP/RKN/List.txt'; rkn.parent.mkdir(parents=True)
    rkn.write_text('covered.example\n')
    user = tree/'lists/extra-domains.txt'
    original = '# user choice\nsub.covered.example\nnew.example\n'
    user.write_text(original)
    env = dict(os.environ, ZAPRET_BASE=str(tree), ZAPRET2_DIR=str(tree), WORK_DIR=str(base/'work'), backup_tmp=str(base/'backup'))
    subprocess.run(['sh','-c',stubs+'\n'+functions+'\nstart_fw'],env=env,check=True)
    assert user.read_text()==original, 'firewall startup removed user domains'
    (base/'backup').mkdir(); (base/'backup/extra-domains.txt').write_text(original)
    for shipped in [None, 'shipped.example\n']:
        if shipped is not None:
            src=base/'work/files/lists/extra-domains.txt'; src.parent.mkdir(parents=True); src.write_text(shipped)
        user.unlink()
        script = 'print_info() { :; }; die() { exit 1; }; restore() {\n'+restore+'\n}; restore'
        subprocess.run(['sh','-c',script],env=env,check=True)
        assert user.exists() and user.read_text()==original, 'reinstall must restore user file with or without WORK_DIR'
    # An explicitly cleared list is a user choice too.
    (base/'backup/extra-domains.txt').write_text('')
    subprocess.run(['sh','-c',script],env=env,check=True)
    assert user.read_text()=='', 'reinstall repopulated an explicitly empty list'
    # Fresh installs still receive defaults, including the download-only path.
    (base/'backup/extra-domains.txt').unlink()
    deploy = re.search(r'^deploy_critical_file\(\) \{.*?^\}', install, re.M | re.S).group()
    deploy += '\n' + re.search(r'^z2k_snapshot_external\(\) \{.*?^\}', install, re.M | re.S).group()
    network = 'z2k_fetch() { printf "downloaded.example\\n" > "$2"; }; print_warning() { :; };\n'
    for cached in [True, False]:
        if not cached: src.unlink()
        user.unlink()
        subprocess.run(['sh','-c',network+deploy+'\n'+script],env=env,check=True)
        assert user.read_text()==('shipped.example\n' if cached else 'downloaded.example\n')
print('PASS: startup and reinstall preserve user records, comments and empty list')
PY
