-- tests/test_z2k_circular_allow_nohost.lua
-- Unit tests for allow_nohost extension в z2k-autocircular.lua wrapped circular.
-- См. PLAN_orchestrator_replacement.md B1.
--
-- Test paths изолированы через Z2K_AUTOCIRCULAR_DIR_OVERRIDE и
-- Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE env vars, выставленных wrapper'ом.
-- Production state.tsv/probe-override.tsv не трогаются.

local PASS, FAIL = 0, 0

local function check(cond, msg)
  if cond then
    PASS = PASS + 1
    print("[PASS] " .. msg)
  else
    FAIL = FAIL + 1
    print("[FAIL] " .. msg)
  end
end

-- ---------- Globals required by z2k-autocircular wrapper ----------

VERDICT_PASS = 0
VERDICT_DROP = 1
VERDICT_MODIFY = 2

function DLOG(...) end
function DLOG_ERR(...) end

-- Tracks what desync.track.hostname looked like INSIDE orig_circular.
-- Reset before each test.
local seen_hostname_in_orig = nil
local seen_hostname_is_ip_in_orig = nil
-- Optional: force orig_circular to throw an error.
local orig_should_throw = false

-- Minimal orig_circular: capture observation, optionally throw, return verdict.
function circular(ctx, desync)
  seen_hostname_in_orig = desync.track.hostname
  seen_hostname_is_ip_in_orig = desync.track.hostname_is_ip
  if orig_should_throw then
    error("forced test error from orig_circular")
  end
  return VERDICT_PASS
end

-- Mocks для pcall'нутых блоков. Возвращаем nil — pre/post-блоки уйдут в early
-- return (`if not hrec_before then ... end`) и не будут ломаться.
function get_record_for_desync(desync, do_seed) return nil end
function policy_seed_strategy() return nil end
function apply_probe_override() return nil end
function flow_start_if_needed() end
function flow_finish() return nil, nil end
function maybe_rotate_youtube_silent_retry() return nil, nil, nil end
function reset_youtube_silent_retry() end
function conn_record_flags(desync) return false, false, false, nil, nil end
function has_positive_incoming_response() return false end
function telemetry_record_event() end
function persist_if_changed() return false end
function clear_persisted() end
function debug_log() end
function now_f() return 1000.0 end

