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

local loaded = false
local state = {} -- state[askey][host_norm] = { strategy = N, ts = unix_time }

local last_write = 0
local write_interval = 2 -- seconds

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

local function choose_state_file_for_write()
  local f = io.open(STATE_FILE_PRIMARY, "a")
  if f then f:close(); return STATE_FILE_PRIMARY end
  f = io.open(STATE_FILE_FALLBACK, "a")
  if f then f:close(); return STATE_FILE_FALLBACK end
  return nil
end

local function load_state()
  if loaded then return end
  loaded = true
  state = {}

  local path = choose_state_file_for_read()
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

local function seed_from_state(desync)
  load_state()

  local hkf = get_hostkey_func(desync)
  if not hkf then return nil, nil, nil end

  local hostkey = hkf(desync)
  if not hostkey then return nil, nil, nil end

  local askey = get_askey(desync)
  local hostn = normalize_hostkey_for_state(hostkey)
  if not hostn then return nil, nil, nil end

  local hrec = ensure_autostate_record(askey, hostkey)
  if not hrec.nstrategy then
    local rec = state[askey] and state[askey][hostn]
    if rec and rec.strategy then
      hrec.nstrategy = rec.strategy
    end
  end

  return askey, hostn, hrec
end

local function persist_if_changed(askey, hostn, hrec)
  if not askey or not hostn or not hrec or not hrec.nstrategy then return end
  local n = tonumber(hrec.nstrategy)
  if not n or n < 1 then return end

  -- Strategy "1" is default. Don't persist it. If it was previously persisted, delete the record.
  if n == 1 then
    if state[askey] and state[askey][hostn] then
      state[askey][hostn] = nil
      if next(state[askey]) == nil then state[askey] = nil end
      write_state()
    end
    return
  end

  local prev = state[askey] and state[askey][hostn] and state[askey][hostn].strategy or nil
  if prev == n then return end

  if not state[askey] then state[askey] = {} end
  state[askey][hostn] = { strategy = n, ts = os.time() or 0 }
  write_state()
end

-- Wrap circular() from zapret-auto.lua.
if type(circular) == "function" then
  local orig_circular = circular
  circular = function(ctx, desync)
    local askey, hostn, hrec
    pcall(function()
      askey, hostn, hrec = seed_from_state(desync)
    end)
    local verdict = orig_circular(ctx, desync)
    pcall(function()
      persist_if_changed(askey, hostn, hrec)
    end)
    return verdict
  end
end
