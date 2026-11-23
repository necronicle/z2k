-- z2k-gv-autopilot.lua — рантайм автопилота YouTube / googlevideo / gvt1 (PR 3).
--
-- Работает поверх атомарной таблицы политики /tmp/z2k-gv-policy.dat от z2k-detect
-- gvsub и использует общий конструктор ICMP Port Unreachable из z2k-quic-reject.lua.
--
-- Функции --lua-desync:
--   z2k_autopilot_quic         — Guard 1: allowlist-by-proof для googlevideo/gvt1
--                                и глобальный QUIC-блок при global_quic_blocked=1.
--   z2k_autopilot_tcp_fastfail — Guard 2: мгновенный TCP RST,ACK (<1 мс) на мёртвых
--                                узлах google/isp (НИКОГДА play/gfe/yt/unknown) при
--                                активном cross-stack Safety Fuse и anti-storm (<6/3с).
--   z2k_autopilot_stall_guard  — Guard 4: сторож зависания ISP GGC после ServerHello;
--                                двунаправленный TCP RST при отсутствии ответа за stall_ms.
--   z2k_autopilot_observe      — DoH/DoT-логгер новых googlevideo/gvt1 узлов в
--                                /tmp/z2k-gv-observed.tsv.

local DEFAULT_POLICY_PATH = "/tmp/z2k-gv-policy.dat"
local DEFAULT_OBSERVED_PATH = "/tmp/z2k-gv-observed.tsv"

local CACHE_TTL_SEC = 1.0
local DEFAULT_POLICY_STALE_SEC = 300
local OBSERVED_DEDUPE_SEC = 120.0
local OBSERVED_MAX_LINES = 256
local OBSERVED_MAX_BYTES = 32768
local ANTISTORM_WINDOW_SEC = 3.0
local ANTISTORM_MAX_RSTS = 5 -- строго < 6 RST за 3с на клиента

local DEFAULT_STALL_MS = 1800
local MIN_STALL_MS = 1600
local MAX_STALL_MS = 3500

local TCP_FLAG_FIN = rawget(_G, "TH_FIN") or 0x01
local TCP_FLAG_SYN = rawget(_G, "TH_SYN") or 0x02
local TCP_FLAG_RST = rawget(_G, "TH_RST") or 0x04
local TCP_FLAG_ACK = rawget(_G, "TH_ACK") or 0x10
local V_DROP = rawget(_G, "VERDICT_DROP") or 2

local orig_io_open = io and io.open
local ip4_id_seq = 0
local override_policy_path = nil
local override_observed_path = nil

local policy_cache = {
    loaded = false,
    loaded_at = 0,
    path = nil,
    open_fn = nil,
    policy = nil,
}

local observed_seen = {}
local observed_seen_count = 0
local rst_history = {}
local active_stall_timers = {}

local function band(a, b)
    if type(bitand) == "function" then
        return bitand(a, b)
    end
    local res, bitval = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then
            res = res + bitval
        end
        bitval = bitval * 2
        a = math.floor(a / 2)
        b = math.floor(b / 2)
    end
    return res
end

local function add_u32(a, b)
    if type(u32add) == "function" then
        return u32add(a, b)
    end
    return (a + b) % 4294967296
end

local function seq_ge_safe(a, b)
    if type(seq_ge) == "function" then
        return seq_ge(a, b)
    end
    local diff = (a - b) % 4294967296
    return diff < 2147483648
end

local function clock_now()
    if type(clock_getfloattime) == "function" then
        return clock_getfloattime()
    end
    return os.time()
end

local function next_ip4_id()
    ip4_id_seq = (ip4_id_seq % 65535) + 1
    return ip4_id_seq
end

local function dlog(msg)
    if type(DLOG) == "function" then
        DLOG(msg)
    end
end

local function policy_path()
    local env = os and os.getenv and os.getenv("Z2K_POLICY_FILE_OVERRIDE")
    if env and env ~= "" then return env end
    if override_policy_path and override_policy_path ~= "" then return override_policy_path end
    return DEFAULT_POLICY_PATH
end

local function observed_path()
    local env = os and os.getenv and os.getenv("Z2K_OBSERVED_FILE_OVERRIDE")
    if env and env ~= "" then return env end
    if override_observed_path and override_observed_path ~= "" then return override_observed_path end
    return DEFAULT_OBSERVED_PATH
end

