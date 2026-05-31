-- z2k-state-persist.lua
-- Persist zapret-auto.lua "circular" per-host strategy across nfqws2 restarts.
--
-- Design (state layer over the NATIVE circular(); ported from the proven
-- pre-r-41 z2k-autocircular.lua state core — persist + a bounded sticky-success
-- revert that keeps state.tsv on the strategy actually working):
--   - zapret-auto.lua stores nstrategy in global autostate[askey][hostkey].
--   - This file wraps circular() to:
--       1) seed autostate from a single TSV file on disk (best effort),
--       2) save nstrategy back to disk when it changes (rate-limited), and
--       3) revert circular's nstrategy drift when the host recently succeeded.
--   - Single state.tsv, full-file rewrite with merge (split-brain-safe across
--     processes) + a lockfile + a debounce window. NO sharding, NO WAL.
--   - Persist fires on confirmed-success states AND on every outgoing initial
--     packet (TLS ClientHello / QUIC initial / HTTP request) as a fallback, so
--     default-1 and hard-to-observe QUIC profiles still show; a server-active
--     rejection never pins. persist_if_changed() + debounce keep writes cheap.
--   - Sticky-success revert (THE accuracy fix): orig_circular drifts nstrategy
--     on parallel failing flows (HTTP/2 fan-out behind one hostname) even while
--     the host succeeds; if it advanced nstrategy within 30s of a real success
--     on (host|key), revert to the pre-circular value so the persisted/active
--     strategy stays the one actually working. (silent-retry / probe-override /
--     UCB stay OUT — those are Этап 6.)
--   - Storage key = desync.arg.key when provided, else desync.func_instance.

-- Test isolation: env overrides redirect state into a tmp dir for unit tests.
local STATE_DIR_PRIMARY = os.getenv("Z2K_STATE_DIR_OVERRIDE")
                          or os.getenv("Z2K_AUTOCIRCULAR_DIR_OVERRIDE")
                          or "/opt/zapret2/extra_strats/cache/autocircular"
local _fallback_base    = os.getenv("Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE")
                          or "/tmp"
local STATE_FILE_PRIMARY  = STATE_DIR_PRIMARY .. "/state.tsv"
local STATE_FILE_FALLBACK = _fallback_base .. "/z2k-autocircular-state.tsv"

local loaded = false
local state = {}            -- state[askey][hostn] = { strategy = N, ts = T }
-- last_written = snapshot of what WE last wrote to the primary state.tsv. The
-- external-edit reconcile diffs the disk-now against THIS (not `state`, which
-- can lead disk during the debounce window) so the rotator's own in-RAM drift
-- is never mistaken for an outside edit. See reconcile_external_edits().
local last_written = {}     -- last_written[askey][hostn] = { strategy = N, ts = T }
local last_write = 0
local write_interval = 2    -- seconds (debounce window for flash-friendly writes)

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function now_t()
  return tonumber(os.time() or 0) or 0
end

local function is_blank(s)
  return (s == nil) or (tostring(s) == "")
end

local function normalize_hostkey_for_state(hostkey)
  if hostkey == nil then return nil end
  local s = tostring(hostkey)
  if s == "" then return nil end
  s = s:gsub("%.$", "")       -- strip trailing dot
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

-- Best-effort early bailout only; real write safety = lock + tmp + rename.
local function can_replace_file_via_parent_dir(path)
  if is_blank(path) then return false end
  local dir = tostring(path):match("^(.*)/[^/]+$")
  if is_blank(dir) then return false end
  local probe = string.format("%s/.z2k-write-probe-%d.tmp", dir, now_t())
  local f = io.open(probe, "w")
  if not f then return false end
  f:close()
  os.remove(probe)
  return true
end

local function create_empty_state_file(path)
  local f = io.open(path, "w")
  if not f then return false end
  f:write("# z2k autocircular state (persisted circular nstrategy)\n")
  f:write("# key\thost\tstrategy\tts\n")
  f:close()
  return true
end

local function choose_state_file_for_read()
  if can_append_existing_file(STATE_FILE_PRIMARY) then return STATE_FILE_PRIMARY end
  if can_read_file(STATE_FILE_FALLBACK) then return STATE_FILE_FALLBACK end
  if can_read_file(STATE_FILE_PRIMARY) then return STATE_FILE_PRIMARY end
  return nil
