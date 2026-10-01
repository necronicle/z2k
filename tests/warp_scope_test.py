import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1])
# Only the OS boundary is replaced: real list parsing, device resolution,
# main policy, and NDM hook run unmodified. No Linux netfilter on macOS.
ADAPTER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['NETFILTER_STATE'])
s=json.loads(p.read_text())
a=sys.argv[1:]; rc=0; out=[]
if Path(sys.argv[0]).name == 'iptables':
    if a[0]=='-w': a=a[1:]
    table=a[1]; op=a[2]; chain=a[3]; rule=a[4:]
    chains=s['tables'].setdefault(table,{})
    if op=='-N':
        if chain in chains: rc=1
        else: chains[chain]=[]
    elif op=='-S':
        if chain not in chains: rc=1
        else:
            out=['-N '+chain]+['-A '+chain+' '+' '.join(r) for r in chains[chain]]
    elif op=='-F': chains[chain]=[]
    elif op=='-X': chains.pop(chain,None)
    elif op=='-C': rc=int(rule not in chains.get(chain,[]))
    elif op=='-D':
        if rule in chains.get(chain,[]): chains[chain].remove(rule)
        else: rc=1
    elif op in ('-A','-I'):
        if '-j' in rule:
            target=rule[rule.index('-j')+1]
            if target not in ('MARK','RETURN','TCPMSS','ACCEPT','MASQUERADE','NFLOG') and target not in chains: rc=1
        if not rc:
            if op=='-I':
                if rule[0].isdigit(): rule=rule[1:]
                chains.setdefault(chain,[]).insert(0,rule)
            else: chains.setdefault(chain,[]).append(rule)
    else: raise Exception(a)
elif Path(sys.argv[0]).name == 'ipset':
    sets=s['sets']; op=a[0]
    if op=='swap' and a[2]=='z2k_warp_src' and os.environ.get('FAIL_SOURCE_SWAP'): sys.exit(1)
    if op=='create': sets.setdefault(a[1],[])
    elif op=='destroy': sets.pop(a[1],None)
    elif op=='swap': sets[a[1]],sets[a[2]]=sets[a[2]],sets[a[1]]
    elif op=='restore':
        for line in sys.stdin:
            args=line.split()
            if args: sets[args[1]].append(args[2])
    elif op=='list':
        if len(a)==2 and a[1]=='-n': out=list(sets)
        elif a[-1] not in sets: rc=1
    elif op=='save': out=['create '+a[1]+' hash:ip']+['add '+a[1]+' '+x for x in sets.get(a[1],[])]
    else: raise Exception(a)
elif Path(sys.argv[0]).name == 'ip':
    if 'neigh' in a: out=['192.168.1.10 dev br0 lladdr aa:bb:cc:dd:ee:ff REACHABLE']
# Read-only commands run in pipelines concurrently; they must not overwrite
# another command's mutation (unlike the real kernel, a JSON file is not atomic).
readonly = (Path(sys.argv[0]).name == 'ip' or
            (Path(sys.argv[0]).name == 'iptables' and op in ('-C','-S')) or
            (Path(sys.argv[0]).name == 'ipset' and op in ('list','save')))
