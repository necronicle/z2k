-- Bounded QUIC handshake observation (v1/v2). A Retry/Initial is progress,
-- not success. Only bidirectional short-header traffic ends this observation
-- successfully. This is a transport heuristic, not authenticated application
-- success. Unsupported versions use the native counters.
local WAIT_MS, MAX_MS = 5000, 15000
-- Пул QUIC стал общим и переименован (16.09.2026): yt_quic -> quic. Старые
-- имена оставлены намеренно — конфиг и lua едут разными файлами, и в окне
-- обновления живой демон может держать ещё старый ключ.
local POOLS = { quic = true, yt_quic = true, gv_quic = true }
local serial = 0

local function now_ms()
    return (type(clock_getfloattime) == "function" and clock_getfloattime() or os.time()) * 1000
end

local function varint(p, offset)
    local b = p:byte(offset)
    if not b then return nil end
    local size = 2 ^ math.floor(b / 64)
    if offset + size - 1 > #p then return nil end
    local value = b % 64
    for i = offset + 1, offset + size - 1 do value = value * 256 + p:byte(i) end
    return value, offset + size
end

local function packet(p, offset, short_cid)
    local first = p:byte(offset)
    if not first then return nil end
    if first < 128 then
        if not short_cid or #short_cid == 0 or #p - offset + 1 < 1 + #short_cid + 17 then return nil end
        if p:sub(offset + 1, offset + #short_cid) ~= short_cid then return nil end
        return { kind = "short" }, #p + 1
    end
    if #p - offset + 1 < 7 then return nil end
    local version = p:byte(offset+1) * 16777216 + p:byte(offset+2) * 65536
        + p:byte(offset+3) * 256 + p:byte(offset+4)
    local pos = offset + 5
    local dlen = p:byte(pos)
    if dlen > 20 or pos + dlen + 1 > #p then return nil end
    local dcid = p:sub(pos + 1, pos + dlen)
    pos = pos + dlen + 1
    local slen = p:byte(pos)
    if slen > 20 or pos + slen > #p then return nil end
    local scid = p:sub(pos + 1, pos + slen)
    pos = pos + slen + 1
    local kind
    if version == 0 then
        if #p - pos + 1 < 4 or (#p - pos + 1) % 4 ~= 0 then return nil end
        kind = "version"
    elseif version == 1 then
        kind = ({[0]="initial", "zero", "handshake", "retry"})[math.floor(first / 16) % 4]
    elseif version == 0x6b3343cf then
        kind = ({[0]="retry", "initial", "zero", "handshake"})[math.floor(first / 16) % 4]
    else
        return nil
    end
    if kind == "version" or kind == "retry" then
        if kind == "retry" and #p - pos + 1 < 17 then return nil end
        return { kind=kind, version=version, dcid=dcid, scid=scid }, #p + 1
    end
    if kind == "initial" then
        local token
        token, pos = varint(p, pos)
        if not token or token > #p - pos + 1 then return nil end
        pos = pos + token
    end
    local length
    length, pos = varint(p, pos)
    if not length or length < 17 or length > #p - pos + 1 then return nil end
    return { kind=kind, version=version, dcid=dcid, scid=scid }, pos + length
end

local function cancel(q)
    if type(timer_del) == "function" then timer_del(q.timer) end
end

local function arm(q, crec, hrec, arg)
    local delay = math.max(10, math.min(q.wait, q.deadline - now_ms()))
    timer_set(q.timer, "z2k_quic_silence_timer", math.floor(delay), true,
        { crec=crec, hrec=hrec, arg={fails=arg.fails, time=arg.time} })
end

function z2k_quic_silence_timer(_name, data)
    if not data or not data.crec or not data.hrec then return end
    -- Core validates the generation, terminal result and explicit final pin.
    circular_report_failure(data.hrec, data.crec, data.arg or {})
end

function z2k_fail_quic_silence(desync, crec)
    if not desync.dis or not desync.dis.udp or not POOLS[desync.arg.key]
        or type(circular_report_failure) ~= "function" then
        return standard_failure_detector(desync, crec)
    end
    if crec.quic_native then return standard_failure_detector(desync, crec) end
    local p = desync.dis.payload or ""
    local q = crec.quic_observation
    if not q then
        if not desync.outgoing or desync.l7payload ~= "quic_initial" then return false, "pending" end
        local initial = packet(p, 1)
        if not initial or initial.kind ~= "initial" then
            crec.quic_native = true
            return standard_failure_detector(desync, crec)
        end
        local wait = tonumber(desync.arg.quic_wait_ms) or WAIT_MS
        wait = math.max(1000, math.min(60000, wait))
        serial = serial + 1
        q = { version=initial.version, client_cid=initial.scid, server_cid=initial.dcid,
            phase=0, wait=wait, deadline=now_ms()+math.max(MAX_MS, wait*3), timer="z2kqs_"..serial }
        crec.quic_observation = q
        arm(q, crec, crec.host_record, desync.arg)
    end

    local previous, offset, count = q.phase, 1, 0
    while offset <= #p and count < 8 do
        local expected = desync.outgoing and q.server_cid or q.client_cid
        local h, next_offset = packet(p, offset, expected)
        if not h then break end
        count = count + 1
        if h.kind == "short" and q.phase >= 2 then
            if desync.outgoing then q.out_short = true else q.in_short = true end
            q.phase = math.max(q.phase, 4)
        elseif desync.outgoing and h.kind == "initial" then
            q.version, q.client_cid = h.version, h.scid
        elseif not desync.outgoing and h.dcid == q.client_cid then
            if h.kind == "version" then
                q.phase = math.max(q.phase, 1)
            elseif h.version == q.version then
                q.server_cid = h.scid
                if h.kind == "retry" then q.phase = math.max(q.phase, 1)
                elseif h.kind == "initial" then q.phase = math.max(q.phase, 2)
                elseif h.kind == "handshake" then q.phase = math.max(q.phase, 3) end
            end
        end
        offset = next_offset
    end
    if q.in_short and q.out_short then
        cancel(q)
        return false, "success"
    end
    -- Once either intercepted direction ends, completion can happen outside
    -- Lua's view. A later timer would mistake lost visibility for a failure.
    local limit = tonumber(desync.outgoing and desync.arg.quic_out_limit or desync.arg.quic_in_limit) or 8
    if limit > 0 and pos_get(desync, 'n') >= limit then
        cancel(q)
        return false, "neutral"
    end
    if q.phase > previous then arm(q, crec, crec.host_record, desync.arg) end
    -- Repeated Initials/Retry and arbitrary UDP replies cannot perpetually
    -- extend the deadline or trigger the native two-datagram success shortcut.
    return false, "pending"
end