end

local function choose_state_file_for_write()
  if can_append_existing_file(STATE_FILE_PRIMARY) then return STATE_FILE_PRIMARY end
  if can_replace_file_via_parent_dir(STATE_FILE_PRIMARY) then return STATE_FILE_PRIMARY end
  if can_append_existing_file(STATE_FILE_FALLBACK) then return STATE_FILE_FALLBACK end
  if can_replace_file_via_parent_dir(STATE_FILE_FALLBACK) then return STATE_FILE_FALLBACK end
  if create_empty_state_file(STATE_FILE_FALLBACK) then return STATE_FILE_FALLBACK end
  return nil
end

-- Merge a TSV file's rows into dest (last-newer-ts wins per host).
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

-- Shallow {askey -> hostn -> {strategy,ts}} copy keeping only persisted fields.
-- Used to snapshot disk/merged into `last_written` (the external-edit baseline).
local function snapshot_strategies(src)
  local out = {}
  for askey, hosts in pairs(src) do
    out[askey] = {}
    for hostn, rec in pairs(hosts) do
      if rec and rec.strategy then
        out[askey][hostn] = { strategy = rec.strategy, ts = rec.ts }
      end
    end
  end
  return out
end

local function load_state()
  if loaded then return end
  loaded = true
  state = {}
  local path = choose_state_file_for_read()
  if not path then return end
  merge_state_file_into(STATE_FILE_PRIMARY, state)
  merge_state_file_into(STATE_FILE_FALLBACK, state)
  -- Prime the external-edit baseline from the disk we just loaded. Without this
  -- `last_written` starts empty and the first reconcile would treat EVERY disk
  -- row as an outside edit (re-adopting it / rewinding any in-RAM drift that
  -- circular accumulated before the first debounced write). Priming makes the
  -- first reconcile a no-op for untouched rows.
  last_written = snapshot_strategies(state)
end

-- ---------------------------------------------------------------------------
-- write path: lock + tmp + rename, debounced, merge-with-disk
-- ---------------------------------------------------------------------------
local function acquire_lock(path)
  local lockfile = path .. ".lock"
  local lf_ts = io.open(lockfile, "r")
  if lf_ts then
    local content = lf_ts:read("*a")
    lf_ts:close()
    local lock_time = tonumber(content)
    if lock_time and (now_t() - lock_time) > 10 then
      os.remove(lockfile)        -- stale (>10s) → steal
    else
      return nil, lockfile       -- fresh → another writer holds it
    end
  end
  -- Exclusive create where the Lua build supports the glibc "x" mode. Stock Lua
  -- (l_checkmode) REJECTS "wx" with an "invalid mode" error rather than returning
  -- nil, so guard the open in pcall; on unsupported builds fall back to a
  -- non-exclusive create after an existence recheck (best effort — write safety
  -- is anyway provided by tmp-file + rename, and stale locks self-clear after 10s).
  local lf
  local ok_wx, res = pcall(io.open, lockfile, "wx")
  if ok_wx then lf = res end
  if not lf then
    local recheck = io.open(lockfile, "r")
    if recheck then recheck:close(); return nil, lockfile end
    lf = io.open(lockfile, "w")
  end
  if not lf then return nil, lockfile end
  lf:write(tostring(now_t()))
  lf:close()
  return true, lockfile
end

local function release_lock(lockfile)
  if lockfile then os.remove(lockfile) end
end