if not readonly: p.write_text(json.dumps(s))
print('\n'.join(out)) if out else None
sys.exit(rc)
'''

with tempfile.TemporaryDirectory() as tmp:
    sb=Path(tmp); (sb/'bin').mkdir(); (sb/'lists').mkdir(); (sb/'sys/wdtt0').mkdir(parents=True)
    for name in ('iptables','ipset','ip'):
        f=sb/'bin'/name; f.write_text(ADAPTER); f.chmod(0o755)
    state=sb/'state.json'
    def reset():
        state.write_text(json.dumps({'tables':{'mangle':{'PREROUTING':[],'OUTPUT':[]}},'sets':{}}))
    reset()
    (sb/'z2k-warp.sh').write_text((ROOT/'files/z2k-warp.sh').read_text())
    (sb/'device.json').write_text('{"iface":"z2ktun0"}')
    env=dict(os.environ, Z2K_STUB_PATH=str(sb/'bin'), NETFILTER_STATE=str(state),
             ZAPRET2_DIR=str(sb), CONFIG_FILE=str(sb/'config'), WARP_LISTS_DIR=str(sb/'lists'),
             WARP_FILTER=str(ROOT/'files/z2k-warp-list-filter.awk'), WARP_DEVICE=str(sb/'device.json'),
             DEVICE_JSON=str(sb/'device.json'), WARP_DOMAINS=str(sb/'domains.v1'),
             WARP_STATUS=str(sb/'status.json'), SYS_CLASS_NET=str(sb/'sys'),
             WARP_NDMC='/nonexistent', Z2K_WARP_SOURCE_ONLY='1')
    def run(command):
        subprocess.run(['sh','-c','. "$ZAPRET2_DIR/z2k-warp.sh"; '+command],env=env,check=True,stdout=subprocess.DEVNULL)
    def config(devices='', wdtt=False, lists=True):
        (sb/'config').write_text('GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT='+str(int(wdtt))+'\n')
        (sb/'lists/devices.txt').write_text(devices)
        (sb/'lists/sites.txt').write_text('myip.ru\n8.8.4.4\n' if lists else '')
        run('warp_ipset_all')
        # DNS observer result for myip.ru, using independent client sets.
        data=json.loads(state.read_text())
        for client in ('192.168.1.10','192.168.1.11','10.77.0.2'):
            data['sets']['z2kd_'+client]=['8.8.8.8'] if lists else []
        state.write_text(json.dumps(data))
        run('warp_pbr_up')
    def marked(src, dst, iface):
        data=json.loads(state.read_text()); chains=data['tables']['mangle']
        def walk(chain,mark=0):
            for rule in chains.get(chain,[]):
                matches=True
                for flag,val in (('-s',src),('-i',iface)):
                    if flag in rule:
                        wanted=rule[rule.index(flag)+1]
                        matches &= (ipaddress.ip_address(val) in ipaddress.ip_network(wanted)) if flag=='-s' else (val.startswith(wanted[:-1]) if wanted.endswith('+') else val==wanted)
                if '--match-set' in rule:
                    i=rule.index('--match-set'); name,direction=rule[i+1:i+3]
                    addr=src if direction=='src' else dst
                    matches &= any(ipaddress.ip_address(addr) in ipaddress.ip_network(net) for net in data['sets'].get(name,[]))
                if not matches: continue
                target=rule[rule.index('-j')+1]
                if target=='RETURN': return mark
                if target=='MARK': mark=0x989
                elif target in chains: mark=walk(target,mark)
            return mark
        return bool(walk('PREROUTING'))
    failures=[]; passed=0
    def check(name,want,src='192.168.1.10',dst='8.8.8.8',iface='br0'):
        global passed
        got=marked(src,dst,iface)
        if got!=want: failures.append(name); print('[FAIL]',name,'expected',want,'got',got, state.read_text())
        else: passed+=1; print('[PASS]',name)
    config()
    check('no device selection: listed DNS on LAN',True)
    check('WDTT off excludes listed DNS',False,'10.77.0.2',iface='wdtt0')
    check('WDTT off excludes static destination',False,'10.77.0.2','8.8.4.4','wdtt0')
    config('192.168.1.10\n')
    check('selected device listed domain',True)
    check('unselected device listed domain',False,'192.168.1.11')
    check('unselected device static destination',False,'192.168.1.11','8.8.4.4')
    check('selected device unlisted destination',False,dst='9.9.9.9')
    config('192.168.1.10\n',True)
    check('WDTT on includes listed domain',True,'10.77.0.2',iface='wdtt0')
    check('WDTT on excludes unlisted destination',False,'10.77.0.2','9.9.9.9','wdtt0')
    config('de:ad:be:ef:00:01\n')
    check('offline selection must not expand to whole LAN',False)
    config('192.168.1.10\n',True,False)
    check('no lists with selected device',False,dst='9.9.9.9')
    check('no lists with WDTT on',False,'10.77.0.2','9.9.9.9','wdtt0')
    config('',False,False)
    check('nothing selected: no WARP traffic',False)
    # NDM rebuild must preserve the same source restriction.
    config('192.168.1.10\n')
    data=json.loads(state.read_text()); data['tables']['mangle']={'PREROUTING':[],'OUTPUT':[]}; state.write_text(json.dumps(data))
    subprocess.run(['sh',str(ROOT/'files/ndm/93-z2k-warp.sh')],env=dict(env,type='iptables',table='mangle',Z2K_WARP_SOURCE_ONLY=''),check=True)
    check('NDM restores selected device',True)
    check('NDM does not restore global DNS bypass',False,'192.168.1.11')
    check('NDM does not restore WDTT bypass',False,'10.77.0.2',iface='wdtt0')
    # Upgrade from direct marks must not leave any route around the new gate.
    data=json.loads(state.read_text())
    for rule in [
        ['-m','set','--match-set','z2k_warp','dst','-j','MARK','--set-xmark','0x989/0x989'],
        ['-m','set','--match-set','z2k_warp_src','src','-j','MARK','--set-mark','0x989'],
        ['-i','wdtt0','-j','MARK','--set-xmark','0x989/0x989'],
        ['-s','192.168.1.11/32','-m','set','--match-set','z2kd_192.168.1.11','dst','-j','MARK','--set-xmark','0x989/0x989']]:
        data['tables']['mangle']['PREROUTING'].append(rule)
    state.write_text(json.dumps(data))
    run('warp_policy_sync')
    check('upgrade removes global static bypass',False,'192.168.1.11','8.8.4.4')
    check('upgrade removes direct DNS bypass',False,'192.168.1.11')
    check('upgrade removes whole-device bypass',False,dst='9.9.9.9')
    check('upgrade removes WDTT catch-all',False,'10.77.0.2','9.9.9.9','wdtt0')
    run('warp_pbr_down')
    check('teardown removes static route',False,dst='8.8.4.4')
    check('teardown removes DNS route',False)
    run('warp_pbr_up')
    check('re-enable restores selected listed route',True)
    # The old set must not route a deselected device if a settings apply fails.
    # Include a first-upgrade legacy mark: flushing only the new gate is insufficient.
    data=json.loads(state.read_text())
    data['tables']['mangle']['PREROUTING'].append(['-m','set','--match-set','z2k_warp','dst','-j','MARK','--set-xmark','0x989/0x989'])
    state.write_text(json.dumps(data))
    (sb/'lists/devices.txt').write_text('192.168.1.11\n')
    failed=subprocess.run(['sh','-c','. "$ZAPRET2_DIR/z2k-warp.sh"; warp_ipset_all'],
                          env=dict(env,FAIL_SOURCE_SWAP='1'),stdout=subprocess.DEVNULL)
    if failed.returncode == 0:
        failures.append('source swap failure reported'); print('[FAIL] source swap failure reported')
    else:
        passed+=1; print('[PASS] source swap failure reported')
    check('failed source swap cannot retain deselected client',False)
    check('failed upgrade source swap removes legacy bypass',False,'192.168.1.11','8.8.4.4')
    print('\nPASSED:',passed,'\nFAILED:',len(failures))
    sys.exit(bool(failures))
