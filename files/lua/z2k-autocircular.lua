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
local DEBUG_FLAG_PRIMARY = STATE_DIR_PRIMARY .. "/debug.flag"
local DEBUG_FLAG_FALLBACK = "/tmp/z2k-autocircular-debug.flag"
local DEBUG_LOG_PRIMARY = STATE_DIR_PRIMARY .. "/debug.log"
local DEBUG_LOG_FALLBACK = "/tmp/z2k-autocircular-debug.log"

local loaded = false
local state = {} -- state[askey][host_norm] = { strategy = N, ts = unix_time }

local last_write = 0
local write_interval = 2 -- seconds

local debug_enabled = false
local debug_checked_at = 0
local debug_refresh_interval = 5 -- seconds

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
  if not askey then return false end
  local s = tostring(askey)
  return s == "rkn_tcp" or s == "rkn_quic" or s == "custom_quic"
end

local function is_quic_key(askey)
  if not askey then return false end
  local s = tostring(askey)
  return s == "yt_quic" or s == "rkn_quic" or s == "custom_quic"
end

-- Wrap circular() from zapret-auto.lua.
if type(circular) == "function" then
  local orig_circular = circular
  circular = function(ctx, desync)
    local askey_before, hostn_before, hrec_before
    pcall(function()
      askey_before, hostn_before, hrec_before = get_record_for_desync(desync, true)
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
      local persisted = false
      if successful_state or response_state or quic_candidate_state then
        persisted = persist_if_changed(askey, hostn, hrec)
      end

      local debug_event = persisted or failure_after or successful_state or response_state or quic_candidate_state
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
          " nstrategy=" .. tostring(n_after) ..
          " failure=" .. tostring(failure_after and 1 or 0) ..
          " nocheck=" .. tostring(nocheck_after and 1 or 0) ..
          " success_state=" .. tostring(successful_state and 1 or 0) ..
          " response_state=" .. tostring(response_state and 1 or 0) ..
          " quic_candidate_state=" .. tostring(quic_candidate_state and 1 or 0) ..
          " persisted=" .. tostring(persisted and 1 or 0)
        )
      end
    end)
    return verdict
  end
end
