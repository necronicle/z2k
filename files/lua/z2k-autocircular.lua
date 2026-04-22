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
local RKN_SILENT_FLAG = STATE_DIR_PRIMARY .. "/rkn_silent_fallback.flag"

local loaded = false
local state = {} -- state[askey][host_norm] = { strategy = N, ts = unix_time }
local telemetry_loaded = false
local telemetry = {} -- telemetry[askey][hostn][strategy] = { ok, fail, lat, ts, cooldown_until }

local last_write = 0
local write_interval = 2 -- seconds
local pending_write = false
local last_telemetry_write = 0
local telemetry_write_interval = 5 -- seconds

local debug_enabled = false
local debug_checked_at = 0
local debug_refresh_interval = 5 -- seconds

local rkn_silent_enabled = false
local rkn_silent_checked_at = 0

-- Seed PRNG with better entropy when available
do
    local seed = os.time() or 0
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(4)
        f:close()
        if bytes and #bytes == 4 then
            seed = seed + bytes:byte(1) + bytes:byte(2) * 256 +
                   bytes:byte(3) * 65536 + bytes:byte(4) * 16777216
        end
    end
    math.randomseed(seed)
end

local policy_enabled = false
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

local function can_read_file(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

local function can_append_existing_file(path)
  if not can_read_file(path) then return false end
  local f = io.open(path, "a")
  if not f then return false end
  f:close()
  return true
end

-- Note on TOCTOU: this check is a best-effort early bailout only.
-- Actual write safety is guaranteed by acquire_lock() + write-to-tmp + os.rename().
-- If permissions change between this check and the write, the rename will fail
-- gracefully and pending_write will be set for retry.
local function can_replace_file_via_parent_dir(path)
  if is_blank(path) then return false end
  local dir = tostring(path):match("^(.*)/[^/]+$")
  if is_blank(dir) then return false end

  local probe = string.format(
    "%s/.z2k-write-probe-%d-%d.tmp",
    dir,
    tonumber(os.time() or 0) or 0,
    math.random(100000, 999999)
  )

  local f = io.open(probe, "w")
  if not f then return false end
  f:close()
  os.remove(probe)
  return true
end

local function choose_state_file_for_read()
  if can_append_existing_file(STATE_FILE_PRIMARY) then
    return STATE_FILE_PRIMARY
  end
  if can_read_file(STATE_FILE_FALLBACK) then
    return STATE_FILE_FALLBACK
  end
  if can_read_file(STATE_FILE_PRIMARY) then
    return STATE_FILE_PRIMARY
  end
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
  if can_append_existing_file(STATE_FILE_PRIMARY) then
    return STATE_FILE_PRIMARY
  end
  if can_replace_file_via_parent_dir(STATE_FILE_PRIMARY) then
    return STATE_FILE_PRIMARY
  end
  if can_append_existing_file(STATE_FILE_FALLBACK) then
    return STATE_FILE_FALLBACK
  end
  if can_replace_file_via_parent_dir(STATE_FILE_FALLBACK) then
    return STATE_FILE_FALLBACK
  end
  if create_empty_state_file(STATE_FILE_FALLBACK) then
    return STATE_FILE_FALLBACK
  end
  return nil
end

local function ensure_state_file_exists()
  return choose_state_file_for_read()
end

local function merge_state_file_into(path, dest)
  if not path or not dest then return end
  local f = io.open(path, "r")
  if not f then return end

  for line in f:lines() do
    if line ~= "" and not line:match("^%s*#") then
      local askey, host, strat, ts = line:match("^([^\t]+)\t([^\t]+)\t([0-9]+)\t?([0-9]*)")
      if askey and host and strat then
        local n = tonumber(strat)
        if n and n >= 1 then
          local hn = normalize_hostkey_for_state(host)
          if hn then
            if not dest[askey] then dest[askey] = {} end
            local tsn = tonumber(ts) or 0
            local prev = dest[askey][hn]
            if (not prev) or ((tonumber(prev.ts) or 0) <= tsn) then
              dest[askey][hn] = { strategy = n, ts = tsn }
            end
          end
        end
      end
    end
  end

  f:close()
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
  if can_append_existing_file(TELEMETRY_FILE_PRIMARY) then
    return TELEMETRY_FILE_PRIMARY
  end
  if can_read_file(TELEMETRY_FILE_FALLBACK) then
    return TELEMETRY_FILE_FALLBACK
  end
  if can_read_file(TELEMETRY_FILE_PRIMARY) then
    return TELEMETRY_FILE_PRIMARY
  end
  return nil
end

local function choose_telemetry_file_for_write()
  if can_append_existing_file(TELEMETRY_FILE_PRIMARY) then
    return TELEMETRY_FILE_PRIMARY
  end
  if can_replace_file_via_parent_dir(TELEMETRY_FILE_PRIMARY) then
    return TELEMETRY_FILE_PRIMARY
  end
  if can_append_existing_file(TELEMETRY_FILE_FALLBACK) then
    return TELEMETRY_FILE_FALLBACK
  end
  if can_replace_file_via_parent_dir(TELEMETRY_FILE_FALLBACK) then
    return TELEMETRY_FILE_FALLBACK
  end
  if create_empty_telemetry_file(TELEMETRY_FILE_FALLBACK) then
    return TELEMETRY_FILE_FALLBACK
  end
  return nil
end

local function ensure_telemetry_file_exists()
  return choose_telemetry_file_for_read()
end

local function merge_telemetry_file_into(path, dest)
  if not path or not dest then return end
  local f = io.open(path, "r")
  if not f then return end

  for line in f:lines() do
    if line ~= "" and not line:match("^%s*#") then
      local askey, hostn, strat, okv, failv, latv, tsv, cdv =
        line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]*)\t?([^\t]*)")
      local s = tonumber(strat)
      if askey and hostn and s and s >= 1 then
        if not dest[askey] then dest[askey] = {} end
        if not dest[askey][hostn] then dest[askey][hostn] = {} end
        local next_rec = {
          ok = tonumber(okv) or 0,
          fail = tonumber(failv) or 0,
          lat = tonumber(latv) or 0,
          ts = tonumber(tsv) or 0,
          cooldown_until = tonumber(cdv) or 0,
        }
        local prev = dest[askey][hostn][s]
        local prev_ts = prev and (tonumber(prev.ts) or 0) or -1
        local next_ts = tonumber(next_rec.ts) or 0
        local prev_cd = prev and (tonumber(prev.cooldown_until) or 0) or -1
        local next_cd = tonumber(next_rec.cooldown_until) or 0
        if (not prev) or (next_ts > prev_ts) or (next_ts == prev_ts and next_cd >= prev_cd) then
          dest[askey][hostn][s] = next_rec
        end
      end
    end
  end

  f:close()
