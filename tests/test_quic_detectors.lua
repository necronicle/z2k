-- Unit test for the yt_quic byte/progress-based rotation detectors
-- (z2k_quic_success / z2k_quic_stall in files/lua/z2k-detectors.lua).
--
-- Root they fix: standard UDP success latched on the 2nd incoming datagram
-- (udp_in=1) → pinned slot1, yt_quic NEVER rotated. A failing slot produces
-- SHORT abandoned connections, so a single-packet out>=8 threshold never fired.
-- z2k_quic_stall is now PROGRESS-based (mirrors z2k_mid_stream_stall): it tracks
-- max download + when it last grew in desync.track.lua_state.quic, and fires when
-- a connection actively retried (out>=3), lived >=2s, has <24KB download, and
-- download plateaued (no growth >=1s). A working slot crosses 24KB → success →
-- reset, before the 2s window, so it never accumulates.
--
-- DIRECTION (load-bearing): success on INCOMING → pos_get('b') [no reverse] =
-- download; stall on OUTGOING → pos_get('d',false)=client pkts, pos_get('b',true)
-- =download. Run from repo root:  lua tests/test_quic_detectors.lua

DLOG = function() end

-- controllable clock + counters
local NOW, DL, OUT = 0, 0, 0
os = os or {}
os.time = function() return NOW end
function pos_get(_, mode, _)
  if mode == 'b' then return DL end
  if mode == 'd' then return OUT end
  return 0
end

dofile("files/lua/z2k-detectors.lua")

local pass, fail = 0, 0
local function ck(name, got, want)
  if got == want then pass = pass + 1; print("[PASS] " .. name)
  else fail = fail + 1; print("[FAIL] " .. name .. " got=" .. tostring(got) .. " want=" .. tostring(want)) end
end
local function mk(outgoing) return { outgoing = outgoing, dis = { udp = true }, track = { pos = {}, lua_state = {} } } end

-- run a packet sequence {t,out,dl} on ONE outgoing desync (shared lua_state); return last verdict
local function run_stall(seq)
  local d = mk(true)
  local last = false
  for _, s in ipairs(seq) do
    NOW, OUT, DL = s[1], s[2], s[3]
    last = z2k_quic_stall(d, {})
  end
  return last
end

-- ---------- success ----------
NOW = 0
DL = 30000; ck("success: 30KB download -> pin",             z2k_quic_success(mk(false), {}), true)
DL = 24576; ck("success: exactly 24576 (not >) -> no pin",  z2k_quic_success(mk(false), {}), false)
DL = 5000;  ck("success: 5KB handshake -> no pin",          z2k_quic_success(mk(false), {}), false)
DL = 30000; ck("success: outgoing -> false (incoming only)",z2k_quic_success(mk(true), {}),  false)

-- ---------- stall: real failures ----------
-- handshake-OK-but-no-video: download plateaus at 5KB while client retries
ck("stall: handshake plateau (out3,age2,5KB,noprog2) -> fail",
   run_stall({ {0,1,5000}, {1,2,5000}, {2,3,5000} }), true)
-- Initial-dropped: zero download, client retransmitting
ck("stall: initial-dropped (out3,age2,0B) -> fail",
   run_stall({ {0,1,0}, {1,2,0}, {2,3,0} }), true)

-- ---------- stall: must NOT fire ----------
-- working: download keeps GROWING each packet -> progress fresh -> never stalls
ck("stall: working ramp (download grows) -> no fail",
   run_stall({ {0,1,2000}, {1,2,8000}, {2,3,18000} }), false)
-- young connection: age<2s
ck("stall: young (age0) -> no fail",
   run_stall({ {0,3,5000} }), false)
-- recent progress: download just grew this second -> no-progress=0
ck("stall: recent progress (grew at age2) -> no fail",
   run_stall({ {0,1,5000}, {1,2,5000}, {2,3,9000} }), false)
-- quick preconnect: out<3
ck("stall: preconnect (out2) -> no fail",
   run_stall({ {0,1,0}, {1,2,0} }), false)
-- incoming packet: stall is outgoing-only
do NOW, OUT, DL = 5, 3, 0; ck("stall: incoming -> false (outgoing only)", z2k_quic_stall(mk(false), {}), false) end

-- ---------- guards ----------
do
  local d = mk(true); d.dis = { tcp = true }; NOW, OUT, DL = 5, 5, 0
  ck("stall: non-udp (tcp) -> false", z2k_quic_stall(d, {}), false)
end
do
  local d = mk(false); d.dis = { tcp = true }; DL = 99999
  ck("success: non-udp (tcp) -> false", z2k_quic_success(d, {}), false)
end

print("--- " .. pass .. " PASS / " .. fail .. " FAIL ---")
os.exit(fail == 0 and 0 or 1)
