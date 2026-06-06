-- tests/test_z2k_state_persist.lua
-- Unit tests for z2k-state-persist.lua — the PERSIST-ONLY layer over the native
-- circular(): a single state.tsv, full-file merge-rewrite, persist on every
-- outgoing initial packet (incl. the default strategy 1, so working-on-default
-- profiles still show), hostless keying via hostkey=z2k_nohost_key, restart
-- restore, config clamp, and the sticky-success revert.
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
  -- mirror automate_content_gate (zapret-auto.lua): an incoming flow delivering
  -- real reverse content past the handshake region stamps the per-host content
  -- gate, which drives state-persist's content-backed sticky re-arm.
  if not desync.outgoing then
    local rev = desync.track.pos and desync.track.pos.reverse
    if rev and tonumber(rev.pbcounter) and rev.pbcounter > 16384 then
      hrec.content_seen_last = now
    end
  end
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
  if opts.hostname_is_ip then d.track.hostname_is_ip = true end
  if opts.in_bytes and d.track then d.track.pos = { reverse = { pbcounter = opts.in_bytes } } end
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

-- T8: a hostless flow (Discord, no hostname) persists under "nohost" via the
-- native hostkey=z2k_nohost_key function. (The allow_nohost path — which mutated
-- track.hostname in the persist layer — was removed 2026-05-30; discord_voice
-- migrated to hostkey=z2k_nohost_key, so both Discord profiles now key the
-- robust native way.)
fresh()
circular(nil, mk("discord_voice", nil, {hostkey = "z2k_nohost_key",
                                        l7payload = "quic_initial", sim = 2}))
check("T8: hostless discord_voice persisted under 'nohost' via z2k_nohost_key", 2, row("discord_voice", "nohost"))

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

-- T15: a CONTENT-BACKED success (incoming ServerHello + real reverse content
-- past the gate), then circular drifts upward within the window → nstrategy
-- reverts to the pre-circular value, and the working strategy (1) stays in
-- state.tsv. Content-backing is required: a bare ServerHello no longer arms the
-- sticky re-arm (see T15b — the whatsapp/Meta handshake-but-block protection).
do
  fresh()
  now = 1000
  circular(nil, mk("rkn_tcp", "sticky.com", {outgoing = false, l7payload = "tls_server_hello", in_bytes = 20000}))
  now = 1010
  circular(nil, mk("rkn_tcp", "sticky.com", {sim = 3}))   -- circular drifts 1→3
  check("T15: drift reverted to pre-circular value (recent success)",
        1, autostate["rkn_tcp"]["sticky.com"].nstrategy)
  check("T15: state.tsv stays on the working strategy 1", 1, row("rkn_tcp", "sticky.com"))
end

-- T15b: a BARE ServerHello with NO real content (handshake-but-BLOCKED class —
-- whatsapp/Meta ~3-5KB cert flight that never delivers content) must NOT arm the
-- sticky re-arm. Otherwise the ServerHello flood perpetually pins a non-piercing
-- strategy and snaps the rotator's content-gated rotation straight back within
-- the 30s window (the Layer-2 deadlock). content_backed=false → drift is KEPT.
do
  fresh()
  now = 1500
  circular(nil, mk("rkn_tcp", "blocked.com", {outgoing = false, l7payload = "tls_server_hello", in_bytes = 4000}))
  now = 1510
  circular(nil, mk("rkn_tcp", "blocked.com", {sim = 3}))   -- circular drifts 1→3
  check("T15b: bare ServerHello (no content) does NOT revert drift (whatsapp class)",
        3, autostate["rkn_tcp"]["blocked.com"].nstrategy)
  check("T15b: state.tsv keeps the rotated strategy 3", 3, row("rkn_tcp", "blocked.com"))
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
  circular(nil, mk("rkn_tcp", "old.com", {outgoing = false, l7payload = "tls_server_hello", in_bytes = 20000}))
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
  circular(nil, mk("yt_tcp", "googlevideo.com", {outgoing = false, l7payload = "tls_server_hello", in_bytes = 20000}))
  now = 5005
  circular(nil, mk("gv_tcp", "googlevideo.com", {sim = 3}))   -- different profile, same host
  check("T19: cross-profile success does NOT freeze gv_tcp drift",
        3, autostate["gv_tcp"]["googlevideo.com"].nstrategy)
end