local function write_state()
  local now = now_t()
  if now ~= 0 and (now - last_write) < write_interval then
    return                       -- debounced; the next packet's write flushes it
  end
  last_write = now

  local path = choose_state_file_for_write()
  if not path then return end

  local locked, lockfile = acquire_lock(path)
  if not locked then return end

  -- Merge existing on-disk rows so a concurrent writer's entries are not lost.
  local merged = {}
  merge_state_file_into(path, merged)
  -- A readable file whose row is gone = a real external delete; an unreadable
  -- file = a transient I/O failure we must NOT mistake for "everything deleted".
  local disk_readable = can_read_file(path)
  for askey, hosts in pairs(state) do
    if not merged[askey] then merged[askey] = {} end
    for hostn, rec in pairs(hosts) do
      if rec.deleted then
        merged[askey][hostn] = nil
      elseif disk_readable and merged[askey][hostn] == nil
             and last_written[askey] and last_written[askey][hostn] then
        -- We wrote this host before (it's in last_written) yet it's gone from a
        -- readable disk now → the webpanel × (or a manual edit) removed it. Do
        -- NOT resurrect it, and drop our stale mirror so no later flush re-adds
        -- it. This closes the reconcile-debounce race: even if reconcile hasn't
        -- run yet, a sibling host's write can no longer revive a deleted row.
        merged[askey][hostn] = nil
        hosts[hostn] = nil
      else
        merged[askey][hostn] = rec
      end
    end
  end

  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then release_lock(lockfile); return end
  f:write("# z2k autocircular state (persisted circular nstrategy)\n")
  f:write("# key\thost\tstrategy\tts\n")
  for askey, hosts in pairs(merged) do
    for hostn, rec in pairs(hosts) do
      if rec and rec.strategy then
        f:write(tostring(askey), "\t", tostring(hostn), "\t",
                tostring(rec.strategy), "\t", tostring(rec.ts or 0), "\n")
      end
    end
  end
  f:close()
  if not os.rename(tmp, path) then
    os.remove(tmp)
  else
    -- Record exactly what is now on disk, so the external-edit reconcile can
    -- tell OUR own writes apart from outside edits (webpanel × / manual edit).
    last_written = snapshot_strategies(merged)
  end
  release_lock(lockfile)
end

-- ---------------------------------------------------------------------------
-- record derivation (simple — mirrors the old persist core exactly)
-- ---------------------------------------------------------------------------
local allowed_hostkey_funcs = {
  standard_hostkey = true,
  nld_hostkey = true,
  sld_hostkey = true,
  tld_hostkey = true,
  z2k_nohost_key = true,
}

local function get_hostkey_func(desync)
  if desync and desync.arg and desync.arg.hostkey then
    local fname = tostring(desync.arg.hostkey)
    if not allowed_hostkey_funcs[fname] then return nil end
    local f = _G[fname]
    if type(f) == "function" then return f end
    return nil
  end
  if type(standard_hostkey) == "function" then return standard_hostkey end
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
  if do_seed then load_state() end
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
    -- Mark deleted (propagates removal through the merge on write).
    state[askey][hostn] = { deleted = true, ts = now_t() }
    -- Bypass the debounce: a deletion must hit disk immediately, otherwise a
    -- crash within the write_interval window leaves the row on disk and the
    -- next start re-seeds the supposedly-cleared entry.
    last_write = 0
    write_state()
  end
end

local function persist_if_changed(askey, hostn, hrec)
  if not askey or not hostn or not hrec or not hrec.nstrategy then return false end
  local n = tonumber(hrec.nstrategy)
  if not n or n < 1 then return false end
  local prev = state[askey] and state[askey][hostn] and state[askey][hostn].strategy or nil
  if prev == n then return false end          -- skip ONLY when unchanged
  if not state[askey] then state[askey] = {} end
  state[askey][hostn] = { strategy = n, ts = now_t() }
  write_state()
  return true
end

-- allow_nohost handling REMOVED 2026-05-30: it mutated desync.track.hostname
-- to "nohost" so the native standard_hostkey would give hostless flows a stable
-- rotation key. That was a fragile cross-layer hack (a persist layer doing
-- circular's keying). All hostless profiles now key via the native
-- hostkey=z2k_nohost_key function instead (discord_udp already did; discord_voice
-- migrated in quic_strats.ini), so no profile sets allow_nohost any more and this
-- path became dead code. The native hostkey is consumed by get_hostkey_func below
-- (z2k_nohost_key is in allowed_hostkey_funcs), so persist keying still lands on
-- "nohost" for hostless flows — functionality preserved, the hack gone.

-- ---------------------------------------------------------------------------
-- known-good gating helpers (ported from the legacy z2k-autocircular state core)
-- ---------------------------------------------------------------------------
local STICKY_WINDOW_SEC = 30

local function now_f()
  if type(clock_getfloattime) == "function" then
    local ok, v = pcall(clock_getfloattime)
    if ok and tonumber(v) then return tonumber(v) end
  end
  return tonumber(os.time() or 0) or 0
end

-- Native conntrack success/failure flags stamped on desync.track.lua_state.automate
-- (crec) by the native success/failure detectors and z2k detectors.
local function conn_record_flags(desync)
  local tr = desync and desync.track
  local ls = tr and tr.lua_state
  local crec = ls and ls.automate
  if not crec then return false, false, false, false end
  return (crec.nocheck and true or false),
         (crec.failure and true or false),
         (crec.z2k_neutral_observed and true or false),
         (crec.z2k_server_active_reject and true or false)
end

-- A real success signal on an INCOMING packet. TLS ServerHello = handshake
-- reached the server. HTTP reply must be classified "positive" by
-- z2k_classify_http_reply (z2k-detectors.lua, loaded earlier in the --lua-init
-- chain); neutral 4xx/5xx and unmarked cross-SLD redirects must NOT pin.
-- Liberal fallback if the classifier is not loaded (init-order race).
local function has_positive_incoming_response(desync)
  if not desync or desync.outgoing then return false end
  local p = desync.l7payload
  if p == "tls_server_hello" then return true end
  if p == "http_reply" then
    if type(z2k_classify_http_reply) == "function" then
      return z2k_classify_http_reply(desync) == "positive"
    end
    return true
  end
  return false
end

local function is_quic_key(askey)
  if not askey then return false end
  local s = tostring(askey)
  return s == "yt_quic" or s == "rkn_quic" or s == "custom_quic" or s == "cf_quic"
end

-- Sticky-success revert is SAFE only for real-hostname pools, where each visited
-- host gets its own (host|key) bucket. Hostless pools (hostkey=z2k_nohost_key →
-- hostn="nohost": discord_udp / STUN / voice DTLS to many Discord DC IPs)
-- collapse ALL flows into ONE shared "nohost|<key>" bucket. A success on one
-- flow would then revert (pin) every OTHER flow's circular advancement, freezing
-- the whole pool on the first-working strategy and breaking voice to DCs that
-- need a different desync. r-43 had no revert at all, so discord rotated freely
-- and voice worked — keep exactly that behaviour for hostless/discord pools.
local function is_sticky_eligible(askey, hostn)
  if hostn == nil or hostn == "nohost" then return false end
  local s = askey and tostring(askey) or ""
  if s:match("^discord") then return false end
  return true
end

-- ---------------------------------------------------------------------------
-- External-edit reconcile — make state.tsv authoritative for OUTSIDE writes.
--
-- The rotator is native bol-van circular(); it keeps nstrategy in RAM
-- (autostate) and we only SEED it from disk on a host's first packet. So an
-- external change to an ALREADY-ACTIVE host (the webpanel × delete, or a manual
-- edit) used to be ignored until a full service restart. This re-reads the disk
-- and applies genuine external changes to the LIVE autostate, so they take
-- effect without bouncing nfqws.
--
-- It diffs disk-now against `last_written` (what WE last wrote to disk), NOT
-- against `state` (which leads disk during the write debounce) — so the
-- rotator's own in-RAM drift is never mistaken for an outside edit. Debounced.
local last_reconcile = 0
local reconcile_interval = 2   -- seconds

-- autostate is keyed by raw hostkey; disk/state by normalized hostn. Apply n to
-- every live record whose hostkey normalizes to hostn.
--
-- NOTE on blast radius: hostless pools (Discord et al.) collapse ALL flows to a
-- single hostkey=z2k_nohost_key bucket normalizing to "nohost". Deleting the
-- "nohost" row therefore resets the WHOLE pool to strategy 1 — that's the only
-- coherent semantic (there's one shared record), and "× = reset this bucket to
-- 1" is exactly what the operator asked, so we accept the wide reset.
local function set_live_nstrategy(askey, hostn, n)
  local ah = autostate and autostate[askey]
  if not ah then return end
  for hostkey, arec in pairs(ah) do
    if normalize_hostkey_for_state(hostkey) == hostn then
      arec.nstrategy = n
    end
  end
end

local function reconcile_external_edits()
  if not loaded then return end
  local now = now_t()
  if now ~= 0 and (now - last_reconcile) < reconcile_interval then return end
  last_reconcile = now

  -- Read the SAME view the bridge actually persists to — primary AND fallback,
  -- newer-ts winning — exactly like load_state(). Reading only the primary would
  -- be wrong on a read-only /opt where the bridge writes the /tmp fallback: the
  -- primary would look empty and every host would be (mis)read as deleted,
  -- turning reconcile into a mass-reset loop. If NEITHER file is readable we
  -- bail — an I/O failure must never be mistaken for "the operator deleted
  -- everything".
  local p_ok = can_read_file(STATE_FILE_PRIMARY)
  local f_ok = can_read_file(STATE_FILE_FALLBACK)
  if not (p_ok or f_ok) then return end
  local disk = {}
  if p_ok then merge_state_file_into(STATE_FILE_PRIMARY, disk) end
  if f_ok then merge_state_file_into(STATE_FILE_FALLBACK, disk) end

  -- (1) External DELETE — present at our last write, gone from disk now → the
  --     operator removed it (×) → reset its live rotation to strategy 1 and drop
  --     our mirror, so the next packet re-persists it at 1 ("скинуть на 1ю").
  for askey, hosts in pairs(last_written) do
    for hostn in pairs(hosts) do
      if not (disk[askey] and disk[askey][hostn]) then
        set_live_nstrategy(askey, hostn, 1)
        if state[askey] then state[askey][hostn] = nil end
      end
    end
  end

  -- (2) External EDIT/ADD — disk strategy differs from our last write → adopt it
  --     into the live autostate and our mirror.
  for askey, hosts in pairs(disk) do
    for hostn, drec in pairs(hosts) do
      local lw = last_written[askey] and last_written[askey][hostn]
      local dn = tonumber(drec.strategy)
      if dn and (not lw or tonumber(lw.strategy) ~= dn) then
        set_live_nstrategy(askey, hostn, dn)
        if not state[askey] then state[askey] = {} end
        state[askey][hostn] = { strategy = dn, ts = drec.ts }
      end
    end
  end

  -- Adopt disk as the new baseline.
  last_written = snapshot_strategies(disk)
end

-- ---------------------------------------------------------------------------
-- wrap circular() — persist + bounded sticky-success revert + external reconcile.
-- Keeps state.tsv on the strategy actually working (reverts circular's
-- parallel-flow drift within 30s of a real success). NO silent-retry / probe /
-- UCB here — those stay at Этап 6.
-- ---------------------------------------------------------------------------
if type(circular) == "function" then
  local orig_circular = circular
  circular = function(ctx, desync)
    local askey_before, hostn_before, hrec_before
    local nstrategy_before_circular   -- snapshot before orig_circular mutates hrec
    -- pre-block errors stay swallowed: never break the nfqws desync path.
    pcall(function()
      askey_before, hostn_before, hrec_before = get_record_for_desync(desync, true)
    end)

    -- Apply external state.tsv edits (webpanel × / manual) to the live autostate
    -- BEFORE the rotator runs, so an operator reset takes effect this packet
    -- (debounced internally). Errors swallowed — must never break the desync.
    pcall(reconcile_external_edits)

    -- Snapshot the sticky-revert baseline AFTER reconcile: circular starts from
    -- the reconciled value, so an operator edit/delete applied just now is the
    -- legitimate starting point, NOT "drift" to be rolled back. Capturing it
    -- before reconcile would let the 30s sticky window erase the operator's
    -- change on the very next packet.
    if hrec_before then
      nstrategy_before_circular = tonumber(hrec_before.nstrategy)
    end

    -- pcall ONLY to guarantee hostname restore before re-propagating errors.
    local ok, verdict_or_err = pcall(orig_circular, ctx, desync)
    local verdict
    if ok then
      verdict = verdict_or_err
      -- post-block errors stay swallowed (persist accounting must never throw).
      pcall(function()
        local askey_after, hostn_after, hrec_after
        pcall(function()
          askey_after, hostn_after, hrec_after = get_record_for_desync(desync, false)
        end)
        -- Stay bound to circular()'s host record (askey_before); askey_after may
        -- point at an executed instance (e.g. fake_1_2), not the circular state.
        local askey = askey_before or askey_after
        local hostn = hostn_before or hostn_after
        local hrec = hrec_before
        if (not hrec or not hrec.nstrategy) and hrec_after and hrec_after.nstrategy then
          hrec = hrec_after
        elseif not hrec then
          hrec = hrec_after
        end
        if not hrec then return end

        local nocheck_after, failure_after, neutral_after, server_active_after =
          conn_record_flags(desync)
        local n_after = tonumber(hrec.nstrategy) or nil

        -- Config changed (fewer strategies than persisted): normalize to 1 and
        -- drop the now-invalid persisted entry.
        local ct = tonumber(hrec.ctstrategy) or nil
        if ct and ct > 0 and n_after and (n_after < 1 or n_after > ct) then
          hrec.nstrategy = 1
          clear_persisted(askey, hostn)
          return
        end

        -- Known-good gating (legacy state core). A server-active rejection
        -- (TCP refused / TLS alert post-SH / bare 451 / WAF) must NEVER pin —
        -- the peer actively refused, a packet-level bypass cannot help; it has
        -- priority over every success state (nocheck may be latched from an
        -- earlier ServerHello, then a fatal alert arrives in this callback).
        local server_active_event = server_active_after
        local successful_state = nocheck_after and (not failure_after)
          and (not neutral_after) and (not server_active_event)
        local response_state = has_positive_incoming_response(desync)
          and (not failure_after) and (not neutral_after) and (not server_active_event)
        -- QUIC flows may not reliably trigger the success detector, but
        -- nstrategy>1 already means circular rotated this host — persist that
        -- candidate for QUIC keys.
        local quic_candidate_state =
          is_quic_key(askey) and (desync and desync.l7payload == "quic_initial")
          and (not failure_after) and (not server_active_event)
          and n_after and n_after > 1
        -- Broad fallback so default-1 / hard-to-observe profiles still show.
        local outgoing_initial = desync and desync.outgoing and n_after and
          (desync.l7payload == "tls_client_hello" or
           desync.l7payload == "quic_initial" or
           desync.l7payload == "http_req")
        local success_event = successful_state or response_state or quic_candidate_state

        -- Sticky-success revert (THE accuracy fix). orig_circular advances
        -- nstrategy on TCP-level signals (retrans / lua failures) that fire on
        -- parallel failing flows even while OTHER flows on the same host succeed
        -- (HTTP/2 fan-out behind one hostname). Without this, state.tsv records
        -- the drifted strategy, not the working one. Per-profile scope
        -- (hostn|askey): success on gv_tcp must NOT freeze rotation on yt_tcp.
        local sticky_key = (hostn and askey_after)
          and (hostn .. "|" .. tostring(askey_after)) or nil
        _G.Z2K_STICKY_SUCCESS_TS = _G.Z2K_STICKY_SUCCESS_TS or {}
        if success_event and sticky_key then
          _G.Z2K_STICKY_SUCCESS_TS[sticky_key] = now_f()
        end
        if sticky_key and is_sticky_eligible(askey, hostn) and nstrategy_before_circular and hrec.nstrategy
           and (tonumber(hrec.nstrategy) or 0) > nstrategy_before_circular then
          local last_ok = _G.Z2K_STICKY_SUCCESS_TS[sticky_key]
          if last_ok and (now_f() - last_ok) <= STICKY_WINDOW_SEC then
            hrec.nstrategy = nstrategy_before_circular
          end
        end

        -- Persist the (possibly reverted) strategy. Confirmed success OR the
        -- outgoing-initial fallback triggers a save; server-active never pins.
        if (success_event or outgoing_initial) and not server_active_event then
          persist_if_changed(askey, hostn, hrec)
        end
      end)
    end

    if not ok then error(verdict_or_err, 0) end
    return verdict
  end
end

-- Exported API (used by unit tests; webpanel/diag read state.tsv directly).
z2k_state_persist = {
  load_state = load_state,
  get_record = get_record_for_desync,
  persist_if_changed = persist_if_changed,
  clear_persisted = clear_persisted,
  write_state = write_state,
  -- flush(): bypass the debounce and force an immediate write (tests / shutdown).
  flush = function() last_write = 0; write_state() end,
  state_file = function() return STATE_FILE_PRIMARY end,
  _state = function() return state end,
  _set_interval = function(n) write_interval = tonumber(n) or write_interval end,
  _reset = function() loaded = false; state = {}; last_write = 0; last_written = {}; last_reconcile = 0; _G.Z2K_STICKY_SUCCESS_TS = {} end,
}
