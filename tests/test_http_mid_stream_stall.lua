-- tests/test_http_mid_stream_stall.lua
-- Unit tests for z2k_http_mid_stream_stall (z2k-detectors.lua,
-- HTTP byte-window mirror of z2k_mid_stream_stall TLS detector).
--
-- Run: lua tests/test_http_mid_stream_stall.lua
-- Exit code 0 on green, 1 on any failure.
--
-- Mirror structure of test_mid_stream_stall.lua but gates on http_reply
-- (incoming) and http_req (outgoing retry) instead of TLS handshake
-- payloads. Constants: LO=14000, HI=32000.

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

-- standard_hostkey mirror — nld=2 normalization (cf-X.cf.com → cf.com).
function standard_hostkey(desync)
    local host = desync and desync.track and desync.track.hostname
    if type(host) ~= "string" or host == "" then return nil end
    local stripped = host:match("^[^.]+%.(.+)$")
    if stripped and stripped:find(".", 1, true) then
        return stripped
    end
    return host
end

Z2K_DETECTOR_MAP_MAX        = 4096
Z2K_DETECTOR_EVICT_BATCH    = 1024
Z2K_DETECTOR_EVICT_INTERVAL = 4096

-- ----- load detector under test -------------------------------------------

dofile("files/lua/z2k-detectors.lua")

-- Neutralize sibling detectors so they don't shadow the http_mid_stream
-- signal we're trying to assert.
z2k_tls_stalled              = function() return false end
z2k_tls_alert_fatal          = function() return false end
z2k_mid_stream_stall         = function() return false end
standard_failure_detector    = function() return false end
z2k_classify_http_reply      = function() return nil, nil end

-- ----- helpers ------------------------------------------------------------

-- Each simulated TCP flow gets its own lua_state. Detector stashes
-- per-flow state in lua_state.http_mid_stream.
local function mk_flow(host)
    local lua_state = {}
    local function in_pkt(seq, payload_len, flags)
        return {
            outgoing  = false,
            l7payload = "http_reply",
            track     = { hostname = host, lua_state = lua_state },
            dis = {
                payload = payload_len and string.rep("x", payload_len) or nil,
                tcp = {
                    th_seq   = seq or 0,
                    th_flags = flags or TH_ACK,
                },
            },
        }
    end
    local function out_req()
        return {
            outgoing  = true,
            l7payload = "http_req",
            track     = { hostname = host, lua_state = lua_state },
            dis = {
                payload = "GET / HTTP/1.1\r\n",
                tcp = { th_seq = 1, th_flags = TH_PUSH + TH_ACK },
            },
        }
    end
    return { in_pkt = in_pkt, out_req = out_req }
end

local function reset_detector()
    dofile("files/lua/z2k-detectors.lua")
    z2k_tls_stalled              = function() return false end
    z2k_tls_alert_fatal          = function() return false end
    z2k_mid_stream_stall         = function() return false end
    standard_failure_detector    = function() return false end
    z2k_classify_http_reply      = function() return nil, nil end
end

local function deliver(flow, start_seq, packet_size, count)
    local seq = start_seq
    for i = 1, count do
        set_now(mock_now + 1)
        z2k_http_mid_stream_stall(flow.in_pkt(seq, packet_size), {})
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

print("--- z2k_http_mid_stream_stall (HTTP byte-window) ---")

-- T1: first GET no fire (no prior state)
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("first GET no fire", false, r)
end

-- T2: progress < LO=14000, retry GET → no fire
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(f.out_req(), {})        -- GET1 t=1000
    deliver(f, 100, 1500, 5)                          -- ~7500 bytes < LO
    set_now(1015)                                     -- silence 10s
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("progress < LO no fire", false, r)
end

-- T3: progress in [LO, HI], silence ≥ SILENCE_SEC, active retry → fire
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(f.out_req(), {})        -- GET1 t=1000
    deliver(f, 100, 1500, 14)                         -- ~21000 bytes in [LO,HI]
    set_now(1025)                                     -- silence 11s, gap=25s ≤ 30s
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("stall window + silence + active retry → fire", true, r)
end