-- T20: hostless/discord pools are EXEMPT from the sticky revert (regression fix
-- 2026-05-30 — Discord voice). Hostkey=z2k_nohost_key collapses ALL discord
-- flows into one shared "nohost|discord_udp" bucket; reverting would pin the
-- whole pool on the first-working strategy and break voice to DCs that need a
-- different desync. Must behave like r-43 (no revert at all): the drift is KEPT
-- even though the shared nohost bucket just had a success.
do
  fresh()
  now = 6000
  -- a success stamps the shared "nohost|discord_udp" bucket...
  circular(nil, mk("discord_udp", nil, {outgoing = false, l7payload = "tls_server_hello", hostkey = "z2k_nohost_key", in_bytes = 20000}))
  now = 6005
  circular(nil, mk("discord_udp", nil, {hostkey = "z2k_nohost_key", sim = 3}))  -- circular drifts 1→3
  check("T20: discord/nohost drift NOT reverted (native circular like r-43)",
        3, autostate["discord_udp"]["nohost"].nstrategy)
end

-- ===========================================================================
-- External-edit reconcile (option B — state.tsv authoritative for OUTSIDE writes).
-- The webpanel × delete (and manual edits) change state.tsv directly; the
-- circular wrapper re-reads the disk and applies genuine external changes to the
-- live autostate so they take effect WITHOUT a service restart. It diffs disk
-- against last_written (what WE wrote), so our own debounced writes are never
-- mistaken for an external edit. Reconcile is debounced 2s → advance `now` ≥2
-- between the seeding call and the call that should observe the edit.

-- T21: webpanel × delete (row removed from disk) → live nstrategy reset to 1,
-- and the deleted host re-persists at strategy 1 on the same packet.
do
  fresh()
  now = 7000
  circular(nil, mk("rkn_tcp", "ext.com", {sim = 2}))   -- live=2, disk=2, last_written=2
  check("T21: seeded at strategy 2", 2, autostate["rkn_tcp"]["ext.com"].nstrategy)
  write_file("# h\n# h2\n")                             -- operator × removes the row
  now = 7005                                            -- past the 2s reconcile debounce
  circular(nil, mk("rkn_tcp", "ext.com"))              -- reconcile fires before circular
  check("T21: external × delete resets live nstrategy to 1",
        1, autostate["rkn_tcp"]["ext.com"].nstrategy)
  check("T21: deleted host re-persists at strategy 1", 1, row("rkn_tcp", "ext.com"))
end

-- T22: an external EDIT (operator sets a different strategy on disk) is adopted
-- into the live rotator and kept.
do
  fresh()
  now = 7100
  circular(nil, mk("rkn_tcp", "edit.com", {sim = 2}))  -- live=2, disk=2, last_written=2
  write_file("# h\n# h2\nrkn_tcp\tedit.com\t3\t7200\n")  -- operator edits to 3
  now = 7105
  circular(nil, mk("rkn_tcp", "edit.com"))
  check("T22: external edit adopted into live nstrategy",
        3, autostate["rkn_tcp"]["edit.com"].nstrategy)
  check("T22: adopted strategy stays on disk", 3, row("rkn_tcp", "edit.com"))
end

-- T23: when the disk matches our last write (our OWN debounced write, no outside
-- change), reconcile must NOT reset anything — this is the debounce-race guard.
do
  fresh()
  now = 7200
  circular(nil, mk("rkn_tcp", "stable.com", {sim = 2}))
  now = 7205
  circular(nil, mk("rkn_tcp", "stable.com"))           -- disk == last_written → no-op
  check("T23: unchanged disk does NOT trigger a spurious reset",
        2, autostate["rkn_tcp"]["stable.com"].nstrategy)
end

-- T24: deleting ONE host leaves a sibling host on the same key untouched.
do
  fresh()
  now = 7300
  circular(nil, mk("rkn_tcp", "keepme.com", {sim = 2}))
  circular(nil, mk("rkn_tcp", "delme.com",  {sim = 3}))
  write_file("# h\n# h2\nrkn_tcp\tkeepme.com\t2\t7300\n")  -- × removes only delme
  now = 7305
  circular(nil, mk("rkn_tcp", "keepme.com"))           -- reconcile resets the deleted one
  check("T24: sibling delete resets only the deleted host",
        1, autostate["rkn_tcp"]["delme.com"].nstrategy)
  check("T24: sibling kept host untouched",
        2, autostate["rkn_tcp"]["keepme.com"].nstrategy)
end

