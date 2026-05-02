-- tests/test_mid_stream_stall.lua
-- Unit tests for z2k_mid_stream_stall (z2k-detectors.lua, byte-window v3).
--
-- Run: lua tests/test_mid_stream_stall.lua
-- Exit code 0 on green, 1 on any failure.
--
-- The detector is keyed by a flow-key derived from standard_hostkey()
-- (with raw host fallback) and tracks byte progress per-flow inside
-- desync.track.lua_state, with a per-key candidate snapshot held in
-- the module-global state map. Tests here drive the detector through
-- the public z2k_mid_stream_stall() entry point with desync structs
-- that include explicit lua_state tables — one per simulated flow —
-- so per-flow vs per-key separation is exercised end-to-end.
--
-- Mocks below override the upstream globals z2k_mid_stream_stall
-- depends on (bitand, TH_*, standard_hostkey, os.time) so the file
-- under test can be `dofile`'d into the test process. Other detectors
-- in the same file (z2k_tls_stalled, z2k_classify_http_reply etc.) get
-- no-op overrides AFTER load so they don't interfere with mid-stream
-- specific assertions.

-- ----- mocks ---------------------------------------------------------------

if _VERSION >= "Lua 5.3" then
    bitand = assert(load("return function(a, b) return a & b end"))()
else
    function bitand(a, b)
        local r, p = 0, 1
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then r = r + p end
            a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
        end
        return r
    end
end

TH_FIN  = 0x01
TH_SYN  = 0x02
TH_RST  = 0x04
TH_PUSH = 0x08
TH_ACK  = 0x10

local mock_now = 1000
local function set_now(t) mock_now = t end

do
    local mt = getmetatable(os) or {}
    mt.__index = mt.__index or {}
    os.time = function() return mock_now end
end

-- standard_hostkey: simulate upstream nld=2 normalization. Strips the
-- first label when the result still has ≥2 labels (so cf-A.cf.com →
-- cf.com but cf.com → cf.com), matching the dissect_nld(host, 2)
-- behavior used by zapret-auto when nld=2 is set in the circular.
function standard_hostkey(desync)
    local host = desync and desync.track and desync.track.hostname
    if type(host) ~= "string" or host == "" then return nil end
    local stripped = host:match("^[^.]+%.(.+)$")
    if stripped and stripped:find(".", 1, true) then
        return stripped
    end
    return host
end

-- Eviction limits: pin them high enough that the test workload doesn't
-- accidentally trip eviction sweeps mid-test. The detector reads these
-- as upvalues at load time; they need to exist as globals BEFORE
-- dofile so the local declarations inside the file pick our values.
Z2K_DETECTOR_MAP_MAX        = 4096
Z2K_DETECTOR_EVICT_BATCH    = 1024
Z2K_DETECTOR_EVICT_INTERVAL = 4096

-- ----- load detector under test -------------------------------------------

dofile("files/lua/z2k-detectors.lua")

-- After load, neutralize sibling detectors so they don't shadow the
-- mid-stream signal we're trying to assert. Each becomes a no-op that
-- returns false (= "not a fail") for any input.
z2k_tls_stalled              = function() return false end
z2k_tls_alert_fatal          = function() return false end
standard_failure_detector    = function() return false end
z2k_classify_http_reply      = function() return nil, nil end

-- ----- helpers ------------------------------------------------------------

-- Each simulated TCP flow gets its own lua_state table that persists
-- across packets of that flow. The detector stashes per-flow state
-- (max_seq, base_seq, fin_seen, …) in lua_state.mid_stream so its
-- byte-window logic only mixes data within one TCP connection.
--
-- The constructor returns closures that build incoming and outgoing
-- desync structs sharing the same lua_state, so a test can interleave
-- packets and CHs over a single flow naturally.
local function mk_flow(host)
    local lua_state = {}
    local function in_pkt(seq, payload_len, flags)
        return {
            outgoing = false,
            track    = { hostname = host, lua_state = lua_state },
            dis = {
                payload = payload_len and string.rep("x", payload_len) or nil,
                tcp = {
                    th_seq   = seq or 0,
                    th_flags = flags or TH_ACK,
                },
            },
        }
    end
    local function out_ch()
        return {
            outgoing  = true,
            l7payload = "tls_client_hello",
            track     = { hostname = host, lua_state = lua_state },
            dis = {
                payload = "\x16\x03\x01\x00\x00",
                tcp = { th_seq = 1, th_flags = TH_PUSH + TH_ACK },
            },
        }
    end
    return { in_pkt = in_pkt, out_ch = out_ch }
