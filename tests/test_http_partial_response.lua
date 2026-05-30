-- tests/test_http_partial_response.lua
-- Unit tests for z2k_http_partial_response (per-flow rewrite, task #11).
--
-- Run: lua tests/test_http_partial_response.lua
-- Exit code 0 on green, 1 on any failure.
--
-- The detector compares a response's advertised Content-Length against the
-- bytes actually received, measured per-flow via the cumulative reverse
-- byte counter (desync.track.pos.reverse.pbcounter) anchored on the outgoing
-- http_req. State lives in desync.track.lua_state.http_partial. These tests
-- drive complete / capped / keep-alive / chunked / below-threshold flows and
-- the graceful-degradation guards. The OLD implementation summed #payload
-- only on http_reply-tagged packets and so false-FAILed every multi-packet
-- response — the complete-response cases here are the regression guard.

-- ----- mocks ---------------------------------------------------------------

if _VERSION >= "Lua 5.3" then
    bitand = assert(load("return function(a, b) return a & b end"))()
else
    function bitand(a, b) return 0 end
end
TH_FIN, TH_SYN, TH_RST, TH_PUSH, TH_ACK = 0x01, 0x02, 0x04, 0x08, 0x10
os.time = os.time
function standard_failure_detector() return false end
function standard_hostkey(d) return d and d.track and d.track.hostname end
DLOG = function() end
b_debug = false

dofile("files/lua/z2k-detectors.lua")

-- ----- helpers -------------------------------------------------------------

-- Build a desync packet. `ls` is the shared per-flow lua_state table; `pb`
-- is the cumulative reverse pbcounter value at this point in the flow.
local function mk(host, ls, outgoing, l7, pb, payload)
    return {
        outgoing = outgoing,
        l7payload = l7,
        track = {
            hostname = host,
            lua_state = ls,
            pos = { reverse = { pbcounter = pb } },
        },
        dis = { tcp = { th_flags = TH_ACK }, payload = payload },
    }
end

local function reply_payload(cl)
    return "HTTP/1.1 200 OK\r\n"
        .. "Content-Length: " .. cl .. "\r\n"
        .. "Content-Type: text/html\r\n\r\n"
        .. "<!doctype html><html>"
end

-- header length exactly as the detector computes it (offset of \r\n\r\n + 3)
local function hdr_len(payload)
    local p = string.find(payload, "\r\n\r\n", 1, true)
    return p and (p + 3) or 0
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

print("--- z2k_http_partial_response ---")

-- Case 1: complete multi-packet response (received == CL+headers) -> NO fire.
-- This is the direct regression guard against the old false-FAIL bug.
do
    local ls, host = {}, "complete.example.com"
    local CL = 20000
    local body = reply_payload(CL)
    local hl = hdr_len(body)
    check("c1: req1 anchors, no fire", false,
          z2k_http_partial_response(mk(host, ls, true, "http_req", 0, "GET / HTTP/1.1\r\n\r\n")))
    z2k_http_partial_response(mk(host, ls, false, "http_reply", #body, body))
    check("c1: complete response -> no fire", false,
          z2k_http_partial_response(mk(host, ls, true, "http_req", hl + CL, "GET / HTTP/1.1\r\n\r\n")))
end

-- Case 2: body capped at 6000 of 20000 -> fire on the retry request.
do
    local ls, host = {}, "capped.example.com"
    local CL = 20000
    local body = reply_payload(CL)
    local hl = hdr_len(body)
    z2k_http_partial_response(mk(host, ls, true, "http_req", 0, "GET / HTTP/1.1\r\n\r\n"))
    z2k_http_partial_response(mk(host, ls, false, "http_reply", #body, body))
    check("c2: capped response fires on retry", true,
          z2k_http_partial_response(mk(host, ls, true, "http_req", hl + 6000, "GET / HTTP/1.1\r\n\r\n")))
end

-- Case 3: keep-alive, two complete responses -> no false fire (exercises the
-- per-request re-anchoring so response #2 is measured independently).
do
    local ls, host = {}, "ka.example.com"
    local CL = 10000
    local body = reply_payload(CL)
    local hl = hdr_len(body)
    z2k_http_partial_response(mk(host, ls, true, "http_req", 0, "GET /a HTTP/1.1\r\n\r\n"))
    z2k_http_partial_response(mk(host, ls, false, "http_reply", #body, body))
    check("c3: resp1 complete -> no fire", false,
          z2k_http_partial_response(mk(host, ls, true, "http_req", hl + CL, "GET /b HTTP/1.1\r\n\r\n")))
    z2k_http_partial_response(mk(host, ls, false, "http_reply", (hl + CL) + #body, body))
    check("c3: resp2 complete (re-anchored) -> no fire", false,
          z2k_http_partial_response(mk(host, ls, true, "http_req", 2 * (hl + CL), "GET /c HTTP/1.1\r\n\r\n")))
end

-- Case 4: chunked / no Content-Length -> never measured, never fires.
do
    local ls, host = {}, "chunked.example.com"
    local body = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    z2k_http_partial_response(mk(host, ls, true, "http_req", 0, "GET / HTTP/1.1\r\n\r\n"))
    z2k_http_partial_response(mk(host, ls, false, "http_reply", #body, body))
    check("c4: chunked/no-CL never fires", false,
          z2k_http_partial_response(mk(host, ls, true, "http_req", 500, "GET / HTTP/1.1\r\n\r\n")))
end

-- Case 5: response below MIN_EXPECTED (CL=5000 < 8000) -> not measured.
do
    local ls, host = {}, "small.example.com"
    local CL = 5000
    local body = reply_payload(CL)
    local hl = hdr_len(body)
    z2k_http_partial_response(mk(host, ls, true, "http_req", 0, "GET / HTTP/1.1\r\n\r\n"))
    z2k_http_partial_response(mk(host, ls, false, "http_reply", #body, body))
    check("c5: below MIN_EXPECTED never fires", false,
          z2k_http_partial_response(mk(host, ls, true, "http_req", hl + 1000, "GET / HTTP/1.1\r\n\r\n")))
end

-- Case 6: graceful — missing lua_state -> no fire (no crash).
do
    local d = {
        outgoing = true, l7payload = "http_req",
        track = { hostname = "x", pos = { reverse = { pbcounter = 100 } } },
        dis = { tcp = {}, payload = "GET" },
    }
    check("c6: missing lua_state -> no fire", false, z2k_http_partial_response(d))
end

-- Case 7: graceful — missing reverse pbcounter -> no fire (cannot measure).
do
    local d = {
        outgoing = true, l7payload = "http_req",
        track = { hostname = "x", lua_state = {}, pos = { reverse = {} } },
        dis = { tcp = {}, payload = "GET" },
    }
    check("c7: missing pbcounter -> no fire", false, z2k_http_partial_response(d))
end

-- Case 8: a cap fires exactly once; a following request with NO new reply
-- (expected reset to 0) must not double-fire.
do
    local ls, host = {}, "once.example.com"
    local CL = 20000
    local body = reply_payload(CL)
    local hl = hdr_len(body)
    z2k_http_partial_response(mk(host, ls, true, "http_req", 0, "GET / HTTP/1.1\r\n\r\n"))
    z2k_http_partial_response(mk(host, ls, false, "http_reply", #body, body))
    check("c8: cap fires once", true,
          z2k_http_partial_response(mk(host, ls, true, "http_req", hl + 6000, "GET / HTTP/1.1\r\n\r\n")))
    check("c8: no double-fire without a new reply", false,
          z2k_http_partial_response(mk(host, ls, true, "http_req", hl + 6000, "GET / HTTP/1.1\r\n\r\n")))
end

-- Case 9: crec.nocheck short-circuits.
do
    check("c9: crec.nocheck short-circuits", false,
          z2k_http_partial_response(mk("nc.example.com", {}, true, "http_req", 100, "GET"),
                                    { nocheck = true }))
end

-- ----- summary -------------------------------------------------------------

print("--- summary ---")
print(string.format("PASSED: %d", PASS))
print(string.format("FAILED: %d", FAIL))
os.exit(FAIL == 0 and 0 or 1)
