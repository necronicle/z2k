-- z2k-state-persist.lua
-- Persist zapret-auto.lua "circular" per-host strategy across nfqws2 restarts.
--
-- Saves the native circular host strategy and honors explicit operator pins.
-- Flow attribution and rotation live in zapret-auto.lua; this layer never
-- infers success from traffic in order to undo an automatic rotation.
-- State writes remain merged, locked and rate limited.
--
-- Unit tests: tests/test_z2k_state_persist.lua (Lua harness) and
-- tests/test_z2k_state_persist.sh (shell wrapper) — run via
-- tests/run_all.sh, or directly with `lua5.3 tests/test_z2k_state_persist.lua`.

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
  f:write("# key\thost\tstrategy\tts\tmode\tsni\n")
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
      -- 5th column = mode (auto|frozen). Optional for backward compat: a legacy
      -- 4-column row parses mode="" → normalized to "auto" below.
      local askey, host, strat, ts, mode, sni =
        line:match("^([^\t]+)\t([^\t]+)\t([0-9]+)\t?([0-9]*)\t?([a-z]*)\t?([A-Za-z0-9.-]*)")
      if askey and host and strat then
        local n = tonumber(strat)
        if n and n >= 1 then
          local hn = normalize_hostkey_for_state(host)
          if hn then
            if not dest[askey] then dest[askey] = {} end
            local tsn = tonumber(ts) or 0
            local m = (mode ~= nil and mode ~= "") and mode or "auto"
            local prev = dest[askey][hn]
            if (not prev) or ((tonumber(prev.ts) or 0) <= tsn) then
              dest[askey][hn] = { strategy = n, ts = tsn, mode = m,
                                  sni = (sni and #sni > 0) and sni or nil }
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
        out[askey][hostn] = { strategy = rec.strategy, ts = rec.ts,
                              mode = rec.mode or "auto", sni = rec.sni }
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
    local now = now_t()
    if not lock_time then
      -- Пустой или нечисловой lockfile. Замок создаётся и заполняется ДВУМЯ
      -- операциями (io.open ниже, затем lf:write), и процесс, убитый между
      -- ними — а OOM здесь штатное явление — оставляет файл нулевой длины.
      -- Раньше tonumber("") давал nil, условие протухания было ложным, и мы
      -- уходили в "держит другой писатель". Навсегда: файл лежит на /opt и
      -- переживает перезагрузку, то есть персист умирал молча и необратимо.
      -- Незаполненный замок владельца не имеет — забираем.
      os.remove(lockfile)
    elseif lock_time > now + 10 then
      -- Метка из будущего: часы уехали вперёд и потом вернулись (на Keenetic
      -- после power-loss это обычное дело — NTP подтягивает время уже после
      -- старта). По разнице такой замок не протухнет никогда, поэтому судим
      -- по несуразности самой метки, а не по возрасту.
      os.remove(lockfile)
    elseif (now - lock_time) > 10 then
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

local flush_pending = false
local function write_state()
  local now = now_t()
  if now ~= 0 and (now - last_write) < write_interval then
    if not flush_pending and type(timer_set) == "function" then
      flush_pending = true
      timer_set("z2k_state_flush", function()
        flush_pending = false
        write_state()
      end, (write_interval - (now - last_write)) * 1000 + 10, true)
    end
    return
  end
  if flush_pending and type(timer_del) == "function" then timer_del("z2k_state_flush") end
  flush_pending = false
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
  f:write("# key\thost\tstrategy\tts\tmode\tsni\n")
  for askey, hosts in pairs(merged) do
    for hostn, rec in pairs(hosts) do
      if rec and rec.strategy then
        -- Шестая колонка приписана в хвост намеренно: парсер читает поля по
        -- позиции, поэтому старый файл без неё читается как прежде, а старая
        -- версия кода на новом файле просто не увидит лишнее поле.
        f:write(tostring(askey), "\t", tostring(hostn), "\t",
                tostring(rec.strategy), "\t", tostring(rec.ts or 0), "\t",
                tostring(rec.mode or "auto"), "\t",
                tostring(rec.sni or ""), "\n")
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
  -- The generated domain pools use this helper; persistence must derive the
  -- same host record as circular for saves, restoration and operator pins.
  z2k_service_hostkey = true,
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
      -- Подобранное имя переживает перезапуск: иначе после каждого рестарта
      -- человек снова платил бы полным перебором за уже найденное.
      -- Имя в файле — уже доказанное (см. запись), поэтому и восстанавливаем его
      -- как доказанное: одна неудачная попытка после рестарта не должна
      -- отправлять человека проходить перебор заново.
      if rec.sni then hrec.z2k_sni = rec.sni; hrec.z2k_sni_ok = true end
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
  -- Подобранное имя из белого списка. Хранится рядом с номером плеча, а не
  -- вместо него: имя и разрез — разные оси, разрез продолжает ротироваться.
  -- В файл уезжает только ДОКАЗАВШЕЕ себя имя — то, с которым хост ответил.
  -- Имена-кандидаты живут в памяти: после перезапуска памяти нет, и записанный
  -- кандидат означал бы «начни с середины списка», а записанный неудачник —
  -- «начни с заведомо плохого». Замер 30.08.2026 показал второе.
  local sni = hrec.z2k_sni_ok and hrec.z2k_sni or nil
  local prev_sni = state[askey] and state[askey][hostn] and state[askey][hostn].sni or nil
  -- Пропускаем, только если не изменилось НИ ОДНО из двух. Проверять один
  -- номер плеча нельзя: у обхода 16 КБ плечо как раз стоит на месте, а меняется
  -- имя — с прежним условием шестая колонка не записалась бы никогда.
  if prev == n and prev_sni == sni then return false end
  -- Preserve any operator-set mode (frozen) across an engine-driven save: a row
  -- the operator froze must keep mode="frozen" on disk even if some code path
  -- persists its strategy. (For a frozen row the freeze gate forces nstrategy back
  -- to the pinned value, so prev==n and we return above before reaching here.)
  local mode = (state[askey] and state[askey][hostn] and state[askey][hostn].mode) or "auto"
  if not state[askey] then state[askey] = {} end
  state[askey][hostn] = { strategy = n, ts = now_t(), mode = mode, sni = sni }
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
-- Native conntrack success/failure flags stamped on desync.track.lua_state.automate
-- (crec) by the native success/failure detectors and z2k detectors.
local function conn_record_flags(desync)
  local tr = desync and desync.track
  local ls = tr and tr.lua_state
  local crec = ls and ls.automate
  if not crec then return false, false, false, false end
  return (crec.nocheck and true or false),
         (crec.failure and true or false),
         ((crec.neutral or crec.z2k_neutral_observed) and true or false),
         (crec.z2k_server_active_reject and true or false)
end

-- A real success signal on an INCOMING packet. TLS ServerHello = handshake
-- reached the server. HTTP reply must be classified "positive" by
-- z2k_classify_http_reply (с 2026-08-26 живёт в z2k-alert.lua, который в
-- --lua-init стоит РАНЬШЕ этого файла — см. S99zapret2.new); neutral 4xx/5xx и
-- cross-SLD редиректы без маркера пинить НЕ должны.
-- Мягкий откат, если классификатор не загрузился: обновление раскладывает
-- файлы по одному, и в этом окне рядом может лежать ещё старая пара.
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
  return s == "quic" or s == "yt_quic" or s == "rkn_quic" or s == "custom_quic" or s == "cf_quic"
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
      -- A manual reset to the same number is still a new attempt generation.
      arec.generation = nil
      -- Вместе со стратегией обнуляем накопленные неудачи хоста.
      --
      -- Момент, когда человек жмёт «×» или выбирает стратегию руками, — это
      -- почти всегда момент СРАЗУ ПОСЛЕ того, как он увидел, что сайт отвалился.
      -- То есть счётчик уже 2 из 3 в шестидесятисекундном окне. Без сброса
      -- первая же неудача на только что выбранной стратегии добивает порог, и
      -- ротатор уезжает с неё — человек уверен, что закрепил выбор, а выбор
      -- сменился сам. Неудачи, накопленные ДО вмешательства, к новой стратегии
      -- отношения не имеют.
      --
      -- Зовём штатную функцию движка, а не чистим поля руками: она и есть
      -- предусмотренная для этого точка (zapret-auto.lua, вызывается внешней
      -- логикой при смене состояния не через детектор). На старом движке,
      -- где её нет, гейт оставляет поведение прежним.
      if type(automate_failure_counter_reset) == "function" then
        pcall(automate_failure_counter_reset, arec)
      end
    end
  end
end

local function reconcile_external_edits(force)
  if not loaded then return end
  local now = now_t()
  if not force and now ~= 0 and (now - last_reconcile) < reconcile_interval then return end
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
      -- A mode-only flip (freeze toggled at the SAME strategy) is also an external
      -- edit we must adopt — otherwise freezing a row already on its current
      -- strategy would be ignored until the strategy itself changed.
      local dmode = drec.mode or "auto"
      local lwmode = (lw and lw.mode) or "auto"
      if dn and (not lw or tonumber(lw.strategy) ~= dn or lwmode ~= dmode) then
        set_live_nstrategy(askey, hostn, dn)
        if not state[askey] then state[askey] = {} end
        state[askey][hostn] = { strategy = dn, ts = drec.ts, mode = dmode }
      end
    end
  end

  -- Adopt disk as the new baseline.
  last_written = snapshot_strategies(disk)
end

local function apply_pin(askey, hostn, hrec)
  if not hrec or not askey or not hostn then return end
  local srec = state[askey] and state[askey][hostn]
  if srec and srec.mode == "frozen" and tonumber(srec.strategy) then
    hrec.nstrategy = tonumber(srec.strategy)
    hrec.final = tonumber(srec.strategy)
  else
    hrec.final = nil
  end
end

-- ---------------------------------------------------------------------------
-- wrap circular() — persistence + explicit operator reconciliation.
-- No automatic success-based override of circular's result.
-- ---------------------------------------------------------------------------
if type(circular) == "function" then
  local orig_circular = circular
  circular = function(ctx, desync)
    local askey_before, hostn_before, hrec_before
    local nstrategy_before_circular   -- used for initial seed recovery
    -- pre-block errors stay swallowed: never break the nfqws desync path.
    pcall(function()
      askey_before, hostn_before, hrec_before = get_record_for_desync(desync, true)
    end)

    -- Apply external state.tsv edits (webpanel × / manual) to the live autostate
    -- BEFORE the rotator runs, so an operator reset takes effect this packet
    -- (debounced internally). Errors swallowed — must never break the desync.
    pcall(reconcile_external_edits)

    pcall(function()
      apply_pin(askey_before, hostn_before, hrec_before)
      if hrec_before and not hrec_before.on_strategy_changed then
        hrec_before.on_strategy_changed = function(rec)
          persist_if_changed(askey_before, hostn_before, rec)
        end
        hrec_before.before_async_result = function(rec)
          -- No packet may arrive between an operator pin and a QUIC timeout.
          reconcile_external_edits(true)
          apply_pin(askey_before, hostn_before, rec)
        end
      end
    end)

    -- Remember whether this host was seeded before circular ran.
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

        -- SEED-RECOVERY (display-truth invariant). If the pre-circular seed
        -- missed for this host (nstrategy_before_circular == nil — e.g. the first
        -- real packet created the record only now, or load_state lost the race)
        -- circular fell back to its default nstrategy=1 (zapret-auto.lua) while
        -- disk still holds the real pinned/persisted value. Without this, that
        -- cosmetic 1 then gets persisted over the truth and the display lies.
        -- Detect exactly that signature and ADOPT the persisted value into live so
        -- disk and live converge on the SAME real strategy on this very packet.
        -- STRICT exact key (state[askey][hostn], hostn carries |4/|6) — never
        -- cross-adopt a sibling address family (would break family-split / r-49).
        -- A webpanel × delete clears the disk row first, so there is no N!=1 row
        -- to recover from → a genuine reset to 1 is never resurrected.
        local seed_recovered = false
        if nstrategy_before_circular == nil and tonumber(hrec.nstrategy) == 1
           and askey and hostn then
          local rec = state[askey] and state[askey][hostn]
          -- The in-RAM `state` can lag the truth: a pin written AFTER load_state
          -- ran, or arriving inside the reconcile debounce window, is on DISK but
          -- not yet in `state`. Read disk DIRECTLY (only in this rare recovery
          -- path — a fresh record that circular defaulted to 1) so the pin is
          -- honored before the default-1 persist below can clobber it. Same
          -- merged primary+fallback view load_state/reconcile use.
          if not (rec and tonumber(rec.strategy)) then
            local disk = {}
            if can_read_file(STATE_FILE_PRIMARY) then merge_state_file_into(STATE_FILE_PRIMARY, disk) end
            if can_read_file(STATE_FILE_FALLBACK) then merge_state_file_into(STATE_FILE_FALLBACK, disk) end
            rec = disk[askey] and disk[askey][hostn]
          end
          if rec and tonumber(rec.strategy) and tonumber(rec.strategy) ~= 1 then
            hrec.nstrategy = tonumber(rec.strategy)
            seed_recovered = true
          end
        end

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

        -- Rotation belongs exclusively to circular. Persistence never rolls
        -- back a decision based on unrelated/recent successful connections.

        -- (Freeze enforcement moved to the pre-circular FREEZE CLAMP at the top of
        -- this wrapper: hrec.final makes the engine itself refuse to rotate a frozen
        -- host — instead of this post-hoc force-back that only masked the display
        -- while the rotated strategy already executed on the wire. The persisted
        -- mode="frozen" column still survives restarts/reboot/auto-update.)

        -- Persist the (possibly reverted) strategy. Confirmed success OR the
        -- outgoing-initial fallback triggers a save; server-active never pins.
        if (success_event or outgoing_initial or seed_recovered) and not server_active_event then
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
  _reset = function() if type(timer_del) == "function" then timer_del("z2k_state_flush") end; flush_pending = false; loaded = false; state = {}; last_write = 0; last_written = {}; last_reconcile = 0 end,
}