-- T25: an external edit that raises the strategy WHILE a success is fresh (<30s)
-- must be adopted and NOT rolled back by the sticky-success revert. Regression
-- guard for the ordering fix: the sticky baseline is snapshotted AFTER reconcile,
-- so an operator edit is the starting point, not "drift" to undo.
do
  fresh()
  local PLAN5 = { {arg={strategy=1}}, {arg={strategy=2}}, {arg={strategy=3}},
                  {arg={strategy=4}}, {arg={strategy=5}} }  -- edit-to-4 must be in range
  now = 8000
  circular(nil, mk("rkn_tcp", "h3.com", {sim = 2, plan = PLAN5}))    -- live=2, disk=2
  now = 8001
  circular(nil, mk("rkn_tcp", "h3.com", {outgoing = false, l7payload = "tls_server_hello", plan = PLAN5, in_bytes = 20000})) -- success stamp
  write_file("# h\n# h2\nrkn_tcp\th3.com\t4\t8002\n")   -- operator edits 2 → 4
  now = 8003                                            -- 2s later: inside the 30s window
  circular(nil, mk("rkn_tcp", "h3.com", {plan = PLAN5}))
  check("T25: external edit-up NOT reverted by the sticky window",
        4, autostate["rkn_tcp"]["h3.com"].nstrategy)
  check("T25: edited strategy persists to disk", 4, row("rkn_tcp", "h3.com"))
end

-- T26: a host deleted externally (webpanel ×) stays deleted even when a SIBLING
-- host's write flushes during the reconcile debounce window — write_state must
-- not resurrect a row that's gone from a readable disk but still in our mirror.
-- Regression guard for the debounce-race fix.
do
  fresh()
  now = 9200
  circular(nil, mk("rkn_tcp", "delh.com", {sim = 2}))  -- reconcile fires here (last_reconcile=9200)
  circular(nil, mk("rkn_tcp", "sib2.com", {sim = 2}))  -- same second → reconcile debounced
  write_file("# h\n# h2\nrkn_tcp\tsib2.com\t2\t9200\n")  -- × removes delh, keeps sib2
  circular(nil, mk("rkn_tcp", "sib2.com", {sim = 3}))  -- sibling write within the window (2→3, in range)
  check("T26: externally-deleted host NOT resurrected by a sibling write",
        nil, row("rkn_tcp", "delh.com"))
  check("T26: sibling host still persists its own rotation", 3, row("rkn_tcp", "sib2.com"))
end

-- 5-strategy plan so a pin to 4/5 is IN range (DEFAULT_PLAN has only 1-3, which
-- the config-clamp at zapret-auto/state-persist correctly normalizes to 1).
local PLAN5_R = { {arg={strategy=1}}, {arg={strategy=2}}, {arg={strategy=3}},
                  {arg={strategy=4}}, {arg={strategy=5}} }

-- T27: SEED-RECOVERY (display-truth invariant). An operator pins a host AFTER
-- load_state already ran, and the first packet for it lands INSIDE the reconcile
-- debounce window (so reconcile can't adopt it that packet). Without recovery the
-- record is created at default 1 and that 1 persists OVER the pin → live=1 while
-- the operator asked for 5 (the exact divergence observed on flibusta). Recovery
-- reads disk directly and adopts 5 so live AND disk are 5.
do
  fresh()
  now = 9500
  circular(nil, mk("rkn_tcp", "warm.com"))   -- triggers load_state (empty disk); reconcile fires (last_reconcile=9500)
  -- operator pins pinned.com=5 (older ts so a default-1 persist would otherwise win the merge)
  write_file("# h\n# h2\nrkn_tcp\twarm.com\t1\t9500\nrkn_tcp\tpinned.com\t5\t9400\n")
  circular(nil, mk("rkn_tcp", "pinned.com", {plan = PLAN5_R}))  -- same `now` → reconcile debounced; only seed-recovery can save it
  check("T27: cold pin adopted into LIVE despite reconcile debounce",
        5, autostate["rkn_tcp"]["pinned.com"].nstrategy)
  check("T27: pin NOT clobbered by default-1 (disk == live)", 5, row("rkn_tcp", "pinned.com"))
end

-- T28: seed-recovery must NOT misfire. A genuine cold default-1 host with NO disk
-- row stays 1 and is persisted as 1 (recovery only adopts a real disk value != 1).
do
  fresh()
  now = 9600
  circular(nil, mk("rkn_tcp", "plain.com"))
  check("T28: genuine default-1 host stays 1 (no spurious recovery)",
        1, autostate["rkn_tcp"]["plain.com"].nstrategy)
  check("T28: default-1 persisted normally", 1, row("rkn_tcp", "plain.com"))
end

-- T29: a cold pin present BEFORE the first packet is seeded via the normal
-- pre-circular path (not recovery); recovery doesn't interfere with it.
do
  fresh()
  write_file("# h\n# h2\nrkn_tcp\tseeded.com\t4\t9700\n")
  now = 9701
  circular(nil, mk("rkn_tcp", "seeded.com", {plan = PLAN5_R}))
  check("T29: cold pin seeded via normal pre-circular path",
        4, autostate["rkn_tcp"]["seeded.com"].nstrategy)
  check("T29: seeded value persisted", 4, row("rkn_tcp", "seeded.com"))
end

print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
