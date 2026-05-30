-- tests/test_tls_stalled.lua
-- Unit tests for z2k_tls_stalled (z2k-detectors.lua).
--
-- Run: lua tests/test_tls_stalled.lua
-- Exit code 0 on green, 1 on any failure.
--
-- Focus: the ServerHello-validation relaxation (Этап 1 review, workflow
-- w4h4x4bif). z2k_tls_stalled fires a fail when an outgoing ClientHello is
-- retried inside [STALLED_SEC, MAX_SEC] with NO intervening ServerHello.
-- A valid incoming ServerHello must CLEAR the per-flow timestamp so the
-- next ClientHello is treated as a fresh visit (no fire). The old guard
-- `rec_len + 5 <= #p` required the whole TLS record to fit in the captured
-- segment and so false-rejected fragmented / coalesced ServerHello flights
-- (rec_len > #p) — the timestamp was never cleared and the next ClientHello
-- false-fired. These tests pin the fixed behaviour AND the anti-spoof
-- guards we deliberately kept.
--
-- The detector inherits z2k_tls_alert_fatal at entry; we override it to a
-- no-op AFTER load so only the SH-validation / CH-timing logic is exercised.

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

TH_FIN, TH_SYN, TH_RST, TH_PUSH, TH_ACK = 0x01, 0x02, 0x04, 0x08, 0x10

local mock_now = 1000
local function set_now(t) mock_now = t end
os.time = function() return mock_now end

function standard_failure_detector() return false end
function standard_hostkey(desync)
    return desync and desync.track and desync.track.hostname
end
DLOG = function() end
b_debug = false

dofile("files/lua/z2k-detectors.lua")

-- Neutralise the inherited fail-signal so we test SH/CH logic in isolation.
z2k_tls_alert_fatal = function() return false end

-- ----- helpers -------------------------------------------------------------

local function be16(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

-- Build a TLS-record-framed ServerHello payload.
--   rec_len : value written into record-length bytes (4-5)
--   hs_len  : value written into handshake-length bytes (8-9; byte 7 = 0)
--   total   : actual #payload — set < rec_len+5 to simulate fragmentation
--   hs_type : handshake type byte (6); 0x02 = ServerHello
local function sh_payload(rec_len, hs_len, total, hs_type)
    hs_type = hs_type or 0x02
    local hdr = string.char(0x16, 0x03, 0x03)   -- content_type=handshake, ver 3.3
        .. be16(rec_len)                         -- bytes 4-5 record length
        .. string.char(hs_type)                  -- byte 6 handshake type
        .. string.char(0x00)                     -- byte 7 hs_len MSB (24-bit)
        .. be16(hs_len)                          -- bytes 8-9 hs_len low
    if #hdr >= total then return hdr:sub(1, total) end
    return hdr .. string.rep("\0", total - #hdr)
end

local function ch(host)
    return { outgoing = true, l7payload = "tls_client_hello",
             track = { hostname = host },
             dis = { tcp = { th_flags = TH_ACK }, payload = "ch" } }
end

local function sh(host, payload)
    return { outgoing = false, l7payload = "tls_server_hello",
             track = { hostname = host },
             dis = { tcp = { th_flags = TH_ACK }, payload = payload } }
end

-- ----- harness -------------------------------------------------------------

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

print("--- z2k_tls_stalled ---")

-- Case 1 (THE FIX): a fragmented ServerHello (rec_len=5000 > #p=200) is a
-- legitimate handshake and MUST clear the stall timestamp, so the next
-- ClientHello is a fresh visit and does NOT fire. Pre-fix this false-fired.
do
    local host = "frag.example.com"
    set_now(1000); check("case1: first CH records, no fire", false, z2k_tls_stalled(ch(host), {}))
    set_now(1005); check("case1: fragmented SH returns false (not a CH retry)",
                         false, z2k_tls_stalled(sh(host, sh_payload(5000, 4996, 200)), {}))
    set_now(1025)
    check("case1: fragmented SH cleared ts -> next CH no false fire",
          false, z2k_tls_stalled(ch(host), {}))
end

-- Case 2 (no regression): a full, non-fragmented ServerHello still clears.
do
    local host = "full.example.com"
    set_now(2000); z2k_tls_stalled(ch(host), {})
    set_now(2005); z2k_tls_stalled(sh(host, sh_payload(100, 96, 200)), {})
    set_now(2025)
    check("case2: full SH clears ts -> next CH no fire",
          false, z2k_tls_stalled(ch(host), {}))
end

-- Case 3 (detector still works): two ClientHellos 15s apart with NO
-- ServerHello between them is a real handshake stall -> fire.
do
    local host = "stall.example.com"
    set_now(3000); z2k_tls_stalled(ch(host), {})
    set_now(3015)
    check("case3: CH retry @15s with no SH fires", true, z2k_tls_stalled(ch(host), {}))
end

-- Case 4 (anti-spoof kept): a record that is NOT a ServerHello
-- (handshake_type byte 6 != 0x02) must NOT clear the timestamp, so a
-- following CH retry still fires.
do
    local host = "spoof.example.com"
    set_now(4000); z2k_tls_stalled(ch(host), {})
    set_now(4005); z2k_tls_stalled(sh(host, sh_payload(100, 96, 200, 0x01)), {})
    set_now(4025)
    check("case4: non-ServerHello record does NOT clear ts -> CH still fires",
          true, z2k_tls_stalled(ch(host), {}))
end

-- Case 5 (header self-consistency kept): handshake length overruns the
-- declared record (hs_len+4 > rec_len) -> structurally invalid -> not
-- cleared -> following CH retry still fires.
do
    local host = "incon.example.com"
    set_now(5000); z2k_tls_stalled(ch(host), {})
    set_now(5005); z2k_tls_stalled(sh(host, sh_payload(100, 200, 300)), {})
    set_now(5025)
    check("case5: inconsistent record (hs_len+4 > rec_len) does NOT clear",
          true, z2k_tls_stalled(ch(host), {}))
end

-- ----- summary -------------------------------------------------------------

print("--- summary ---")
print(string.format("PASSED: %d", PASS))
print(string.format("FAILED: %d", FAIL))
os.exit(FAIL == 0 and 0 or 1)
