-- z2k-autocircular.lua
-- Persist zapret-auto.lua "circular" per-host strategy across nfqws2 restarts.
--
-- Design:
-- - zapret-auto.lua stores nstrategy in global table `autostate[askey][hostkey]`.
-- - This file wraps `circular()` to:
--   1) seed autostate from a TSV file on disk (best effort),
--   2) save nstrategy back to disk when it changes (rate-limited).
--
-- Notes:
-- - We do NOT change rotation logic; only persist/restore.
-- - Storage key uses `desync.arg.key` when provided; otherwise falls back to `desync.func_instance`.

local STATE_DIR_PRIMARY = "/opt/zapret2/extra_strats/cache/autocircular"
local STATE_FILE_PRIMARY = STATE_DIR_PRIMARY .. "/state.tsv"
local STATE_FILE_FALLBACK = "/tmp/z2k-autocircular-state.tsv"
local TELEMETRY_FILE_PRIMARY = STATE_DIR_PRIMARY .. "/telemetry.tsv"
local TELEMETRY_FILE_FALLBACK = "/tmp/z2k-autocircular-telemetry.tsv"
local DEBUG_FLAG_PRIMARY = STATE_DIR_PRIMARY .. "/debug.flag"
local DEBUG_FLAG_FALLBACK = "/tmp/z2k-autocircular-debug.flag"
local DEBUG_LOG_PRIMARY = STATE_DIR_PRIMARY .. "/debug.log"
local DEBUG_LOG_FALLBACK = "/tmp/z2k-autocircular-debug.log"

local loaded = false
local state = {} -- state[askey][host_norm] = { strategy = N, ts = unix_time }
local telemetry_loaded = false
local telemetry = {} -- telemetry[askey][hostn][strategy] = { ok, fail, lat, ts, cooldown_until }

local last_write = 0
local write_interval = 2 -- seconds
local last_telemetry_write = 0
local telemetry_write_interval = 5 -- seconds

local debug_enabled = false
local debug_checked_at = 0
local debug_refresh_interval = 5 -- seconds

local policy_enabled = true
local policy_epsilon = 0.15
local policy_cooldown_sec = 120
local policy_ucb_c = 0.65
local policy_lat_penalty = 0.10

local function now_f()
  if type(clock_getfloattime) == "function" then
    local ok, v = pcall(clock_getfloattime)
    if ok and tonumber(v) then
      return tonumber(v)
    end
  end
  return tonumber(os.time() or 0) or 0
end

local function is_blank(s)
  return (s == nil) or (tostring(s) == "")
end

local function normalize_hostkey_for_state(hostkey)
  if hostkey == nil then return nil end
  local s = tostring(hostkey)
  if s == "" then return nil end
  s = s:gsub("%.$", "") -- trailing dot
  return string.lower(s)
end

local function choose_state_file_for_read()
  local f = io.open(STATE_FILE_PRIMARY, "r")
  if f then f:close(); return STATE_FILE_PRIMARY end
  f = io.open(STATE_FILE_FALLBACK, "r")
  if f then f:close(); return STATE_FILE_FALLBACK end
  return nil
end

local function choose_debug_log_file_for_write()
  local f = io.open(DEBUG_LOG_PRIMARY, "a")
  if f then f:close(); return DEBUG_LOG_PRIMARY end
  f = io.open(DEBUG_LOG_FALLBACK, "a")
  if f then f:close(); return DEBUG_LOG_FALLBACK end
  return nil
end

local function refresh_debug_enabled()
  local now = os.time() or 0
  if now ~= 0 and (now - debug_checked_at) < debug_refresh_interval then
    return debug_enabled
  end
  debug_checked_at = now

  local f = io.open(DEBUG_FLAG_PRIMARY, "r")
  if f then
    f:close()
    debug_enabled = true
    return true
  end
  f = io.open(DEBUG_FLAG_FALLBACK, "r")
  if f then
    f:close()
    debug_enabled = true
    return true
  end

  debug_enabled = false
  return false
end

local function debug_log(msg)
  if not refresh_debug_enabled() then return end
  local path = choose_debug_log_file_for_write()
  if not path then return end
  local f = io.open(path, "a")
  if not f then return end
  f:write(tostring(os.time() or 0), "\t", tostring(msg), "\n")
  f:close()
