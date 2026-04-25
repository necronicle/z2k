-- z2k-dynamic-strategy.lua — runtime-parameterized desync handler.
--
-- Wired into rkn_tcp / google_tls / cdn_tls rotators as a sequential
-- :strategy=(max+1) slot (e.g. strategy=48 in rkn_tcp where 1..47
-- already exist).  count_strategies() in zapret-auto.lua errors on
-- gaps, so the slot must always be `last+1` — never 200 or anything
-- else that creates a hole in the strategy table.
--
-- Activation contract:
--
--   * Generator writes /tmp/z2k-classify-dynparams with `family=...`,
--     primitive-specific params, and `target_host=<sld>`. Then pins
--     `(profile_key, sld, slot_id)` in state.tsv via the helper script.
--
--   * autocircular reads state.tsv on the next flow → sets
--     hrec.nstrategy = slot_id → only the strategy chain instance
--     with `:strategy=slot_id` runs, which is *this* function.
--
--   * Handler dispatches to fake / multisplit / hostfakesplit /
--     multidisorder based on `family=`, applying primitive-specific
--     args from the params dict.
--
-- Safety: if rotator wraps to slot_id for an UNRELATED host (the
-- pinned host's strategies all failed and circular advanced past),
-- the dynparams dict still describes the pinned host's flow.
-- target_host check makes the handler a no-op for any other host
-- so we never apply the wrong strategy to the wrong domain.
--
-- Empty / missing dynparams → silent no-op (passes packet through
-- unchanged, matches argdebug pattern from zapret-lib.lua).

local DYNPARAMS_PATH = "/tmp/z2k-classify-dynparams"
local CACHE_TTL = 1.0

local cached = nil
local cached_at = 0

local function now_f()
    if type(clock_getfloattime) == "function" then
        local ok, v = pcall(clock_getfloattime)
        if ok and tonumber(v) then return tonumber(v) end
    end
    return tonumber(os.time() or 0) or 0
end

local function load_params()
    local f = io.open(DYNPARAMS_PATH, "r")
    if not f then return nil end
    local p = {}
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" and line:match("%S") then
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.*)$")
            if k then p[k] = v end
        end
    end
    f:close()
    if next(p) == nil then return nil end
    return p
end

local function get_params()
    local t = now_f()
    if cached and (t - cached_at) < CACHE_TTL then return cached end
    cached = load_params()
    cached_at = t
    return cached
end

-- Match current connection host against pinned target_host. Use suffix
-- match so nld=2 (per-SLD) state.tsv pins on `linkedin.com` cover
-- `www.linkedin.com` connections too.
local function host_matches(target, current)
    if not target or target == "" then return true end
    if not current or current == "" then return false end
    if current == target then return true end
    return current:sub(-(#target + 1)) == ("." .. target)
end

local FAKE_KEYS = {"blob", "repeats", "tcp_seq", "tcp_ack", "tcp_ts",
                   "tcp_md5", "ip_id", "ip_ttl", "ip_autottl",
                   "tls_mod", "badsum", "payload"}
local SPLIT_KEYS = {"pos", "seqovl", "seqovl_pattern", "payload"}
local HOSTFAKE_KEYS = {"host", "seqovl", "badsum", "tcp_seq", "tcp_ack",
                       "ip_ttl", "repeats", "payload"}
local DISORDER_KEYS = {"pos", "seqovl", "seqovl_pattern", "payload"}

local function apply_args(desync, params, allowed)
    for _, k in ipairs(allowed) do
        if params[k] ~= nil then
            desync.arg[k] = params[k]
        end
    end
end

function z2k_dynamic_strategy(ctx, desync)
    local p = get_params()
    if not p or not p.family then return end

    local cur = desync and desync.track and desync.track.hostname
    if not host_matches(p.target_host, cur) then return end

    if not p.payload then p.payload = "tls_client_hello" end
    desync.arg.dir = p.dir or "out"

    local family = p.family
    if family == "fake" then
        apply_args(desync, p, FAKE_KEYS)
        return fake(ctx, desync)
    elseif family == "multisplit" then
        apply_args(desync, p, SPLIT_KEYS)
        return multisplit(ctx, desync)
    elseif family == "hostfakesplit" then
        apply_args(desync, p, HOSTFAKE_KEYS)
        return hostfakesplit(ctx, desync)
    elseif family == "multidisorder" then
        apply_args(desync, p, DISORDER_KEYS)
        return multidisorder(ctx, desync)
    end
end