end

-- Reset the detector's per-host state map between tests by re-loading
-- the module file. Local upvalues (z2k_mid_stream_state) are
-- re-created and the previous flow instances become unreferenced.
local function reset_detector()
    dofile("files/lua/z2k-detectors.lua")
    z2k_tls_stalled              = function() return false end
    z2k_tls_alert_fatal          = function() return false end
    standard_failure_detector    = function() return false end
    z2k_classify_http_reply      = function() return nil, nil end
end

-- Helper: drive one flow through `n` data packets of given size,
-- starting from initial_seq. Each packet bumps mock_now by 1.
local function deliver(flow, start_seq, packet_size, count)
    local seq = start_seq
    for i = 1, count do
        set_now(mock_now + 1)
        z2k_mid_stream_stall(flow.in_pkt(seq, packet_size), {})
        seq = seq + packet_size
    end
end

-- ----- harness ------------------------------------------------------------

local PASS, FAIL = 0, 0

local function check(name, want, got)
    if want == got then
        PASS = PASS + 1
        print(string.format("[PASS] %s", name))
    else
        FAIL = FAIL + 1
        print(string.format("[FAIL] %s: want=%s got=%s",
            name, tostring(want), tostring(got)))
    end
end

-- ----- tests --------------------------------------------------------------

print("--- z2k_mid_stream_stall (byte-window v3) ---")

-- T1: first CH never fires (no prior state, no candidate)
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    local r = z2k_mid_stream_stall(f.out_ch(), {})
    check("first CH no fire", false, r)
end

-- T2: progress < LO (< 8 KB) → no candidate, retry CH no fire
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_mid_stream_stall(f.out_ch(), {})        -- CH1 t=1000
    deliver(f, 100, 1500, 3)                    -- ~4500 bytes < LO
    set_now(1015)                               -- silence 12s
    local r = z2k_mid_stream_stall(f.out_ch(), {})  -- CH2 t=1015 (gap=15s)
    check("progress < LO no fire", false, r)
end

-- T3: progress in [LO, HI], silence ≥ SILENCE_SEC, active retry → fire
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_mid_stream_stall(f.out_ch(), {})        -- CH1 t=1000
    deliver(f, 100, 1500, 8)                    -- ~12000 bytes in [LO, HI]
    set_now(1020)                               -- silence 12s, ch_gap=20s ≤ 30s
    local r = z2k_mid_stream_stall(f.out_ch(), {})
    check("stall window + silence + active retry → fire", true, r)
end

-- T4: progress > HI → success path, candidate cleared, retry no fire
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_mid_stream_stall(f.out_ch(), {})        -- CH1 t=1000
    deliver(f, 100, 1500, 20)                   -- ~30000 bytes > HI=26000
    set_now(1025)                               -- ch_gap=25s ≤ 30s
    local r = z2k_mid_stream_stall(f.out_ch(), {})
    check("progress > HI no fire (success path)", false, r)
end

-- T5: FIN after progress in window → candidate cleared by owning flow
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_mid_stream_stall(f.out_ch(), {})
    deliver(f, 100, 1500, 8)                    -- ~12000 bytes
    set_now(mock_now + 1)
    z2k_mid_stream_stall(f.in_pkt(100000, 0, TH_FIN + TH_ACK), {})
    set_now(mock_now + 10)                      -- ch_gap small enough
    local r = z2k_mid_stream_stall(f.out_ch(), {})
    check("FIN after progress → no fire", false, r)
end

-- T5b: RST has the same effect as FIN
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_mid_stream_stall(f.out_ch(), {})
    deliver(f, 100, 1500, 8)
    set_now(mock_now + 1)
    z2k_mid_stream_stall(f.in_pkt(100000, 0, TH_RST + TH_ACK), {})
    set_now(mock_now + 10)
    local r = z2k_mid_stream_stall(f.out_ch(), {})
    check("RST after progress → no fire", false, r)
end

