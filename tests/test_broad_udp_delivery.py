"""Exercise the delivery wrapper's actual regen/validate block under errexit."""
from pathlib import Path
import subprocess
import sys

script = Path(sys.argv[1] if len(sys.argv) > 1 else 'specs/remove-broad-udp/router-install.sh').read_text()
start = script.index('au_step_regen_config\n') if 'au_step_regen_config\n' in script else script.index('au_gen_libs_source\n')
block = script[start:script.index('\n. /opt/zapret2/config', start)]
# Keep the production shell control flow; provide only external dependencies.
block = block.replace('sh /opt/zapret2/z2k-config-validator.sh /opt/zapret2/config', 'validate_fixture')
for generator_rc, validator_rc, expected in [(0,0,0),(0,1,0),(0,2,1),(7,0,1)]:
    fixture = f'''set -e
ZAPRET2_DIR=/unused
B=/unused
au_gen_libs_source() {{ :; }}
create_official_config() {{
    # Mirrors best-effort cleanup of an already absent ipset before generation.
    false
    echo GENERATOR_REACHED
    return {generator_rc}
}}
au_step_regen_config() {{ au_gen_libs_source; create_official_config /unused >/dev/null 2>&1; }}
validate_fixture() {{ return {validator_rc}; }}
au_step_validate_config() {{ validate_fixture || [ "$?" = 1 ]; }}
'''
    p = subprocess.run(['sh', '-c', fixture + block], capture_output=True, text=True)
    assert (p.returncode == 0) == (expected == 0), (generator_rc, validator_rc, p.returncode, p.stdout, p.stderr)
    if expected == 0:
        assert 'GENERATOR_REACHED' in p.stdout, 'generator output must remain visible'
    print(f'PASS generator={generator_rc} validator={validator_rc} rc={p.returncode}')