end

local function create_empty_state_file(path)
  local f = io.open(path, "w")
  if not f then return false end
  f:write("# z2k autocircular state (persisted circular nstrategy)\n")
  f:write("# key\thost\tstrategy\tts\n")
  f:close()
  return true
end

local function choose_state_file_for_write()
  local f = io.open(STATE_FILE_PRIMARY, "a")
  if f then f:close(); return STATE_FILE_PRIMARY end
  f = io.open(STATE_FILE_FALLBACK, "a")
  if f then f:close(); return STATE_FILE_FALLBACK end
  return nil
end

local function ensure_state_file_exists()
  local existing = choose_state_file_for_read()
  if existing then return existing end

  local writable = choose_state_file_for_write()
  if not writable then return nil end

  if create_empty_state_file(writable) then
    return writable
  end
  return nil
end

local function create_empty_telemetry_file(path)
  local f = io.open(path, "w")
  if not f then return false end
  f:write("# z2k autocircular telemetry\n")
  f:write("# key\thost\tstrategy\tok\tfail\tlat\tts\tcooldown_until\n")
  f:close()
  return true
end

local function choose_telemetry_file_for_read()
  local f = io.open(TELEMETRY_FILE_PRIMARY, "r")
  if f then f:close(); return TELEMETRY_FILE_PRIMARY end
  f = io.open(TELEMETRY_FILE_FALLBACK, "r")
  if f then f:close(); return TELEMETRY_FILE_FALLBACK end
  return nil
end

local function choose_telemetry_file_for_write()
  local f = io.open(TELEMETRY_FILE_PRIMARY, "a")
  if f then f:close(); return TELEMETRY_FILE_PRIMARY end
  f = io.open(TELEMETRY_FILE_FALLBACK, "a")
  if f then f:close(); return TELEMETRY_FILE_FALLBACK end
  return nil
end

local function ensure_telemetry_file_exists()
  local existing = choose_telemetry_file_for_read()
  if existing then return existing end
  local writable = choose_telemetry_file_for_write()
  if not writable then return nil end
  if create_empty_telemetry_file(writable) then
    return writable
  end
  return nil
end

local function load_state()
  if loaded then return end
  loaded = true
  state = {}

  local path = ensure_state_file_exists()
  if not path then return end

  local f = io.open(path, "r")
  if not f then return end

  for line in f:lines() do
    if line ~= "" and not line:match("^%s*#") then
      local askey, host, strat, ts = line:match("^([^\t]+)\t([^\t]+)\t([0-9]+)\t?([0-9]*)")
      if askey and host and strat then
        local n = tonumber(strat)
        -- Do not keep default strategy "1" on disk. It is the implicit default anyway.
        if n and n >= 2 then
          local hn = normalize_hostkey_for_state(host)
          if hn then
            if not state[askey] then state[askey] = {} end
            state[askey][hn] = { strategy = n, ts = tonumber(ts) or 0 }
          end
        end
      end
    end
  end

  f:close()
end

local function write_state()
  local now = os.time() or 0
  if now ~= 0 and (now - last_write) < write_interval then
    return
  end
  last_write = now

  local path = choose_state_file_for_write()
  if not path then return end
  local tmp = path .. ".tmp"

  local f = io.open(tmp, "w")
  if not f then return end

  f:write("# z2k autocircular state (persisted circular nstrategy)\n")
  f:write("# key\thost\tstrategy\tts\n")

  for askey, hosts in pairs(state) do
    for hostn, rec in pairs(hosts) do
      if rec and rec.strategy then
        f:write(tostring(askey), "\t", tostring(hostn), "\t", tostring(rec.strategy), "\t", tostring(rec.ts or 0), "\n")
      end
    end
  end

  f:close()
  os.rename(tmp, path)
end

local function telemetry_host(askey, hostn, create)
  if not askey or not hostn then return nil end
  local a = telemetry[askey]
  if not a then
    if not create then return nil end
    a = {}
    telemetry[askey] = a
  end
  local h = a[hostn]
  if not h then
    if not create then return nil end
    h = {}
    a[hostn] = h
  end
  return h
end

