-- z2k-detectors.lua
--
-- Custom nfqws2 failure/success detectors used by z2k circular rotators.
-- Loaded via --lua-init=@... BEFORE z2k-autocircular.lua so the detector
-- functions exist by name when the rotator resolves them via
-- circular:failure_detector=z2k_tls_stalled / success_detector=z2k_success_no_reset.
--
-- Previously lived inline in z2k-autocircular.lua. Split out in Phase 4 of
-- the z2k-enhanced roadmap so detector logic can be iterated on without
-- touching the much larger rotator/state-persistence file.
--
-- Dependencies (must be loaded earlier in the --lua-init chain):
--   zapret-lib.lua     — basic types, deepcopy, etc.
--   zapret-antidpi.lua — http_dissect_reply, array_field_search, is_dpi_redirect
--   zapret-auto.lua    — standard_failure_detector, standard_success_detector
--
-- Functions exported to the global namespace (called by nfqws2 via name):
--   z2k_tls_alert_fatal   — TLS fatal alert / HTTP DPI redirect / block page
--   z2k_tls_stalled       — everything above + per-host TLS handshake stall
--   z2k_success_no_reset  — success without resetting host failure counters
--
-- Functions kept file-local (used only by other functions in this file):
--   z2k_http_block_reply     — keyword-based block page detection
--   z2k_http_dpi_redirect    — SLD-based DPI redirect detection

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
-- See full rationale + design notes below next to the function body.
local Z2K_TLS_STALLED_SEC = 10
local z2k_tls_stalled_host_ts = {}
local z2k_tls_stalled_insert_counter = 0

-- Bounded LRU policy for per-host detector state.
--
-- Why: both z2k_tls_stalled_host_ts and z2k_mid_stream_state are module-
-- globals that accumulate one entry per unique SNI seen on the `rkn_tcp`
-- profile (via failure_detector=z2k_mid_stream_stall). On Russian routers
-- with 500 MB RAM and a CDN-heavy browsing pattern the unique-SNI set can
-- grow into tens of thousands of entries over days of uptime, which
-- triggered repeat OOM-kills of nfqws2 (confirmed in dmesg on Mark's
-- test router: anon-rss 78 MB and 146 MB kills).
--
-- Strategy: cap each map at Z2K_DETECTOR_MAP_MAX entries; when an insert
-- pushes the size past the cap, drop the oldest EVICT_BATCH entries by
-- timestamp. Check is amortised via a per-map counter so the O(n) scan
-- fires only once every EVICT_INTERVAL inserts, not on every packet.
--
-- Cap scales with hardware class via Z2K_DETECTOR_CAP env (set by
-- S99zapret2 from /proc/meminfo). Falls back to 512 when env is absent
-- (hand-run nfqws2 for debugging). Evict batch is 1/4 of the cap —
-- drops 25% of entries on overflow, which trades some detector memory
-- on rarely-visited hosts for a bounded working set without thrashing.
-- Eviction check amortised every 1/8 of cap inserts so the O(n) sweep
-- does not fire on every packet.
local Z2K_DETECTOR_MAP_MAX = tonumber(os.getenv("Z2K_DETECTOR_CAP")) or 512
if Z2K_DETECTOR_MAP_MAX < 64 then Z2K_DETECTOR_MAP_MAX = 64 end
if Z2K_DETECTOR_MAP_MAX > 2048 then Z2K_DETECTOR_MAP_MAX = 2048 end
local Z2K_DETECTOR_EVICT_BATCH = math.floor(Z2K_DETECTOR_MAP_MAX / 4)
local Z2K_DETECTOR_EVICT_INTERVAL = math.floor(Z2K_DETECTOR_MAP_MAX / 8)
if Z2K_DETECTOR_EVICT_INTERVAL < 16 then Z2K_DETECTOR_EVICT_INTERVAL = 16 end

local function z2k_detector_evict_oldest(map, batch, ts_of)
  local entries = {}
  local i = 0
  for k, v in pairs(map) do
    i = i + 1
    entries[i] = { k = k, ts = ts_of(v) or 0 }
  end
  if i <= batch then return end
  table.sort(entries, function(a, b) return a.ts < b.ts end)
  for j = 1, batch do
    map[entries[j].k] = nil
  end
end

local function z2k_tls_stalled_ts_of(v)
  return tonumber(v) or 0
end

