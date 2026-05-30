-- tests/test_z2k_state_persist.lua
-- Unit tests for z2k-state-persist.lua — the PERSIST-ONLY layer over the native
-- circular(): a single state.tsv, full-file merge-rewrite, persist on every
-- outgoing initial packet (incl. the default strategy 1, so working-on-default
-- profiles still show), allow_nohost handling, restart restore, config clamp.
--
-- This mirrors the proven pre-r-41 z2k-autocircular persist core 1:1.
-- The .sh wrapper points Z2K_STATE_DIR_OVERRIDE / fallback at an isolated tmp dir.

local PASS, FAIL = 0, 0
local function check(name, want, got)
  if want == got then
    PASS = PASS + 1; print("[PASS] " .. name)
  else
    FAIL = FAIL + 1
    print(string.format("[FAIL] %s: want=%s got=%s", name, tostring(want), tostring(got)))
  end
end

local STATE_DIR  = assert(os.getenv("Z2K_STATE_DIR_OVERRIDE"), "Z2K_STATE_DIR_OVERRIDE must be set by wrapper")
local STATE_FILE = STATE_DIR .. "/state.tsv"

-- ---- controllable clock ----
local now = 1000
os.time = function() return now end   -- luacheck: ignore

-- ---- nfqws2 runtime mocks (must exist BEFORE loading the module) ----
autostate = {}

function host_ip(desync)              -- raises if target nil (mirrors zapret-lib)
  return (desync.target.ip) or (desync.target.ip6)
end

function standard_hostkey(desync)     -- mirrors zapret-auto.lua
  local hostkey = desync.track and desync.track.hostname
  if hostkey then
    return hostkey
  elseif not (desync.arg and desync.arg.reqhost) then
    hostkey = host_ip(desync)
  end
  return hostkey
end

function z2k_nohost_key(desync)       -- mirrors z2k-modern-core.lua
  local t = desync and desync.track
  local h = t and t.hostname
  if h and #h > 0 and not (t and t.hostname_is_ip) then return h end
  return "nohost"
end

-- mock native circular(orig): no-track guard; derive ctstrategy from plan; keep
-- seeded nstrategy or default 1; optional _sim rotation; record `executed`.
local executed
function circular(ctx, desync)        -- luacheck: ignore
  if not desync or not desync.track then executed = nil; return 0 end
  local askey = (desync.arg and desync.arg.key) or desync.func_instance or "default"
  local hkf = (desync.arg and desync.arg.hostkey and _G[desync.arg.hostkey]) or standard_hostkey
  local hostkey = hkf(desync)
  if not hostkey then return 0 end
  autostate[askey] = autostate[askey] or {}
  local hrec = autostate[askey][hostkey] or {}
  autostate[askey][hostkey] = hrec
  if not hrec.ctstrategy then
    local uniq, n = {}, 0
    for _, ins in pairs(desync.plan or {}) do
      local s = ins.arg and tonumber(ins.arg.strategy)
      if s and s >= 1 and not uniq[s] then uniq[s] = true; n = n + 1 end
    end
    hrec.ctstrategy = n
  end
  if not hrec.nstrategy then hrec.nstrategy = 1 end
  if desync._sim then hrec.nstrategy = desync._sim end
  executed = nil
  for _, ins in pairs(desync.plan or {}) do
    if ins.arg and tonumber(ins.arg.strategy) == hrec.nstrategy then executed = hrec.nstrategy end
  end
  return 0
end

-- ---- load the module under test (wraps the mock circular) ----
dofile("files/lua/z2k-state-persist.lua")
local P = z2k_state_persist
assert(P, "z2k_state_persist export missing")

-- ---- helpers ----
local DEFAULT_PLAN = { {arg={strategy=1}}, {arg={strategy=2}}, {arg={strategy=3}} }

local function mk(key, host, opts)
  opts = opts or {}
  local d = {
    arg = { key = key },
    func_instance = key,
    track = { hostname = host },
    outgoing = (opts.outgoing ~= false),
    l7payload = opts.l7payload or "tls_client_hello",
    plan = opts.plan or DEFAULT_PLAN,
  }
  if opts.hostkey then d.arg.hostkey = opts.hostkey end
  if opts.allow_nohost then d.arg.allow_nohost = "1" end
  if opts.hostname_is_ip then d.track.hostname_is_ip = true end
  if opts.sim then d._sim = opts.sim end
  if opts.crec and d.track then d.track.lua_state = { automate = opts.crec } end
  if opts.no_track then d.track = nil end
  return d
end

local function read_state()
  local t = {}
  local f = io.open(STATE_FILE, "r")
  if not f then return t end
  for line in f:lines() do
    if line ~= "" and not line:match("^%s*#") then
      local k, h, s = line:match("^([^\t]+)\t([^\t]+)\t([0-9]+)")
      if k then t[k] = t[k] or {}; t[k][h] = tonumber(s) end
    end
  end
  f:close()
  return t