end

local function load_state()
  if loaded then return end
  loaded = true
  state = {}

  local path = ensure_state_file_exists()
  if not path then return end

  merge_state_file_into(STATE_FILE_PRIMARY, state)
  merge_state_file_into(STATE_FILE_FALLBACK, state)
end

local function acquire_lock(path)
  local lockfile = path .. ".lock"
  -- Check for stale lock (older than 10 seconds)
  local lf_ts = io.open(lockfile, "r")
  if lf_ts then
    local content = lf_ts:read("*a")
    lf_ts:close()
    local lock_time = tonumber(content)
    if lock_time and ((os.time() or 0) - lock_time) > 10 then
      os.remove(lockfile)
    else
      return nil, lockfile -- lock is fresh, another process holds it
    end
  end
  -- Try exclusive create: "wx" works in Lua 5.3+/glibc; fallback to "w" with
  -- prior existence check (not perfectly atomic but good enough for our use case).
  local lf = io.open(lockfile, "wx")
  if not lf then
    -- "wx" not supported or file appeared between check and open
    local recheck = io.open(lockfile, "r")
    if recheck then
      recheck:close()
      return nil, lockfile -- another process created it
    end
    lf = io.open(lockfile, "w")
  end
  if not lf then return nil, lockfile end
  lf:write(tostring(os.time() or 0))
  lf:close()
  return true, lockfile
end

local function release_lock(lockfile)
  if lockfile then os.remove(lockfile) end
end

