-- tests/test_silent_drop_detector.lua
-- Unit tests for z2k_silent_drop_detector (z2k-detectors.lua).
--
-- Run: lua tests/test_silent_drop_detector.lua
-- Exit code 0 on green, 1 on any failure.
--
-- Covers the 4 behavioural cases from the 2026-05-15 fix commit
-- (handshake_seen marker + server-flight bytes bypass) plus chain-
-- delegation invariant (siblings z2k_mid_stream_stall, z2k_tls_stalled
-- etc. continue to run regardless of silent-drop bypass).
--
-- Loads the real detector via dofile, then replaces sibling detectors
-- with traceable stubs so we can assert delegation behaviour
-- independently of their internal logic.

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
do
    local mt = getmetatable(os) or {}
    mt.__index = mt.__index or {}
    os.time = function() return mock_now end
end

function standard_hostkey(desync)
    local host = desync and desync.track and desync.track.hostname
    if type(host) ~= "string" or host == "" then return nil end
    return host
end

Z2K_DETECTOR_MAP_MAX        = 4096
Z2K_DETECTOR_EVICT_BATCH    = 1024
Z2K_DETECTOR_EVICT_INTERVAL = 4096

-- DLOG is the upstream debug logger; the detector calls it on the
-- failure path. Tests don't care about its output, so stub it.
DLOG = function() end

-- ----- load detector under test -------------------------------------------

dofile("files/lua/z2k-detectors.lua")

-- ----- delegation tracer --------------------------------------------------
--
-- Sibling detectors in the chain are replaced with stubs that record an
-- invocation and return false (= "I didn't catch anything"). After each
-- call we read the tracer to assert that delegation either ran or
-- short-circuited — the silent-drop bypasses must not silently skip the
-- chain.

local chain_calls
local function reset_chain()
    chain_calls = {
        mid_stream      = 0,
        http_mid_stream = 0,
        http_partial    = 0,
        tls_stalled     = 0,
        tls_alert       = 0,
    }
end

z2k_mid_stream_stall      = function() chain_calls.mid_stream      = chain_calls.mid_stream      + 1; return false end
z2k_http_mid_stream_stall = function() chain_calls.http_mid_stream = chain_calls.http_mid_stream + 1; return false end
z2k_http_partial_response = function() chain_calls.http_partial    = chain_calls.http_partial    + 1; return false end
z2k_tls_stalled           = function() chain_calls.tls_stalled     = chain_calls.tls_stalled     + 1; return false end
z2k_tls_alert_fatal       = function() chain_calls.tls_alert       = chain_calls.tls_alert       + 1; return false end

-- ----- helpers ------------------------------------------------------------

-- Build an outgoing TCP packet desync struct with explicit packet/byte
-- counters in track.pos.direct (outgoing) / track.pos.reverse (incoming).
-- The silent-drop detector reads pdcounter (packets-with-data) and
-- pbcounter (bytes-of-data) from these tables.
local function out_packet(out_pkts, in_pkts, in_bytes_arg, out_bytes_arg)
    return {
        outgoing = true,
        track = {
            hostname = "test.example.com",
            pos = {
                direct  = { pdcounter = out_pkts, pbcounter = out_bytes_arg or 0 },
                reverse = { pdcounter = in_pkts,  pbcounter = in_bytes_arg  or 0 },
            },
        },
        dis = {
            payload = "encrypted",
            tcp = { th_seq = 1, th_flags = TH_PUSH + TH_ACK },
        },
    }
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

local function chain_total()
    return chain_calls.mid_stream + chain_calls.http_mid_stream
         + chain_calls.http_partial + chain_calls.tls_stalled
         + chain_calls.tls_alert
end

-- ----- tests --------------------------------------------------------------

print("--- z2k_silent_drop_detector ---")