end

local function row(k, h)
  local t = read_state()
  return t[k] and t[k][h] or nil
end

local function write_file(contents)
  local f = assert(io.open(STATE_FILE, "w"))
  f:write(contents)
  f:close()
end

local function fresh()
  os.remove(STATE_FILE)
  os.remove(STATE_FILE .. ".lock")
  P._reset()
  autostate = {}
  P._set_interval(0)   -- disable the 2s debounce for deterministic tests
end

-- ===========================================================================
-- T1: a brand-new host the rotator keeps on strategy 1 IS recorded (1:1 with
-- the old autocircular — working-on-default profiles must show in the rotator).
fresh()
circular(nil, mk("rkn_tcp", "example.com"))
check("T1: cold default-1 host recorded (strategy 1)", 1, row("rkn_tcp", "example.com"))

-- T2: a real rotation (to strategy 2) is persisted.
fresh()
circular(nil, mk("rkn_tcp", "x.com", {sim = 2}))
check("T2: rotation to 2 persisted", 2, row("rkn_tcp", "x.com"))

-- T3: round-trip — written value is restored after a process restart (reset).
do
  fresh()
  circular(nil, mk("yt_tcp", "youtube.com", {sim = 3}))
  check("T3: pre-restart value written", 3, row("yt_tcp", "youtube.com"))
  P._reset(); autostate = {}            -- simulate nfqws2 restart (memory cleared)
  circular(nil, mk("yt_tcp", "youtube.com"))   -- first packet seeds from disk
  check("T3: nstrategy restored from disk", 3, autostate["yt_tcp"]["youtube.com"].nstrategy)
  check("T3: still 3 on disk after restart", 3, row("yt_tcp", "youtube.com"))
end

-- T4: no write when the strategy is unchanged (persist_if_changed returns false).
do
  fresh()
  local hrec = { nstrategy = 2 }
  check("T4: first persist returns true", true,  P.persist_if_changed("rkn_tcp", "a.com", hrec))
  check("T4: second persist (same) returns false", false, P.persist_if_changed("rkn_tcp", "a.com", hrec))
end

-- T5: on-disk format is `key<TAB>host<TAB>strategy<TAB>ts`.
do
  fresh()
  circular(nil, mk("rkn_tcp", "fmt.com", {sim = 2}))
  local f = io.open(STATE_FILE, "r"); local body = f:read("*a"); f:close()
  check("T5: row format key\\thost\\tstrat\\tts present", true,
        body:match("rkn_tcp\tfmt%.com\t2\t%d+") ~= nil)
end

-- T6: hostnames are normalized to lowercase before keying.
fresh()
circular(nil, mk("rkn_tcp", "MixedCase.COM", {sim = 2}))
check("T6: host lowercased on persist", 2, row("rkn_tcp", "mixedcase.com"))

