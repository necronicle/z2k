-- Early TCP failures beyond the standard RST/retransmission detector.
-- No host-liveness veto, TTL attribution or incoming-retransmission heuristic.
-- circular owns attempt identity, terminal results, rotation and optional RST.
-- The second return value is part of the fork's detector contract:
-- pending = keep observing; neutral = stop without changing the host counter.

local RESPONSE_LIMIT = 4096
local REQUEST_LIMIT = 32768
local BLOCK_PORTALS = {
    ["eais.rkn.gov.ru"] = true,
    ["lawfilter.ertelecom.ru"] = true,
    ["blackhole.svyaztelecom.ru"] = true,
    ["warning.rt.ru"] = true,
    ["warn.beeline.ru"] = true,
    ["deny.megafon.ru"] = true,
}

local function body_marker(body)
    local low = body:lower()
    for domain in pairs(BLOCK_PORTALS) do
        -- A complete hostname, not rkn inside SparkNotes or a URL suffix.
        if (" " .. low .. " "):find("[^%w_.%-]" .. domain:gsub("%.", "%%.") .. "[^%w_.%-]") then
            return domain
        end
    end
    -- Specific block-page wording; individual words are not signatures.
    if low:find("access blocked by rkn", 1, true) then return "blocked_by_rkn" end
end

local function location_host(value)
    if not value then return nil end
    local authority = value:match("^%s*[Hh][Tt][Tt][Pp][Ss]?://([^/%s?#]+)")
        or value:match("^%s*//([^/%s?#]+)")
    if not authority then return nil end
    authority = authority:match("([^@]+)$")
    return authority:gsub(":%d+$", ""):gsub("%.$", ""):lower()
end

function z2k_classify_http_reply(desync)
    if not desync or desync.outgoing or desync.l7payload ~= "http_reply" then return nil end
    local p = desync.dis and desync.dis.payload
    if type(p) ~= "string" then return nil end
    local code = tonumber(p:match("^HTTP/1%.[01]%s+(%d%d%d)%s"))
    if not code then return nil end
    local split = p:find("\r\n\r\n", 1, true)
    if not split then return "neutral", "incomplete_headers" end
    local headers, body = p:sub(1, split + 1):lower(), p:sub(split + 4)
    if code >= 400 and code < 600 then
        -- Compressed bodies cannot be classified by plaintext substring scans.
        local encoding = headers:match("\r\ncontent%-encoding:%s*([^\r\n]+)")
        if encoding and encoding ~= "identity" then return "neutral", "encoded_body" end
        local marker = body_marker(body)
        if marker then return "hard_fail", "http_block_portal:" .. marker end
        return "neutral", "http_error_without_signature"
    end
    if code >= 200 and code < 300 or code == 304 then return "positive" end
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        local location = p:match("\r\n[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[ \t]*([^\r\n]+)")
        local target = location_host(location)
        if target and BLOCK_PORTALS[target] then return "hard_fail", "http_redirect_portal:" .. target end
        if location and location:match("^/[^/]") then return "positive" end
        local host = desync.track and desync.track.hostname
        if target and host and target == host:lower():gsub(":%d+$", ""):gsub("%.$", "") then return "positive" end
        -- A cross-domain redirect is ordinary navigation, not proof of DPI.
        return "neutral", "http_redirect"
    end
    return "neutral", "http_other_status"
end