local function write_state()
  local now = os.time() or 0
  if now ~= 0 and (now - last_write) < write_interval then
    pending_write = true
    return
  end
  last_write = now
  pending_write = false

  local path = choose_state_file_for_write()
  if not path then
    pending_write = true
    return
  end

  -- Acquire lock to prevent concurrent writes
  local locked, lockfile = acquire_lock(path)
  if not locked then
    pending_write = true
    return
  end -- another process is writing, skip this cycle

  local tmp = path .. ".tmp"

  -- Read existing file to merge state (prevents split-brain across processes)
  local merged_state = {}
  local f_in = io.open(path, "r")
  if f_in then
    for line in f_in:lines() do
      if line ~= "" and not line:match("^%s*#") then
        local askey, host, strat, ts = line:match("^([^\t]+)\t([^\t]+)\t([0-9]+)\t?([0-9]*)")
        if askey and host and strat then
          if not merged_state[askey] then merged_state[askey] = {} end
          merged_state[askey][host] = { strategy = tonumber(strat), ts = tonumber(ts) or 0 }
        end
      end
    end
    f_in:close()
  end

  -- Apply our in-memory state over the merged state
  for askey, hosts in pairs(state) do
    if not merged_state[askey] then merged_state[askey] = {} end
    for hostn, rec in pairs(hosts) do
      if rec.deleted then
        merged_state[askey][hostn] = nil
      else
        merged_state[askey][hostn] = rec
      end
    end
  end

  local f = io.open(tmp, "w")
  if not f then
    pending_write = true
    release_lock(lockfile)
    return
  end

  f:write("# z2k autocircular state (persisted circular nstrategy)\n")
  f:write("# key\thost\tstrategy\tts\n")

  for askey, hosts in pairs(merged_state) do
    for hostn, rec in pairs(hosts) do
      if rec and rec.strategy then
        f:write(tostring(askey), "\t", tostring(hostn), "\t", tostring(rec.strategy), "\t", tostring(rec.ts or 0), "\n")
      end
    end
  end

  f:close()
  local ok, err = os.rename(tmp, path)
  if not ok then
    DLOG("ERROR: rename %s -> %s failed: %s\n", tmp, path, tostring(err))
    os.remove(tmp)
    pending_write = true
  end
  release_lock(lockfile)
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

  merge_telemetry_file_into(TELEMETRY_FILE_PRIMARY, telemetry)
  merge_telemetry_file_into(TELEMETRY_FILE_FALLBACK, telemetry)
end

local function write_telemetry()
  local now = now_f()
  if now ~= 0 and (now - last_telemetry_write) < telemetry_write_interval then
    return
  end
  last_telemetry_write = now

  local path = choose_telemetry_file_for_write()
  if not path then return end

  -- Acquire lock to prevent concurrent writes
  local locked, lockfile = acquire_lock(path)
  if not locked then return end

  local tmp = path .. ".tmp"

  -- Read existing file to merge telemetry (prevents split-brain across processes)
  local merged = {}
  local f_in = io.open(path, "r")
  if f_in then
    for line in f_in:lines() do
      if line ~= "" and not line:match("^%s*#") then
        local askey, hostn, strat, okv, failv, latv, tsv, cdv =
          line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]*)\t?([^\t]*)")
        local s = tonumber(strat)
        if askey and hostn and s and s >= 1 then
          if not merged[askey] then merged[askey] = {} end
          if not merged[askey][hostn] then merged[askey][hostn] = {} end
          merged[askey][hostn][s] = {
            ok = tonumber(okv) or 0,
            fail = tonumber(failv) or 0,
            lat = tonumber(latv) or 0,
            ts = tonumber(tsv) or 0,
            cooldown_until = tonumber(cdv) or 0,
          }
        end
      end
    end
    f_in:close()
  end

  -- Apply our in-memory telemetry over the merged data
  for askey, hosts in pairs(telemetry) do
    if not merged[askey] then merged[askey] = {} end
    for hostn, strats in pairs(hosts) do
      if not merged[askey][hostn] then merged[askey][hostn] = {} end
      for s, rec in pairs(strats) do
        if rec then
          merged[askey][hostn][s] = rec
        end
      end
    end
  end

  local f = io.open(tmp, "w")
  if not f then
    release_lock(lockfile)
    return
  end

  f:write("# z2k autocircular telemetry\n")
  f:write("# key\thost\tstrategy\tok\tfail\tlat\tts\tcooldown_until\n")
  for askey, hosts in pairs(merged) do
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
  local ok, err = os.rename(tmp, path)
  if not ok then
    DLOG("ERROR: rename %s -> %s failed: %s\n", tmp, path, tostring(err))
    os.remove(tmp)
  end
  release_lock(lockfile)
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

