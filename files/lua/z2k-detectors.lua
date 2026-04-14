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
