-- z2k-dynamic-strategy.lua — runtime-parameterized desync strategy.
--
-- Used by z2k-classify generator to probe candidate strategies WITHOUT
-- restarting nfqws2. The generator writes new parameters to a runtime
-- file; this handler reads them per-packet (with 1-second TTL cache to
-- avoid I/O storms) and dispatches to the appropriate fake/multisplit/
-- hostfakesplit/multidisorder primitive.
--
-- Wire-up: in strats_new2.txt autocircular block, add
--   --lua-desync=z2k_dynamic_strategy:strategy=200
-- and pre-install the lua-init for this file in S99zapret2.new.
-- z2k-classify-inject.sh writes /tmp/z2k-classify-dynparams; the next
-- packet to a state.tsv-pinned host with strategy=200 picks up the
-- new params automatically.

local DYNPARAMS_PATH = "/tmp/z2k-classify-dynparams"
local CACHE_TTL = 1.0  -- seconds

local cached_params = nil
local cached_at = 0

-- Return current epoch as float; fall back to integer if no
-- clock_getfloattime in this nfqws2 build.
local function now_f()
    if type(clock_getfloattime) == "function" then
        local ok, v = pcall(clock_getfloattime)
        if ok and tonumber(v) then return tonumber(v) end
    end
    return tonumber(os.time() or 0) or 0
end

-- Parse the dynparams file. Format: one key=value per line, values
-- may contain colons. Comments (#) and blank lines ignored.
-- Returns table of params or nil on read error.
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
    return p
end

-- Cached read: re-read file at most once per CACHE_TTL seconds. Avoids
-- pounding tmpfs on every packet of a busy connection.
local function get_params()
    local t = now_f()
    if cached_params and (t - cached_at) < CACHE_TTL then
        return cached_params
    end
    local p = load_params()
    if p then
        cached_params = p
        cached_at = t
    end
    return cached_params
end

-- Set fields on the desync table from a params dict, ONLY for keys
-- the underlying primitive understands. Each primitive ignores keys
-- it doesn't recognize, but we filter to keep DLOG output clean.
local function apply_args(desync, params, allowed)
    for _, k in ipairs(allowed) do
        if params[k] ~= nil then
            desync.arg[k] = params[k]
        end
    end
end

-- Family dispatch. Each branch maps to an existing zapret-antidpi.lua
-- function (fake / multisplit / hostfakesplit / multidisorder).
local FAKE_KEYS = {"blob", "repeats", "tcp_seq", "tcp_ack", "tcp_ts",
                   "tcp_md5", "ip_id", "ip_ttl", "ip_autottl",
                   "tls_mod", "badsum", "payload"}
local SPLIT_KEYS = {"pos", "seqovl", "seqovl_pattern", "payload"}
local HOSTFAKE_KEYS = {"host", "seqovl", "badsum", "tcp_seq", "tcp_ack",
                       "ip_ttl", "repeats", "payload"}
local DISORDER_KEYS = {"pos", "seqovl", "seqovl_pattern", "payload"}

function z2k_dynamic_strategy(ctx, desync)
    local p = get_params()
    if not p then
        DLOG("z2k_dynamic_strategy: no dynparams file, no-op")
        return
    end

    local family = p.family
    if not family then
        DLOG("z2k_dynamic_strategy: missing family= in dynparams, no-op")
        return
    end

    -- All families default payload to tls_client_hello unless
    -- explicitly overridden in dynparams.
    if not p.payload then p.payload = "tls_client_hello" end
    -- All families default dir=out (we're the client).
    desync.arg.dir = p.dir or "out"

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

    else
        DLOG("z2k_dynamic_strategy: unknown family '" .. family .. "', no-op")
    end
end