-- T6: nld=2 — stall on static.cf.com, retry CH on api.cf.com → fire
-- (different flows, same key, candidate ownership doesn't matter for
-- a CH that's just consulting the candidate)
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("static.cf.com")
    z2k_mid_stream_stall(fA.out_ch(), {})       -- CH on static (key=cf.com)
    deliver(fA, 100, 1500, 8)                   -- A delivers ~12000 bytes
    set_now(1020)                               -- silence 12s, ch_gap=20s
    local fB = mk_flow("api.cf.com")
    local r = z2k_mid_stream_stall(fB.out_ch(), {})
    check("nld=2 cross-subdomain stall → fire", true, r)
end

-- T7: parallel preconnect — second CH right after recent progress,
-- silence < SILENCE_SEC → no fire even though candidate may be in window
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_mid_stream_stall(f.out_ch(), {})        -- CH1 t=1000
    deliver(f, 100, 1500, 8)                    -- last progress mock_now=1008
    set_now(1009)                               -- silence 1s only
    local r = z2k_mid_stream_stall(f.out_ch(), {})
    check("parallel preconnect (no silence) → no fire", false, r)
end

-- T8: z2k_tls_stalled inheritance — if upstream returns true, mid_stream
-- returns true regardless of byte-window state
do
    reset_detector()
    z2k_tls_stalled = function() return true end
    set_now(1000)
    local f = mk_flow("a.example.com")
    local r = z2k_mid_stream_stall(f.out_ch(), {})
    check("z2k_tls_stalled inheritance fires through", true, r)
end

-- T9: stale state — silence > RETRY_MAX_SEC → no fire (fresh visit)
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_mid_stream_stall(f.out_ch(), {})
    deliver(f, 100, 1500, 8)                    -- progress at t≈1008
    set_now(1300)                               -- 292s later → > RETRY_MAX_SEC
    local r = z2k_mid_stream_stall(f.out_ch(), {})
    check("stale state (>RETRY_MAX_SEC) → no fire", false, r)
end

-- T10: interleaved parallel flows — A stalls in [LO, HI], B succeeds
-- past HI on the SAME nld=2 key. B's success must NOT clear A's
-- candidate (parallel flow ownership separation).
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("static.cf.com")
    local fB = mk_flow("api.cf.com")           -- same nld=2 key cf.com
    z2k_mid_stream_stall(fA.out_ch(), {})
    z2k_mid_stream_stall(fB.out_ch(), {})
    -- A delivers ~12000 (in window), publishes candidate owned by A
    deliver(fA, 100, 1500, 8)
    -- B delivers >18000 (success), but TCP seq space is independent;
    -- B's success path must only clear B's own candidate, not A's.
    deliver(fB, 50000, 1500, 17)                -- ~25500 bytes via B
    set_now(1030)                               -- silence on A 22s, ch_gap small
    local fC = mk_flow("static.cf.com")
    local r = z2k_mid_stream_stall(fC.out_ch(), {})
    check("parallel flow B success does NOT cross-clear A's candidate",
          true, r)
end

-- T11: per-flow FIN ownership — flow B FINs, A still stalled.
-- B's FIN must NOT clear A's candidate.
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("static.cf.com")
    local fB = mk_flow("api.cf.com")
    z2k_mid_stream_stall(fA.out_ch(), {})
    deliver(fA, 100, 1500, 8)                   -- A publishes candidate
    set_now(mock_now + 1)
    -- B sends a FIN on its own connection — should clear ONLY B's
    -- (which is anyway nil for B), leaving A's candidate intact.
    z2k_mid_stream_stall(fB.in_pkt(50000, 0, TH_FIN + TH_ACK), {})
    set_now(1025)                               -- silence on A ~17s
    local fC = mk_flow("static.cf.com")
    local r = z2k_mid_stream_stall(fC.out_ch(), {})
    check("parallel flow B FIN does NOT clear A's candidate", true, r)
end

-- T12: active-retry gate — single CH after a long quiet period with
-- candidate present should NOT fire (legitimate single navigation).
-- Need to drive incoming packets to publish the candidate WITHOUT
-- racing CH events that would update last_ch_ts.
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    -- No CH on the key first — drop straight to incoming packets to
    -- build the candidate so last_ch_ts stays at 0.
    deliver(f, 100, 1500, 8)                    -- candidate, last_progress=1008
    set_now(1050)                               -- silence 42s, well > SILENCE
    -- First CH on this key — prev_ch_ts == 0, so ch_gap is huge,
    -- active-retry gate should suppress fire.
    local r = z2k_mid_stream_stall(f.out_ch(), {})
    check("single CH after stall (no prior CH) → no fire", false, r)
end

-- T13: active-retry gate — two CHs > ACTIVE_RETRY_SEC apart with
-- candidate in between → no fire (two isolated visits, not retry)
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("a.example.com")
    z2k_mid_stream_stall(fA.out_ch(), {})       -- CH1 t=1000
    deliver(fA, 100, 1500, 8)                   -- candidate, last_progress≈1008
    set_now(1100)                               -- 100s later > ACTIVE_RETRY_SEC
    local fB = mk_flow("a.example.com")
    local r = z2k_mid_stream_stall(fB.out_ch(), {})
    -- ch_gap = 1100 - 1000 = 100s > 30s → suppressed by active-retry
    check("CH gap > ACTIVE_RETRY_SEC → no fire", false, r)
end

-- T14: missing lua_state — detector falls back to no-op for that
-- packet (early packet before nfqws2 populates the field)
do
    reset_detector(); set_now(1000)
    local desync = {
        outgoing  = true,
        l7payload = "tls_client_hello",
        track     = { hostname = "a.example.com" }, -- no lua_state
        dis       = { payload = "\x16\x03\x01\x00\x00",
                      tcp = { th_seq = 1, th_flags = TH_PUSH + TH_ACK } },
    }
    local r = z2k_mid_stream_stall(desync, {})
    check("missing lua_state → no fire (graceful)", false, r)
end

-- T15: stale candidate is auto-cleared on CH so a NEW flow can
-- publish fresh evidence under the same key.
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("a.example.com")
    z2k_mid_stream_stall(fA.out_ch(), {})       -- CH1 t=1000
    deliver(fA, 100, 1500, 8)                   -- A publishes candidate t=1008
    set_now(1300)                               -- 292s later > RETRY_MAX_SEC
    local fB = mk_flow("a.example.com")
    z2k_mid_stream_stall(fB.out_ch(), {})       -- CH on B → stale-clears A's
    -- After stale clear, B can now publish a fresh candidate.
    deliver(fB, 100, 1500, 8)                   -- B's data t=1301..1308
    set_now(1320)                               -- silence 12s, ch_gap=20s
    local fC = mk_flow("a.example.com")
    local r = z2k_mid_stream_stall(fC.out_ch(), {})
    check("stale A candidate cleared, B can fire on fresh stall", true, r)
end

-- T16: active-retry gate also clears candidate so a subsequent rapid
-- CH (within ACTIVE_RETRY_SEC of THIS suppressed CH) cannot ride on
-- the same stale candidate and fire.
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("a.example.com")
    z2k_mid_stream_stall(fA.out_ch(), {})       -- CH1 t=1000
    deliver(fA, 100, 1500, 8)                   -- candidate t=1008
    set_now(1100)                               -- ch_gap=100s > 30s
    local fB = mk_flow("a.example.com")
    z2k_mid_stream_stall(fB.out_ch(), {})       -- CH2 suppressed, clears cand
    set_now(1105)                               -- ch_gap=5s ≤ 30s
    local fC = mk_flow("a.example.com")
    local r = z2k_mid_stream_stall(fC.out_ch(), {})
    check("rapid CH after suppressed CH does NOT ride on stale cand",
          false, r)
end

-- T17: inverse parallel — A enters [LO, HI] first, B also stalls in
-- [LO, HI] (multi-candidate map allows both to coexist), A then
-- crosses past HI and clears ITS OWN entry; B's still-stalled entry
-- is preserved and a retry CH fires on it. Single-candidate model
-- would lose B's evidence here.
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("static.cf.com")
    local fB = mk_flow("api.cf.com")            -- same nld=2 key cf.com
    z2k_mid_stream_stall(fA.out_ch(), {})       -- CH1 t=1000 last_ch=1000
    deliver(fA, 100, 1500, 8)                   -- A: max_seq=12000 (in [LO,HI])
                                                -- A's candidate published t=1008
    set_now(1009)
    z2k_mid_stream_stall(fB.out_ch(), {})       -- CH2 ch_gap=9 last_ch=1009
    deliver(fB, 50000, 1500, 6)                 -- B: max_seq=9000 (in [LO,HI])
                                                -- B's candidate published t=1015
                                                -- B then stalls (no more pkts)
    -- A continues past HI=26000: 11 more packets, max_seq=12000+11*1500=28500
    deliver(fA, 100 + 8 * 1500, 1500, 11)       -- A's candidate cleared
    set_now(1030)                               -- ch_gap from fB CH=21s ≤ 30s
    local fC = mk_flow("static.cf.com")
    local r = z2k_mid_stream_stall(fC.out_ch(), {})
    -- Should fire on B's surviving candidate (max_seq=9000,
    -- silence=1030-1015=15s)
    check("inverse parallel: A success past HI, B stalled fires", true, r)
end

-- ----- result -------------------------------------------------------------

print(string.format("\n%d passed, %d failed", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