-- Bounded prefix reassembly. Handles gaps, retransmissions and matching
-- overlaps. Conflicting overlaps are inconclusive, never a block signature.
local function prefix_add(state, seq, payload, limit)
    if state.bad then return false end
    if seq < 1 or seq > limit or #payload == 0 then return true end
    payload = payload:sub(1, limit - seq + 1)
    local data = state.data or ""
    local overlap = math.min(#payload, #data - seq + 1)
    if overlap > 0 and data:sub(seq, seq + overlap - 1) ~= payload:sub(1, overlap) then
        state.bad = true
        return false
    end
    if seq <= #data + 1 then
        if seq + #payload - 1 > #data then state.data = data .. payload:sub(#data - seq + 2) end
    else
        state.parts = state.parts or {}
        state.bytes = (state.bytes or 0) + #payload
        if #state.parts >= 16 or state.bytes > limit * 2 then state.bad = true; return false end
        state.parts[#state.parts + 1] = { seq, payload }
    end
    local changed = true
    while changed and state.parts do
        changed = false
        for i = #state.parts, 1, -1 do
            local part = state.parts[i]
            if part[1] <= #(state.data or "") + 1 then
                table.remove(state.parts, i)
                state.bytes = state.bytes - #part[2]
                if not prefix_add(state, part[1], part[2], limit) then return false end
                changed = true
                break
            end
        end
    end
    return true
end

local function record_length(p)
    if #p < 5 or p:byte(2) ~= 3 or p:byte(3) > 3 then return nil end
    return p:byte(4) * 256 + p:byte(5)
end

-- Opt-in recovery for one updater which can wait indefinitely after its
-- ClientHello was ACKed. No inference about established/application traffic.
local discord_tls_serial = 0
local function discord_tls_now()
    return clock_getfloattime()
end

local function discord_tls_cancel(crec)
    local q = crec.discord_tls
    if not q then return end
    q.done = true
    timer_del(q.name)
    if q.budget.pending == q then q.budget.pending = nil end
end

function z2k_discord_tls_timer(_name, data)
    local c, h, q = data.crec, data.hrec, data.observation
    if q.done then return end
    discord_tls_cancel(c)
    if c.nocheck or c.failure or q.lua_state.automate ~= c then return end
    -- The core reconciles operator edits and checks the attempt generation,
    -- final pin and quorum before accepting this one connection's failure.
    circular_report_failure(h, c, data.arg)
    if not c.failure then return end
    q.budget.used = q.budget.used + 1
    DLOG("discord TLS: ACKed ClientHello timed out; retry " .. q.budget.used .. "/6")
    -- Use the server's last ACK headers: sequence = client's RCV.NXT, so
    -- this is an acceptable reset, rather than an out-of-window challenge.
    local ok, sent = pcall(rawsend_dissect, q.reset, q.options)
    if not ok or not sent then DLOG_ERR("discord TLS: could not reset stalled client") end
end

local function discord_tls_observe(desync, crec)
    local arg, dis = desync.arg, desync.dis
    local q, h = crec.discord_tls, crec.host_record
    if arg.discord_tls_timeout ~= "1" or not arg.reset or arg.key ~= "rkn_tcp"
        or not desync.track or desync.track.hostname ~= "updates.discord.com"
        or arg.hostkey ~= "z2k_service_hostkey" or not h
        or type(circular_report_failure) ~= "function"
        or type(timer_set) ~= "function" or type(timer_del) ~= "function"
        or type(clock_getfloattime) ~= "function" then return end
    if q and q.done then return end
    local p, tcp = dis.payload or "", dis.tcp
    if (desync.outgoing and tcp.th_dport or tcp.th_sport) ~= 443 then return end
    local count = pos_get(desync, 'n')
    local limit = tonumber(desync.outgoing and arg.discord_tls_out_limit or arg.discord_tls_in_limit)
    -- At the capture boundary a reply could become invisible. Stop observing.
    if not count or not limit or count >= limit
        or bitand(tcp.th_flags, TH_SYN + TH_FIN + TH_RST) ~= 0
        or (not desync.outgoing and #p > 0) then
        if q then discord_tls_cancel(crec) end
        return
    end
    if desync.outgoing then
        if q then
            if #p > 0 and pos_get(desync, 's') >= crec.request_end then discord_tls_cancel(crec) end
            return
        end
        if desync.l7payload ~= "tls_client_hello" or crec.request_start ~= 1
            or not crec.request_end or type(tcp.th_seq) ~= "number"
            or type(tcp.th_ack) ~= "number" or bitand(tcp.th_flags, TH_ACK) == 0
            or crec.server_hello or crec.http_started or crec.response_prefix
            or h.final == h.nstrategy then return end
        -- ACKing one TLS record does not necessarily ACK the entire handshake:
        -- leave ClientHellos split across TLS records to the native detector.
        local hello = desync.reasm_data or p
        if #hello < 9 or hello:byte(6) ~= 1 then return end
        local hello_length = hello:byte(7)*65536 + hello:byte(8)*256 + hello:byte(9)
        if #hello < hello_length + 9 or record_length(hello) ~= hello_length + 4 then return end
        local now = discord_tls_now()
        local b = h.discord_tls_budget
        if not b then b = { started=now, used=0 }; h.discord_tls_budget = b end
        if b.pending then return end
        if now - b.started >= 300 then b.started, b.used = now, 0 end
        if b.used >= 6 then return end
        discord_tls_serial = discord_tls_serial + 1
        q = { name="z2kdt_"..discord_tls_serial, budget=b, lua_state=desync.track.lua_state,
            server_seq=tcp.th_ack,
            request_end=(tcp.th_seq + crec.request_end - crec.request_start) % 4294967296 }
        crec.discord_tls, b.pending = q, q
        -- Start the deadline at ClientHello, but never reset unless the entire
        -- request was ACKed. This also bounds the lifetime of an unACKed watch.
        timer_set(q.name, function(name, data)
            if not q.reset then discord_tls_cancel(crec); return end
            z2k_discord_tls_timer(name, data)
        end, 10000, true, { crec=crec, hrec=h, observation=q,
            arg={fails=arg.fails, time=arg.time} })
    elseif q and bitand(tcp.th_flags, TH_ACK) ~= 0
        and type(tcp.th_ack) == "number" and type(tcp.th_seq) == "number"
        and tcp.th_ack == q.request_end and tcp.th_seq == q.server_seq then
        q.reset = deepcopy(dis)
        q.reset.payload = nil
        q.reset.tcp.th_flags, q.reset.tcp.th_win = TH_RST, 0
        q.reset.tcp.options = nil
        q.options = rawsend_opts_base(desync)
    end
end

local function first_request(desync, crec)
    local p, seq = desync.dis.payload or "", pos_get(desync, 's')
    if not crec.request_start then
        if desync.l7payload ~= "tls_client_hello" and desync.l7payload ~= "http_req" then return end
        crec.request_start = seq
        crec.request_kind = desync.l7payload
        if crec.request_kind == "tls_client_hello" then
            local len = record_length(desync.reasm_data or p)
            if len and len + 5 <= REQUEST_LIMIT then crec.request_end = seq + len + 5 end
        else
            crec.request_prefix = {}
        end
    end
    if crec.request_prefix then
        local start = seq - crec.request_start + 1
        if not prefix_add(crec.request_prefix, start, p, RESPONSE_LIMIT) then
            crec.request_prefix = nil
            return
        end
        local data = crec.request_prefix.data or ""
        local boundary = data:find("\r\n\r\n", 1, true)
        crec.request_end = crec.request_start + (boundary and boundary + 3 or #data)
        if boundary or #data >= RESPONSE_LIMIT then crec.request_prefix = nil end
    end
end

local function native_failure(desync, crec)
    -- Old engines may still send RST inside standard_failure_detector. Clear
    -- reset in this call; the new dispatcher uses the original arg only after
    -- accepting the result. Never run the broad cross-domain redirect heuristic.
    local copy, arg = {}, {}
    for k, v in pairs(desync) do copy[k] = v end
    for k, v in pairs(desync.arg) do arg[k] = v end
    arg.reset, arg.no_http_redirect = nil, true
    copy.arg = arg
    return standard_failure_detector(copy, crec)
end

local function http_response(desync, crec, state)
    local data = state.data or ""
    local boundary = data:find("\r\n\r\n", 1, true)
    if not boundary then
        if #data >= RESPONSE_LIMIT then return false, "neutral" end
        return false, "pending"
    end
    local packet = { outgoing = false, l7payload = "http_reply", track = desync.track, dis = { payload = data } }
    local class = z2k_classify_http_reply(packet)
    if class == "hard_fail" then return true end
    if class == "positive" then return false, "success" end
    local code = tonumber(data:match("^HTTP/1%.[01]%s+(%d%d%d)%s"))
    if not code or code < 400 or code >= 600 then return false, "neutral" end
    local header = data:sub(1, boundary + 1):lower()
    local length = tonumber(header:match("\r\ncontent%-length:%s*(%d+)%s*\r\n"))
    if #data >= RESPONSE_LIMIT or (length and #data - boundary - 3 >= length)
        or header:find("\r\ncontent%-encoding:", 1, false) then
        return false, "neutral"
    end
    -- No length (or chunked): inspect only the bounded prefix, until EOF/cap.
    return false, "pending"
end

local function tls_response(crec, state)
    local data, offset = state.data or "", 1
    if #data - offset + 1 >= 5 then
        local record = data:sub(offset)
        local len = record_length(record)
        if not len or len == 0 or len > 18432 then return false, "neutral" end
        local kind = record:byte(1)
        if kind == 22 then
            if #record < 9 then return false, "pending" end
            local handshake_len = record:byte(7) * 65536 + record:byte(8) * 256 + record:byte(9)
            if record:byte(6) == 2 and len >= 4 and handshake_len >= 38 then
                crec.server_hello = true
                crec.response_prefix = nil
                return false -- only normal byte-progress success from here on
            end
            return false, "neutral"
        elseif kind == 21 then
            if len ~= 2 then return false, "neutral" end
            if #record < 7 then return false, "pending" end
            if record:byte(6) == 2 and record:byte(7) ~= 0 then
                DLOG("z2k_fail_tls_alert: plaintext fatal alert " .. record:byte(7))
                return true
            end
            return false, "neutral"
        elseif kind == 20 or kind == 23 then
            -- Cannot interpret protected records as plaintext alerts, including
            -- TLS 1.2 abbreviated handshakes. No guessed ciphertext severity.
            return false, "neutral"
        else
            return false, "neutral"
        end
    end
    return false, "pending"
end

function z2k_fail_tls_alert(desync, crec)
    if not crec or not desync.dis or not desync.dis.tcp then return false end
    local p, flags = desync.dis.payload or "", desync.dis.tcp.th_flags
    if desync.outgoing then
        first_request(desync, crec)
        discord_tls_observe(desync, crec)
        local seq = pos_get(desync, 's')
        if crec.request_end and not crec.server_hello and not crec.http_started
            and seq >= crec.request_start and seq < crec.request_end then
            return native_failure(desync, crec)
        end
        return false
    end
    discord_tls_observe(desync, crec)
    -- RST is a transport failure within the native window, regardless of TTL.
    if bitand(flags, TH_RST) ~= 0 then return native_failure(desync, crec) end
    if crec.server_hello then return false end
    if #p == 0 then
        if bitand(flags, TH_FIN) ~= 0 and crec.response_prefix then return false, "neutral" end
        return false
    end
    local http = crec.request_kind == "http_req" or desync.arg.key == "http_rkn" or desync.l7payload == "http_reply"
    crec.http_started = http or nil
    crec.response_prefix = crec.response_prefix or {}
    local state = crec.response_prefix
    if not prefix_add(state, pos_get(desync, 's'), p, RESPONSE_LIMIT) then
        crec.response_prefix = nil
        return false, "neutral"
    end
    local failed, outcome
    if http then failed, outcome = http_response(desync, crec, state)
    else failed, outcome = tls_response(crec, state) end
    if failed or outcome == "neutral" or outcome == "success" then crec.response_prefix = nil end
    return failed, outcome
end