-- T4: progress > HI=32000 → success path, candidate cleared, retry no fire
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(f.out_req(), {})        -- GET1 t=1000
    deliver(f, 100, 1500, 23)                         -- ~34500 bytes > HI
    set_now(1030)                                     -- gap=30s ≤ 30s
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("progress > HI no fire (success path)", false, r)
end

-- T5: FIN after progress in window → candidate cleared
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(f.out_req(), {})
    deliver(f, 100, 1500, 14)                         -- ~21000 bytes
    set_now(mock_now + 1)
    z2k_http_mid_stream_stall(f.in_pkt(100000, 0, TH_FIN + TH_ACK), {})
    set_now(mock_now + 10)
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("FIN after progress → no fire", false, r)
end

-- T5b: RST has the same effect as FIN
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(f.out_req(), {})
    deliver(f, 100, 1500, 14)
    set_now(mock_now + 1)
    z2k_http_mid_stream_stall(f.in_pkt(100000, 0, TH_RST + TH_ACK), {})
    set_now(mock_now + 10)
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("RST after progress → no fire", false, r)
end

-- T6: nld=2 — stall on static.cf.com, retry GET on api.cf.com → fire
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("static.cf.com")
    z2k_http_mid_stream_stall(fA.out_req(), {})
    deliver(fA, 100, 1500, 14)                        -- A delivers ~21000 bytes
    set_now(1025)
    local fB = mk_flow("api.cf.com")
    local r = z2k_http_mid_stream_stall(fB.out_req(), {})
    check("nld=2 cross-subdomain stall → fire", true, r)
end

-- T7: parallel preconnect — second GET right after recent progress
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(f.out_req(), {})
    deliver(f, 100, 1500, 14)                         -- last progress mock_now=1014
    set_now(1015)                                     -- silence 1s
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("parallel preconnect (no silence) → no fire", false, r)
end

-- T8: z2k_tls_alert_fatal inheritance — upstream fail → mid_stream fires
do
    reset_detector()
    z2k_tls_alert_fatal = function() return true end
    set_now(1000)
    local f = mk_flow("a.example.com")
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("z2k_tls_alert_fatal inheritance fires through", true, r)
end

-- T9: stale state — silence > RETRY_MAX_SEC → no fire
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(f.out_req(), {})
    deliver(f, 100, 1500, 14)
    set_now(1300)                                     -- 286s later > RETRY_MAX_SEC
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("stale state (>RETRY_MAX_SEC) → no fire", false, r)
end

-- T10: interleaved parallel flows — A stalls in window, B succeeds.
-- B's success must NOT clear A's candidate.
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("static.cf.com")
    z2k_http_mid_stream_stall(fA.out_req(), {})       -- last_req=1000
    deliver(fA, 100, 1500, 14)                        -- A ~21000 (in window)
    set_now(1015)
    local fB = mk_flow("api.cf.com")
    z2k_http_mid_stream_stall(fB.out_req(), {})       -- last_req=1015
    deliver(fB, 50000, 1500, 23)                      -- B ~34500 (>HI, success)
    set_now(1040)                                     -- silence on A ~26s, gap=25s
    local fC = mk_flow("static.cf.com")
    local r = z2k_http_mid_stream_stall(fC.out_req(), {})
    check("parallel B success does NOT cross-clear A's candidate", true, r)
end

-- T11: per-flow FIN ownership — flow B FINs, A still stalled.
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("static.cf.com")
    local fB = mk_flow("api.cf.com")
    z2k_http_mid_stream_stall(fA.out_req(), {})
    deliver(fA, 100, 1500, 14)                        -- A publishes candidate
    set_now(mock_now + 1)
    z2k_http_mid_stream_stall(fB.in_pkt(50000, 0, TH_FIN + TH_ACK), {})
    set_now(1030)                                     -- silence on A ~16s
    local fC = mk_flow("static.cf.com")
    local r = z2k_http_mid_stream_stall(fC.out_req(), {})
    check("parallel B FIN does NOT clear A's candidate", true, r)
end