-- Whitelist of allowed global hostkey function names
local allowed_hostkey_funcs = {
  standard_hostkey = true,
  nld_hostkey = true,
  sld_hostkey = true,
  tld_hostkey = true,
}

local function get_hostkey_func(desync)
  if desync and desync.arg and desync.arg.hostkey then
    local fname = tostring(desync.arg.hostkey)
    if not allowed_hostkey_funcs[fname] then
      debug_log("get_hostkey_func: rejected non-whitelisted function: " .. fname)
      return nil
    end
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
    -- Mark as deleted instead of nil to propagate deletion during merge
    state[askey][hostn] = { deleted = true, ts = os.time() or 0 }
    write_state()
  end
end

local function persist_if_changed(askey, hostn, hrec)
  if not askey or not hostn or not hrec or not hrec.nstrategy then return false end
  local n = tonumber(hrec.nstrategy)
  if not n or n < 1 then return false end

  local prev = state[askey] and state[askey][hostn] and state[askey][hostn].strategy or nil
  if prev == n then return false end

  if not state[askey] then state[askey] = {} end
  state[askey][hostn] = { strategy = n, ts = os.time() or 0 }
  write_state()
  return true
end

local policy_explore_good = 0.03  -- exploration chance when current strategy is working (3%)
local youtube_silent_retry_window_sec = 120
local youtube_silent_retry_min_gap_sec = 2
local youtube_silent_retry_threshold = 2
local youtube_silent_retry = {}

local function refresh_rkn_silent_enabled()
  local now = os.time() or 0
  if now ~= 0 and (now - rkn_silent_checked_at) < debug_refresh_interval then
    return rkn_silent_enabled
  end
  rkn_silent_checked_at = now
  local f = io.open(RKN_SILENT_FLAG, "r")
  if f then
    f:close()
    rkn_silent_enabled = true
    return true
  end
  rkn_silent_enabled = false
  return false
end

local function is_youtube_tcp_key(askey)
  if not askey then return false end
  local s = tostring(askey)
  if s == "yt_tcp" then return true end
  if s == "rkn_tcp" and refresh_rkn_silent_enabled() then return true end
  return false
end

local function youtube_silent_retry_rec(askey, hostn, create)
  if not askey or not hostn then return nil end
  local a = youtube_silent_retry[askey]
  if not a then
    if not create then return nil end
    a = {}
    youtube_silent_retry[askey] = a
  end
  local r = a[hostn]
  if not r and create then
    r = { attempts = 0, strategy = 0, last_t = 0 }
    a[hostn] = r
  end
  return r
end

local function reset_youtube_silent_retry(askey, hostn)
  local r = youtube_silent_retry_rec(askey, hostn, false)
  if not r then return end
  r.attempts = 0
  r.last_t = 0
end