local function z2k_tls_stalled_maybe_evict()
  z2k_tls_stalled_insert_counter = z2k_tls_stalled_insert_counter + 1
  if z2k_tls_stalled_insert_counter < Z2K_DETECTOR_EVICT_INTERVAL then return end
  z2k_tls_stalled_insert_counter = 0

  local n = 0
  for _ in pairs(z2k_tls_stalled_host_ts) do n = n + 1 end
  if n <= Z2K_DETECTOR_MAP_MAX then return end
  z2k_detector_evict_oldest(z2k_tls_stalled_host_ts, Z2K_DETECTOR_EVICT_BATCH, z2k_tls_stalled_ts_of)
end

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
      z2k_tls_stalled_host_ts[host] = now
      z2k_tls_stalled_maybe_evict()
      if elapsed >= Z2K_TLS_STALLED_SEC then
        if type(DLOG) == "function" then
          DLOG("z2k_tls_stalled: host=" .. host .. " prev ClientHello " .. elapsed .. "s ago with no ServerHello — counting as fail")
        end
        return true
      end
      -- Too early: timestamp already bumped above
      return false
    end
    -- First attempt for this host: just record
    z2k_tls_stalled_host_ts[host] = now
    z2k_tls_stalled_maybe_evict()
    return false
  end

  return false
end

-- Mid-stream stall detector — superset of z2k_tls_stalled.
--
-- Catches the class of failure where TLS handshake completes cleanly,
-- the server sends some initial data, then the data stream halts mid-
-- transfer and never resumes. Pattern observed in the field on
-- Ростелеком against *.cloudflare.com: first ~10-14KB burst arrives
-- normally, then all subsequent packets are silently dropped upstream
-- (no RST, no TLS alert, no FIN). The user's curl / browser waits on
-- TCP read until the client-side timeout fires.
--
-- Why z2k_tls_stalled and the other detectors miss this class:
-- - standard_failure_detector counts retransmits with payload > 0,
--   but there's nothing to retransmit — server-side ACKs progressed
--   normally, then server just stopped sending.
-- - standard_success_detector with inseq=4K fires as soon as ~4KB
--   incoming sequence accumulates, which happens well before the
--   ~10-14KB stall. Once success is recorded, the flow is pinned to
--   the current strategy and further events are ignored.
-- - z2k_tls_stalled only activates when NO ServerHello has arrived
--   yet; it exits early once SH is seen.
--
-- Design: process-global `host → state` map, same persistence style
-- as z2k_tls_stalled. For each host we track `last_in_ts` — the
-- timestamp of the most recent incoming packet that carried a non-
-- empty payload. When we see a new outgoing ClientHello for that
-- same host, we compare `now` to the previous `last_in_ts`. If the
-- gap is ≥ Z2K_MID_STREAM_STALL_SEC, that means the previous flow
-- received some data but then went silent for long enough that the
-- user (or their browser) gave up and started a fresh connection.
-- That's our stall signature.
--
-- Failure signal kicks in from the SECOND connection attempt onwards
-- for a given host — identical flavor to z2k_tls_stalled's logic,
-- since the first attempt has no prior state to compare against.
-- Combined with the rotator's fails=3 it takes ~3 reload cycles
-- (≈30-60 seconds of real-user retrying) before circular rotates.
--
-- Known limitations / false positive sources:
--   - A user who opens a page, reads it for >15s, and reloads will
--     trip this detector even if the original flow completed cleanly.
--     With fails=3 this means three such reads-and-reloads in a row
--     to the same host before rotation fires. Rare in normal use but
--     possible for "reference pages" that people read slowly.
--   - We do NOT inspect TCP FIN flags to distinguish "flow closed
--     cleanly" from "flow stalled". Pure time-based heuristic.
--   - Hosts visited only once never trigger this detector. That's
--     correct for rotation (no repeat pattern to learn from) but
--     also means one-shot failures are not caught here.
--
-- Active-retry gating (revised 2026-04-18).
--
-- The raw "previous flow got some data, then silence >= N s before the
-- next CH" heuristic false-positives heavily on normal browsing: a user
-- reads a page for 40 s and clicks a link, and the detector counts the
-- idle gap as a stall — even though the previous flow had completed
-- cleanly. Over fails=3 these innocent idle events silently rotate away
-- from a known-working strategy, which users experienced as "долго
-- подбирает стратегии / само не ротируется".
--
-- Refinement: only fire when the user is ACTIVELY RETRYING this host.
-- Signal: the gap between consecutive ClientHellos to the same host is
-- short (≤ Z2K_MID_STREAM_RETRY_WINDOW). Pattern matches "page doesn't
-- load, user hits reload" — which is what true Rostelecom mid-stream
-- stalls produce. Pattern does NOT match "user reads page, navigates
-- somewhere else on the site an minute later" — which is the false
-- positive we were eating.
--
-- Added state field `last_ch_ts`. Two numeric fields × ≤512 hosts =
-- still bounded at well under 100 KB.
--
-- Z2K_MID_STREAM_STALL_SEC reverted to 15 s. With the active-retry
-- gate we no longer need the 30 s buffer, and 15 s catches genuine
-- CF post-handshake stalls (~10-14 KB burst → silence) within one
-- retry cycle instead of two.
local Z2K_MID_STREAM_STALL_SEC = 15
local Z2K_MID_STREAM_RETRY_WINDOW = 60
local z2k_mid_stream_state = {}
local z2k_mid_stream_insert_counter = 0