local function policy_stale_sec()
    local env = os and os.getenv and os.getenv("Z2K_POLICY_STALE_SEC")
    local v = env and tonumber(env)
    if v and v > 0 then return v end
    return DEFAULT_POLICY_STALE_SEC
end

local function clamp_num(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Парсинг десятичного IPv4 в 4-байтовую бинарную строку.
local function parse_ipv4_binary(s)
    local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    if (#a > 1 and a:sub(1, 1) == "0")
        or (#b > 1 and b:sub(1, 1) == "0")
        or (#c > 1 and c:sub(1, 1) == "0")
        or (#d > 1 and d:sub(1, 1) == "0") then
        return nil
    end
    local na, nb, nc, nd = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not (na and nb and nc and nd) then return nil end
    if na > 255 or nb > 255 or nc > 255 or nd > 255 then return nil end
    return string.char(na, nb, nc, nd)
end

-- Парсинг группы колонов (левая/правая часть IPv6) в 16-битные слова.
local function parse_ipv6_side(part, allow_v4)
    local words = {}
    if part == "" then return words end
    if part:sub(1, 1) == ":" or part:sub(-1) == ":" then return nil end
    local idx = 1
    local len = #part
    while idx <= len do
        local colon = part:find(":", idx, true)
        local tok = colon and part:sub(idx, colon - 1) or part:sub(idx)
        if tok == "" then return nil end
        if tok:find(".", 1, true) then
            if not allow_v4 or colon ~= nil then return nil end
            local v4 = parse_ipv4_binary(tok)
            if not v4 then return nil end
            local b1, b2, b3, b4 = v4:byte(1, 4)
            words[#words + 1] = b1 * 256 + b2
            words[#words + 1] = b3 * 256 + b4
        else
            if #tok > 4 or not tok:match("^[0-9a-fA-F]+$") then return nil end
            words[#words + 1] = tonumber(tok, 16)
        end
        if not colon then break end
        idx = colon + 1
    end
    return words
end

-- Канонический парсер IPv4/IPv6 текста -> 4 или 16 байт + семейство ("v4"|"v6").
function z2k_autopilot_parse_ip(addr)
    if type(addr) ~= "string" or addr == "" then return nil end
    local clean = addr:match("^%s*(.-)%s*$")
    if clean == "" then return nil end
    -- Срезаем zone-id (%eth0) и возможные скобки [::1]
    if clean:sub(1, 1) == "[" and clean:sub(-1) == "]" then
        clean = clean:sub(2, -2)
    end
    clean = clean:gsub("%%.*$", "")
    if clean == "" then return nil end

    if not clean:find(":", 1, true) then
        local v4 = parse_ipv4_binary(clean)
        if v4 then return v4, "v4" end
        return nil
    end

    local dcolon = clean:find("::", 1, true)
    local words = {}
    if dcolon then
        local left_s = clean:sub(1, dcolon - 1)
        local right_s = clean:sub(dcolon + 2)
        if right_s:find("::", 1, true) then return nil end
        if left_s:find(".", 1, true) then return nil end
        local left = parse_ipv6_side(left_s, false)
        local right = parse_ipv6_side(right_s, true)
        if not left or not right then return nil end
        local gap = 8 - (#left + #right)
        if gap < 1 then return nil end
        for i = 1, #left do words[#words + 1] = left[i] end
        for _ = 1, gap do words[#words + 1] = 0 end
        for i = 1, #right do words[#words + 1] = right[i] end
    else
        local side = parse_ipv6_side(clean, true)
        if not side or #side ~= 8 then return nil end
        words = side
    end

    if #words ~= 8 then return nil end
    local bytes = {}
    for i = 1, 8 do
        local w = words[i]
        bytes[#bytes + 1] = string.char(math.floor(w / 256), w % 256)
    end
    return table.concat(bytes), "v6"
end

-- Бинарное маскирование IP-адреса по длине префикса (/24, /48 и т.д.).
function z2k_autopilot_mask_prefix(raw_bin, plen)
    if type(raw_bin) ~= "string" then return nil end
    local n = #raw_bin
    if n ~= 4 and n ~= 16 then return nil end
    if type(plen) ~= "number" or plen < 0 or plen > n * 8 or plen ~= math.floor(plen) then
        return nil
    end
    if plen == n * 8 then return raw_bin end
    local out = {}
    for i = 1, n do
        local b = raw_bin:byte(i)
        local bits_before = (i - 1) * 8
        if plen >= bits_before + 8 then
            out[i] = string.char(b)
        elseif plen <= bits_before then
            out[i] = "\0"
        else
            local keep = plen - bits_before
            local step = 2 ^ (8 - keep)
            out[i] = string.char(math.floor(b / step) * step)
        end
    end
    return table.concat(out)
end

local function parse_cidr(cidr_str)
    if type(cidr_str) ~= "string" then return nil end
    local ip_part, plen_part = cidr_str:match("^([^/]+)/(%d+)$")
    if not ip_part then return nil end
    local plen = tonumber(plen_part)
    local raw, family = z2k_autopilot_parse_ip(ip_part)
    if not raw or not plen then return nil end
    local masked = z2k_autopilot_mask_prefix(raw, plen)
    if not masked then return nil end
    return masked, plen, family
end

local function bin_to_ip_text(raw)
    if type(raw) ~= "string" then return nil end
    if type(ntop) == "function" then
        local s = ntop(raw)
        if s then return s end
    end
    if #raw == 4 then
        return string.format("%d.%d.%d.%d", raw:byte(1, 4))
    end
    if #raw == 16 then
        local words = {}
        for i = 1, 16, 2 do
            words[#words + 1] = raw:byte(i) * 256 + raw:byte(i + 1)
        end
        local best_start, best_len = 0, 0
        local cur_start, cur_len = 0, 0
        for i = 1, 8 do
            if words[i] == 0 then
                if cur_len == 0 then cur_start = i end
                cur_len = cur_len + 1
                if cur_len > best_len then
                    best_start, best_len = cur_start, cur_len
                end
            else
                cur_len = 0
            end
        end
        if best_len < 2 then best_start, best_len = 0, 0 end
        local parts = {}
        local i = 1
        while i <= 8 do
            if i == best_start then
                parts[#parts + 1] = ""
                if i == 1 then parts[#parts + 1] = "" end
                i = i + best_len
                if i > 8 then parts[#parts + 1] = "" end
            else
                parts[#parts + 1] = string.format("%x", words[i])
                i = i + 1
            end
        end
        return table.concat(parts, ":")
    end
    return nil
end

local function parse_kv_line(line)
    local fields = {}
    for tok in line:gmatch("[^\t]+") do
        local k, v = tok:match("^([^=]+)=(.*)$")
        if k then
            fields[k] = v
        end
    end
    return fields
end

local function parse_policy_file(path, open_fn, now)
    local f = open_fn(path, "r")
    if not f then return nil end

    local header = nil
    local ips = {}
    local prefixes = { v4 = {}, v6 = {} }
    local prefix_lens_set = { v4 = {}, v6 = {} }

    for line in f:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local kv = parse_kv_line(line)
            local rtype = kv.type
            if rtype == "header" then
                header = {
                    version = tonumber(kv.version),
                    updated = tonumber(kv.updated),
                    usable_v4 = tonumber(kv.usable_v4) or 0,
                    usable_v6 = tonumber(kv.usable_v6) or 0,
                    baseline_rtt_ms = tonumber(kv.baseline_rtt_ms) or 0,
                    ggc_rtt_ms = tonumber(kv.ggc_rtt_ms) or 0,
                    global_quic_blocked = tonumber(kv.global_quic_blocked) or 0,
                    preflight_sni = kv.preflight_sni or "",
                    resyn_delay_ms = tonumber(kv.resyn_delay_ms),
                    preflight_giveup_ms = tonumber(kv.preflight_giveup_ms),
                    ggc_stall_guard_ms = tonumber(kv.ggc_stall_guard_ms),
                    stale = tonumber(kv.stale) or 0,
                }
            elseif rtype == "prefix" and kv.addr then
                local masked, plen, family = parse_cidr(kv.addr)
                if masked then
                    prefixes[family][plen] = prefixes[family][plen] or {}
                    prefixes[family][plen][masked] = {
                        scope = "prefix",
                        kind = kv.kind or "unknown",
                        verdict = kv.verdict or "unknown",
                        quic_ok = tonumber(kv.quic_ok) or 0,
                        rtt_ms = tonumber(kv.rtt_ms) or 0,
                        resyn_delay_ms = tonumber(kv.resyn_delay_ms),
                        giveup_ms = tonumber(kv.giveup_ms),
                        stall_ms = tonumber(kv.stall_ms),
                    }
                    prefix_lens_set[family][plen] = true
                end
            elseif rtype == "ip" and kv.addr then
                local raw = z2k_autopilot_parse_ip(kv.addr)
                if raw then
                    ips[raw] = {
                        scope = "ip",
                        kind = kv.kind or "unknown",
                        verdict = kv.verdict or "unknown",
                        quic_ok = tonumber(kv.quic_ok) or 0,
                        rtt_ms = tonumber(kv.rtt_ms) or 0,
                        resyn_delay_ms = tonumber(kv.resyn_delay_ms),
                        giveup_ms = tonumber(kv.giveup_ms),
                        stall_ms = tonumber(kv.stall_ms),
                    }
                end
            end
        end
    end
    f:close()

    if not header or header.version ~= 1 or not header.updated or header.updated <= 0 or header.stale == 1 then
        return nil
    end
    if now >= header.updated and (now - header.updated) > policy_stale_sec() then
        return nil
    end

    local prefix_lens = { v4 = {}, v6 = {} }
    for _, fam in ipairs({ "v4", "v6" }) do
        for plen in pairs(prefix_lens_set[fam]) do
            prefix_lens[fam][#prefix_lens[fam] + 1] = plen
        end
        table.sort(prefix_lens[fam], function(a, b) return a > b end)
    end

    return {
        header = header,
        ips = ips,
        prefixes = prefixes,
        prefix_lens = prefix_lens,
    }
end

local function load_policy()
    local open_fn = io and io.open
    if not open_fn then return nil end
    local path = policy_path()
    local now = clock_now()

    -- Инвалидируем RAM-кэш при смене пути, моке io.open, истечении 1с TTL или откате часов.
    if policy_cache.loaded
        and open_fn == orig_io_open
        and policy_cache.open_fn == open_fn
        and policy_cache.path == path
        and now >= policy_cache.loaded_at
        and (now - policy_cache.loaded_at) < CACHE_TTL_SEC then
        return policy_cache.policy
    end

    local pol = parse_policy_file(path, open_fn, now)
    policy_cache.loaded = true
    policy_cache.loaded_at = now
    policy_cache.path = path
    policy_cache.open_fn = open_fn
    policy_cache.policy = pol
    return pol
end

function z2k_autopilot_safety_fuse(header)
    if not header then return false end
    return ((header.usable_v4 or 0) + (header.usable_v6 or 0)) >= 1
end

function z2k_autopilot_lookup_raw(raw_bin)
    if type(raw_bin) ~= "string" then return nil, nil, nil end
    local family
    if #raw_bin == 4 then
        family = "v4"
    elseif #raw_bin == 16 then
        family = "v6"
    else
        return nil, nil, nil
    end

    local pol = load_policy()
    if not pol then return nil, nil, nil end

    local exact = pol.ips[raw_bin]
    if exact then
        return exact, pol.header, pol
    end

    local fam_prefixes = pol.prefixes[family]
    local lens = pol.prefix_lens[family]
    for i = 1, #lens do
        local plen = lens[i]
        local masked = z2k_autopilot_mask_prefix(raw_bin, plen)
        local p_entry = masked and fam_prefixes[plen] and fam_prefixes[plen][masked]
        if p_entry then
            return p_entry, pol.header, pol
        end
    end

    return nil, pol.header, pol
end

function z2k_autopilot_lookup_dis(dis)
    if type(dis) ~= "table" then return nil, nil, nil end
    local raw_dst = nil
    if dis.ip6 and dis.ip6.ip6_dst then
        raw_dst = dis.ip6.ip6_dst
    elseif dis.ip and dis.ip.ip_dst then
        raw_dst = dis.ip.ip_dst
    end
    if not raw_dst then return nil, nil, nil end
    return z2k_autopilot_lookup_raw(raw_dst)
end

function z2k_autopilot_lookup_text(addr)
    local raw = z2k_autopilot_parse_ip(addr)
    if not raw then return nil, nil, nil end
    return z2k_autopilot_lookup_raw(raw)
end

local function normalize_observed_host(hostname)
    if type(hostname) ~= "string" or hostname == "" then return nil end
    local h = hostname:lower():gsub("%.$", "")
    if #h < 5 or #h > 253 then return nil end
    if h:find("[^a-z0-9.-]") or h:sub(1, 1) == "." or h:find("..", 1, true) then
        return nil
    end
    if h == "c.youtube.com" or h:sub(-14) == ".c.youtube.com" then
        return nil
    end
    if h:match("^[a-z0-9.-]+%.googlevideo%.com$") or h:match("^[a-z0-9.-]+%.gvt1%.com$") then
        return h
    end
    return nil
end

local function append_observed_line(dst_text, host)
    local open_fn = io and io.open
    if not open_fn then return end
    local path = observed_path()
    local new_line = dst_text .. "\t" .. host .. "\n"

    -- Читаем текущий файл для ограничения объёма (<= 256 строк / 32 KiB) без os.rename/os.remove,
    -- чтобы не ломать права (nfqws2 работает под nobody, gvsub усекает in-place).
    local rf = open_fn(path, "r")
    if rf then
        local content = rf:read(OBSERVED_MAX_BYTES + 1024) or ""
        rf:close()
        local lines = {}
        local bytes = 0
        for l in content:gmatch("[^\r\n]+") do
            lines[#lines + 1] = l
            bytes = bytes + #l + 1
        end
        if #lines >= OBSERVED_MAX_LINES or (bytes + #new_line) > OBSERVED_MAX_BYTES then
            local keep_from = math.max(1, #lines - math.floor(OBSERVED_MAX_LINES / 2) + 2)
            local trimmed = {}
            local trimmed_bytes = #new_line
            for i = #lines, keep_from, -1 do
                local l = lines[i]
                if (#trimmed + 1) >= OBSERVED_MAX_LINES or (trimmed_bytes + #l + 1) > OBSERVED_MAX_BYTES then
                    break
                end
                trimmed[#trimmed + 1] = l
                trimmed_bytes = trimmed_bytes + #l + 1
            end
            local out = {}
            for i = #trimmed, 1, -1 do
                out[#out + 1] = trimmed[i] .. "\n"
            end
            out[#out + 1] = new_line
            local wf = open_fn(path, "w")
            if wf then
                wf:write(table.concat(out))
                wf:close()
            end
            return
        end
    end

    local af = open_fn(path, "a")
    if af then
        af:write(new_line)
        af:close()
    end
end

local function observe_packet(desync)
    if not (desync and desync.outgoing and desync.dis) then return end
    local l7 = desync.l7payload
    if l7 ~= "tls_client_hello" and l7 ~= "quic_initial" then return end
    local track = desync.track
    if not track or track.hostname_is_ip then return end
    local host = normalize_observed_host(track.hostname)
    if not host then return end

    local raw_dst = (desync.dis.ip6 and desync.dis.ip6.ip6_dst) or (desync.dis.ip and desync.dis.ip.ip_dst)
    if not raw_dst then return end

    local pol = load_policy()
    if pol and pol.ips[raw_dst] and pol.ips[raw_dst].verdict ~= "unknown" then
        return
    end

    local dst_text = bin_to_ip_text(raw_dst)
    if not dst_text then return end

    local now = clock_now()
    local dedupe_key = dst_text .. "\t" .. host
    local last = observed_seen[dedupe_key]
    if last and now >= last and (now - last) < OBSERVED_DEDUPE_SEC then
        return
    end

    if observed_seen_count >= 1024 then
        observed_seen = {}
        observed_seen_count = 0
    end
    if not observed_seen[dedupe_key] then
        observed_seen_count = observed_seen_count + 1
    end
    observed_seen[dedupe_key] = now

    append_observed_line(dst_text, host)
end

local function prune_and_allow_rst(client_raw, now)
    if type(client_raw) ~= "string" then return false end
    local hist = rst_history[client_raw]
    if not hist then
        -- Защита от разрастания таблицы при множестве клиентских адресов.
        local count = 0
        for _ in pairs(rst_history) do
            count = count + 1
            if count > 256 then
                rst_history = {}
                break
            end
        end
        hist = {}
        rst_history[client_raw] = hist
    end

    local kept = {}
    for i = 1, #hist do
        local t = hist[i]
        if now >= t and (now - t) < ANTISTORM_WINDOW_SEC then
            kept[#kept + 1] = t
        end
    end
    rst_history[client_raw] = kept

    if #kept >= ANTISTORM_MAX_RSTS then
        return false
    end
    kept[#kept + 1] = now
    return true
end

local function reject_quic_packet(ctx, desync)
    if type(z2k_quic_reject_send) == "function" then
        return z2k_quic_reject_send(ctx, desync)
    end
    if ctx and type(execution_plan_cancel) == "function" then
        pcall(execution_plan_cancel, ctx)
    end
    return V_DROP
end

local function is_gv_or_play_hostname(hostname)
    if type(hostname) ~= "string" or hostname == "" then return false end
    local h = hostname:lower():gsub("%.$", "")
    return h == "googlevideo.com"
        or h:sub(-16) == ".googlevideo.com"
        or h == "gvt1.com"
        or h:sub(-9) == ".gvt1.com"
end

-- --lua-desync=z2k_autopilot_observe — пассивное наблюдение DoH/DoT в профилях.
function z2k_autopilot_observe(_, desync)
    observe_packet(desync)
end

-- --lua-desync=z2k_autopilot_quic — Guard 1: QUIC Allowlist-by-Proof + global_quic_blocked.
function z2k_autopilot_quic(ctx, desync)
    if type(direction_cutoff_opposite) == "function" then
        direction_cutoff_opposite(ctx, desync, "out")
    end
    local dis = desync and desync.dis
    if not (desync and desync.outgoing and dis and dis.udp and (dis.ip or dis.ip6)) then
        return
    end
    if type(payload_check) == "function" then
        if not payload_check(desync, "quic_initial") then return end
    elseif desync.l7payload ~= "quic_initial" then
        return
    end

    observe_packet(desync)

    local entry, header, pol = z2k_autopilot_lookup_dis(dis)
    if not pol or not header then
        return
    end

    local arg = desync.arg or {}
    local host = desync.track and desync.track.hostname
    local is_gv_host = is_gv_or_play_hostname(host)
    local is_other_host = (type(host) == "string" and host ~= "" and not is_gv_host)

    local is_gv_target = false
    if arg.mode == "gv" then
        is_gv_target = true
    elseif is_gv_host then
        is_gv_target = true
    elseif not is_other_host and entry and (entry.kind == "google" or entry.kind == "isp" or entry.kind == "play") then
        is_gv_target = true
    end

    if is_gv_target and arg.yt ~= "0" then
        if entry and entry.quic_ok == 1 then
            return
        end
        dlog("z2k_autopilot_quic: reject QUIC Initial without quic_ok=1")
        return reject_quic_packet(ctx, desync)
    end

    if header.global_quic_blocked == 1 and arg.global ~= "0" then
        dlog("z2k_autopilot_quic: reject QUIC Initial (global_quic_blocked=1)")
        return reject_quic_packet(ctx, desync)
    end
end

local function build_tcp_rst_dis(is_v6, src_ip, dst_ip, sport, dport, seq, ack)
    local dis = {
        tcp = {
            th_sport = sport,
            th_dport = dport,
            th_seq = seq or 0,
            th_ack = ack or 0,
            th_flags = TCP_FLAG_RST + TCP_FLAG_ACK,
            th_win = 0,
        },
        payload = "",
    }
    if is_v6 then
        dis.ip6 = {
            ip6_flow = 0x60000000,
            ip6_nxt = 6,
            ip6_hlim = 64,
            ip6_src = src_ip,
            ip6_dst = dst_ip,
        }
    else
        dis.ip = {
            ip_v = 4,
            ip_hl = 5,
            ip_tos = 0,
            ip_id = next_ip4_id(),
            ip_off = 0,
            ip_ttl = 64,
            ip_p = 6,
            ip_src = src_ip,
            ip_dst = dst_ip,
        }
    end
    return dis
end

-- --lua-desync=z2k_autopilot_tcp_fastfail — Guard 2: мгновенный TCP RST,ACK (<1 мс).
function z2k_autopilot_tcp_fastfail(ctx, desync)
    local dis = desync and desync.dis
    if not (desync and desync.outgoing and dis and dis.tcp and (dis.ip or dis.ip6)) then
        return
    end
    local tcp = dis.tcp
    if band(tcp.th_flags, TCP_FLAG_SYN) == 0 or band(tcp.th_flags, TCP_FLAG_ACK) ~= 0 then
        return
    end

    local entry, header = z2k_autopilot_lookup_dis(dis)
    if not entry or not z2k_autopilot_safety_fuse(header) then
        return
    end
    if entry.kind ~= "google" and entry.kind ~= "isp" then
        return
    end
    if entry.verdict ~= "dead_l3" and entry.verdict ~= "dead_ggc" and entry.verdict ~= "bad_unbypassable" then
        return
    end

    local is_v6 = dis.ip6 ~= nil
    local cli_src = is_v6 and dis.ip6.ip6_src or dis.ip.ip_src
    local srv_dst = is_v6 and dis.ip6.ip6_dst or dis.ip.ip_dst
    if not prune_and_allow_rst(cli_src, clock_now()) then
        dlog("z2k_autopilot_tcp_fastfail: anti-storm skip RST")
        return
    end

    local rst_dis = build_tcp_rst_dis(
        is_v6,
        srv_dst,
        cli_src,
        tcp.th_dport,
        tcp.th_sport,
        0,
        add_u32(tcp.th_seq, 1)
    )
    local ifout = (desync.ifin and desync.ifin ~= "") and desync.ifin or nil
    if type(rawsend_dissect) == "function" then
        local ok = rawsend_dissect(rst_dis, { ifout = ifout })
        if ok then
            dlog("z2k_autopilot_tcp_fastfail: RST,ACK sent (" .. tostring(entry.kind) .. "/" .. tostring(entry.verdict) .. ")")
        else
            dlog("z2k_autopilot_tcp_fastfail: rawsend_dissect failed")
        end
    end

    if ctx and type(execution_plan_cancel) == "function" then
        pcall(execution_plan_cancel, ctx)
    end
    return V_DROP
end

local function flow_hex_key(dis, outgoing)
    local is_v6 = dis.ip6 ~= nil
    local src = is_v6 and dis.ip6.ip6_src or dis.ip.ip_src
    local dst = is_v6 and dis.ip6.ip6_dst or dis.ip.ip_dst
    local sport, dport = dis.tcp.th_sport, dis.tcp.th_dport
    if not outgoing then
        src, dst = dst, src
        sport, dport = dport, sport
    end
    local raw = src .. dst .. string.char(
        math.floor(sport / 256) % 256, sport % 256,
        math.floor(dport / 256) % 256, dport % 256
    )
    return raw:gsub(".", function(b) return string.format("%02x", b:byte()) end)
end

local function cancel_stall_timer(st)
    if not st or not st.timer_name then return end
    active_stall_timers[st.timer_name] = nil
    if type(timer_del) == "function" then
        timer_del(st.timer_name)
    end
    st.timer_name = nil
end

function z2k_autopilot_stall_timer(name, st)
    if not st or st.timer_name ~= name then return end
    active_stall_timers[name] = nil
    st.timer_name = nil
    if st.crec and st.crec.z2k_sg_done then return end
    if not st.armed then return end
    st.armed = false
    if st.crec then st.crec.z2k_sg_done = true end

    local pol = load_policy()
    local header = pol and pol.header
    if not z2k_autopilot_safety_fuse(header) then
        dlog("z2k_autopilot_stall_guard: safety fuse blocked RST")
        return
    end
    if not prune_and_allow_rst(st.cli_ip, clock_now()) then
        dlog("z2k_autopilot_stall_guard: anti-storm blocked RST")
        return
    end

    local cli_seq = st.cli_next_seq or 0
    local srv_seq = st.srv_next_seq or 0

    if type(rawsend_dissect) == "function" then
        local cli_rst = build_tcp_rst_dis(
            st.is_v6,
            st.srv_ip,
            st.cli_ip,
            st.srv_port,
            st.cli_port,
            srv_seq,
            cli_seq
        )
        local srv_rst = build_tcp_rst_dis(
            st.is_v6,
            st.cli_ip,
            st.srv_ip,
            st.cli_port,
            st.srv_port,
            cli_seq,
            srv_seq
        )
        rawsend_dissect(cli_rst, { ifout = st.cli_iface })
        rawsend_dissect(srv_rst, { ifout = st.srv_iface, fwmark = st.fwmark })
        dlog("z2k_autopilot_stall_guard: bidirectional RST sent after stall")
    end
end

-- --lua-desync=z2k_autopilot_stall_guard — Guard 4: сторож зависания ISP GGC после ServerHello.
function z2k_autopilot_stall_guard(_, desync)
    local dis = desync and desync.dis
    if not (dis and dis.tcp and (dis.ip or dis.ip6)) then
        return
    end

    observe_packet(desync)

    local crec = desync.track and desync.track.lua_state
    if not crec or crec.z2k_sg_done then
        return
    end

    local st = crec.z2k_sg
    if not st then
        local entry = z2k_autopilot_lookup_dis(dis)
        if not entry or entry.kind ~= "isp" then
            return
        end
        local is_v6 = dis.ip6 ~= nil
        local s_ip = is_v6 and dis.ip6.ip6_src or dis.ip.ip_src
        local d_ip = is_v6 and dis.ip6.ip6_dst or dis.ip.ip_dst
        local c_ip, r_ip, c_port, r_port
        if desync.outgoing then
            c_ip, r_ip = s_ip, d_ip
            c_port, r_port = dis.tcp.th_sport, dis.tcp.th_dport
        else
            c_ip, r_ip = d_ip, s_ip
            c_port, r_port = dis.tcp.th_dport, dis.tcp.th_sport
        end
        st = {
            key = flow_hex_key(dis, desync.outgoing),
            crec = crec,
            is_v6 = is_v6,
            cli_ip = c_ip,
            srv_ip = r_ip,
            cli_port = c_port,
            srv_port = r_port,
            saw_client_hello = false,
            saw_server_hello = false,
            armed = false,
        }
        crec.z2k_sg = st
    end

    if desync.outgoing then
        if desync.ifin and desync.ifin ~= "" then st.cli_iface = desync.ifin end
        if desync.ifout and desync.ifout ~= "" then st.srv_iface = desync.ifout end
        if desync.fwmark ~= nil then st.fwmark = desync.fwmark end
    else
        if desync.ifout and desync.ifout ~= "" then st.cli_iface = desync.ifout end
        if desync.ifin and desync.ifin ~= "" then st.srv_iface = desync.ifin end
    end

    local tcp = dis.tcp
    local plen = dis.payload and #dis.payload or 0
    local syn = band(tcp.th_flags, TCP_FLAG_SYN) ~= 0
    local fin = band(tcp.th_flags, TCP_FLAG_FIN) ~= 0
    local rst = band(tcp.th_flags, TCP_FLAG_RST) ~= 0
    local ack = band(tcp.th_flags, TCP_FLAG_ACK) ~= 0

    if desync.outgoing then
        local c_next = add_u32(tcp.th_seq, plen + (syn and 1 or 0) + (fin and 1 or 0))
        if not st.cli_next_seq or seq_ge_safe(c_next, st.cli_next_seq) then
            st.cli_next_seq = c_next
        end
        if ack and not st.srv_next_seq then
            st.srv_next_seq = tcp.th_ack
        end
    else
        local s_next = add_u32(tcp.th_seq, plen + (syn and 1 or 0) + (fin and 1 or 0))
        if not st.srv_next_seq or seq_ge_safe(s_next, st.srv_next_seq) then
            st.srv_next_seq = s_next
        end
        if ack and not st.cli_next_seq then
            st.cli_next_seq = tcp.th_ack
        end
    end

    if rst or fin then
        cancel_stall_timer(st)
        st.armed = false
        crec.z2k_sg_done = true
        return
    end

    if not desync.outgoing then
        if st.armed and plen > 0 then
            cancel_stall_timer(st)
            st.armed = false
            crec.z2k_sg_done = true
            return
        end
        if not st.saw_server_hello then
            if desync.l7payload == "tls_server_hello" or (st.saw_client_hello and plen > 0) then
                st.saw_server_hello = true
            end
        end
        return
    end

    if desync.l7payload == "tls_client_hello" then
        st.saw_client_hello = true
        return
    end

    if st.saw_server_hello and not st.armed and plen > 0 then
        local entry, header = z2k_autopilot_lookup_dis(dis)
        if not z2k_autopilot_safety_fuse(header) then
            return
        end
        local raw_ms = (entry and entry.stall_ms) or (header and header.ggc_stall_guard_ms) or DEFAULT_STALL_MS
        local stall_ms = clamp_num(math.floor(raw_ms), MIN_STALL_MS, MAX_STALL_MS)
        st.armed = true
        if type(timer_set) == "function" then
            st.timer_name = "z2k_sg_" .. st.key
            active_stall_timers[st.timer_name] = st
            timer_set(st.timer_name, "z2k_autopilot_stall_timer", stall_ms, true, st)
        end
    end
end

function z2k_autopilot_set_paths(pol, obs)
    override_policy_path = pol
    override_observed_path = obs
    policy_cache.loaded = false
    policy_cache.loaded_at = 0
    policy_cache.path = nil
    policy_cache.policy = nil
end

function z2k_autopilot_reset()
    policy_cache.loaded = false
    policy_cache.loaded_at = 0
    policy_cache.path = nil
    policy_cache.open_fn = nil
    policy_cache.policy = nil
    observed_seen = {}
    observed_seen_count = 0
    rst_history = {}
    for _, st in pairs(active_stall_timers) do
        cancel_stall_timer(st)
    end
    active_stall_timers = {}
end