local function maybe_rotate_youtube_silent_retry(desync, askey, hostn, hrec)
  if not is_youtube_tcp_key(askey) then return nil, nil, nil end
  if not desync or not desync.outgoing or desync.l7payload ~= "tls_client_hello" then
    return nil, nil, nil
  end
  if not hrec then return nil, nil, nil end

  local ct = tonumber(hrec.ctstrategy) or 0
  local cur = tonumber(hrec.nstrategy) or 1
  if cur < 1 then cur = 1 end

  local now = now_f()
  local r = youtube_silent_retry_rec(askey, hostn, true)
  if not r then return nil, nil, nil end

  local gap = now - (tonumber(r.last_t) or 0)
  if tonumber(r.strategy) == cur and gap >= youtube_silent_retry_min_gap_sec and gap <= youtube_silent_retry_window_sec then
    r.attempts = (tonumber(r.attempts) or 0) + 1
  else
    r.attempts = 1
  end
  r.strategy = cur
  r.last_t = now

  local attempts = tonumber(r.attempts) or 0
  if attempts < youtube_silent_retry_threshold or ct < 2 then
    return nil, nil, attempts
  end

  local next_strategy = cur >= ct and 1 or (cur + 1)
  telemetry_record_event(askey, hostn, cur, false, nil, now)
  hrec.nstrategy = next_strategy
  r.strategy = next_strategy
  r.attempts = 0
  r.last_t = now
  return cur, next_strategy, attempts
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

  local now = now_f()

  -- Respect current working strategy: if it has good telemetry and is not in
  -- cooldown, keep it.  Only override with very low probability (3%) to allow
  -- occasional exploration without destroying a known-good choice.
  local current = tonumber(hrec.nstrategy)
  if current and current >= 1 and current <= ct then
    local cur_rec = telemetry_rec(askey, hostn, current, false)
    if cur_rec then
      local cur_ok = tonumber(cur_rec.ok) or 0
      local cur_fail = tonumber(cur_rec.fail) or 0
      local cur_total = cur_ok + cur_fail
      if not telemetry_is_cooldown(cur_rec, now) and cur_total >= 2 then
        local cur_rate = cur_ok / cur_total
        if cur_rate > 0.5 then
          if math.random() >= policy_explore_good then
            if st then st.policy_seeded = true end
            return nil, nil
          end
        end
      end
    else
      -- No telemetry for current strategy yet: let it accumulate data.
      -- This is critical for TCP profiles where success telemetry is never
      -- recorded (incoming packets don't reach circular). Without this,
      -- UCB would override persisted working strategies on every connection.
      if st then st.policy_seeded = true end
      return nil, nil
    end
  end

  local pick, score = policy_pick_strategy(askey, hostn, ct, now)
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

-- Extended failure detector beyond standard_failure_detector:
-- 1. HTTP DPI redirect to block page (SLD mismatch for 301/303/308, not just 302/307)
-- 2. HTTP block page keywords (lawfilter, rkn, etc.) as fallback
-- 3. TLS fatal alert (Cloudflare ECH handshake_failure, etc.)

-- Keyword-based block page detection (fallback when SLD check is unavailable).
-- Catches DPI block pages by ISP-specific patterns in Location header or body.
local function z2k_http_block_reply(payload)
  if type(payload) ~= "string" then return false end
  local code_s = payload:match("^HTTP/%d%.%d%s+([0-9][0-9][0-9])")
  local code = tonumber(code_s)
  if not code then return false end

  -- Unambiguous block status codes
  if code == 403 or code == 451 then
    return true
  end

  -- Any redirect with block-indicating keywords in Location
  if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
    local low = string.lower(payload)
    if low:find("\r\nlocation:", 1, true) then
      if low:find("block", 1, true) or
         low:find("forbidden", 1, true) or
         low:find("zapret", 1, true) or
         low:find("rkn", 1, true) or
         low:find("lawfilter", 1, true) or
         low:find("restrict", 1, true) or
         low:find("vigruzki", 1, true) or
         low:find("eais", 1, true) or
         low:find("warning", 1, true) or
         low:find("blackhole", 1, true) then
        return true
      end
    end
  end
  return false
end

-- SLD-based redirect detection: any redirect (301/302/303/307/308) to a
-- different second-level domain is a DPI redirect. This is the most universal
-- check — works for any ISP regardless of their block page URL patterns.
-- standard_failure_detector only checks 302/307; we extend to all codes.
local function z2k_http_dpi_redirect(desync)
  if not desync or desync.outgoing then return false end
  if desync.l7payload ~= "http_reply" then return false end
  if not desync.track or not desync.track.hostname then return false end
  if type(http_dissect_reply) ~= "function" then return false end
  if type(array_field_search) ~= "function" then return false end
  if type(is_dpi_redirect) ~= "function" then return false end

  local hdis = http_dissect_reply(desync.dis.payload)
  if not hdis then return false end
  local c = hdis.code
  -- 302/307 are already caught by standard_failure_detector, but re-checking
  -- them here is harmless (crec.nocheck prevents double-counting) and makes
  -- this function self-contained.
  if c ~= 301 and c ~= 302 and c ~= 303 and c ~= 307 and c ~= 308 then
    return false
  end
  local idx = array_field_search(hdis.headers, "header_low", "location")
  if not idx then return false end
  return is_dpi_redirect(desync.track.hostname, hdis.headers[idx].value)
end

function z2k_tls_alert_fatal(desync, crec)
  if type(standard_failure_detector) == "function" then
    local ok, res = pcall(standard_failure_detector, desync, crec)
    if ok and res then return true end
  end

  if not desync or desync.outgoing then return false end
  local dis = desync.dis

  -- RST and FIN are handled by standard_failure_detector (RST within inseq=4K,
  -- retransmissions within maxseq=32K). We do NOT extend these checks because:
  -- - DPI sends RST early (within first few hundred bytes), already covered
  -- - FIN is normal TCP close, NOT a DPI signal. Short connections (TLS 1.3
  --   session resumption + small API response < 4K) would cause false positives:
  --   success_detector (inseq=4K) hasn't fired yet when FIN arrives, so the
  --   failure detector runs and counts normal connection close as failure.
  --   With fails=2, two short API calls within 60s = false rotation.

  -- HTTP DPI redirect: ISP redirects to block page (e.g. lawfilter.ertelecom.ru).
  -- SLD-based check is universal for any ISP; keyword-based is a fallback.
  if z2k_http_dpi_redirect(desync) then
    return true
  end
  local payload = dis and dis.payload
  if z2k_http_block_reply(payload) then
    return true
  end

  -- TLS fatal alert (e.g. Cloudflare ECH handshake_failure)
  if type(payload) ~= "string" then return false end
  if #payload < 7 then return false end
  if payload:byte(1) ~= 0x15 then return false end -- TLS record: alert (21)
  if payload:byte(6) ~= 0x02 then return false end -- alert level: fatal (2)
  return true
end

-- Stalled TLS handshake detector — superset of z2k_tls_alert_fatal.
--
-- Inherits all of z2k_tls_alert_fatal's signals (retrans, incoming RST,
-- HTTP DPI redirect, TLS fatal alert) and adds one more: if we've seen
-- an outgoing TLS ClientHello for a host and no incoming ServerHello
-- arrived within Z2K_TLS_STALLED_SEC seconds, classify the NEXT attempt
-- to that host as a failure.
--
-- Why it exists: some ISPs (observed on Ростелеком against cloudflare.com,
-- meet.google.com, discord.com) accept the TCP handshake and ACK our
-- modified ClientHello at L4, but silently drop it at the application
-- layer — no RST, no TLS alert, no response at all. The TCP client
-- doesn't retransmit because data was ACK'd, so standard_failure_detector
-- sees nothing, standard_success_detector may even mark the flow as
-- successful once seqspace crosses 4K, and circular pins itself to the
-- broken strategy forever.
--
-- Per-host design: nfqws2 detectors are packet-driven, so a purely silent
-- flow never triggers a second callback for its own crec — the detector
-- can only *record* on the outgoing CH and never gets another chance to
-- check elapsed time. An earlier attempt used a per-crec timestamp and
-- failed in the field because the timeout check had nobody to run it.
-- This version keeps a PROCESS-GLOBAL map `host → last CH timestamp`
-- that persists across connections. On every new CH for the same host,
-- we compare to the previous timestamp and, if elapsed exceeds the
-- threshold without any intervening ServerHello having cleared the
-- entry, we count this attempt as a failure.
--
-- Failure signal kicks in starting from the SECOND attempt that occurs
-- more than Z2K_TLS_STALLED_SEC after the first. Combined with circular's
-- fails=3 this means roughly 4-5 stalled attempts from the user before
-- the rotator advances to the next strategy.
--
-- 10s timeout is deliberately conservative — legitimate slow servers
-- (overloaded CDNs, satellite links) usually finish the TLS handshake
-- well under that. If field testing shows false positives, bump up.
--
-- Memory: the host map grows monotonically. For a router gateway the
-- distinct hostname set stabilises in the low thousands, each entry is
-- roughly 50 bytes — <100 KB even under heavy use. ServerHello clears
-- entries for working hosts, so only actually-stuck hosts accumulate.
local Z2K_TLS_STALLED_SEC = 10
local z2k_tls_stalled_host_ts = {}

