-- tests/test_native_detector.lua
-- Proves bol-van's STANDARD detectors (standard_failure_detector /
-- standard_success_detector in zapret2-z2k-fork/lua/zapret-auto.lua) cover the
-- block classes we built custom detectors for — WITHOUT any outgoing-packet-count
-- heuristic, so they cannot false-rotate working HTTP/2 hosts (the r-49 class).
--
-- This is the evidence behind Z2K_NATIVE_DETECTORS=1 (config_official.sh): with
-- the connmark-reply fix making incoming RSTs visible, the standard detector's
-- three native failure signals replace z2k_silent_drop_detector:
--   1. incoming RST  (seq<=inseq)                 -> DPI reset
--   2. outgoing retransmission >= retrans(=3)      -> SILENT DROP (no RST):
--      the client's own TCP retransmits when the server flight is dropped.
--   3. DPI http redirect (302/307)                 -> tested elsewhere
-- and success = enough reverse bytes flowed (seq>inseq) — a blocked path never
-- reaches it, a working host always does.
--
-- Run: lua tests/test_native_detector.lua   (exit 0 green, 1 on any fail)

-- ----- version-safe bitand --------------------------------------------------
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

-- ----- runtime mocks the engine expects -------------------------------------
TH_FIN, TH_SYN, TH_RST, TH_PUSH, TH_ACK = 0x01, 0x02, 0x04, 0x08, 0x10
b_debug = false
DLOG = function() end
DLOG_ERR = function() end

-- pos_get(desync, kind, reverse): the engine's relative position accessor.
--   's' -> relative tcp sequence   'n' -> udp packet count
--   'b' -> reverse byte counter     'd' -> reverse data-packet counter
function pos_get(desync, kind, reverse)
    if kind == 's' then return desync._seq or 0 end
    if kind == 'n' then return reverse and (desync._nin or 0) or (desync._nout or 0) end
    if kind == 'b' then return reverse and (desync._b or 0) or 0 end
    if kind == 'd' then return reverse and (desync._d or 0) or 0 end
    return 0
end

function is_retransmission(desync) return desync._retrans == true end

-- reset-branch helpers (only reached when arg.reset is set; we keep it off)
function deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepcopy(v) end
    return r
end
function dis_reverse() end
function rawsend_dissect() end
function http_dissect_reply() return nil end
function array_field_search() return nil end
function is_dpi_redirect() return false end

dofile((os.getenv("Z2K_ENGINE_LUA")) or "../zapret2-z2k-fork/lua/zapret-auto.lua")

-- ----- fixtures -------------------------------------------------------------
-- Incoming TCP packet with given flags + relative seq.
local function in_tcp(flags, seq, l7, host, payload)
    return {
        outgoing = false,
        l7payload = l7,
        track = { hostname = host },
        _seq = seq,
        dis = { tcp = { th_flags = flags }, payload = payload or "" },
    }
end
-- Outgoing TCP packet; retrans=true marks it a retransmission.
local function out_tcp(seq, retrans, payload)
    return {
        outgoing = true,
        _seq = seq,
        _retrans = retrans,
        dis = { tcp = { th_flags = TH_ACK }, payload = payload or "GETx" },
    }
end

-- ----- harness --------------------------------------------------------------
local PASS, FAIL = 0, 0
local function check(name, want, got)
    if want == got then
        PASS = PASS + 1
        print(string.format("[PASS] %s", name))
    else
        FAIL = FAIL + 1
        print(string.format("[FAIL] %s: want=%s got=%s", name, tostring(want), tostring(got)))
    end
end

print("--- standard_failure_detector ---")

-- (1) incoming DPI RST inside the inseq window -> FAIL. The flibusta-48 class,
-- now visible after the connmark-reply fix.
do
    local d = in_tcp(TH_RST + TH_ACK, 100, nil, "flibusta.is")
    d.arg = { inseq = 26000 }
    check("RST seq=100 (<=inseq) fires", true, standard_failure_detector(d, {}))
end

-- (2) incoming RST BEYOND the inseq window -> NOT a DPI reset (legit late RST).
do
    local d = in_tcp(TH_RST + TH_ACK, 90000, nil, "host")
    d.arg = { inseq = 26000 }
    check("RST seq=90000 (>inseq) does NOT fire", false, standard_failure_detector(d, {}))
end

-- (3) SILENT DROP with NO RST: the client retransmits its request because the
-- server flight was dropped. 3rd retransmission (retrans=3 default) -> FAIL.
-- This is the native replacement for z2k_silent_drop_detector.
do
    local crec = {}
    local arg = { inseq = 26000 } -- retrans/maxseq use defaults (3 / 32768)
    local function r() local d = out_tcp(500, true); d.arg = arg; return standard_failure_detector(d, crec) end
    check("silent-drop retrans #1 no fire", false, r())
    check("silent-drop retrans #2 no fire", false, r())
    check("silent-drop retrans #3 FIRES (>=retrans=3)", true, r())
end

-- (4) r-49 SAFETY: a plain incoming DATA packet (working host, no RST) must NOT
-- fire. The standard detector reacts ONLY to a real RST / retrans / redirect —
-- never to outgoing packet COUNT — so a working HTTP/2 host streaming data can
-- never be heuristically mistaken for a block.
do
    local d = in_tcp(TH_ACK + TH_PUSH, 5000, nil, "youtube.com", "appdata")
    d.arg = { inseq = 26000 }
    check("working-host incoming data does NOT fire", false, standard_failure_detector(d, {}))
end

-- (5) r-49 SAFETY: a NON-retransmitted outgoing packet must NOT fire (normal
-- request / keep-alive burst — the exact pattern silent_drop false-fired on).
do
    local d = out_tcp(800, false)
    d.arg = { inseq = 26000 }
    check("non-retransmit outgoing does NOT fire", false, standard_failure_detector(d, {}))
end

print("--- standard_success_detector ---")

-- (6) working host: reverse seq crosses inseq -> SUCCESS (resets failure counter,
-- pins the strategy). A blocked path never delivers this many bytes.
do
    local d = in_tcp(TH_ACK + TH_PUSH, 40000, nil, "youtube.com", "appdata")
    d.arg = { inseq = 26000 }
    check("incoming seq=40000 (>inseq) = success", true, standard_success_detector(d, {}))
end

-- (7) blocked path: only the handshake trickled in, below inseq -> NOT success,
-- so failures are free to accumulate and rotate.
do
    local d = in_tcp(TH_ACK, 3000, nil, "flibusta.is")
    d.arg = { inseq = 26000 }
    check("incoming seq=3000 (<inseq) NOT success", false, standard_success_detector(d, {}))
end

-- ----- summary --------------------------------------------------------------
print("--- summary ---")
print(string.format("PASSED: %d", PASS))
print(string.format("FAILED: %d", FAIL))
os.exit(FAIL == 0 and 0 or 1)
