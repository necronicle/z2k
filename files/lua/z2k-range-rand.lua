-- z2k-range-rand.lua
--
-- Phase 7 — per-connection range randomisation for numeric strategy args.
--
-- Strategies written as `fake:repeats=2-6:...` (hyphen between two integers)
-- now resolve the range to a sticky random integer picked once per flow and
-- cached in `desync.track.lua_state`. Each subsequent invocation of the same
-- strategy on the same flow sees the same resolved number, so replays do not
-- mutate packet characteristics mid-handshake. A new flow to the same host
-- picks a fresh value.
--
-- Implementation strategy: override the upstream global action functions
-- (`fake`, `multisplit`, `fakedsplit`, `fakeddisorder`, `hostfakesplit`) with
-- a thin wrapper that walks a short list of range-eligible arg keys, resolves
-- each via a per-flow cache, then passes through to the original function.
-- Strategies that do not use range syntax are completely untouched — the
-- wrapper is transparent for fixed-value args.
--
-- Must load AFTER zapret-antidpi.lua (where the originals live) and before
-- any strategies fire. Enforced via --lua-init order in S99zapret2.new.
--
-- Range-eligible keys:
--   repeats  — how many times to send the fake packet
--   seqovl   — seq overlap byte count
--   tcp_seq  — tcp seq adjust (when used as numeric offset)
--   tcp_ts   — tcp timestamp adjust (numeric; negative allowed)
-- Other args (pos, host, blob, payload, tls_mod etc) are NOT range-resolved
-- here — pos uses positional markers with its own syntax, the rest are
-- string literals.

local z2k_rr_keys_pos = { "repeats", "seqovl" }
local z2k_rr_keys_signed = { "tcp_seq", "tcp_ts" }

-- Parse "a-b" → (a, b) integers, or nil if not a valid pure range.
-- Only accepts unsigned integers for positive-only keys.
local function parse_range_pos(v)
  if type(v) ~= "string" then return nil end
  local a, b = v:match("^(%d+)%-(%d+)$")
  if not a then return nil end
  a, b = tonumber(a), tonumber(b)
  if not a or not b or a > b then return nil end
  return a, b
end

-- Parse "a-b" where a or b may be negative (e.g. "-2000--500" or "-5-5")
-- Accepts leading minus on either side. Never matches a single-value literal
-- like "-1000" (which is a scalar, not a range).
local function parse_range_signed(v)
  if type(v) ~= "string" then return nil end
  local a, b = v:match("^(%-?%d+)%-(%-?%d+)$")
  if not a then return nil end
  a, b = tonumber(a), tonumber(b)
  if not a or not b or a > b then return nil end
  return a, b
end

-- Get (or create) the per-flow cache table stored under lua_state.
-- Returns nil if lua_state isn't available (e.g. first packet before
-- track is populated) — caller falls back to the original string.
local function z2k_rr_cache(desync)
  local ls = desync and desync.track and desync.track.lua_state
  if type(ls) ~= "table" then return nil end
  local c = ls.__z2k_range_rand
  if type(c) ~= "table" then
    c = {}
    ls.__z2k_range_rand = c
  end
  return c
end

-- Resolve an `arg[key]` range in place. Sticky per flow+func_instance+key
-- so a later invocation on the same flow gets the same number and replays
-- are byte-identical. Deterministic fallback if cache missing: use the
-- midpoint (avoids math.random when state isn't ready).
local function z2k_rr_resolve_one(desync, key, parser)
  local arg = desync.arg
  local v = arg[key]
  local lo, hi = parser(v)
  if not lo then return end

  local cache = z2k_rr_cache(desync)
  local fi = desync.func_instance or "?"
  local ck = fi .. ":" .. key
  local resolved

  if cache then
    resolved = cache[ck]
    if not resolved then
      resolved = math.random(lo, hi)
      cache[ck] = resolved
      if type(DLOG) == "function" then
        DLOG("z2k_range_rand: "..key.."="..v.." resolved to "..resolved.." fi="..fi)
      end
    end
  else
    -- No track state available — stable midpoint so behavior is still
    -- deterministic and doesn't explode on missing state.
    resolved = math.floor((lo + hi) / 2)
  end

  arg[key] = tostring(resolved)
end

local function z2k_rr_resolve_all(desync)
  if not desync or not desync.arg then return end
  for i = 1, #z2k_rr_keys_pos do
    z2k_rr_resolve_one(desync, z2k_rr_keys_pos[i], parse_range_pos)
  end
  for i = 1, #z2k_rr_keys_signed do
    z2k_rr_resolve_one(desync, z2k_rr_keys_signed[i], parse_range_signed)
  end
end

-- Install wrappers over upstream global action functions. Save the
-- original via a local reference before rebinding the global — the
-- closure captures `_orig`, and calls it after range resolution.
local function z2k_rr_wrap(fname)
  local _orig = _G[fname]
  if type(_orig) ~= "function" then
    if type(DLOG) == "function" then
      DLOG("z2k_range_rand: cannot wrap '"..fname.."' — not a function")
    end
    return
  end
  _G[fname] = function(ctx, desync)
    z2k_rr_resolve_all(desync)
    return _orig(ctx, desync)
  end
end

for _, fname in ipairs({
  "fake",
  "multisplit",
  "multidisorder",
  "fakedsplit",
  "fakeddisorder",
  "hostfakesplit",
  "syndata",
}) do
  z2k_rr_wrap(fname)
end
