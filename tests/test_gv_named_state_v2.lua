-- No replacement persist implementation: exercise shipped load/merge/save APIs.
dofile('files/lua/z2k-state-persist.lua')
local P = z2k_state_persist
local phase = os.getenv('Z2K_GV_TEST_PHASE')
P.load_state()
local function ip() return P._state().gv_tcp and P._state().gv_tcp['192.0.2.1|4'] end
if phase == 'repro' then
    -- Once guarded, the old repro is still established by shell v1 alone.
    P.flush()
    print(ip() and '[REPRO] persist accepts restored IP' or '[FIX] persist rejects restored IP')
else
    assert(not ip(), 'persist imported obsolete IP after migration/restore')
    assert(P._state().gv_tcp['192.0.2.2|4'].mode == 'frozen')
    assert(P._state().gv_tcp['gvt1.com|6'].strategy == 4)
    assert(not P.persist_if_changed('gv_tcp', '192.0.2.9|4', {nstrategy=1}))
    assert(not P.persist_if_changed('gv_tcp', 'other.example|6', {nstrategy=1}))
    -- A sibling save merges the dirty on-disk file again.
    assert(P.persist_if_changed('rkn_tcp', 'valid.example|4', {nstrategy=2}))
    P.flush()
    local f = assert(io.open(P.state_file()))
    local text = f:read('*a'); f:close()
    assert(not text:find('192.0.2.1|4', 1, true))
    assert(text:find('192.0.2.2|4', 1, true))
end