function z2k_tls_stalled(desync, crec)
  -- Inherit existing fail signals
  if type(z2k_tls_alert_fatal) == "function" then
    local ok, res = pcall(z2k_tls_alert_fatal, desync, crec)
    if ok and res then return true end
  end

  if not desync then return false end
  local host = desync.track and desync.track.hostname
  if not host or host == "" then return false end
  local now = os.time and os.time() or 0
  if now == 0 then return false end

  -- Incoming ServerHello: handshake progressing for this host, clear tracking
  if not desync.outgoing and desync.l7payload == "tls_server_hello" then
    z2k_tls_stalled_host_ts[host] = nil
    return false
  end

  -- Outgoing ClientHello: check previous CH timestamp for this host
  if desync.outgoing and desync.l7payload == "tls_client_hello" then
    local prev = z2k_tls_stalled_host_ts[host]
    if prev then
      local elapsed = now - prev
      if elapsed >= Z2K_TLS_STALLED_SEC then
        if type(DLOG) == "function" then
          DLOG("z2k_tls_stalled: host=" .. host .. " prev ClientHello " .. elapsed .. "s ago with no ServerHello — counting as fail")
        end
        z2k_tls_stalled_host_ts[host] = now
        return true
      end
      -- Too early: update to more recent value but don't fail yet
      z2k_tls_stalled_host_ts[host] = now
      return false
    end
    -- First attempt for this host: just record
    z2k_tls_stalled_host_ts[host] = now
    return false
  end

  return false
