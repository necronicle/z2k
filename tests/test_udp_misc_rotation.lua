-- luacheck: globals VERDICT_MASK VERDICT_PRESERVE_NEXT pos_counter_overflow
-- luacheck: read globals plan_instance_execute apply_execution_plan
-- Native packet/runtime scaffolding from the fork; all tested Lua is real.
local fork = os.getenv('Z2K_FORK_DIR') or '../zapret2-z2k-fork'
local H = dofile(fork..'/tests/harness.lua')
-- Restore real plan execution/range checks overwritten by the generic harness.
dofile(fork..'/lua/zapret-lib.lua')
dofile(fork..'/lua/zapret-antidpi.lua')
local profile = assert(os.getenv('Z2K_TEST_UDP_MISC_PROFILE'))
local win_out = assert(tonumber(os.getenv('Z2K_UDP_PKT_OUT')))
local win_in = assert(tonumber(os.getenv('Z2K_UDP_PKT_IN')))

-- Parse the generated instance options into the plan normally supplied by C.
local function range(value)
    if value == 'a' or value == 'x' then
        return {from={mode=value, pos=0}, to={mode=value, pos=0}}
    end
    local n = value:match('^<n(%d+)$')
    assert(n, 'unsupported test range: '..value)
    return {from={mode='a', pos=0}, to={mode='n', pos=tonumber(n)}, upper_cutoff=true}
end
local instances = {}
local incoming, outgoing, payload = 'x', 'a', 'all'
for option, value in profile:gmatch('%-%-([%w-]+)=([^%s]+)') do
    if option == 'in-range' then incoming = value
    elseif option == 'out-range' then outgoing = value
    elseif option == 'payload' then payload = value
    elseif option == 'lua-desync' then
        local func = value:match('^[^:]+')
        local args = {}
        for k,v in value:gmatch(':([^:=]+)=([^:]+)') do args[k] = v end
        instances[#instances+1] = {func=func, func_n=#instances+1,
            func_instance=func..tostring(#instances+1), arg=args,
            payload_filter=payload, incoming=range(incoming), outgoing=range(outgoing)}
    end
end
H.eq(3, #instances)
H.eq('circular', instances[1].func)

-- Only native send/blob resolution is replaced. Real fake performs its own
-- direction_check, payload_check and replay guard before reaching this boundary.
local sends = {}
blob = function(_, name) return name end -- luacheck: ignore 121
rawsend_payload_segmented = function(d, data) -- luacheck: ignore 121
    sends[#sends+1] = {blob=data, repeats=d.arg.repeats, out=d.outgoing,
        n=pos_get(d, 'n'), payload=d.l7payload}
end
bitor = function(a,b) return a + b - bitand(a,b) end -- luacheck: ignore 121
VERDICT_MASK, VERDICT_PRESERVE_NEXT = 3, 4 -- luacheck: ignore 121
pos_counter_overflow = function() return false end -- luacheck: ignore 121

local function step(track, out, nout, nin, l7)
    local d = H.udp(track, out, 'datagram', l7 or 'stun', nout, nin)
    if (out and nout or nin) > (out and win_out or win_in) then return end
    d.plan = {}
    for _,item in ipairs(instances) do
        local instance = deepcopy(item)
        instance.range = out and instance.outgoing or instance.incoming
        d.plan[#d.plan+1] = instance
    end
    local first = table.remove(d.plan, 1)
    plan_instance_execute(d, VERDICT_PASS, first)
    -- fake changes desync.arg, so inspect state using circular's original args.
    apply_execution_plan(d, first)
    return automate_host_record(d), d.track.lua_state.automate
end
local function track()
    return H.track('udp.example')
end
local function failed_attempt()
    local t = track()
    local h,c
    for n=1,win_out do h,c = step(t, true, n, 0) end
    return h,c
end
H.test('two unanswered attempts rotate once; next connection executes arm 2', function()
    sends = {}
    local h,c = failed_attempt()
    H.eq(true, c.failure); H.eq(1, h.failure_counter); H.eq(1, h.nstrategy)
    h,c = failed_attempt()
    H.eq(true, c.failure); H.eq(2, h.nstrategy)
    H.eq(2, #sends) -- one fake call per attempt despite eight outgoing packets
    step(track(), true, 1, 0)
    H.eq('quic_google', sends[3].blob); H.eq('6', sends[3].repeats)
end)
H.test('first reply clears previous failure; healthy flows do not rotate', function()
    sends = {}
    local h = failed_attempt()
    H.eq(1, h.failure_counter)
    for _=1,3 do
        local t = track()
        step(t, true, 1, 0)
        local c
        h,c = step(t, false, 1, 1, 'unknown')
        H.eq(true, c.nocheck); H.eq(nil, h.failure_counter)
        for n=2,win_out do step(t, true, n, 1) end
        H.eq(1, h.nstrategy)
    end
    H.eq(4, #sends)
end)
H.test('both arms fake only the first outgoing packet, with original blob/repeats', function()
    for arm,name in ipairs({'0x00000000', 'quic_google'}) do
        sends = {}
        local t = track()
        local d = H.udp(t, true, 'datagram', 'stun')
        apply_execution_plan(d, instances[1])
        local h = automate_host_record(d)
        h.nstrategy = arm
        for n=1,win_out do step(t, true, n, 0) end
        for n=1,win_in do step(t, false, win_out, n, 'stun') end
        H.eq(1, #sends); H.eq(name, sends[1].blob); H.eq('6', sends[1].repeats)
        H.eq(true, sends[1].out); H.eq(1, sends[1].n)
    end
end)
H.test('unknown game payload and empty payload produce no fake on either arm', function()
    sends = {}
    for _,l7 in ipairs({'unknown', 'empty'}) do
        for arm=1,2 do
            local t = track()
            local d = H.udp(t, true, 'game', l7)
            apply_execution_plan(d, instances[1])
            automate_host_record(d).nstrategy = arm
            step(t, true, 1, 0, l7)
            for n=2,win_out do step(t, true, n, 0, l7) end
        end
    end
    H.eq(0, #sends)
end)
H.test('failure threshold is reached inside capture window, not on first packet', function()
    sends = {}
    local t = track()
    for n=1,3 do
        local _,c = step(t, true, n, 0)
        H.eq(nil, c.failure)
    end
    local h,c = step(t, true, 4, 0)
    H.eq(true, c.failure); H.eq(1, h.failure_counter)
    H.eq(nil, step(t, true, win_out+1, 0))
    H.eq(nil, step(t, false, win_out, win_in+1))
end)
H.finish()