-- T7: only OUTGOING INITIAL packets persist (a non-initial l7payload doesn't).
fresh()
circular(nil, mk("rkn_tcp", "noinit.com", {sim = 2, l7payload = "other"}))
check("T7: non-initial payload writes no row", nil, row("rkn_tcp", "noinit.com"))

-- T8: allow_nohost (discord_udp) — IP/no-hostname flow persists under "nohost".
fresh()
circular(nil, mk("discord_udp", nil, {hostkey = "z2k_nohost_key", allow_nohost = true,
                                      l7payload = "quic_initial", sim = 2}))
check("T8: discord nohost persisted under 'nohost'", 2, row("discord_udp", "nohost"))

-- T9: QUIC initial packets persist (yt_quic) — the path that was missing before.
fresh()
circular(nil, mk("yt_quic", "googlevideo.com", {l7payload = "quic_initial", sim = 2}))
check("T9: yt_quic QUIC-initial persisted", 2, row("yt_quic", "googlevideo.com"))

-- T10: config shrank (nstrategy beyond ctstrategy) → normalize to 1 + drop entry.
do
  fresh()
  write_file("# h\n# h2\nrkn_tcp\tshrink.com\t5\t900\n")  -- persisted 5 from a bigger config
  -- plan now has only 3 strategies → ctstrategy=3, seeded nstrategy=5 > 3.
  circular(nil, mk("rkn_tcp", "shrink.com", {plan = DEFAULT_PLAN}))
  check("T10: out-of-range nstrategy normalized to 1", 1, autostate["rkn_tcp"]["shrink.com"].nstrategy)
  check("T10: stale entry cleared from disk", nil, row("rkn_tcp", "shrink.com"))
end

-- T11: clear_persisted removes a host from disk (merge drops the deleted marker).
do
  fresh()
  circular(nil, mk("rkn_tcp", "del.com", {sim = 2}))
  check("T11: present before clear", 2, row("rkn_tcp", "del.com"))
  P.clear_persisted("rkn_tcp", "del.com")
  check("T11: removed after clear", nil, row("rkn_tcp", "del.com"))
end

-- T12: full-file rewrite keeps OTHER hosts (merge, no clobber).
do
  fresh()
  circular(nil, mk("rkn_tcp", "keepa.com", {sim = 2}))
  circular(nil, mk("rkn_tcp", "keepb.com", {sim = 3}))
  circular(nil, mk("yt_tcp",  "keepc.com", {sim = 3}))
  check("T12: host A kept", 2, row("rkn_tcp", "keepa.com"))
  check("T12: host B kept", 3, row("rkn_tcp", "keepb.com"))
  check("T12: host C (other key) kept", 3, row("yt_tcp", "keepc.com"))
end

-- T13: a flow with no conntrack track is a no-op (no crash, nothing written).
do
  fresh()
  local ok = pcall(function() circular(nil, mk("rkn_tcp", "x", {no_track = true})) end)
  check("T13: no-track flow does not crash", true, ok)
  check("T13: no-track flow wrote nothing", nil, row("rkn_tcp", "x"))
end

-- T14: an existing newer-ts on-disk row is not rolled back by the merge.
do
  fresh()
  write_file("# h\n# h2\nrkn_tcp\tmerge.com\t7\t5000\n")  -- newer ts already on disk
  P.load_state()
  -- a different host change triggers a rewrite; merge must preserve merge.com=7
  circular(nil, mk("rkn_tcp", "other.com", {sim = 2}))
  check("T14: pre-existing disk row preserved through rewrite", 7, row("rkn_tcp", "merge.com"))
  check("T14: new host also written", 2, row("rkn_tcp", "other.com"))
end

-- ===========================================================================
-- Sticky-success revert (THE accuracy fix, ported from legacy z2k-autocircular).
-- orig_circular drifts nstrategy on parallel failing flows even while the host
-- succeeds; if a real success happened within 30s, the drift is reverted so
-- state.tsv stays on the working strategy.

-- T15: a real success (incoming ServerHello), then circular drifts upward
-- within the window → nstrategy reverts to the pre-circular value, and the
-- working strategy (1) is what stays in state.tsv.
do
  fresh()
  now = 1000
  circular(nil, mk("rkn_tcp", "sticky.com", {outgoing = false, l7payload = "tls_server_hello"}))
  now = 1010
  circular(nil, mk("rkn_tcp", "sticky.com", {sim = 3}))   -- circular drifts 1→3
  check("T15: drift reverted to pre-circular value (recent success)",
        1, autostate["rkn_tcp"]["sticky.com"].nstrategy)
  check("T15: state.tsv stays on the working strategy 1", 1, row("rkn_tcp", "sticky.com"))
end

-- T16: drift WITHOUT a recent success is NOT reverted (rotation still works).
do
  fresh()
  now = 2000
  circular(nil, mk("rkn_tcp", "drift.com"))               -- establishes nstrategy=1
  now = 2005
  circular(nil, mk("rkn_tcp", "drift.com", {sim = 3}))    -- drifts; no success recorded
  check("T16: drift NOT reverted without recent success",
        3, autostate["rkn_tcp"]["drift.com"].nstrategy)
  check("T16: state.tsv shows the drifted strategy 3", 3, row("rkn_tcp", "drift.com"))
end

-- T17: a success older than the 30s window does NOT revert the drift.
do
  fresh()
  now = 3000
  circular(nil, mk("rkn_tcp", "old.com", {outgoing = false, l7payload = "tls_server_hello"}))
  now = 3040                                              -- 40s later, window is 30s
  circular(nil, mk("rkn_tcp", "old.com", {sim = 3}))
  check("T17: stale success (>30s) does NOT revert drift",
        3, autostate["rkn_tcp"]["old.com"].nstrategy)
end

-- T18: a server-active rejection (crec.z2k_server_active_reject) must NEVER pin
-- to state.tsv — the peer refused, a packet-level bypass cannot help.
do
  fresh()
  now = 4000
  circular(nil, mk("rkn_tcp", "refuse.com", {sim = 2, crec = {z2k_server_active_reject = true}}))
  check("T18: server-active rejection is NOT pinned", nil, row("rkn_tcp", "refuse.com"))
end

-- T19: sticky revert is PER-PROFILE — a success on yt_tcp must not freeze a
-- drift on gv_tcp for the same hostname.
do
  fresh()
  now = 5000
  circular(nil, mk("yt_tcp", "googlevideo.com", {outgoing = false, l7payload = "tls_server_hello"}))
  now = 5005
  circular(nil, mk("gv_tcp", "googlevideo.com", {sim = 3}))   -- different profile, same host
  check("T19: cross-profile success does NOT freeze gv_tcp drift",
        3, autostate["gv_tcp"]["googlevideo.com"].nstrategy)
end

print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
