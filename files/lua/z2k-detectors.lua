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
--   z2k_tls_alert_fatal              — TLS fatal alert / HTTP classifier
--                                       (3-state) / TLS handshake stall chain
--   z2k_tls_stalled                  — extends z2k_tls_alert_fatal with
--                                       per-host CH-without-SH stall window
--   z2k_mid_stream_stall             — extends z2k_tls_stalled with post-
--                                       handshake mid-stream stall (active
--                                       retry within 60s window)
--   z2k_success_no_reset             — HTTP-neutral-aware success without
--                                       resetting host failure counters
--                                       (used by yt_tcp profile)
--   z2k_http_success_positive_only   — HTTP-aware success_detector: only
--                                       2xx/304/same-SLD-3xx fire success;
--                                       neutral / hard_fail mark crec
--                                       (rkn_tcp / gv_tcp / http_rkn)
--   z2k_classify_http_reply          — shared HTTP reply classifier returning
--                                       positive | neutral | hard_fail | nil
--                                       + sanitized reason. Single source of
--                                       truth for marker lists, used from
--                                       autocircular's positive-response
--                                       check, the failure_detector chain,
--                                       and both success_detectors above.
--
-- Functions kept file-local (used only by other functions in this file):
--   z2k_http_classifier_check  — failure-detector wrapper around
--                                 z2k_classify_http_reply that stamps
--                                 crec.z2k_neutral_observed on neutral.

-- ---------------------------------------------------------------------------
-- Shared marker lists (single source of truth for HTTP block-page detection)
-- ---------------------------------------------------------------------------
--
-- Body markers: substrings checked against lowercased response body.
-- These are RU-DPI specific; "blackhole" is included because it appears
-- both as a domain name (blackhole.svyaztelecom.ru) and in some block-page
-- HTML. Generic words like "forbidden"/"warning"/"restrict" are NOT in
-- the body list because they appear on legitimate 4xx pages too.
local Z2K_HTTP_BLOCK_BODY_MARKERS = {
  "rkn", "lawfilter", "zapret", "eais", "blocked-by", "vigruzki", "blackhole",
}

-- Host-prefix markers for cross-SLD redirect detection. Operator block
-- pages commonly live on subdomains like warn.beeline.ru, deny.megafon.ru.
-- These prefixes (with trailing dot — host-anchored) catch operator
-- redirect targets without firing on legitimate URLs containing the
-- bare word in path/query.
local Z2K_HTTP_BLOCK_HOST_PREFIXES = {
  "warn.", "deny.", "restrict.", "block.", "blocked.", "blackhole.",
}

-- Sanitize a reason_detail string for safe inclusion in debug.log lines.
-- Keep ASCII alphanumeric + dot/dash/equals/colon/underscore; replace
-- everything else (CRLF, spaces, tabs, non-ASCII, raw URL chars) with
-- underscore. Cap length at 64 chars to avoid log bloat. This prevents
-- log injection from attacker-controlled Location URLs / response bodies.
local function z2k_sanitize_reason(s)
  if type(s) ~= "string" then return "" end
  if #s > 64 then s = s:sub(1, 64) end
  return (s:gsub("[^A-Za-z0-9._:=-]", "_"))
end

local function z2k_find_body_marker(payload_lower)
  for _, m in ipairs(Z2K_HTTP_BLOCK_BODY_MARKERS) do
    if payload_lower:find(m, 1, true) then return m end
  end
  return nil
end