local function telemetry_rec(askey, hostn, strategy, create)
  local s = tonumber(strategy)
  if not s or s < 1 then return nil end
  local h = telemetry_host(askey, hostn, create)
  if not h then return nil end
  local r = h[s]
  if not r and create then
    r = { ok = 0, fail = 0, lat = 0, ts = 0, cooldown_until = 0 }
    h[s] = r
  end
  return r
end

local function load_telemetry()
  if telemetry_loaded then return end
  telemetry_loaded = true
  telemetry = {}

  local path = ensure_telemetry_file_exists()
  if not path then return end
  local f = io.open(path, "r")
  if not f then return end

  for line in f:lines() do
    if line ~= "" and not line:match("^%s*#") then
      local askey, hostn, strat, okv, failv, latv, tsv, cdv =
        line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]*)\t?([^\t]*)")
      local s = tonumber(strat)
      if askey and hostn and s and s >= 1 then
        local r = telemetry_rec(askey, hostn, s, true)
        if r then
          r.ok = tonumber(okv) or 0
          r.fail = tonumber(failv) or 0
          r.lat = tonumber(latv) or 0
          r.ts = tonumber(tsv) or 0
          r.cooldown_until = tonumber(cdv) or 0
        end
      end
    end
  end
  f:close()
end

local function write_telemetry()
  local now = now_f()
  if now ~= 0 and (now - last_telemetry_write) < telemetry_write_interval then
    return
  end
  last_telemetry_write = now

  local path = choose_telemetry_file_for_write()
  if not path then return end
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end

  f:write("# z2k autocircular telemetry\n")
  f:write("# key\thost\tstrategy\tok\tfail\tlat\tts\tcooldown_until\n")
  for askey, hosts in pairs(telemetry) do
    for hostn, strats in pairs(hosts) do
      for s, rec in pairs(strats) do
        if rec then
          f:write(
            tostring(askey), "\t",
            tostring(hostn), "\t",
            tostring(s), "\t",
            tostring(rec.ok or 0), "\t",
            tostring(rec.fail or 0), "\t",
            tostring(rec.lat or 0), "\t",
            tostring(rec.ts or 0), "\t",
            tostring(rec.cooldown_until or 0), "\n"
          )
        end
      end
    end
  end
  f:close()
  os.rename(tmp, path)
end

local function telemetry_total_attempts(h)
  if type(h) ~= "table" then return 0 end
  local n = 0
  for _, rec in pairs(h) do
    if rec then
      n = n + (tonumber(rec.ok) or 0) + (tonumber(rec.fail) or 0)
    end
  end
  return n
end

local function telemetry_is_cooldown(rec, now)
  if not rec then return false end
  local cd = tonumber(rec.cooldown_until) or 0
  return cd > now
end

local function telemetry_record_event(askey, hostn, strategy, success, latency_s, now)
  local r = telemetry_rec(askey, hostn, strategy, true)
  if not r then return end
  if success then
    r.ok = (tonumber(r.ok) or 0) + 1
    r.cooldown_until = 0
  else
    r.fail = (tonumber(r.fail) or 0) + 1
    r.cooldown_until = now + policy_cooldown_sec
  end
  local lat = tonumber(latency_s)
  if lat and lat > 0 then
    local prev = tonumber(r.lat) or 0
    if prev <= 0 then
      r.lat = lat
    else
      r.lat = prev * 0.8 + lat * 0.2
    end
  end
  r.ts = now
  write_telemetry()
end