end

-- Conservative success detector for TCP profiles.
-- Detects success but does NOT reset host failure counters.
-- This is important for TV clients: successful handshakes from other devices
-- on the same domain must not mask repeated webOS failures.
function z2k_success_no_reset(desync, crec)
  if type(standard_success_detector) ~= "function" then return false end
  local ok, result = pcall(standard_success_detector, desync, crec)
  if ok and result then
    if crec then
      crec.nocheck = true
    end
    return false
  end
  return false
end

-- Wrap circular() from zapret-auto.lua.
if type(circular) == "function" then
  local orig_circular = circular
  circular = function(ctx, desync)
    local askey_before, hostn_before, hrec_before
    local policy_pick_before, policy_score_before
    local silent_rotate_from_before, silent_rotate_to_before, silent_attempts_before
    pcall(function()
      askey_before, hostn_before, hrec_before = get_record_for_desync(desync, true)
      if hrec_before then
        silent_rotate_from_before, silent_rotate_to_before, silent_attempts_before =
          maybe_rotate_youtube_silent_retry(desync, askey_before, hostn_before, hrec_before)
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
      -- Persist on every outgoing initial packet as a fallback. Some profiles
      -- still expose success only indirectly, and even the restored manual
      -- YouTube layout benefits from saving the active candidate immediately.
      -- write_state() is rate-limited (2s) and persist_if_changed() skips
      -- redundant writes.
      local outgoing_initial = desync and desync.outgoing and n_after and
        (desync.l7payload == "tls_client_hello" or
         desync.l7payload == "quic_initial" or
         desync.l7payload == "http_req")
      local success_event = successful_state or response_state or quic_candidate_state
      local failure_event = failure_after and (not success_event)
      local persisted = false
      if success_event or outgoing_initial then
        persisted = persist_if_changed(askey, hostn, hrec)
      end

      if success_event or failure_event then
        reset_youtube_silent_retry(askey, hostn)
      end

      local latency_s, flow_strategy = nil, nil
      if success_event or failure_event then
        latency_s, flow_strategy = flow_finish(desync)
        local strat_for_stat = n_after or flow_strategy
        if strat_for_stat then
          telemetry_record_event(askey, hostn, strat_for_stat, success_event and (not failure_event), latency_s, now_f())
        end
      end

      if pending_write then
        write_state()
      end

      local debug_event = persisted or failure_after or success_event or failure_event or outgoing_initial or (policy_pick_before ~= nil)
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
          " outgoing_initial=" .. tostring(outgoing_initial and 1 or 0) ..
          " silent_attempts=" .. tostring(silent_attempts_before or 0) ..
          " silent_rotate_from=" .. tostring(silent_rotate_from_before or "") ..
          " silent_rotate_to=" .. tostring(silent_rotate_to_before or "") ..
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