local function z2k_find_host_marker(host_lower)
  -- Substring markers (e.g. "lawfilter" matches lawfilter.ertelecom.ru
  -- AND blackhole-substring matches blackhole.svyaztelecom.ru).
  for _, m in ipairs(Z2K_HTTP_BLOCK_BODY_MARKERS) do
    if host_lower:find(m, 1, true) then return m end
  end
  -- Host-prefix markers (warn.beeline.ru, deny.megafon.ru, etc).
  for _, p in ipairs(Z2K_HTTP_BLOCK_HOST_PREFIXES) do
    if host_lower:sub(1, #p) == p then return "prefix:" .. p end
  end
  return nil
end

-- Extract host from Location header value, lowercased. Handles three
-- forms:
--   1. absolute URL    "https://example.com/path"  → use dissect_url
--   2. scheme-relative "//example.com/path"        → manual parse
--                       (dissect_url misses these — its regex is
--                       `[a-z]+://` which doesn't match `//host`)
--   3. path-only       "/some/path"                → returns nil
--                       (no host change, same-origin redirect)
-- Strip `:port` suffix from a hostname (mirrors dissect_url's domain
-- extraction at zapret-lib.lua:1816-1821). Apply before SLD comparison
-- so example.com:443 == example.com.
local function z2k_strip_port(host)
  if type(host) ~= "string" then return host end
  return (host:gsub(":%d+$", ""))
end

local function z2k_extract_loc_host(location)
  if type(location) ~= "string" or location == "" then return nil end
  if location:sub(1, 2) == "//" then
    local host = location:match("^//([^/?#]+)")
    if not host then return nil end
    return z2k_strip_port(host):lower()
  end
  if type(dissect_url) == "function" then
    local ds = dissect_url(location)
    if ds and ds.domain then return ds.domain:lower() end
  end
  return nil
end

-- z2k_classify_http_reply(desync) — shared HTTP-reply classifier.
--
-- Returns:
--   "positive", nil                  — real-success response (2xx, 304,
--                                       same-SLD 3xx upgrade)
--   "neutral",  reason_string        — suspicious/ambiguous response
--                                       (4xx/5xx no marker, cross-SLD 3xx
--                                       no marker, unparseable redirect)
--   "hard_fail", reason_string       — confirmed block (4xx/5xx with body
--                                       marker; cross-SLD 3xx with host
--                                       marker or block-prefix)
--   nil, nil                         — not applicable (not http_reply,
--                                       no payload, no parseable code)
--
-- Used in commit 3 by z2k-autocircular.lua's has_positive_incoming_response()
-- (reads only the "positive" return). Will be used in commit 4 by a
-- rewritten z2k_http_block_reply path AND a new
-- z2k_http_success_positive_only success_detector.
function z2k_classify_http_reply(desync)
  if not desync or desync.outgoing then return nil, nil end
  if desync.l7payload ~= "http_reply" then return nil, nil end
  local payload = desync.dis and desync.dis.payload
  if type(payload) ~= "string" then return nil, nil end

  local code_s = payload:match("^HTTP/%d%.%d%s+([0-9][0-9][0-9])")
  local code = tonumber(code_s)
  if not code then return nil, nil end

  -- 2xx and 304 = real positive
  if code >= 200 and code < 300 then return "positive", nil end
  if code == 304 then return "positive", nil end

  -- 4xx / 5xx — body-marker check.
  --
  -- IMPORTANT: scan the BODY only, not headers. Per RFC 7725 a legitimate
  -- 451 from origin/CDN may carry `Link: <authority>; rel="blocked-by"`
  -- header — that header value contains the substring "blocked-by" which
  -- is in our body-marker list. v3.6 explicitly defers Link rel="blocked-by"
  -- parsing as ambiguous (could be DPI or origin compliance), so scanning
  -- headers would produce a hard-fail false positive on every RFC-compliant
  -- region-locked 451.
  if code >= 400 and code < 600 then
    local body = ""
    if type(http_dissect_reply) == "function" then
      local hdis = http_dissect_reply(payload)
      if hdis and hdis.body then body = hdis.body end
    end
    -- Fallback: separate body manually at first blank-line if dissector
    -- is unavailable / returned no body field.
    if body == "" then
      local sep = payload:find("\r\n\r\n", 1, true)
      if sep then body = payload:sub(sep + 4) end
    end
    if body == "" then
      return "neutral", "http_4xx_no_body:code=" .. tostring(code)
    end
    local low = body:lower()
    local marker = z2k_find_body_marker(low)
    if marker then
      return "hard_fail", "http_4xx_marker:" .. z2k_sanitize_reason(marker)
    end
    return "neutral", "http_4xx_no_marker:code=" .. tostring(code)
  end

  -- 3xx — Location parse + cross-SLD check
  if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
    if type(http_dissect_reply) ~= "function" or
       type(array_field_search) ~= "function" then
      return "neutral", "http_redirect_no_dissector"
    end
    local hdis = http_dissect_reply(payload)
    if not hdis then return "neutral", "http_redirect_unparseable" end
    local idx = array_field_search(hdis.headers, "header_low", "location")
    if not idx then return "neutral", "http_redirect_no_location" end
    local loc_host = z2k_extract_loc_host(hdis.headers[idx].value)
    if not loc_host then
      -- Path-only or unparseable Location — same-origin redirect, treat
      -- as positive (the request handshake succeeded; redirect is just
      -- application-level navigation).
      return "positive", nil
    end
    local req_host = desync.track and desync.track.hostname
    if not req_host then return "neutral", "http_redirect_no_req_host" end
    -- Defensive port-strip: HTTP Host header may carry port even though
    -- nfqws2 dissector usually normalises it. Cheap to apply, prevents
    -- a same-origin redirect to host:port being misclassified cross-SLD.
    local req_lower = z2k_strip_port(req_host:lower())
    local req_sld = type(dissect_nld) == "function" and dissect_nld(req_lower, 2) or req_lower
    local loc_sld = type(dissect_nld) == "function" and dissect_nld(loc_host, 2) or loc_host
    if req_sld and loc_sld and req_sld == loc_sld then
      -- Same-SLD redirect = legit (HTTP→HTTPS upgrade, vanity URL,
      -- internal app routing). Strategy did its job — handshake worked.
      return "positive", nil
    end
    -- Cross-SLD — check if loc_host carries a block marker
    local marker = z2k_find_host_marker(loc_host)
    if marker then
      return "hard_fail", "http_redirect_marker:" .. z2k_sanitize_reason(marker)
    end
    return "neutral", "http_redirect_cross_sld_no_marker"
  end

  -- 1xx informational, 3xx other (300/305/306/...), unknown — neutral.
  return "neutral", "http_other_code:code=" .. tostring(code)
end

-- Single HTTP-reply check using the z2k_classify_http_reply helper.
-- Replaces the legacy z2k_http_block_reply (unconditional 403/451 hard
-- fail + raw-payload keyword scan) and z2k_http_dpi_redirect (raw
-- SLD-mismatch via is_dpi_redirect with no marker filter). Both old
-- paths produced false positives the v3.6 plan was specifically
-- designed to fix (legit CF/WAF 403, oauth/shortlink redirects, RFC
-- 7725 origin 451 with Link rel="blocked-by").
--
-- Returns true if classifier returns "hard_fail" (confirmed block).
-- For "neutral" — returns false but stamps crec.z2k_neutral_observed
-- and crec.z2k_reason; autocircular's commit-3 wiring sees this and
-- blocks successful_state / response_state, preventing the strategy
-- from being pinned. For "positive" / nil — returns false, no marks.
local function z2k_http_classifier_check(desync, crec)
  if type(z2k_classify_http_reply) ~= "function" then
    return false
  end
  local class, reason = z2k_classify_http_reply(desync)
  if class == "hard_fail" then
    if crec then crec.z2k_reason = reason end
    return true
  end
  if class == "neutral" then
    if crec then
      crec.z2k_neutral_observed = true
      crec.z2k_reason = reason
    end
  end
  return false
end

function z2k_tls_alert_fatal(desync, crec)
  z2k_detector_log_init_once()
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

  -- HTTP reply classification: 4xx/5xx + body markers, 3xx + cross-SLD
  -- with host-marker/prefix → hard fail. Plain 4xx without markers /
  -- cross-SLD without markers → neutral (stamps crec.z2k_neutral_observed
  -- so autocircular's commit-3 gates block the false-pin).
  -- Replaces the legacy z2k_http_dpi_redirect + z2k_http_block_reply
  -- pair with a single classifier-driven check.
  if z2k_http_classifier_check(desync, crec) then
    return true
  end
  local payload = dis and dis.payload

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
-- Upper bound on how long ago a previous ClientHello can have been seen
-- and still count as evidence of stall. Beyond this we treat the new CH
-- as a fresh visit and refresh the timestamp without firing fail.
--
-- Why: without an upper bound a CH from yesterday (or even hours ago)
-- against a host that's now LRU-resident in the state map would trigger
-- a fail signal on the next visit. That's a false positive — the user
-- isn't "retrying after stall", they're just visiting the site again.
--
-- 120s chosen to align with the silent retry window used elsewhere in
-- the rotator (z2k-autocircular's retry observation window). Anything
-- past that, the user has clearly moved on / come back, not retrying.
local Z2K_TLS_STALLED_MAX_SEC = 120
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

-- One-shot startup line so a misconfigured Z2K_DETECTOR_CAP env var
-- (e.g. S99zapret2 PATH glitch leaving the var unset) is visible in
-- the regular nfqws2 log.
--
-- Deferred to first packet because at module-load time DLOG is not yet
-- defined — z2k-modern-core.lua, which sets DLOG to a real function (or
-- the noop fallback), loads AFTER this file in the --lua-init chain.
-- A direct call here would always hit a nil DLOG. The detectors run on
-- every passing TLS handshake, so the message lands in the log within
-- seconds of nfqws2 startup.
local _z2k_detector_init_logged = false
-- Defined as a top-level (non-local) function on purpose: its only call
-- site is inside z2k_tls_alert_fatal, which is parsed BEFORE this block,
-- so a `local function` here would be invisible to the call site at
-- definition time. Globals are resolved at call time, so this works
-- regardless of source order. Listed in .luacheckrc globals for the
-- linter.
function z2k_detector_log_init_once()
  if _z2k_detector_init_logged then return end
  _z2k_detector_init_logged = true
  if type(DLOG) ~= "function" then return end
  DLOG(string.format(
    "z2k-detectors: cap=%d evict_batch=%d evict_interval=%d (env=%s)",
    Z2K_DETECTOR_MAP_MAX, Z2K_DETECTOR_EVICT_BATCH,
    Z2K_DETECTOR_EVICT_INTERVAL,
    tostring(os.getenv("Z2K_DETECTOR_CAP") or "<unset>")))
end

-- Detector state is keyed by HOST only. This is intentional:
-- the detection target is "the destination host is unreachable",
-- so any flow's CH-without-SH or mid-stream-stall is evidence about
-- the host, not just that flow. A short-lived B5 fix (2026-04-28)
-- switched to host:src_port keying to avoid imagined "trampling",
-- but that broke single-device detection: each new TCP connect has
-- a fresh src_port, so prev_ch_ts was always nil, so the stall
-- detector never fired. Reverted same day after Mark hit it on
-- Android (autocircular wouldn't engage rotation; only by playing
-- YT on a second device with RST/alert detection — host-keyed via
-- standard_failure_detector — the rotator would learn a working
-- strategy and pin it for everyone).
local function z2k_flow_key(desync, host)
  return host
end

-- Separate key generator used by z2k_mid_stream_stall only.
--
-- Mid-stream byte-window detection benefits from cross-subdomain
-- aggregation: a stall on www.cloudflare.com is evidence about the
-- whole cloudflare.com SLD, so progress/silence observed on one
-- subdomain should count toward retries on a sibling. We use the
-- upstream `standard_hostkey(desync)` (zapret-auto.lua:9) which
-- already respects the active circular's nld=2 setting, IP-fallback
-- and reqhost — keeping z2k key semantics in sync with how the
-- rotator buckets hosts (autostate / rotation key).
--
-- z2k_tls_stalled keeps using z2k_flow_key (raw host) above. The
-- handshake-stall detector triggers off ClientHello timing on the
-- same flow, where SLD-level aggregation would produce false
-- positives across legitimate parallel subdomain visits and was
-- never the design intent.
local function z2k_mid_stream_flow_key(desync, host)
  if type(standard_hostkey) == "function" then
    local ok, key = pcall(standard_hostkey, desync)
    if ok and type(key) == "string" and key ~= "" then
      return key
    end
  end
  return host
end

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
  local key = z2k_flow_key(desync, host)

  -- Incoming ServerHello: handshake progressing for this flow, clear tracking.
  -- Validate the record before clearing — TSPU may inject malformed
  -- TLS-shaped records to confuse detectors. We require a structurally
  -- plausible TLS record carrying a ServerHello handshake message:
  --
  --   byte 1     : TLS record content_type == 0x16 (handshake)
  --                (RFC 5246 §6.2.1 / RFC 8446 §5.1)
  --   bytes 2-3  : record version major=0x03, minor in {0x01..0x04}
  --                (TLS 1.0..1.3 — TLS 1.3 ClientHello uses 0x0303
  --                on the wire per RFC 8446 §5.1)
  --   bytes 4-5  : record length, big-endian (must be ≥ inner length)
  --   byte 6     : handshake_type == 0x02 (ServerHello — RFC 8446 §4)
  --   bytes 7-9  : handshake length, big-endian
  --
  -- Size floor lowered from 100 → 60 bytes per RFC 8446 §4.1.3 — the
  -- theoretical SH minimum is ~51 bytes; commonly observed in the wild
  -- 90-130 bytes for major CDNs but smaller is RFC-legal. <60 with
  -- correct fields is still extremely unusual and we treat it as
  -- structurally suspicious.
  --
  -- We do NOT additionally require ChangeCipherSpec or specific
  -- extensions: TLS 1.3 makes CCS optional (compatibility mode only —
  -- RFC 8446 Appendix D.4), and embedded TLS stacks may omit it.
  if not desync.outgoing and desync.l7payload == "tls_server_hello" then
    local p = desync.dis and desync.dis.payload
    if type(p) == "string" and #p >= 60
       and p:byte(1) == 0x16
       and p:byte(2) == 0x03
       and p:byte(3) >= 0x01 and p:byte(3) <= 0x04
       and p:byte(6) == 0x02 then
      -- record_length and handshake_length sanity: both must point
      -- inside the captured payload; any mismatch suggests truncation
      -- or framing fakery.
      local rec_len = p:byte(4) * 256 + p:byte(5)
      local hs_len  = p:byte(8) * 256 + p:byte(9)
      if rec_len + 5 <= #p and hs_len + 4 <= rec_len then
        z2k_tls_stalled_host_ts[key] = nil
      end
    end
    return false
  end

  -- Outgoing ClientHello: check previous CH timestamp for this flow.
  --
  -- Fire fail only when elapsed is in the [Z2K_TLS_STALLED_SEC,
  -- Z2K_TLS_STALLED_MAX_SEC] window. Below the lower bound the retry
  -- is too quick to be evidence of stall. Above the upper bound the
  -- previous CH is too stale to attribute to "active retry" — treat
  -- as fresh visit (timestamp gets refreshed regardless via the
  -- assignment below).
  if desync.outgoing and desync.l7payload == "tls_client_hello" then
    local prev = z2k_tls_stalled_host_ts[key]
    if prev then
      local elapsed = now - prev
      z2k_tls_stalled_host_ts[key] = now
      z2k_tls_stalled_maybe_evict()
      if elapsed >= Z2K_TLS_STALLED_SEC and elapsed <= Z2K_TLS_STALLED_MAX_SEC then
        if type(DLOG) == "function" then
          DLOG("z2k_tls_stalled: host=" .. host .. " prev ClientHello " .. elapsed .. "s ago with no ServerHello — counting as fail")
        end
        return true
      end
      -- Either too early (active retry just happened) or too late
      -- (stale state from earlier visit). Timestamp already bumped above.
      return false
    end
    -- First attempt for this flow: just record
    z2k_tls_stalled_host_ts[key] = now
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
-- Design (v3, 2026-05-01).
--
-- v1 (revert fdc7145) used `last_in_ts` (any incoming payload) + raw
-- elapsed gate; false-positived heavily on legitimate browse-and-
-- reload. v2 keyed on observed byte progress but stored seq/FIN/RST
-- per SLD, which is wrong: TCP sequence space is per-connection and
-- parallel flows under the same nld=2 key would corrupt each other's
-- byte tracking and cross-clear stall candidates.
--
-- v3 splits the state into two layers so each layer's lifetime
-- matches what it is actually scoped to:
--
--   Per-flow (stored in `desync.track.lua_state.mid_stream`) — TCP
--   sequence space and FIN/RST closure are properties of one
--   connection; nfqws2 already gives us a flow-scoped lua_state
--   table that lives across packets of one flow:
--       base_seq         — TCP ISN of the first incoming data packet
--       max_seq          — largest cumulative bytes received
--       last_progress_ts — when max_seq last advanced
--       fin_seen         — flow closed via FIN or RST
--       flow_id          — module-monotonic counter assigned at
--                          flow-state creation; uniquely identifies
--                          this flow's entry in the per-key
--                          candidates map. Counter (not table
--                          address) so a recycled Lua table can't
--                          alias a still-live candidate's owner.
--
--   Per-key (stored in module-global `z2k_mid_stream_state[key]`) —
--   "did SOME flow under this SLD recently exhibit a stall pattern,
--   and have we seen retry CHs":
--       candidates       — map flow_id -> {max_seq, last_progress_ts};
--                          one entry per flow currently in the stall
--                          window. Bounded by MAX_CANDIDATES (oldest
--                          last_progress_ts evicted on insert).
--                          Multi-entry instead of a single owned
--                          slot so parallel flows that interleave
--                          inside the byte window don't displace
--                          each other's evidence.
--       last_ch_ts       — last outgoing ClientHello on this key,
--                          for the active-retry gate
--
-- The mid-stream key uses standard_hostkey() (zapret-auto.lua:9),
-- which respects the active circular's nld=2 setting: a stall on
-- static.cloudflare.com counts toward retries on api.cloudflare.com.
-- z2k_tls_stalled keeps using z2k_flow_key (raw host) — handshake
-- detection has different aggregation needs.
--
-- Per-flow updates:
--   On every incoming packet: update flow_st seq/FIN. If the flow's
--   max_seq is in [LO, HI], publish/refresh THIS flow's entry in the
--   candidates map. If the flow crosses past HI, it's a success —
--   remove THIS flow's entry. FIN/RST removes THIS flow's entry too.
--   Parallel flows under the same key never mutate each other's
--   entries because the map is keyed by flow_id.
--
-- Fail criteria on outgoing ClientHello (the four-way AND, evaluated
-- against each candidate independently — the first that matches
-- fires):
--   1. candidate.max_seq is in the [LO, HI] window (CF stall byte
--      signature: handshake completed, some data flowed, stopped
--      before full asset transfer)
--   2. (now - candidate.last_progress_ts) >= SILENCE_SEC (the flow
--      really went silent — differentiates a genuine stall from a
--      parallel preconnect / HTTP/2 connection rotation)
--   3. (now - candidate.last_progress_ts) <= RETRY_MAX_SEC (the
--      stall snapshot is recent enough to attribute to user retry,
--      not stale state left from an earlier visit). Stale candidates
--      are pruned during the iteration.
--   4. (now - last_ch_ts) <= ACTIVE_RETRY_SEC (the user is actively
--      retrying — this is the second CH within the active-retry
--      window). Without this gate, a single legitimate navigation CH
--      after a small <18KB response that the keep-alive socket
--      didn't FIN within SILENCE_SEC would false-positive. When
--      ch_gap exceeds the gate, ALL candidates are cleared so a
--      rapid follow-up CH within 30s after this isolated one cannot
--      ride on stale evidence.
--
-- When a flow's max_seq crosses past HI: that flow is succeeding;
-- its entry is removed from candidates. The flow record itself
-- stays in lua_state so a later FIN can be observed correctly.

local Z2K_MID_STREAM_LO               = 8000
local Z2K_MID_STREAM_HI               = 26000
local Z2K_MID_STREAM_SILENCE_SEC      = 5
local Z2K_MID_STREAM_RETRY_MAX_SEC    = 120
local Z2K_MID_STREAM_ACTIVE_RETRY_SEC = 30
-- Cap on simultaneous in-window candidates per key. Typical browsers
-- open up to ~6 parallel TCP connections per host; 8 covers normal
-- parallel + small headroom. Eviction policy on overflow: oldest
-- last_progress_ts wins (likely already silent-stalled or replaced).
local Z2K_MID_STREAM_MAX_CANDIDATES   = 8
local z2k_mid_stream_state = {}
local z2k_mid_stream_insert_counter = 0
-- Module-monotonic counter for flow_id assignment. Lua doubles can
-- represent integers up to 2^53 exactly — at 1k flows/sec this is
-- ~285 millennia of unique IDs. We never reset it.
local z2k_mid_stream_flow_seq = 0

local function z2k_mid_stream_new_key_state()
  return {
    candidates = {},
    last_ch_ts = 0,
  }
end

local function z2k_mid_stream_new_flow_state()
  z2k_mid_stream_flow_seq = z2k_mid_stream_flow_seq + 1
  return {
    base_seq         = nil,
    max_seq          = 0,
    last_progress_ts = 0,
    fin_seen         = false,
    flow_id          = z2k_mid_stream_flow_seq,
  }
end

local function z2k_mid_stream_ts_of(v)
  if type(v) ~= "table" then return 0 end
  -- Evict by whichever timestamp is newer — keeps the "most recent
  -- interaction with this key" entries alive through LRU sweeps.
  local newest = tonumber(v.last_ch_ts) or 0
  local cands = v.candidates
  if type(cands) == "table" then
    for _, c in pairs(cands) do
      local t = (type(c) == "table" and tonumber(c.last_progress_ts)) or 0
      if t > newest then newest = t end
    end
  end
  return newest
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

-- Find the flow_id of the candidate with the oldest last_progress_ts,
-- used as the eviction victim when a new candidate would overflow
-- Z2K_MID_STREAM_MAX_CANDIDATES.
local function z2k_mid_stream_oldest_candidate_id(cands)
  local oldest_id, oldest_ts
  for fid, c in pairs(cands) do
    local ts = (type(c) == "table" and tonumber(c.last_progress_ts)) or 0
    if not oldest_ts or ts < oldest_ts then
      oldest_id, oldest_ts = fid, ts
    end
  end
  return oldest_id
end

-- Publish or refresh THIS flow's candidate entry. Bounded — when the
-- map already holds MAX_CANDIDATES entries owned by other flows, the
-- oldest one is evicted to make room.
local function z2k_mid_stream_publish_candidate(key_st, flow_st)
  local cands = key_st.candidates
  local existing = cands[flow_st.flow_id]
  if existing then
    existing.max_seq          = flow_st.max_seq
    existing.last_progress_ts = flow_st.last_progress_ts
    return
  end
  local count = 0
  for _ in pairs(cands) do count = count + 1 end
  if count >= Z2K_MID_STREAM_MAX_CANDIDATES then
    local victim = z2k_mid_stream_oldest_candidate_id(cands)
    if victim then cands[victim] = nil end
  end
  cands[flow_st.flow_id] = {
    max_seq          = flow_st.max_seq,
    last_progress_ts = flow_st.last_progress_ts,
  }
end

-- Clear all candidate entries for a key. Used when the active-retry
-- gate fails — none of the recorded stalls is actionable evidence
-- for the current CH event.
local function z2k_mid_stream_clear_all_candidates(cands)
  for fid in pairs(cands) do
    cands[fid] = nil
  end
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

  -- Per-flow byte tracking lives in lua_state. If nfqws2 hasn't
  -- populated it yet for this packet, we can't track this flow
  -- correctly — skip the byte-window logic.
  local lua_state = desync.track.lua_state
  if type(lua_state) ~= "table" then return false end

  local flow_st = lua_state.mid_stream
  if type(flow_st) ~= "table" then
    flow_st = z2k_mid_stream_new_flow_state()
    lua_state.mid_stream = flow_st
  end

  local key = z2k_mid_stream_flow_key(desync, host)
  local key_st = z2k_mid_stream_state[key]
  if not key_st then
    key_st = z2k_mid_stream_new_key_state()
    z2k_mid_stream_state[key] = key_st
    z2k_mid_stream_maybe_evict()
  end

  -- Incoming packet — update per-flow byte progress and FIN/RST.
  -- The candidates map is keyed by flow_id, so per-flow updates only
  -- touch THIS flow's entry; parallel flows under the same nld=2 key
  -- never displace each other.
  if not desync.outgoing then
    local dis = desync.dis
    if not dis or not dis.tcp then return false end

    local flags = tonumber(dis.tcp.th_flags) or 0
    local fin_bit = (TH_FIN and bitand(flags, TH_FIN)) or 0
    local rst_bit = (TH_RST and bitand(flags, TH_RST)) or 0
    if fin_bit ~= 0 or rst_bit ~= 0 then
      flow_st.fin_seen = true
      key_st.candidates[flow_st.flow_id] = nil
      return false
    end

    if type(dis.payload) ~= "string" or #dis.payload == 0 then
      return false
    end
    local seq = tonumber(dis.tcp.th_seq)
    if not seq then return false end

    if not flow_st.base_seq then flow_st.base_seq = seq end
    local rel = (seq - flow_st.base_seq) + #dis.payload
    if rel > flow_st.max_seq then
      flow_st.max_seq = rel
      flow_st.last_progress_ts = now
    end

    -- Past the stall threshold = this flow is delivering data
    -- successfully. Drop only THIS flow's entry — parallel flows
    -- still in the window keep their evidence.
    if flow_st.max_seq > Z2K_MID_STREAM_HI then
      key_st.candidates[flow_st.flow_id] = nil
      return false
    end

    -- In the stall byte window — publish/refresh THIS flow's entry.
    if flow_st.max_seq >= Z2K_MID_STREAM_LO then
      z2k_mid_stream_publish_candidate(key_st, flow_st)
    end
    return false
  end

  -- Outgoing ClientHello — scan candidates for a fire match. Active-
  -- retry gate runs first so a long-gap CH cannot ride on candidates
  -- accumulated from earlier sessions.
  --
  -- Candidate lifecycle on CH:
  --   * active-retry gate fails (ch_gap > ACTIVE_RETRY_SEC): drop ALL
  --     candidates; this CH is a fresh visit/navigation, not a retry
  --     of any prior stall, and a rapid follow-up CH within 30s
  --     mustn't fire on stale evidence.
  --   * stale-by-time (since_progress > RETRY_MAX_SEC): drop only
  --     that one candidate during the iteration.
  --   * fire path: consume the firing candidate so the same stall
  --     isn't double-counted on the next CH within the retry window.
  --   * silence too short / out-of-window: keep — the flow may still
  --     go silent and trip on the next CH inside the same window.
  if desync.outgoing and desync.l7payload == "tls_client_hello" then
    local prev_ch_ts = key_st.last_ch_ts
    key_st.last_ch_ts = now

    local cands = key_st.candidates
    if next(cands) == nil then return false end

    local ch_gap = (prev_ch_ts > 0) and (now - prev_ch_ts) or math.huge
    if ch_gap > Z2K_MID_STREAM_ACTIVE_RETRY_SEC then
      z2k_mid_stream_clear_all_candidates(cands)
      return false
    end

    local fire_fid, fire_cand, fire_silence
    for fid, cand in pairs(cands) do
      local since_progress = now - cand.last_progress_ts
      if since_progress > Z2K_MID_STREAM_RETRY_MAX_SEC then
        -- Stale: prune during iteration (Lua allows delete-during-
        -- iterate, just not insert).
        cands[fid] = nil
      elseif (not fire_fid)
             and cand.max_seq >= Z2K_MID_STREAM_LO
             and cand.max_seq <= Z2K_MID_STREAM_HI
             and since_progress >= Z2K_MID_STREAM_SILENCE_SEC then
        fire_fid     = fid
        fire_cand    = cand
        fire_silence = since_progress
      end
    end

    if not fire_fid then return false end

    if type(DLOG) == "function" then
      DLOG("z2k_mid_stream_stall: key=" .. key
           .. " host=" .. host
           .. " max_seq=" .. fire_cand.max_seq
           .. " silence=" .. fire_silence .. "s"
           .. " ch_gap=" .. ch_gap .. "s — counting as fail")
    end
    cands[fire_fid] = nil
    return true
  end

  return false
end

-- HTTP mid-stream stall detector (mirror z2k_mid_stream_stall на HTTP path).
--
-- Что ловит: handshake-фаза не релевантна для HTTP (нет TLS), но та же
-- pattern stall'а — сервер отдал ~14-30KB body, потом стрим тихо встаёт
-- без RST/FIN/alert. По треду ntc.party 22516 (#1, #3) реальный диапазон
-- HTTP stall'а 24-32 KB, чуть выше TLS-варианта.
--
-- Differences from z2k_mid_stream_stall (TLS):
--   * Gate signal: incoming `http_reply` (не tls_server_hello/handshake);
--     outgoing retry — `http_req` (не tls_client_hello).
--   * Constants: LO=14000 / HI=32000 (TLS было 8000/26000 — HTTP отдаёт
--     больше bytes в первой инициальной burst'е до stall'а).
--   * State scope: per-flow в `desync.track.lua_state.http_mid_stream`,
--     per-key в module-global `z2k_http_mid_stream_state`. Отдельные
--     карты от TLS чтобы parallel TLS+HTTP к тому же SLD не пересекались.
--   * Inherits z2k_tls_alert_fatal (общий fail signal — RST / TLS alert /
--     HTTP block-marker classifier).
--
-- Mid-stream key через standard_hostkey() (nld=2 aggregation), как у TLS.
-- Multi-candidate map per key (8 max), ownership via flow_id.

local Z2K_HTTP_MID_STREAM_LO               = 14000
local Z2K_HTTP_MID_STREAM_HI               = 32000
local Z2K_HTTP_MID_STREAM_SILENCE_SEC      = 5
local Z2K_HTTP_MID_STREAM_RETRY_MAX_SEC    = 120
local Z2K_HTTP_MID_STREAM_ACTIVE_RETRY_SEC = 30
local Z2K_HTTP_MID_STREAM_MAX_CANDIDATES   = 8
local z2k_http_mid_stream_state = {}
local z2k_http_mid_stream_insert_counter = 0
local z2k_http_mid_stream_flow_seq = 0

local function z2k_http_mid_stream_new_key_state()
  return {
    candidates = {},
    last_req_ts = 0,
  }
end

local function z2k_http_mid_stream_new_flow_state()
  z2k_http_mid_stream_flow_seq = z2k_http_mid_stream_flow_seq + 1
  return {
    base_seq         = nil,
    max_seq          = 0,
    last_progress_ts = 0,
    fin_seen         = false,
    flow_id          = z2k_http_mid_stream_flow_seq,
  }
end

local function z2k_http_mid_stream_ts_of(v)
  if type(v) ~= "table" then return 0 end
  local newest = tonumber(v.last_req_ts) or 0
  local cands = v.candidates
  if type(cands) == "table" then
    for _, c in pairs(cands) do
      local t = (type(c) == "table" and tonumber(c.last_progress_ts)) or 0
      if t > newest then newest = t end
    end
  end
  return newest
end

local function z2k_http_mid_stream_maybe_evict()
  z2k_http_mid_stream_insert_counter = z2k_http_mid_stream_insert_counter + 1
  if z2k_http_mid_stream_insert_counter < Z2K_DETECTOR_EVICT_INTERVAL then return end
  z2k_http_mid_stream_insert_counter = 0
  local n = 0
  for _ in pairs(z2k_http_mid_stream_state) do n = n + 1 end
  if n <= Z2K_DETECTOR_MAP_MAX then return end
  z2k_detector_evict_oldest(z2k_http_mid_stream_state, Z2K_DETECTOR_EVICT_BATCH, z2k_http_mid_stream_ts_of)
end

local function z2k_http_mid_stream_oldest_candidate_id(cands)
  local oldest_id, oldest_ts
  for fid, c in pairs(cands) do
    local ts = (type(c) == "table" and tonumber(c.last_progress_ts)) or 0
    if not oldest_ts or ts < oldest_ts then
      oldest_id, oldest_ts = fid, ts
    end
  end
  return oldest_id
end

local function z2k_http_mid_stream_publish_candidate(key_st, flow_st)
  local cands = key_st.candidates
  local existing = cands[flow_st.flow_id]
  if existing then
    existing.max_seq          = flow_st.max_seq
    existing.last_progress_ts = flow_st.last_progress_ts
    return
  end
  local count = 0
  for _ in pairs(cands) do count = count + 1 end
  if count >= Z2K_HTTP_MID_STREAM_MAX_CANDIDATES then
    local victim = z2k_http_mid_stream_oldest_candidate_id(cands)
    if victim then cands[victim] = nil end
  end
  cands[flow_st.flow_id] = {
    max_seq          = flow_st.max_seq,
    last_progress_ts = flow_st.last_progress_ts,
  }
end

local function z2k_http_mid_stream_clear_all_candidates(cands)
  for fid in pairs(cands) do
    cands[fid] = nil
  end
end

function z2k_http_mid_stream_stall(desync, crec)
  -- Inherit RST / TLS alert / HTTP block-marker fail signals.
  if type(z2k_tls_alert_fatal) == "function" then
    local ok, res = pcall(z2k_tls_alert_fatal, desync, crec)
    if ok and res then return true end
  end

  if not desync then return false end
  local host = desync.track and desync.track.hostname
  if not host or host == "" then return false end
  local now = os.time and os.time() or 0
  if now == 0 then return false end

  local lua_state = desync.track.lua_state
  if type(lua_state) ~= "table" then return false end

  local flow_st = lua_state.http_mid_stream
  if type(flow_st) ~= "table" then
    flow_st = z2k_http_mid_stream_new_flow_state()
    lua_state.http_mid_stream = flow_st
  end

  local key = z2k_mid_stream_flow_key(desync, host)
  local key_st = z2k_http_mid_stream_state[key]
  if not key_st then
    key_st = z2k_http_mid_stream_new_key_state()
    z2k_http_mid_stream_state[key] = key_st
    z2k_http_mid_stream_maybe_evict()
  end

  -- Incoming http_reply — track byte progress and FIN/RST.
  if not desync.outgoing and desync.l7payload == "http_reply" then
    local dis = desync.dis
    if not dis or not dis.tcp then return false end

    local flags = tonumber(dis.tcp.th_flags) or 0
    local fin_bit = (TH_FIN and bitand(flags, TH_FIN)) or 0
    local rst_bit = (TH_RST and bitand(flags, TH_RST)) or 0
    if fin_bit ~= 0 or rst_bit ~= 0 then
      flow_st.fin_seen = true
      key_st.candidates[flow_st.flow_id] = nil
      return false
    end

    if type(dis.payload) ~= "string" or #dis.payload == 0 then
      return false
    end
    local seq = tonumber(dis.tcp.th_seq)
    if not seq then return false end

    if not flow_st.base_seq then flow_st.base_seq = seq end
    local rel = (seq - flow_st.base_seq) + #dis.payload
    if rel > flow_st.max_seq then
      flow_st.max_seq = rel
      flow_st.last_progress_ts = now
    end

    if flow_st.max_seq > Z2K_HTTP_MID_STREAM_HI then
      key_st.candidates[flow_st.flow_id] = nil
      return false
    end

    if flow_st.max_seq >= Z2K_HTTP_MID_STREAM_LO then
      z2k_http_mid_stream_publish_candidate(key_st, flow_st)
    end
    return false
  end

  -- Incoming non-http_reply (other payloads on same TCP — e.g. control
  -- packets) — игнорируем для byte tracking, но FIN/RST всё равно
  -- закроет flow.
  if not desync.outgoing then
    local dis = desync.dis
    if dis and dis.tcp then
      local flags = tonumber(dis.tcp.th_flags) or 0
      local fin_bit = (TH_FIN and bitand(flags, TH_FIN)) or 0
      local rst_bit = (TH_RST and bitand(flags, TH_RST)) or 0
      if fin_bit ~= 0 or rst_bit ~= 0 then
        flow_st.fin_seen = true
        key_st.candidates[flow_st.flow_id] = nil
      end
    end
    return false
  end

  -- Outgoing http_req — retry signal. Scan candidates for fire match.
  if desync.outgoing and desync.l7payload == "http_req" then
    local prev_req_ts = key_st.last_req_ts
    key_st.last_req_ts = now

    local cands = key_st.candidates
    if next(cands) == nil then return false end

    local req_gap = (prev_req_ts > 0) and (now - prev_req_ts) or math.huge
    if req_gap > Z2K_HTTP_MID_STREAM_ACTIVE_RETRY_SEC then
      z2k_http_mid_stream_clear_all_candidates(cands)
      return false
    end

    local fire_fid, fire_cand, fire_silence
    for fid, cand in pairs(cands) do
      local since_progress = now - cand.last_progress_ts
      if since_progress > Z2K_HTTP_MID_STREAM_RETRY_MAX_SEC then
        cands[fid] = nil
      elseif (not fire_fid)
             and cand.max_seq >= Z2K_HTTP_MID_STREAM_LO
             and cand.max_seq <= Z2K_HTTP_MID_STREAM_HI
             and since_progress >= Z2K_HTTP_MID_STREAM_SILENCE_SEC then
        fire_fid     = fid
        fire_cand    = cand
        fire_silence = since_progress
      end
    end

    if not fire_fid then return false end

    if type(DLOG) == "function" then
      DLOG("z2k_http_mid_stream_stall: key=" .. key
           .. " host=" .. host
           .. " max_seq=" .. fire_cand.max_seq
           .. " silence=" .. fire_silence .. "s"
           .. " req_gap=" .. req_gap .. "s — counting as fail")
    end
    cands[fire_fid] = nil
    return true
  end

  return false
end

-- Conservative success detector for TCP profiles.
-- Detects success but does NOT reset host failure counters.
-- This is important for TV clients: successful handshakes from other devices
-- on the same domain must not mask repeated webOS failures.
--
-- HTTP-neutral-aware (commit 4 of v3.6 plan): when the incoming payload
-- is an http_reply, consult z2k_classify_http_reply BEFORE delegating to
-- standard. If neutral or hard_fail, do NOT mark nocheck — instead
-- stamp crec.z2k_neutral_observed so autocircular blocks the false-pin
-- via its commit-3 gates. Without this, large 4xx replies on yt_tcp
-- (which uses this detector) would still cross seq>inseq via standard,
-- set nocheck=true, and pin the strategy as successful.
function z2k_success_no_reset(desync, crec)
  if not desync.outgoing and desync.l7payload == "http_reply" and
     type(z2k_classify_http_reply) == "function" then
    local class, reason = z2k_classify_http_reply(desync)
    if class == "neutral" or class == "hard_fail" then
      if crec then
        crec.z2k_neutral_observed = true
        crec.z2k_reason = reason
      end
      return false
    end
    -- "positive" or nil → fall through to standard
  end
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

-- HTTP-aware success detector for profiles that don't need the
-- "no host failure-counter reset" semantics (rkn_tcp / gv_tcp / http_rkn).
--
-- For incoming http_reply: only "positive" (2xx, 304, same-SLD 3xx)
-- counts as success. "neutral" / "hard_fail" mark crec.z2k_neutral_observed
-- and return false — autocircular blocks the pin via the commit-3 gates.
-- For non-HTTP traffic (TLS handshake bytes etc) — delegate to
-- standard_success_detector, which fires on seq>inseq=18000 (set by
-- ensure_circular_tcp_inseq).
function z2k_http_success_positive_only(desync, crec)
  if not desync.outgoing and desync.l7payload == "http_reply" and
     type(z2k_classify_http_reply) == "function" then
    local class, reason = z2k_classify_http_reply(desync)
    if class == "positive" then
      return true
    end
    if class == "neutral" or class == "hard_fail" then
      if crec then
        crec.z2k_neutral_observed = true
        crec.z2k_reason = reason
      end
      return false
    end
    -- nil class — payload didn't parse as HTTP. Delegate.
  end
  if type(standard_success_detector) ~= "function" then return false end
  local ok, result = pcall(standard_success_detector, desync, crec)
  return ok and result == true
end

-- ----------------------------------------------------------------------------
-- z2k_silent_drop_detector — packet-count-based detection of silent ТСПУ drop.
-- Ported from github.com/ALFiX01/GoodbyeZapret/blob/main/Project/bin/lua/silent-drop-detector.lua
--
-- Идея: ТСПУ может silent-drop'ать pakets без отправки RST/FIN/Alert. У нас
-- content-based детекторы (z2k_tls_alert_fatal, z2k_*_mid_stream_stall) этот
-- кейс не ловят — они смотрят на TLS alert или byte-stream stall, а silent drop
-- происходит на уровне «никаких данных вообще не приходит». autocircular ждёт
-- timeout, теряет 60+ секунд на пустую попытку.
--
-- silent_drop_detector считает outgoing data-packets vs incoming. Если клиент
-- отправил >= tcp_out=4 data-пакетов (после ClientHello/HTTP request), а получил
-- только handshake responses (in_count <= tcp_in=1, что значит SYN-ACK без data) —
-- это silent drop. Сигнал failure → autocircular ротирует на следующую strategy.
--
-- Для http_rkn / rkn_tcp / yt_tcp arms: подключается как failure_detector.
-- Внутри делегирует к existing detector chain (z2k_http_mid_stream_stall или
-- z2k_tls_alert_fatal) если silent-drop signal не сработал — чтобы оба покрытия
-- работали одновременно.
--
-- Args (через :failure_detector_args=:tcp_out=N:tcp_in=M, опционально):
--   tcp_out — outgoing data threshold (default 4)
--   tcp_in  — incoming data threshold (default 1, только SYN-ACK)
function z2k_silent_drop_detector(desync, crec, arg)
  if crec and crec.nocheck then return false end

  local tcp_out_thr = (arg and tonumber(arg.tcp_out)) or 4
  local tcp_in_thr  = (arg and tonumber(arg.tcp_in))  or 1

  if desync.dis and desync.dis.tcp and desync.outgoing and desync.track and
     desync.track.pos then
    local out_count = (desync.track.pos.direct  and (desync.track.pos.direct.dcounter  or desync.track.pos.direct.pcounter))  or 0
    local in_count  = (desync.track.pos.reverse and (desync.track.pos.reverse.dcounter or desync.track.pos.reverse.pcounter)) or 0

    if out_count >= tcp_out_thr and in_count <= tcp_in_thr then
      -- Trigger FAILURE every tcp_out outgoing data-pakets (после первого hit'а)
      -- — это позволяет multiple rotations в long-lived connection где
      -- последовательные strategy ротации можно проверить за один TCP session.
      local last_fail = (crec and crec.z2k_silent_drop_last_fail) or 0
      if out_count >= last_fail + tcp_out_thr then
        if crec then
          crec.z2k_silent_drop_last_fail = out_count
          crec.failure = nil  -- разрешаем повторную rotation
        end
        DLOG("z2k_silent_drop_detector: FAILURE out="..out_count.." in="..in_count.." (last="..last_fail..")")
        return true
      end
    end
  end

  -- Не silent drop — делегируем chain ко всем существующим detectors.
  -- Каждый сам быстро вернёт false если payload не его (TLS vs HTTP).
  -- Порядок: TLS-stream → HTTP-stream → TLS-handshake-stalled → TLS-alert.
  -- z2k_mid_stream_stall (TLS) и z2k_http_mid_stream_stall (HTTP) — byte-window
  -- detectors. z2k_tls_stalled — CH-without-SH window (rkn_tcp default).
  -- z2k_tls_alert_fatal — final fallback с HTTP classifier и TLS-alert chain.
  local function try(fn)
    if type(fn) == "function" then
      local ok, result = pcall(fn, desync, crec, arg)
      if ok and result == true then return true end
    end
    return false
  end
  if try(z2k_mid_stream_stall) then return true end
  if try(z2k_http_mid_stream_stall) then return true end
  if try(z2k_tls_stalled) then return true end
  if try(z2k_tls_alert_fatal) then return true end
  return false
end