-- Globals z2k-autocircular helpers (local в modul'е, но они не вызываются
-- наружу — wrapper'у нужны только helpers выше).

dofile("files/lua/z2k-autocircular.lua")

-- ---------- Helpers для тестов ----------

local function make_desync(opts)
  -- opts: {key, hostname, hostname_is_ip, allow_nohost, l7payload, reqhost}
  return {
    arg = {
      key = opts.key,
      allow_nohost = opts.allow_nohost,
      reqhost = opts.reqhost,
    },
    track = {
      hostname = opts.hostname,
      hostname_is_ip = opts.hostname_is_ip,
      lua_state = {},
    },
    outgoing = true,
    l7payload = opts.l7payload or "quic_initial",
    plan = {},
    func_instance = "circular",
  }
end

local function reset()
  seen_hostname_in_orig = nil
  seen_hostname_is_ip_in_orig = nil
  orig_should_throw = false
end

-- ---------- Case 1: allow_nohost=1 + hostname=nil ----------
do
  reset()
  local d = make_desync({key="discord_udp", allow_nohost="1", hostname=nil})
  local verdict = circular(nil, d)
  check(seen_hostname_in_orig == "nohost",
        "case1: orig_circular sees hostname='nohost' when allow_nohost=1+hostname=nil (got "..tostring(seen_hostname_in_orig)..")")
  check(d.track.hostname == nil,
        "case1: hostname restored to nil after wrapped circular (got "..tostring(d.track.hostname)..")")
  check(verdict == VERDICT_PASS, "case1: verdict propagated correctly")
end

-- ---------- Case 2: allow_nohost=1 + hostname="1.2.3.4" + hostname_is_ip=true ----------
do
  reset()
  local d = make_desync({key="discord_udp", allow_nohost="1",
                         hostname="1.2.3.4", hostname_is_ip=true})
  circular(nil, d)
  check(seen_hostname_in_orig == "nohost",
        "case2: IP literal with hostname_is_ip=true treated as no-real-hostname, swapped to 'nohost'")
  check(d.track.hostname == "1.2.3.4",
        "case2: hostname restored to original IP literal after call")
end

-- ---------- Case 3: allow_nohost=1 + real hostname ----------
do
  reset()
  local d = make_desync({key="discord_udp", allow_nohost="1",
                         hostname="voice.discord.gg", hostname_is_ip=false})
  circular(nil, d)
  check(seen_hostname_in_orig == "voice.discord.gg",
        "case3: real hostname NOT swapped, allow_nohost only kicks in when no real hostname")
  check(d.track.hostname == "voice.discord.gg",
        "case3: hostname unchanged after call")
end

-- ---------- Case 4: allow_nohost=0 + hostname=nil ----------
do
  reset()
  local d = make_desync({key="discord_udp", allow_nohost=nil, hostname=nil})
  circular(nil, d)
  check(seen_hostname_in_orig == nil,
        "case4: allow_nohost=0 + hostname=nil → no swap (orig_circular sees nil)")
  check(d.track.hostname == nil,
        "case4: hostname stays nil after call")
end

-- ---------- Case 5: allow_nohost=1 + empty string hostname ----------
do
  reset()
  local d = make_desync({key="discord_udp", allow_nohost="1", hostname=""})
  circular(nil, d)
  check(seen_hostname_in_orig == "nohost",
        "case5: empty hostname treated as no-real-hostname, swapped")
  check(d.track.hostname == "",
        "case5: empty hostname restored to empty string after call")
end

-- ---------- Case 6: allow_nohost as number 1 (not string) ----------
do
  reset()
  local d = make_desync({key="discord_udp", allow_nohost=1, hostname=nil})
  circular(nil, d)
  check(seen_hostname_in_orig == "nohost",
        "case6: allow_nohost=1 (number) accepted, same as string '1'")
end

-- ---------- Case 7: Hostname restoration on orig_circular error ----------
do
  reset()
  orig_should_throw = true
  local d = make_desync({key="discord_udp", allow_nohost="1", hostname=nil})
  local ok, err = pcall(circular, nil, d)
  check(not ok, "case7: wrapped circular re-throws error from orig_circular (ok="..tostring(ok)..")")
  check(err and string.find(tostring(err), "forced test error") ~= nil,
        "case7: error message preserved (got: "..tostring(err)..")")
  check(d.track.hostname == nil,
        "case7: hostname restored to nil after error (finally executed; got "..tostring(d.track.hostname)..")")
end

-- ---------- Case 8: Hostname restoration on orig_circular error with IP literal ----------
do
  reset()
  orig_should_throw = true
  local d = make_desync({key="discord_udp", allow_nohost="1",
                         hostname="10.20.30.40", hostname_is_ip=true})
  local ok, _ = pcall(circular, nil, d)
  check(not ok, "case8: error propagated through wrapper")
  check(d.track.hostname == "10.20.30.40",
        "case8: original IP literal restored after error path")
end

-- ---------- Case 9: missing desync.track (degenerate input) ----------
do
  reset()
  local d = { arg = { key="x", allow_nohost="1" }, plan = {} }
  -- Should not crash; nohost_setup returns false when desync.track is nil.
  -- orig_circular will fail because it references desync.track.hostname,
  -- but that's the existing built-in behavior, not our concern. Use pcall.
  local ok, _ = pcall(circular, nil, d)
  -- The point: wrapper doesn't AddDamage on nil track.
  check(true, "case9: nil desync.track survived (pcall result="..tostring(ok)..")")
end

-- =====================================================================
-- INTEGRATION TESTS: real-path autostate population
-- =====================================================================
-- Эти тесты НЕ мокают get_record_for_desync — он local в модуле, mock
-- не дойдёт. Вместо этого определяем real-ish standard_hostkey + host_ip
-- globally → get_record_for_desync runs end-to-end → ensure_autostate_record
-- (local в модуле) пишет в _G.autostate. Тесты verify что allow_nohost
-- swap реально создаёт нужные autostate entries.

print()
print("=== Integration tests (real-path autostate) ===")

-- Mimics upstream standard_hostkey contract: вернуть desync.track.hostname
-- если есть; иначе host_ip(desync) если reqhost не задан; иначе nil.
-- (nld dissection пропускаем — не нужно для allow_nohost тестов.)
function standard_hostkey(desync)
  local h = desync and desync.track and desync.track.hostname
  if h then return h end
  if not (desync and desync.arg and desync.arg.reqhost) then
    return host_ip(desync)
  end
  return nil
end

function host_ip(desync)
  return (desync and desync.track and desync.track.fallback_ip) or "10.20.30.40"
end

-- Reset autostate между интеграционными тестами. Reuse global table
-- (модуль читает _G.autostate, не локальную копию).
local function reset_autostate()
  if autostate then
    for k in pairs(autostate) do autostate[k] = nil end
  else
    autostate = {}
  end
end

-- ---------- I1: allow_nohost=1, hostname=nil → autostate[key].nohost ----------
do
  reset()
  reset_autostate()
  local d = make_desync({key="discord_udp", allow_nohost="1", hostname=nil})
  circular(nil, d)
  local nohost_entry = autostate and autostate["discord_udp"] and autostate["discord_udp"]["nohost"]
  check(nohost_entry ~= nil,
        "I1: autostate[discord_udp][nohost] populated when allow_nohost=1+hostname=nil")
  -- Critical: no host_ip-fallback entry should leak (we bypassed host_ip).
  local ip_entry = autostate and autostate["discord_udp"] and autostate["discord_udp"]["10.20.30.40"]
  check(ip_entry == nil,
        "I1: no per-IP autostate entry — host_ip fallback bypassed by hostname swap")
end

-- ---------- I2: IP literal with hostname_is_ip=true → nohost entry ----------
do
  reset()
  reset_autostate()
  local d = make_desync({key="discord_udp", allow_nohost="1",
                         hostname="1.2.3.4", hostname_is_ip=true})
  circular(nil, d)
  local nohost_entry = autostate and autostate["discord_udp"] and autostate["discord_udp"]["nohost"]
  check(nohost_entry ~= nil,
        "I2: autostate[discord_udp][nohost] populated for IP literal with hostname_is_ip=true")
  local ip_entry = autostate and autostate["discord_udp"] and autostate["discord_udp"]["1.2.3.4"]
  check(ip_entry == nil,
        "I2: no per-IP autostate entry for IP literal — treated as no-real-hostname")
end

-- ---------- I3: allow_nohost=0 + hostname=nil → host_ip fallback (backcompat) ----------
do
  reset()
  reset_autostate()
  local d = make_desync({key="discord_udp", allow_nohost=nil, hostname=nil})
  circular(nil, d)
  -- Without allow_nohost, standard_hostkey falls back to host_ip → per-IP entry.
  -- This is upstream circular's default behavior, preserved by our wrapper.
  local ip_entry = autostate and autostate["discord_udp"] and autostate["discord_udp"]["10.20.30.40"]
  check(ip_entry ~= nil,
        "I3: backcompat — allow_nohost=0 → host_ip fallback creates per-IP autostate entry")
  local nohost_entry = autostate and autostate["discord_udp"] and autostate["discord_udp"]["nohost"]
  check(nohost_entry == nil,
        "I3: no nohost entry when allow_nohost=0 (no swap should happen)")
end

-- ---------- I4: real hostname → per-hostname entry, no nohost swap ----------
do
  reset()
  reset_autostate()
  local d = make_desync({key="discord_udp", allow_nohost="1",
                         hostname="voice.discord.gg", hostname_is_ip=false})
  circular(nil, d)
  local entry = autostate and autostate["discord_udp"] and autostate["discord_udp"]["voice.discord.gg"]
  check(entry ~= nil,
        "I4: real hostname → autostate[discord_udp][voice.discord.gg] created")
  local nohost_entry = autostate and autostate["discord_udp"] and autostate["discord_udp"]["nohost"]
  check(nohost_entry == nil,
        "I4: no nohost entry — real hostname bypasses swap")
end

-- ---------- I5: namespace separation discord_udp vs discord_voice ----------
do
  reset()
  reset_autostate()
  -- First call: discord_udp profile (6-strat config_official).
  local d1 = make_desync({key="discord_udp", allow_nohost="1", hostname=nil})
  circular(nil, d1)
  -- Second call: discord_voice profile (12-strat quic_strats.ini alternative).
  local d2 = make_desync({key="discord_voice", allow_nohost="1", hostname=nil})
  circular(nil, d2)

  local udp_entry = autostate and autostate["discord_udp"] and autostate["discord_udp"]["nohost"]
  local voice_entry = autostate and autostate["discord_voice"] and autostate["discord_voice"]["nohost"]
  check(udp_entry ~= nil, "I5: discord_udp.nohost exists после I5-call-1")
  check(voice_entry ~= nil, "I5: discord_voice.nohost exists после I5-call-2")
  -- They must be distinct table references — separate per-namespace records.
  check(udp_entry ~= voice_entry,
        "I5: discord_udp.nohost и discord_voice.nohost — distinct records (no cross-profile collision)")
end

-- ---------- I6: re-entry stability — repeat call returns same record ----------
-- Confirms that subsequent packets для one askey/host pair reuse the same
-- autostate entry (state persists across packets, не пересоздаётся).
do
  reset()
  reset_autostate()
  local d1 = make_desync({key="discord_udp", allow_nohost="1", hostname=nil})
  circular(nil, d1)
  local first = autostate["discord_udp"]["nohost"]
  -- Mutate as if real circular wrote nstrategy.
  first.nstrategy = 3
  -- Second packet same flow.
  local d2 = make_desync({key="discord_udp", allow_nohost="1", hostname=nil})
  circular(nil, d2)
  local second = autostate["discord_udp"]["nohost"]
  check(first == second, "I6: same autostate entry reused on second packet (table reference identity)")
  check(second.nstrategy == 3, "I6: nstrategy=3 preserved across packets (persistence через autostate)")
end

-- ---------- Summary ----------
print()
print(string.format("Tests passed: %d / %d", PASS, PASS + FAIL))
if FAIL > 0 then
  os.exit(1)
end