local function z2k_mid_stream_ts_of(v)
  if type(v) ~= "table" then return 0 end
  -- Evict by whichever timestamp is newer — keeps the "most recent
  -- interaction with this host" entries alive through LRU sweeps.
  local a = tonumber(v.last_in_ts) or 0
  local b = tonumber(v.last_ch_ts) or 0
  return (a > b) and a or b
end

local function z2k_mid_stream_maybe_evict()
  z2k_mid_stream_insert_counter = z2k_mid_stream_insert_counter + 1
  if z2k_mid_stream_insert_counter < Z2K_DETECTOR_EVICT_INTERVAL then return end
  z2k_mid_stream_insert_counter = 0

  local n = 0
  for _ in pairs(z2k_mid_stream_state) do n = n + 1 end
  if n <= Z2K_DETECTOR_MAP_MAX then return end
  z2k_detector_evict_oldest(z2k_mid_stream_state, Z2K_DETECTOR_EVICT_BATCH, z2k_mid_stream_ts_of)
end

function z2k_mid_stream_stall(desync, crec)
  -- Inherit everything z2k_tls_stalled catches (which in turn inherits
  -- z2k_tls_alert_fatal → standard_failure_detector). Strict superset.
  if type(z2k_tls_stalled) == "function" then
    local ok, res = pcall(z2k_tls_stalled, desync, crec)
    if ok and res then return true end
  end

  if not desync then return false end
  local host = desync.track and desync.track.hostname
  if not host or host == "" then return false end
  local now = os.time and os.time() or 0
  if now == 0 then return false end

  -- Incoming packet with non-empty payload → this host's flow is
  -- actively receiving data. Remember the timestamp.
  if not desync.outgoing then
    local dis = desync.dis
    if dis and type(dis.payload) == "string" and #dis.payload > 0 then
      local st = z2k_mid_stream_state[host]
      if not st then
        st = { last_in_ts = now, last_ch_ts = 0 }
        z2k_mid_stream_state[host] = st
        z2k_mid_stream_maybe_evict()
      else
        st.last_in_ts = now
      end
    end
    return false
  end

  -- Outgoing ClientHello → check whether the user is actively retrying
  -- this host and whether the previous flow stalled mid-stream.
  if desync.outgoing and desync.l7payload == "tls_client_hello" then
    local st = z2k_mid_stream_state[host]
    if not st then
      -- First CH ever for this host: just record, no signal yet.
      z2k_mid_stream_state[host] = { last_in_ts = 0, last_ch_ts = now }
      z2k_mid_stream_maybe_evict()
      return false
    end

    local prev_ch_ts = tonumber(st.last_ch_ts) or 0
    local ch_gap = now - prev_ch_ts
    st.last_ch_ts = now

    -- Gate: only fire if user is ACTIVELY retrying (second CH within
    -- the retry window). A CH after a long idle gap is a fresh visit,
    -- not a retry — don't count a stale idle gap as a stall signal.
    if prev_ch_ts == 0 or ch_gap > Z2K_MID_STREAM_RETRY_WINDOW then
      return false
    end

    -- User is retrying. Check the mid-stream stall condition.
    if st.last_in_ts and st.last_in_ts > 0 then
      local since_last_in = now - st.last_in_ts
      if since_last_in >= Z2K_MID_STREAM_STALL_SEC then
        if type(DLOG) == "function" then
          DLOG("z2k_mid_stream_stall: host=" .. host ..
               " active retry (ch_gap=" .. ch_gap ..
               "s) prev flow data " .. since_last_in ..
               "s ago — counting as mid-stream stall fail")
        end
        -- Drop the record entirely rather than keep a stale stub —
        -- the next fresh ClientHello for this host starts clean and
        -- the map size stays bounded between evictions.
        z2k_mid_stream_state[host] = nil
        return true
      end
    end
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