local function policy_pick_strategy(askey, hostn, ct, now)
  if not policy_enabled then return nil, nil end
  local ctn = tonumber(ct)
  if not ctn or ctn < 2 then return nil, nil end

  local h = telemetry_host(askey, hostn, false)
  local total = telemetry_total_attempts(h)
  local candidates = {}
  local fallback = {}

  for s = 1, ctn do
    local rec = h and h[s] or nil
    if not telemetry_is_cooldown(rec, now) then
      table.insert(candidates, s)
    end
    table.insert(fallback, s)
  end
  if #candidates == 0 then
    candidates = fallback
  end
  if #candidates == 0 then
    return 1, 0
  end

  if math.random() < policy_epsilon then
    local s = candidates[math.random(1, #candidates)]
    return s, 0
  end

  local best_s = candidates[1]
  local best_score = -1e9
  for i = 1, #candidates do
    local s = candidates[i]
    local rec = h and h[s] or nil
    local okn = rec and (tonumber(rec.ok) or 0) or 0
    local fn = rec and (tonumber(rec.fail) or 0) or 0
    local att = okn + fn
    local mean = (okn + 1) / (att + 2)
    local explore = policy_ucb_c * math.sqrt(math.log(total + 2) / (att + 1))
    local lat = rec and (tonumber(rec.lat) or 0) or 0
    local penalty = 0
    if lat > 0 then
      penalty = policy_lat_penalty * math.min(lat, 5.0)
    end
    local score = mean + explore - penalty
    if score > best_score then
      best_score = score
      best_s = s
    end
  end
  return best_s, best_score
end

local function flow_state(desync)
  local ls = desync and desync.track and desync.track.lua_state
  if type(ls) ~= "table" then return nil end
  local key = "__z2k_flow_" .. tostring(desync.func_instance or "circular")
  local st = ls[key]
  if type(st) ~= "table" then
    st = {}
    ls[key] = st
  end
  return st
end

local function flow_start_if_needed(desync, strategy)
  local st = flow_state(desync)
  if not st then return end
  if st.t0 and st.t0 > 0 then return end
  local p = desync and desync.l7payload
  if desync and desync.outgoing and (p == "tls_client_hello" or p == "quic_initial" or p == "http_req") then
    st.t0 = now_f()
    st.strategy = tonumber(strategy) or 1
  end
end

local function flow_finish(desync)
  local st = flow_state(desync)
  if not st or not st.t0 then return nil, nil end
  local dt = now_f() - (tonumber(st.t0) or 0)
  local s = tonumber(st.strategy) or nil
  st.t0 = nil
  st.strategy = nil
  if dt and dt > 0 then
    return dt, s
  end
  return nil, s
end

local function get_hostkey_func(desync)
  if desync and desync.arg and desync.arg.hostkey then
    local fname = tostring(desync.arg.hostkey)
    local f = _G[fname]
    if type(f) == "function" then
      return f
    end
    -- Keep it non-fatal: original automate_host_record would throw, but we just skip persistence.
    return nil
  end
  if type(standard_hostkey) == "function" then
    return standard_hostkey
  end
  return nil
end

local function get_askey(desync)
  if desync and desync.arg and not is_blank(desync.arg.key) then
    return tostring(desync.arg.key)
  end
  if desync and desync.func_instance then
    return tostring(desync.func_instance)
  end
  return "default"
end

local function ensure_autostate_record(askey, hostkey)
  if not autostate then autostate = {} end
  if not autostate[askey] then autostate[askey] = {} end
  if not autostate[askey][hostkey] then autostate[askey][hostkey] = {} end
  return autostate[askey][hostkey]
end

local function get_record_for_desync(desync, do_seed)
  if do_seed then
    load_state()
    load_telemetry()
  end
  local hkf = get_hostkey_func(desync)
  if not hkf then return nil, nil, nil end

  local hostkey = hkf(desync)
  if not hostkey then return nil, nil, nil end

  local askey = get_askey(desync)
  local hostn = normalize_hostkey_for_state(hostkey)
  if not hostn then return nil, nil, nil end

  local hrec = ensure_autostate_record(askey, hostkey)
  if do_seed and not hrec.nstrategy then
    local rec = state[askey] and state[askey][hostn]
    if rec and rec.strategy then
      hrec.nstrategy = rec.strategy
    end
  end

  return askey, hostn, hrec
end

local function clear_persisted(askey, hostn)
  if not askey or not hostn then return end
  if state[askey] and state[askey][hostn] then
    state[askey][hostn] = nil
    if next(state[askey]) == nil then state[askey] = nil end
    write_state()
  end
end

local function persist_if_changed(askey, hostn, hrec)
  if not askey or not hostn or not hrec or not hrec.nstrategy then return false end
  local n = tonumber(hrec.nstrategy)
  if not n or n < 1 then return false end

  -- Strategy "1" is default. Do not overwrite or delete stored state with it:
  -- keep the last known successful non-default strategy so restarts don't "forget" it.
  if n == 1 then
    return false
  end

  local prev = state[askey] and state[askey][hostn] and state[askey][hostn].strategy or nil
  if prev == n then return false end

  if not state[askey] then state[askey] = {} end
  state[askey][hostn] = { strategy = n, ts = os.time() or 0 }
  write_state()
  return true
end

local function policy_seed_strategy(desync, askey, hostn, hrec)
  if not policy_enabled then return nil, nil end
  if not askey or not hostn or not hrec then return nil, nil end
  if not desync or not desync.outgoing then return nil, nil end

  local st = flow_state(desync)
  if st and st.policy_seeded then
    return nil, nil
  end
  local p = desync and desync.l7payload
  if p ~= "tls_client_hello" and p ~= "quic_initial" and p ~= "http_req" then
    return nil, nil
  end

  local ct = tonumber(hrec.ctstrategy)
  if not ct or ct < 2 then
    if st then st.policy_seeded = true end
    return nil, nil
  end

  local pick, score = policy_pick_strategy(askey, hostn, ct, now_f())
  if pick and pick >= 1 and pick <= ct then
    hrec.nstrategy = pick
  end
  if st then
    st.policy_seeded = true
    st.strategy = tonumber(hrec.nstrategy) or pick or 1
    st.policy_score = score
  end
  return pick, score
end

local function conn_record_flags(desync)
  local tr = desync and desync.track
  local ls = tr and tr.lua_state
  local crec = ls and ls.automate
  if not crec then return false, false end
  return (crec.nocheck and true or false), (crec.failure and true or false)
end

local function has_positive_incoming_response(desync)
  if not desync or desync.outgoing then return false end
  local p = desync.l7payload
  return p == "tls_server_hello" or p == "http_reply"
end

local function should_debug_key(askey)
  -- User requested monitoring for all keys (not only selected ones).
  return not is_blank(askey)
end

local function is_quic_key(askey)
  if not askey then return false end
  local s = tostring(askey)
  return s == "yt_quic" or s == "rkn_quic" or s == "custom_quic" or s == "cf_quic"
end

-- Some strategy packs gate tcp_ts-based variants using `stopif:iff=cond_tcp_has_ts`.
-- Provide this iff helper even if upstream zapret-auto.lua version is older.
if type(cond_tcp_has_ts) ~= "function" then
  function cond_tcp_has_ts(desync)
    local dis = desync and desync.dis
    local tcp = dis and dis.tcp
    local opts = tcp and tcp.options
    if not tcp or not opts then return false end

    -- Prefer upstream helper if available.
    if type(find_tcp_option) == "function" then
      local ts_kind = TCP_KIND_TS or 8
      local ok = find_tcp_option(opts, ts_kind)
      return ok and true or false
    end

    if type(opts) ~= "table" then
      return false
    end

    -- Fallback: try to detect TCP TS option kind=8 in dissected options.
    for _, opt in pairs(opts) do
      if type(opt) == "table" then
        local kind = tonumber(opt.kind or opt.type or opt[1])
        if kind == 8 then return true end
      else
        if tonumber(opt) == 8 then return true end
      end
    end
    return false
  end
end

-- Failure detector: treat any inbound fatal TLS alert record as a failure.
-- This helps autocircular rotate on early handshake aborts (e.g. Cloudflare ECH),
-- which are not counted by the standard retransmission-based detector.
function z2k_tls_alert_fatal(desync, crec)
  if type(standard_failure_detector) == "function" then
    local ok, res = pcall(standard_failure_detector, desync, crec)
    if ok and res then return true end
  end

  if not desync or desync.outgoing then return false end
  local dis = desync.dis
  local payload = dis and dis.payload
  if type(payload) ~= "string" then return false end
  if #payload < 7 then return false end
  if payload:byte(1) ~= 0x15 then return false end -- TLS record: alert (21)
  if payload:byte(6) ~= 0x02 then return false end -- alert level: fatal (2)
  return true
end

-- Wrap circular() from zapret-auto.lua.
if type(circular) == "function" then
  local orig_circular = circular
  circular = function(ctx, desync)
    local askey_before, hostn_before, hrec_before
    local policy_pick_before, policy_score_before
    pcall(function()
      askey_before, hostn_before, hrec_before = get_record_for_desync(desync, true)
      if hrec_before then
        policy_pick_before, policy_score_before = policy_seed_strategy(desync, askey_before, hostn_before, hrec_before)
        flow_start_if_needed(desync, hrec_before.nstrategy)
      end
    end)
    local verdict = orig_circular(ctx, desync)
    pcall(function()
      local askey_after, hostn_after, hrec_after
      pcall(function()
        askey_after, hostn_after, hrec_after = get_record_for_desync(desync, false)
      end)

      -- For persistence we must stay bound to circular() host record key (askey_before).
      -- askey_after can point to an executed instance (e.g. fake_1_2), not to circular state.
      local askey = askey_before or askey_after
      local hostn = hostn_before or hostn_after
      local hrec = hrec_before
      if (not hrec or not hrec.nstrategy) and hrec_after and hrec_after.nstrategy then
        hrec = hrec_after
      elseif not hrec then
        hrec = hrec_after
      end
      if not hrec then return end

      local nocheck_after, failure_after = conn_record_flags(desync)
      local n_after = hrec and tonumber(hrec.nstrategy) or nil
      flow_start_if_needed(desync, n_after)

      -- If persisted state became incompatible with current strategy count (config changed),
      -- normalize it to strategy 1 for the next connection and drop the persisted entry.
      local ct = hrec and tonumber(hrec.ctstrategy) or nil
      if ct and ct > 0 and n_after and (n_after < 1 or n_after > ct) then
        hrec.nstrategy = 1
        clear_persisted(askey, hostn)
        return
      end

      -- Persist whenever circular is in a known-good state.
      -- This is intentionally broader than only first success transition to avoid missing saves.
      local successful_state = nocheck_after and (not failure_after)
      local response_state = has_positive_incoming_response(desync) and (not failure_after)
      -- QUIC flows may not reliably trigger success detector, but nstrategy>1 already indicates
      -- that circular has rotated this host. Persist that candidate for QUIC keys.
      local quic_candidate_state =
        is_quic_key(askey) and
        (desync and desync.l7payload == "quic_initial") and
        (not failure_after) and
        n_after and n_after > 1
      local success_event = successful_state or response_state or quic_candidate_state
      local failure_event = failure_after and (not success_event)
      local persisted = false
      if success_event then
        persisted = persist_if_changed(askey, hostn, hrec)
      end

      local latency_s, flow_strategy = nil, nil
      if success_event or failure_event then
        latency_s, flow_strategy = flow_finish(desync)
        local strat_for_stat = n_after or flow_strategy
        if strat_for_stat then
          telemetry_record_event(askey, hostn, strat_for_stat, success_event and (not failure_event), latency_s, now_f())
        end
      end

      local debug_event = persisted or failure_after or success_event or failure_event or (policy_pick_before ~= nil)
      if debug_event and (should_debug_key(askey_before) or should_debug_key(askey_after)) then
        local track = desync and desync.track
        local hn = track and track.hostname or ""
        debug_log(
          "key_before=" .. tostring(askey_before) ..
          " key_after=" .. tostring(askey_after) ..
          " host_before=" .. tostring(hostn_before) ..
          " host_after=" .. tostring(hostn_after) ..
          " track_host=" .. tostring(hn) ..
          " l7=" .. tostring(desync and desync.l7payload) ..
          " out=" .. tostring(desync and desync.outgoing and 1 or 0) ..
          " policy_pick=" .. tostring(policy_pick_before or "") ..
          " policy_score=" .. tostring(policy_score_before or "") ..
          " nstrategy=" .. tostring(n_after) ..
          " failure=" .. tostring(failure_after and 1 or 0) ..
          " nocheck=" .. tostring(nocheck_after and 1 or 0) ..
          " success_state=" .. tostring(successful_state and 1 or 0) ..
          " response_state=" .. tostring(response_state and 1 or 0) ..
          " quic_candidate_state=" .. tostring(quic_candidate_state and 1 or 0) ..
          " success_event=" .. tostring(success_event and 1 or 0) ..
          " failure_event=" .. tostring(failure_event and 1 or 0) ..
          " latency_s=" .. tostring(latency_s or "") ..
          " persisted=" .. tostring(persisted and 1 or 0)
        )
      end
    end)
    return verdict
  end
end
