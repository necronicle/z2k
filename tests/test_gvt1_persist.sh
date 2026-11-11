#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/fallback"
for f in "$TMP/state.tsv" "$TMP/fallback/z2k-autocircular-state.tsv"; do
    printf 'quic\tgvt1.com|4\t2\t100\tauto\t\nrkn_tcp\trr.gvt1.com|6\t3\t200\tfrozen\t\nquic\tkeep.example|4\t1\t100\tauto\t\n' > "$f"
done
Z2K_STATE_DIR_OVERRIDE=$TMP Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE=$TMP/fallback lua - "$ROOT" <<'LUA'
local root = arg[1]
dofile(root .. '/files/lua/z2k-state-persist.lua')
z2k_state_persist.load_state()
local state = z2k_state_persist._state()
assert(not state.quic['gvt1.com|4'], 'gvt1 loaded from disk')
assert(not state.rkn_tcp or not state.rkn_tcp['rr.gvt1.com|6'], 'subdomain loaded')
assert(state.quic['keep.example|4'].strategy == 1, 'other row lost')
assert(not z2k_state_persist.persist_if_changed('quic', 'RR.GVT1.COM|6', {nstrategy=5}), 'gvt1 persisted')
z2k_state_persist.persist_if_changed('quic', 'keep.example|4', {nstrategy=2})
z2k_state_persist.flush()
local f = assert(io.open(z2k_state_persist.state_file()))
local body = f:read('*a'); f:close()
assert(not body:lower():find('gvt1', 1, true), 'gvt1 restored by merge/save')
assert(body:find('keep.example|4', 1, true), 'other row lost on save')
print('[PASS] gvt1 Lua load/persist/merge/save')
LUA
