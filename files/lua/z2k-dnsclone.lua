-- z2k-dnsclone.lua
--
-- Действие dnsclone для профиля DNS по UDP 53 (референсный набор, один в один).
-- На исходящий запрос шлётся его клон с изменённым ID и малым TTL (аргумент
-- ttl): DPI его видит и отвечает подложным ответом, а до резолвера клон не
-- доходит. Подложный ответ с ID клона отбрасывается; с resend=1 оригинал
-- уходит заново через rawsend (вердикт исходного пакета — DROP). Аргументы:
-- ttl, ip_id, resend, mark (0 — не менять ID), drop_responses (0 — не
-- отбрасывать), pad (добавить нулевых байт), pending_max, pending_ttl.
-- Тело перенесено без изменений.
--
-- Грузится через --lua-init после zapret-lib.lua (deepcopy, apply_fooling,
-- apply_ip_id, rawsend_dissect_ipfrag, desync_opts). Порядок держит S99.
--
-- luacheck: globals dnsclone
-- luacheck: read globals clock_gettime

local Z2R_DNS_PENDING_MAX_DEF = 16
local Z2R_DNS_PENDING_TTL_MS_DEF = 2000

local function z2r_dns_state(desync)
    if not desync.track then
        return nil
    end

    desync.track.lua_state = desync.track.lua_state or {}
    local st = desync.track.lua_state.z2r_dns_clone
    if not st then
        st = { pending = {} }
        desync.track.lua_state.z2r_dns_clone = st
    end

    return st
end

local function z2r_now_ms()
    local sec, nsec = clock_gettime()
    if not sec then
        return nil
    end
    return sec * 1000 + math.floor(nsec / 1000000)
end

local function z2r_dns_get_id(payload)
    return payload:byte(1) * 256 + payload:byte(2)
end

local function z2r_dns_set_id(payload, id)
    return string.char(math.floor(id / 256) % 256, id % 256) .. payload:sub(3)
end

local function z2r_dns_is_response(payload)
    return payload:byte(3) >= 0x80
end

local function z2r_dns_pending_gc(st, now, ttlms)
    local i = 1
    while i <= #st.pending do
        if now and st.pending[i].t and now - st.pending[i].t > ttlms then
            table.remove(st.pending, i)
        else
            i = i + 1
        end
    end
end

local function z2r_dns_pending_add(st, id, now, max, ttlms)
    z2r_dns_pending_gc(st, now, ttlms)
    for i = 1, #st.pending do
        if st.pending[i].id == id then
            st.pending[i].t = now
            return
        end
    end
    table.insert(st.pending, { id = id, t = now })
    while #st.pending > max do
        table.remove(st.pending, 1)
    end
end

local function z2r_dns_pending_take(st, id, now, ttlms)
    z2r_dns_pending_gc(st, now, ttlms)
    for i = 1, #st.pending do
        if st.pending[i].id == id then
            table.remove(st.pending, i)
            return true
        end
    end
    return false
end

function dnsclone(ctx, desync)
    local dis = desync.dis
    if not dis or not dis.udp or not dis.payload or #dis.payload < 12 then
        return
    end

    local arg = desync.arg or {}
    local mark = arg.mark ~= "0"
    local drop_responses = arg.drop_responses ~= "0"
    local pending_max = tonumber(arg.pending_max) or Z2R_DNS_PENDING_MAX_DEF
    local pending_ttl = tonumber(arg.pending_ttl) or Z2R_DNS_PENDING_TTL_MS_DEF

    if not desync.outgoing then
        if arg.dir == "out" or not mark or not drop_responses then
            return
        end
        if not z2r_dns_is_response(dis.payload) then
            return
        end

        local st = z2r_dns_state(desync)
        if not st then
            return
        end

        local id = z2r_dns_get_id(dis.payload)
        if z2r_dns_pending_take(st, id, z2r_now_ms(), pending_ttl) then
            DLOG("dnsclone: dropping spoofed response id=" .. id)
            return VERDICT_DROP
        end
        return
    end

    if arg.dir == "in" or z2r_dns_is_response(dis.payload) then
        return
    end

    local st = z2r_dns_state(desync)
    local clone = deepcopy(dis)

    if mark then
        local orig_id = z2r_dns_get_id(dis.payload)
        local clone_id = orig_id >= 0x8000 and orig_id - 0x8000 or orig_id + 0x8000
        clone.payload = z2r_dns_set_id(dis.payload, clone_id)
        if st and drop_responses then
            z2r_dns_pending_add(st, clone_id, z2r_now_ms(), pending_max, pending_ttl)
        end
        DLOG("dnsclone: query clone id " .. orig_id .. " -> " .. clone_id)
    end

    local pad = tonumber(arg.pad) or 0
    if pad > 0 then
        clone.payload = clone.payload .. string.rep("\0", pad)
        if clone.udp.uh_ulen then
            clone.udp.uh_ulen = clone.udp.uh_ulen + pad
        end
    end

    if arg.ttl then
        arg.ip_ttl = arg.ip_ttl or arg.ttl
        arg.ip6_ttl = arg.ip6_ttl or arg.ttl
    end
    if not (arg.ip_ttl or arg.ip6_ttl or arg.ip_autottl or arg.ip6_autottl) then
        DLOG("dnsclone: warning - no ttl arguments, clone will reach the resolver")
    end

    apply_fooling(desync, clone)
    apply_ip_id(desync, clone, nil, "none")
    if not rawsend_dissect_ipfrag(clone, desync_opts(desync)) then
        DLOG("dnsclone: rawsend failed")
    end

    if arg.resend == "1" then
        local orig = deepcopy(dis)
        apply_ip_id(desync, orig, nil, "rnd")
        if not rawsend_dissect_ipfrag(orig, desync_opts(desync)) then
            DLOG("dnsclone: rawsend original failed")
        else
            DLOG("dnsclone: original resent via rawsend, dropping verdict packet")
        end
        return VERDICT_DROP
    end

    return
end

DLOG("dns-clone loaded")
