-- Unit test for the yt_quic byte-based rotation detectors
-- (z2k_quic_success / z2k_quic_stall in files/lua/z2k-detectors.lua).
--
-- Root they fix: the standard UDP success latched on the 2nd incoming datagram
-- (udp_in=1) → pinned slot1, yt_quic NEVER rotated (debug-proven 2026-06-05).
-- These pin only on sustained DOWNLOAD (>24KB) and rotate off a stalled slot.
--
-- DIRECTION is the load-bearing detail (a prior auto-draft inverted it):
--   success runs on INCOMING → pos_get('b') [no reverse] = download.
--   stall   runs on OUTGOING → pos_get('d',false)=client pkts, pos_get('b',true)=download.
-- Run from repo root:  lua tests/test_quic_detectors.lua

DLOG = function() end

-- Controllable stubs. pos_get(desync, mode, reverse):
--  the harness sets DL (download bytes) and OUT (client datagram count); the
--  detectors must read DL for both 'b' reads (success no-reverse on incoming,
--  stall reverse on outgoing both resolve to download) and OUT for 'd'.
local DL, OUT = 0, 0
function pos_get(_, mode, _)
  if mode == 'b' then return DL end
  if mode == 'd' then return OUT end
  return 0
end

dofile("files/lua/z2k-detectors.lua")

local pass, fail = 0, 0
local function ck(name, got, want)
  if got == want then
    pass = pass + 1
    print("[PASS] " .. name)
  else
    fail = fail + 1
    print("[FAIL] " .. name .. " got=" .. tostring(got) .. " want=" .. tostring(want))
  end
end
local function mk(outgoing) return { outgoing = outgoing, dis = { udp = true }, track = { pos = {} } } end

-- success: pin only on sustained download
DL = 30000; ck("success: 30KB download -> pin",                z2k_quic_success(mk(false), {}), true)
DL = 24576; ck("success: exactly 24576 (not > ) -> no pin",    z2k_quic_success(mk(false), {}), false)
DL = 5000;  ck("success: 5KB (handshake only) -> no pin",      z2k_quic_success(mk(false), {}), false)
DL = 30000; ck("success: outgoing packet -> false (in only)",  z2k_quic_success(mk(true), {}),  false)

-- stall: rotate off a slot that burns datagrams without delivering download
OUT = 10; DL = 5000;  ck("stall: out10 dl5KB -> fail",                 z2k_quic_stall(mk(true), {}), true)
OUT = 8;  DL = 0;     ck("stall: out8 dl0 (dead flow) -> fail",        z2k_quic_stall(mk(true), {}), true)
OUT = 10; DL = 30000; ck("stall: out10 dl30KB (working) -> no fail",   z2k_quic_stall(mk(true), {}), false)
OUT = 4;  DL = 2000;  ck("stall: out4 small-call -> no fail",          z2k_quic_stall(mk(true), {}), false)
OUT = 10; DL = 5000;  ck("stall: incoming packet -> false (out only)", z2k_quic_stall(mk(false), {}), false)

-- guard: non-udp / no-track must be inert
do
  local d = mk(false); d.dis = { tcp = true }; DL = 99999
  ck("success: non-udp (tcp) -> false", z2k_quic_success(d, {}), false)
end

print("--- " .. pass .. " PASS / " .. fail .. " FAIL ---")
os.exit(fail == 0 and 0 or 1)
