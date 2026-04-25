-- z2k-dynamic-strategy.lua — runtime-parameterized desync handler.
--
-- Wired into rkn_tcp at strategy=(max+1) by config_official.sh. The
-- handler runs only when autocircular has nstrategy pinned to that
-- slot, which happens via state.tsv pinning written by the inject
-- helper.
--
-- Two-tier param lookup:
--
-- (1) PERSISTENT DB — winners promoted via z2k-classify --apply land
--     in two TSVs that the handler reads with a 5-sec TTL cache:
--
--     /opt/zapret2/lists/z2k-classify-strategies.tsv   (catalog)
--         # id  family  params
--         1     multisplit  pos=1,sniext+1:seqovl=1:...
--         2     fake        blob=...:repeats=6:...
--
--     /opt/zapret2/lists/z2k-classify-domains.tsv      (mapping)
--         # host         strategy_id
--         proton.me      1
--         linkedin.com   1     (← deduped: same strategy)
--         discord.com    2
--
--     Lookup: current host (or its suffix-matched parent for nld=2
--     SLD pinning) → strategy_id → catalog row → apply.
--
-- (2) TRANSIENT — during a generator run, /tmp/z2k-classify-dynparams
--     carries the candidate strategy plus target_host. Used only when
--     the host has NO persistent entry in the DB and the dynparams
--     target_host matches. This is the "test the new strategy on
--     this exact domain" channel — no DB pollution until persist.
--
-- Empty / missing dynparams + no DB hit → silent no-op (returns nil
-- which nfqws2 treats as VERDICT_PASS, matching argdebug).

local DB_STRATEGIES = "/opt/zapret2/lists/z2k-classify-strategies.tsv"
local DB_DOMAINS    = "/opt/zapret2/lists/z2k-classify-domains.tsv"
local DYNPARAMS     = "/tmp/z2k-classify-dynparams"
local DB_TTL        = 5.0
local DYN_TTL       = 1.0

local cache_strategies = {}  -- id -> {family=..., params=...}
local cache_domains    = {}  -- host -> id
local cache_loaded_at  = 0

local cache_dyn        = nil
local cache_dyn_at     = 0

local function now_f()
    if type(clock_getfloattime) == "function" then
        local ok, v = pcall(clock_getfloattime)
        if ok and tonumber(v) then return tonumber(v) end
    end
    return tonumber(os.time() or 0) or 0
end

-- ---------- DB loading ----------

local function load_db()
    cache_strategies = {}
    cache_domains = {}

    local f = io.open(DB_STRATEGIES, "r")
    if f then
        for line in f:lines() do
            if line:sub(1, 1) ~= "#" and line:match("%S") then
                local id, family, params = line:match("^(%d+)\t([^\t]+)\t(.*)$")
                if id then
                    cache_strategies[tonumber(id)] = {
                        family = family,
                        params = params or "",
                    }
                end
            end
        end
        f:close()
    end

    f = io.open(DB_DOMAINS, "r")
    if f then
        for line in f:lines() do
            if line:sub(1, 1) ~= "#" and line:match("%S") then
                local host, id = line:match("^(%S+)\t(%d+)")
                if host and id then
                    cache_domains[host] = tonumber(id)
                end
            end
        end
        f:close()
    end
    cache_loaded_at = now_f()
end

local function get_db()
    if (now_f() - cache_loaded_at) >= DB_TTL then load_db() end
    return cache_strategies, cache_domains
end

-- Suffix match: nld=2 pins per-SLD (linkedin.com), so probes from
-- www.linkedin.com or any.linkedin.com should resolve to the same DB
-- entry. Walk the domains table looking for an entry where
-- current_host equals or ends with ".<entry>".
local function lookup_strategy_for_host(host)
    if not host or host == "" then return nil end
    local strategies, domains = get_db()

    local id = domains[host]
    if not id then
        for d, sid in pairs(domains) do
            local dlen = #d
            if #host > dlen and host:sub(-(dlen + 1)) == ("." .. d) then
                id = sid
                break
            end
        end
    end
    if not id then return nil end
    return strategies[id]
end

-- ---------- transient dynparams ----------

local function load_dyn()
    local f = io.open(DYNPARAMS, "r")
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

local function get_dyn()
    local t = now_f()
    if cache_dyn and (t - cache_dyn_at) < DYN_TTL then return cache_dyn end
    cache_dyn = load_dyn()
    cache_dyn_at = t
    return cache_dyn
end

local function host_matches(target, current)
    if not target or target == "" then return true end
    if not current or current == "" then return false end
    if current == target then return true end
    if #current > #target and
       current:sub(-(#target + 1)) == ("." .. target) then
        return true
    end
    return false
end

-- ---------- params parsing & primitive dispatch ----------

-- Parse "blob=foo:repeats=6:tcp_seq=2:..." into a flat table.
local function parse_params(s)
    local p = {}
    if not s or s == "" then return p end
    for chunk in s:gmatch("[^:]+") do
        if chunk:match("%S") then
            local k, v = chunk:match("^([%w_]+)%s*=?%s*(.*)$")
            if k and k ~= "" then p[k] = v end
        end
    end
    return p
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

local function dispatch(ctx, desync, family, params)
    if not params.payload then params.payload = "tls_client_hello" end
    desync.arg.dir = params.dir or "out"

    if family == "fake" then
        apply_args(desync, params, FAKE_KEYS)
        return fake(ctx, desync)
    elseif family == "multisplit" then
        apply_args(desync, params, SPLIT_KEYS)
        return multisplit(ctx, desync)
    elseif family == "hostfakesplit" then
        apply_args(desync, params, HOSTFAKE_KEYS)
        return hostfakesplit(ctx, desync)
    elseif family == "multidisorder" then
        apply_args(desync, params, DISORDER_KEYS)
        return multidisorder(ctx, desync)
    end
end

-- ---------- entry point ----------

function z2k_dynamic_strategy(ctx, desync)
    local cur = desync and desync.track and desync.track.hostname

    -- (1) Persistent DB lookup — winners promoted via --apply land here.
    if cur then
        local s = lookup_strategy_for_host(cur)
        if s and s.family then
            return dispatch(ctx, desync, s.family, parse_params(s.params))
        end
    end

    -- (2) Transient dynparams — single-host generator test channel.
    local p = get_dyn()
    if p and p.family then
        if not host_matches(p.target_host, cur) then return end
        return dispatch(ctx, desync, p.family, p)
    end

    -- (3) No DB hit, no transient match → silent no-op.
end