-- Case 1: marker=false, in_bytes<3KB, out>=4, in<=1 → FAIL (real silent drop)
-- Detector fires on the silent-drop signal; chain is NOT consulted
-- because the wrapper returns early after detecting drop.
do
    reset_chain()
    local crec = {}
    local d = out_packet(4, 1, 200, 0)
    local fired = z2k_silent_drop_detector(d, crec)
    check("case1: real silent drop fires",            true, fired)
    check("case1: chain not called after early-true", 0,    chain_total())
end

-- Case 2: marker=false, in_bytes<3KB, out<4 → silent-drop branch
-- doesn't fire (insufficient evidence); chain still delegates fully.
do
    reset_chain()
    local crec = {}
    local d = out_packet(3, 1, 200, 0)
    local fired = z2k_silent_drop_detector(d, crec)
    check("case2: out<4 doesn't fire silent-drop",     false, fired)
    check("case2: chain ran (mid_stream)",             1,     chain_calls.mid_stream)
    check("case2: chain ran (http_mid_stream)",        1,     chain_calls.http_mid_stream)
    check("case2: chain ran (http_partial_response)",  1,     chain_calls.http_partial)
    check("case2: chain ran (tls_stalled)",            1,     chain_calls.tls_stalled)
    check("case2: chain ran (tls_alert_fatal)",        1,     chain_calls.tls_alert)
end

-- Case 3: marker=false, in_bytes>=3KB, out>=4, in<=1 → silent-drop
-- bypassed (server flight complete); chain still runs.
-- This is the post-handshake HTTP/2 multiplexing scenario from the
-- 2026-05-14 instagram.com regression.
do
    reset_chain()
    local crec = {}
    local d = out_packet(5, 1, 4000, 8000)
    local fired = z2k_silent_drop_detector(d, crec)
    check("case3: server-flight bypass skips silent-drop", false, fired)
    check("case3: chain still runs (mid_stream)",          1,     chain_calls.mid_stream)
    check("case3: chain still runs (tls_alert)",           1,     chain_calls.tls_alert)
end

-- Case 4: marker=true (positive HTTP observed), any counters → bypass
-- silent-drop; chain still runs.
do
    reset_chain()
    local crec = { z2k_handshake_seen = true }
    local d = out_packet(10, 1, 100, 50000)
    local fired = z2k_silent_drop_detector(d, crec)
    check("case4: handshake_seen marker bypasses silent-drop", false, fired)
    check("case4: chain still runs (mid_stream)",              1,     chain_calls.mid_stream)
    check("case4: chain still runs (http_partial_response)",   1,     chain_calls.http_partial)
end

-- Case 5: crec.nocheck=true → early return for silent-drop heuristic
-- AND chain delegation. This is the canonical "this conntrack already
-- classified as success" short-circuit — but the nocheck guard runs
-- AFTER server-active classification (case 5b regression below), so
-- protocol-level rejection signals are still observed.
do
    reset_chain()
    local crec = { nocheck = true }
    local d = out_packet(10, 1, 200, 50000)
    local fired = z2k_silent_drop_detector(d, crec)
    check("case5: crec.nocheck short-circuits silent-drop", false, fired)
    check("case5: crec.nocheck skips chain too",            0,     chain_total())
    check("case5: nocheck does NOT spuriously stamp server-active",
        nil, crec.z2k_server_active_reject)
end