-- T12: active-retry gate — single GET after stall (no prior GET) → no fire
do
    reset_detector(); set_now(1000)
    local f = mk_flow("a.example.com")
    -- No GET first — drop straight to incoming packets to build candidate
    -- without setting last_req_ts.
    deliver(f, 100, 1500, 14)                         -- candidate, last_progress=1014
    set_now(1050)                                     -- silence 36s, well > SILENCE
    -- First GET on this key — prev_req_ts == 0, ch_gap is huge,
    -- active-retry gate suppresses fire.
    local r = z2k_http_mid_stream_stall(f.out_req(), {})
    check("single GET after stall (no prior GET) → no fire", false, r)
end

-- T13: GET gap > ACTIVE_RETRY_SEC → no fire (two isolated visits)
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(fA.out_req(), {})       -- GET1 t=1000
    deliver(fA, 100, 1500, 14)                        -- candidate, last_progress~1014
    set_now(1100)                                     -- 100s later > ACTIVE_RETRY
    local fB = mk_flow("a.example.com")
    local r = z2k_http_mid_stream_stall(fB.out_req(), {})
    check("GET gap > ACTIVE_RETRY_SEC → no fire", false, r)
end

-- T14: missing lua_state — graceful no-op
do
    reset_detector(); set_now(1000)
    local desync = {
        outgoing  = true,
        l7payload = "http_req",
        track     = { hostname = "a.example.com" },  -- no lua_state
        dis       = { payload = "GET / HTTP/1.1\r\n",
                      tcp = { th_seq = 1, th_flags = TH_PUSH + TH_ACK } },
    }
    local r = z2k_http_mid_stream_stall(desync, {})
    check("missing lua_state → no fire (graceful)", false, r)
end

-- T15: stale candidate auto-cleared on GET so a NEW flow can publish fresh
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(fA.out_req(), {})       -- GET1 t=1000
    deliver(fA, 100, 1500, 14)                        -- A publishes candidate t=1014
    set_now(1300)                                     -- 286s later > RETRY_MAX_SEC
    local fB = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(fB.out_req(), {})       -- GET on B → stale-clears
    deliver(fB, 100, 1500, 14)                        -- B's data t=1301..1314
    set_now(1325)                                     -- silence ~11s, gap=25s
    local fC = mk_flow("a.example.com")
    local r = z2k_http_mid_stream_stall(fC.out_req(), {})
    check("stale A cleared, B can fire on fresh stall", true, r)
end

-- T16: active-retry gate also clears candidate
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(fA.out_req(), {})       -- GET1 t=1000
    deliver(fA, 100, 1500, 14)                        -- candidate t=1014
    set_now(1100)                                     -- gap=100s > 30s
    local fB = mk_flow("a.example.com")
    z2k_http_mid_stream_stall(fB.out_req(), {})       -- GET2 suppressed, clears
    set_now(1105)                                     -- gap=5s ≤ 30s
    local fC = mk_flow("a.example.com")
    local r = z2k_http_mid_stream_stall(fC.out_req(), {})
    check("rapid GET after suppressed GET does NOT ride on stale cand",
          false, r)
end

-- T17: inverse parallel — A enters [LO, HI] first, B also stalls in
-- [LO, HI]; A then crosses past HI clearing only its own entry; B's
-- entry preserved → retry fires on B.
do
    reset_detector(); set_now(1000)
    local fA = mk_flow("static.cf.com")
    local fB = mk_flow("api.cf.com")
    z2k_http_mid_stream_stall(fA.out_req(), {})       -- last_req=1000
    deliver(fA, 100, 1500, 14)                        -- A: max_seq=21000 (in window)
    set_now(1015)
    z2k_http_mid_stream_stall(fB.out_req(), {})       -- last_req=1015
    deliver(fB, 50000, 1500, 12)                      -- B: max_seq=18000 (in window)
                                                      -- B publishes its candidate
                                                      -- B then stalls
    -- A continues past HI=32000: 9 more packets, max_seq=21000+9*1500=34500
    deliver(fA, 100 + 14 * 1500, 1500, 9)             -- A's candidate cleared
    set_now(1040)                                     -- gap from fB GET=25s ≤ 30s
    local fC = mk_flow("static.cf.com")
    local r = z2k_http_mid_stream_stall(fC.out_req(), {})
    check("inverse parallel: A success, B stalled fires", true, r)
end

-- ----- result -------------------------------------------------------------

print(string.format("\n%d passed, %d failed", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