-- Case 5b (review-2026-05-17 RV5.1): real path ServerHello → nocheck
-- latched → next packet is incoming post-SH TLS fatal alert. nocheck
-- guard MUST NOT prevent z2k_classify_server_active from stamping
-- crec.z2k_server_active_reject. Before the fix, the nocheck early-
-- return in z2k_silent_drop_detector swallowed the alert before the
-- classifier ran, leaving autocircular without the marker.
do
    reset_chain()
    local crec = { nocheck = true }
    -- TLS alert record: type=0x15, ver=0x0303, len=2, level=fatal(2),
    -- desc=handshake_failure(40)=0x28.
    local alert = "\x15\x03\x03\x00\x02\x02\x28"
    local d = {
        outgoing = false,
        l7payload = "tls_alert",
        track = {
            hostname = "post-sh-alert.example.com",
            pos = {
                direct  = { pdcounter = 2, pbcounter = 200 },
                reverse = { pdcounter = 3, pbcounter = 200 },  -- > 60 → after SH
            },
        },
        dis = { payload = alert, tcp = { th_flags = 0 } },
    }
    local fired = z2k_silent_drop_detector(d, crec)
    check("case5b: silent-drop returns false for server-active path",
        false, fired)
    check("case5b: crec.z2k_server_active_reject stamped despite nocheck",
        true, crec.z2k_server_active_reject == true)
    check("case5b: reason carries server_active: prefix",
        true,
        type(crec.z2k_reason) == "string" and
        crec.z2k_reason:sub(1, 14) == "server_active:")
end

-- Case 5c: bare 451 was previously stamped as server_active_reject;
-- post-narrowing (current semantics) bare 451 → neutral, autocircular keeps
-- rotating since fingerprint-mask strategies can still bypass origin
-- geo-policy. nocheck-latched flow must NOT spuriously stamp the
-- marker for bare 451.
do
    reset_chain()
    local crec = { nocheck = true }
    local d = {
        outgoing = false,
        l7payload = "http_reply",
        track = {
            hostname = "bare-451.example.com",
            pos = {
                direct  = { pdcounter = 1, pbcounter = 100 },
                reverse = { pdcounter = 2, pbcounter = 100 },
            },
        },
        dis = {
            payload = "HTTP/1.1 451 Unavailable For Legal Reasons\r\n\r\n",
            tcp = { th_flags = 0 },
        },
    }
    local fired = z2k_silent_drop_detector(d, crec)
    check("case5c: silent-drop returns false for bare-451 path",
        false, fired)
    check("case5c: crec.z2k_server_active_reject NOT stamped on bare 451 (current semantics)",
        true, crec.z2k_server_active_reject ~= true)
end

-- Case 6: boundary on bytes_in_handshake_done (default 3072).
-- in_bytes=3071 → silent-drop fires; in_bytes=3072 → bypass.
-- Asserted explicitly because the reviewer's reproducer hinges on
-- exact boundary semantics — make it visible in the test suite.
do
    reset_chain()
    local fired_just_below = z2k_silent_drop_detector(out_packet(4, 1, 3071, 0), {})
    check("case6a: in_bytes=3071 fires (just below threshold)", true, fired_just_below)

    reset_chain()
    local fired_at_boundary = z2k_silent_drop_detector(out_packet(4, 1, 3072, 0), {})
    check("case6b: in_bytes=3072 bypasses (at threshold)", false, fired_at_boundary)
end

-- Case 7: parametric override via arg table — operator can lower
-- bytes_in_handshake_done for known-PSK/resumption-heavy profiles
-- without losing other detectors.
do
    reset_chain()
    local arg = { bytes_in_handshake_done = 256 }
    local fired = z2k_silent_drop_detector(out_packet(4, 1, 300, 0), {}, arg)
    check("case7: lowered threshold via arg bypasses at in_bytes=300", false, fired)
end

-- Case 8: parametric override of packet-count contract — tcp_out=2
-- shifts the silent-drop trigger left for HTTP profiles that bursts
-- fewer outgoing requests before timeout.
do
    reset_chain()
    local arg = { tcp_out = 2, tcp_in = 1 }
    local fired = z2k_silent_drop_detector(out_packet(2, 1, 200, 0), {}, arg)
    check("case8: tcp_out=2 arg lowers fire threshold", true, fired)
end

-- ----- summary ------------------------------------------------------------

print("--- summary ---")
print(string.format("PASSED: %d", PASS))
print(string.format("FAILED: %d", FAIL))
os.exit(FAIL == 0 and 0 or 1)
