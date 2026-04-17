-- z2k-modern-core.lua
-- Core-level desync extensions for z2k:
-- 1) custom 3-fragment IP fragmenters (with optional overlap)
-- 2) QUIC Initial packet morphing (timing/fingerprint)
-- 3) UDP fake-injection handler for games (z2k_game_udp)
--
-- Trimmed 2026-04-18: removed z2k_tls_extshuffle, z2k_tls_fp_pack_v2,
-- z2k_tcpoverlap3, z2k_ech_passthrough, z2k_strategy_profile. None of
-- these were referenced from any strategy, init script or test — they
-- were ~400 lines of dead bytecode living in every nfqws2 Lua VM. Also
-- dropped their private helpers (z2k_tls_ext_is_fixed, z2k_shuffle,
-- z2k_shuffle_range, z2k_overlap_state, z2k_parse_order3,
-- z2k_resolve_marker_pos). Can be restored from git if a future
-- strategy actually wants them.

-- Seed PRNG with better entropy when available
do
    local seed = os.time() or 0
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(4)
        f:close()
        if bytes and #bytes == 4 then
            seed = seed + bytes:byte(1) + bytes:byte(2) * 256 +
                   bytes:byte(3) * 65536 + bytes:byte(4) * 16777216
        end
    end
    math.randomseed(seed)
end

-- Fallback stubs for nfqws2 runtime globals (prevents crash if loaded standalone)
if type(DLOG) ~= "function" then DLOG = function() end end
if type(DLOG_ERR) ~= "function" then DLOG_ERR = function() end end

local function z2k_num(v, fallback)
    local n = tonumber(v)
    if n == nil then return fallback end
    -- Clamp to safe range for bit operations and array indexing
    if n > 2147483647 then n = 2147483647 end
    if n < -2147483648 then n = -2147483648 end
    return n
end

local function z2k_align8(v)
    local n = math.floor(z2k_num(v, 0))
    if n < 0 then n = 0 end
    return bitand(n, NOT7)
end

local function z2k_frag_idx(exthdr)
    if exthdr then
        local first_destopts
        for i = 1, #exthdr do
            if exthdr[i].type == IPPROTO_DSTOPTS then
                first_destopts = i
                break
            end
        end
        for i = #exthdr, 1, -1 do
            if exthdr[i].type == IPPROTO_HOPOPTS or
               exthdr[i].type == IPPROTO_ROUTING or
               (exthdr[i].type == IPPROTO_DSTOPTS and i == first_destopts) then
                return i + 1
            end
        end
    end
    return 1
end

local function z2k_ipfrag3_params(dis, ipfrag_options, totalfrag)
    local pos1
    if dis.tcp then
        pos1 = z2k_num(ipfrag_options.ipfrag_pos_tcp, 32)
    elseif dis.udp then
        pos1 = z2k_num(ipfrag_options.ipfrag_pos_udp, 8)
    elseif dis.icmp then
        pos1 = z2k_num(ipfrag_options.ipfrag_pos_icmp, 8)
    else
        pos1 = z2k_num(ipfrag_options.ipfrag_pos, 32)
    end

    local span = z2k_num(ipfrag_options.ipfrag_span, 24)
    local pos2 = z2k_num(ipfrag_options.ipfrag_pos2, pos1 + span)
    local ov12 = z2k_num(ipfrag_options.ipfrag_overlap12, 0)
    local ov23 = z2k_num(ipfrag_options.ipfrag_overlap23, 0)

    pos1 = z2k_align8(pos1)
    pos2 = z2k_align8(pos2)
    ov12 = z2k_align8(ov12)
    ov23 = z2k_align8(ov23)

    if pos1 < 8 then pos1 = 8 end
    if pos2 <= pos1 then pos2 = pos1 + 8 end
    if pos2 >= totalfrag then pos2 = z2k_align8(totalfrag - 8) end
    if pos2 <= pos1 then return nil end

    if ov12 > (pos1 - 8) then ov12 = pos1 - 8 end
    if ov23 > (pos2 - 8) then ov23 = pos2 - 8 end

    local off2 = pos1 - ov12
    local off3 = pos2 - ov23

    if off2 < 0 then off2 = 0 end
    if off3 <= off2 then off3 = off2 + 8 end
    if off3 >= totalfrag then off3 = z2k_align8(totalfrag - 8) end
    if off3 <= off2 or off3 >= totalfrag then return nil end

    local len1 = pos1
    local len2 = pos2 - off2
    local len3 = totalfrag - off3
    if len1 <= 0 or len2 <= 0 or len3 <= 0 then return nil end

    return len1, off2, len2, off3, len3
end

-- option : ipfrag_pos_tcp / ipfrag_pos_udp / ipfrag_pos_icmp / ipfrag_pos
-- option : ipfrag_pos2 - second split position (bytes, multiple of 8)
-- option : ipfrag_span - used when ipfrag_pos2 is omitted (default 24)
-- option : ipfrag_overlap12 - overlap between fragment 1 and 2 (bytes, multiple of 8)
-- option : ipfrag_overlap23 - overlap between fragment 2 and 3 (bytes, multiple of 8)
-- option : ipfrag_next2 / ipfrag_next3 - IPv6 "next" field override for fragment #2/#3
function z2k_ipfrag3(dis, ipfrag_options)
    DLOG("z2k_ipfrag3")
    if not dis or not (dis.ip or dis.ip6) then
        return nil
    end

    ipfrag_options = ipfrag_options or {}
    local l3 = l3_len(dis)
    local plen = l3 + l4_len(dis) + #dis.payload
    local totalfrag = plen - l3
    if totalfrag <= 24 then
        DLOG("z2k_ipfrag3: packet too short for 3 fragments")
        return nil
    end

    local len1, off2, len2, off3, len3 = z2k_ipfrag3_params(dis, ipfrag_options, totalfrag)
    if not len1 then
        DLOG("z2k_ipfrag3: invalid split params")
        return nil
    end

    if dis.ip then
        local ip_id = dis.ip.ip_id == 0 and math.random(1, 0xFFFF) or dis.ip.ip_id

        local d1 = deepcopy(dis)
        d1.ip.ip_len = l3 + len1
        d1.ip.ip_off = IP_MF
        d1.ip.ip_id = ip_id

        local d2 = deepcopy(dis)
        d2.ip.ip_len = l3 + len2
        d2.ip.ip_off = bitor(bitrshift(off2, 3), IP_MF)
        d2.ip.ip_id = ip_id

        local d3 = deepcopy(dis)
        d3.ip.ip_len = l3 + len3
        d3.ip.ip_off = bitrshift(off3, 3)
        d3.ip.ip_id = ip_id

        return { d1, d2, d3 }
    end

    if dis.ip6 then
        local idxfrag = z2k_frag_idx(dis.ip6.exthdr)
        local l3extra_before_frag = l3_extra_len(dis, idxfrag - 1)
        local l3_local = l3_base_len(dis) + l3extra_before_frag
        local totalfrag6 = plen - l3_local
        if totalfrag6 <= 24 then
            DLOG("z2k_ipfrag3: ipv6 packet too short for 3 fragments")
            return nil
        end

        local p1, p2, p3, p4, p5 = z2k_ipfrag3_params(dis, ipfrag_options, totalfrag6)
        if not p1 then
            DLOG("z2k_ipfrag3: invalid ipv6 split params")
            return nil
        end
        len1, off2, len2, off3, len3 = p1, p2, p3, p4, p5

        local l3extra_with_frag = l3extra_before_frag + 8
        local ident = math.random(1, 0xFFFFFFFF)

        local d1 = deepcopy(dis)
        insert_ip6_exthdr(d1.ip6, idxfrag, IPPROTO_FRAGMENT, bu16(IP6F_MORE_FRAG) .. bu32(ident))
        d1.ip6.ip6_plen = l3extra_with_frag + len1

        local d2 = deepcopy(dis)
        insert_ip6_exthdr(d2.ip6, idxfrag, IPPROTO_FRAGMENT, bu16(bitor(off2, IP6F_MORE_FRAG)) .. bu32(ident))
        if ipfrag_options.ipfrag_next2 then
            d2.ip6.exthdr[idxfrag].next = tonumber(ipfrag_options.ipfrag_next2)
        end
        d2.ip6.ip6_plen = l3extra_with_frag + len2

        local d3 = deepcopy(dis)
        insert_ip6_exthdr(d3.ip6, idxfrag, IPPROTO_FRAGMENT, bu16(off3) .. bu32(ident))
        if ipfrag_options.ipfrag_next3 then
            d3.ip6.exthdr[idxfrag].next = tonumber(ipfrag_options.ipfrag_next3)
        end
        d3.ip6.ip6_plen = l3extra_with_frag + len3

        return { d1, d2, d3 }
    end

    return nil
end

-- Tiny overlap profile for z2k_ipfrag3.
function z2k_ipfrag3_tiny(dis, ipfrag_options)
    local opts = deepcopy(ipfrag_options or {})
    if opts.ipfrag_overlap12 == nil then opts.ipfrag_overlap12 = 8 end
    if opts.ipfrag_overlap23 == nil then opts.ipfrag_overlap23 = 8 end
    if opts.ipfrag_pos2 == nil then
        local p1
        if dis.tcp then
            p1 = z2k_num(opts.ipfrag_pos_tcp, 32)
        elseif dis.udp then
            p1 = z2k_num(opts.ipfrag_pos_udp, 8)
        elseif dis.icmp then
            p1 = z2k_num(opts.ipfrag_pos_icmp, 8)
        else
            p1 = z2k_num(opts.ipfrag_pos, 32)
        end
        opts.ipfrag_pos2 = p1 + 24
    end
    return z2k_ipfrag3(dis, opts)
end

local function z2k_clamp(v, lo, hi, fallback)
    local n = tonumber(v)
    if n == nil then n = fallback end
    if n < lo then n = lo end
    if n > hi then n = hi end
    return n
end

local function z2k_rand_between(a, b)
    local x = tonumber(a) or 0
    local y = tonumber(b) or x
    if y < x then
        x, y = y, x
    end
    return math.random(x, y)
end

local function z2k_payload_pad(payload, pad_min, pad_max)
    local p = payload or ""
    local n = z2k_rand_between(pad_min, pad_max)
    if n <= 0 then
        return p
    end
    return p .. string.rep("\0", n)
end

local z2k_unpack = table.unpack or unpack

local function z2k_quic_reserved_version_bytes()
    -- RFC-reserved grease-like pattern: 0x?a?a?a?a
    local b1 = bitor(bitlshift(math.random(0, 15), 4), 0x0A)
    local b2 = bitor(bitlshift(math.random(0, 15), 4), 0x0A)
    local b3 = bitor(bitlshift(math.random(0, 15), 4), 0x0A)
    local b4 = bitor(bitlshift(math.random(0, 15), 4), 0x0A)
    return b1, b2, b3, b4
end

local function z2k_qvarint_decode_bytes(bytes, pos, nbytes)
    if type(bytes) ~= "table" then
        return nil, nil
    end
    local b0 = bytes[pos]
    if not b0 then
        return nil, nil
    end
    local pref = bitrshift(b0, 6)
    local len = 1
    if pref == 1 then
        len = 2
    elseif pref == 2 then
        len = 4
    elseif pref == 3 then
        len = 8
    end
    if (pos + len - 1) > (nbytes or #bytes) then
        return nil, nil
    end
    local v = bitand(b0, 0x3F)
    for i = 2, len do
        v = (v * 256) + (bytes[pos + i - 1] or 0)
    end
    return v, len
end

local function z2k_qvarint_encode_bytes(value, force_len)
    local v = tonumber(value) or 0
    if v < 0 then v = 0 end
    local len = tonumber(force_len)
    if not len then
        if v < 64 then
            len = 1
        elseif v < 16384 then
            len = 2
        elseif v < 1073741824 then
            len = 4
        else
            len = 8
        end
    end
    if len ~= 1 and len ~= 2 and len ~= 4 and len ~= 8 then
        return nil, nil
    end

    local maxv = 63
    if len == 2 then
        maxv = 16383
    elseif len == 4 then
        maxv = 1073741823
    elseif len == 8 then
        maxv = 4611686018427387903
    end
    if v > maxv then v = maxv end

    local out = {}
    for i = len, 1, -1 do
        out[i] = v % 256
        v = math.floor(v / 256)
    end
    local pref = 0
    if len == 2 then
        pref = bitlshift(1, 6)
    elseif len == 4 then
        pref = bitlshift(2, 6)
    elseif len == 8 then
        pref = bitlshift(3, 6)
    end
    out[1] = bitor(out[1] or 0, pref)
    return out, len
end

local function z2k_quic_randomize_range(bytes, pos, count)
    if not bytes or not pos or not count or count <= 0 then
        return
    end
    local n = #bytes
    local p = tonumber(pos) or 1
    local c = tonumber(count) or 0
    if p < 1 then p = 1 end
    if p > n then return end
    local pend = p + c - 1
    if pend > n then pend = n end
    for i = p, pend do
        bytes[i] = math.random(0, 255)
    end
end

local function z2k_quic_morph_payload(payload, arg)
    if type(payload) ~= "string" then
        return payload
    end
    local n = #payload
    if n < 12 then
        return payload
    end

    local b = { string.byte(payload, 1, n) }
    local h1 = b[1]
    -- Only long-header QUIC packets are handled here.
    if not h1 or bitand(h1, 0x80) == 0 then
        return payload
    end

    local version_chance = z2k_clamp(arg.version_chance, 0, 100, 35)
    local cid_chance = z2k_clamp(arg.cid_chance, 0, 100, 80)
    local token_chance = z2k_clamp(arg.token_chance, 0, 100, 60)
    local token_fill_chance = z2k_clamp(arg.token_fill_chance, 0, 100, 35)
    local token_fill_len = z2k_clamp(arg.token_fill_len, 1, 8, 1)

    if version_chance > 0 and math.random(100) <= version_chance and n >= 5 then
        local v1, v2, v3, v4 = z2k_quic_reserved_version_bytes()
        b[2], b[3], b[4], b[5] = v1, v2, v3, v4
    end

    local pos = 6
    if pos > #b then
        return string.char(z2k_unpack(b))
    end

    local dcid_len = b[pos] or 0
    pos = pos + 1
    if dcid_len < 0 then dcid_len = 0 end
    if (pos + dcid_len - 1) > #b then
        return string.char(z2k_unpack(b))
    end
    if dcid_len > 0 and cid_chance > 0 and math.random(100) <= cid_chance then
        z2k_quic_randomize_range(b, pos, dcid_len)
    end
    pos = pos + dcid_len

    if pos > #b then
        return string.char(z2k_unpack(b))
    end
    local scid_len = b[pos] or 0
    pos = pos + 1
    if scid_len < 0 then scid_len = 0 end
    if (pos + scid_len - 1) > #b then
        return string.char(z2k_unpack(b))
    end
    if scid_len > 0 and cid_chance > 0 and math.random(100) <= cid_chance then
        z2k_quic_randomize_range(b, pos, scid_len)
    end
    pos = pos + scid_len

    if pos > #b then
        return string.char(z2k_unpack(b))
    end
    local token_len, token_vlen = z2k_qvarint_decode_bytes(b, pos, #b)
    if token_len == nil then
        return string.char(z2k_unpack(b))
    end
    local token_pos = pos + token_vlen
    local token_end = token_pos + token_len - 1

    if token_len > 0 then
        if token_end <= #b and token_chance > 0 and math.random(100) <= token_chance then
            z2k_quic_randomize_range(b, token_pos, token_len)
        end
    elseif token_fill_chance > 0 and math.random(100) <= token_fill_chance then
        -- Token fill for empty-token Initial packets.
        -- Conservative path: only 1-byte token length varint is expanded.
        if token_vlen == 1 and token_fill_len < 64 then
            local enc, enc_len = z2k_qvarint_encode_bytes(token_fill_len, 1)
            if enc and enc_len == 1 then
                b[pos] = enc[1]
                for i = 1, token_fill_len do
                    table.insert(b, token_pos + i - 1, math.random(0, 255))
                end

                -- Token expanded; QUIC Initial Length field does NOT need adjustment
                -- because it only covers Packet Number and Payload lengths.
            end
        end
    end

    return string.char(z2k_unpack(b))
end

local function z2k_rawsend_ctx(desync, repeats)
    local arg = desync and desync.arg or {}
    return {
        repeats = repeats or 1,
        ifout = arg.ifout or desync.ifout,
        fwmark = arg.fwmark or desync.fwmark
    }
end

local function z2k_timing_state(desync)
    if not desync or not desync.track then
        return nil, nil
    end
    local st = desync.track.lua_state
    if type(st) ~= "table" then
        return nil, nil
    end
    local key = "__z2k_tm_" .. tostring(desync.func_instance or "z2k_timing_morph")
    local rec = st[key]
    if type(rec) ~= "table" then
        rec = {
            out_seen = 0,
            drops = 0,
            dropped_seq = {}
        }
        st[key] = rec
    end
    return st, rec
end

local function z2k_quic_state(desync)
    if not desync or not desync.track then
        return nil
    end
    local st = desync.track.lua_state
    if type(st) ~= "table" then
        return nil
    end
    local key = "__z2k_qmv2_" .. tostring(desync.func_instance or "z2k_quic_morph_v2")
    local rec = st[key]
    if type(rec) ~= "table" then
        rec = { out_seen = 0, profile = 0 }
        st[key] = rec
    end
    return rec
end

-- Timing/size/burst morphing for first handshake packets.
-- Adds controlled checksum-broken fakes to blur packet-size/burst signatures.
-- Optional guarded drop mode can force single retransmission jitter on TCP.
--
-- args:
--   dir=out                              (default)
--   payload=tls_client_hello,quic_initial,http_req (default)
--   packets=2                            ; max packets to process in flow direction
--   chance=70                            ; probability (%) to emit fake burst
--   fakes=1                              ; number of fakes per packet (1..3)
--   pad_min=8 pad_max=48                ; fake payload padding bytes
--   drop_chance=0                        ; probability (%) to drop original packet (TCP only)
--   drop_budget=1                        ; max guarded drops per flow
--   seq_left=2048 seq_step=128           ; TCP fake left-shifted seq offset
function z2k_timing_morph(ctx, desync)
    if not desync or not desync.dis then
        return
    end
    if not (desync.dis.tcp or desync.dis.udp) then
        return
    end

    direction_cutoff_opposite(ctx, desync, "out")
    if not direction_check(desync, "out") then
        return
    end
    if not payload_check(desync, "tls_client_hello,quic_initial,http_req") then
        return
    end

    local arg = desync.arg or {}
    local max_packets = z2k_clamp(arg.packets, 1, 16, 2)
    local chance = z2k_clamp(arg.chance, 0, 100, 70)
    local fake_count = z2k_clamp(arg.fakes, 1, 3, 1)
    local pad_min = z2k_clamp(arg.pad_min, 0, 512, 8)
    local pad_max = z2k_clamp(arg.pad_max, 0, 1024, 48)
    local drop_chance = z2k_clamp(arg.drop_chance, 0, 100, 0)
    local drop_budget = z2k_clamp(arg.drop_budget, 0, 4, 1)
    local seq_left = z2k_clamp(arg.seq_left, 0, 262144, 2048)
    local seq_step = z2k_clamp(arg.seq_step, 0, 16384, 128)

    local _, rec = z2k_timing_state(desync)
    if not rec then
        return
    end
    rec.out_seen = (tonumber(rec.out_seen) or 0) + 1

    if rec.out_seen > max_packets then
        instance_cutoff_shim(ctx, desync, true)
        return
    end

    if chance > 0 and math.random(100) <= chance then
        local rs = z2k_rawsend_ctx(desync, 1)
        local base_payload = desync.dis.payload or ""

        if desync.dis.tcp then
            for i = 1, fake_count do
                local fake_payload = z2k_payload_pad(base_payload, pad_min, pad_max)
                local seq_off = -seq_left - ((i - 1) * seq_step)
                rawsend_payload_segmented(desync, fake_payload, seq_off, {
                    rawsend = rs,
                    reconstruct = { badsum = true },
                    fooling = { tcp_ts_up = arg.tcp_ts_up }
                })
            end
        elseif desync.dis.udp then
            for i = 1, fake_count do
                local d = deepcopy(desync.dis)
                d.payload = z2k_payload_pad(base_payload, pad_min, pad_max)
                rawsend_dissect(d, rs, { badsum = true })
            end
        end
    end

    if drop_chance > 0 and drop_budget > 0 and desync.dis.tcp and not desync.replay then
        local seq = desync.dis.tcp and tonumber(desync.dis.tcp.th_seq)
        if seq and not rec.dropped_seq[seq] and rec.drops < drop_budget and math.random(100) <= drop_chance then
            rec.drops = rec.drops + 1
            rec.dropped_seq[seq] = true
            DLOG("z2k_timing_morph: guarded drop seq=" .. tostring(seq))
            return VERDICT_DROP
        end
    end
end

-- QUIC Initial morphing profile pack.
-- Chooses one profile per-flow (or forced profile) and applies a fragment-order
-- variant plus checksum-broken burst noise.
--
-- args:
--   dir=out
--   payload=quic_initial
--   packets=2
--   profile=1|2|3                      ; optional forced profile
--   noise=1..3                         ; number of badsum fake packets
--   pad_min=8 pad_max=64               ; extra bytes in fake noise payloads
--   version_chance=35                  ; chance (%) to spoof QUIC version in fakes
--   cid_chance=80                      ; chance (%) to randomize CID bytes in fakes
--   token_chance=60                    ; chance (%) to randomize non-empty token bytes
--   token_fill_chance=35               ; chance (%) to fill empty token in fakes
--   token_fill_len=1                   ; inserted token size for empty-token fill
--   live_chance=0                      ; optional chance (%) to morph live outgoing packet
--   nodrop                             ; keep original packet
function z2k_quic_morph_v2(ctx, desync)
    if not desync or not desync.dis or not desync.dis.udp then
        return
    end

    direction_cutoff_opposite(ctx, desync, "out")
    if not direction_check(desync, "out") then
        return
    end
    if not payload_check(desync, "quic_initial") then
        return
    end

    local arg = desync.arg or {}
    local rec = z2k_quic_state(desync)
    if not rec then
        return
    end
    local max_packets = z2k_clamp(arg.packets, 1, 16, 2)
    rec.out_seen = (tonumber(rec.out_seen) or 0) + 1
    if rec.out_seen > max_packets then
        instance_cutoff_shim(ctx, desync, true)
        return
    end

    local profile_forced = tonumber(arg.profile)
    local profile = profile_forced
    if not profile or profile < 1 or profile > 3 then
        if rec.profile == 0 then
            rec.profile = math.random(1, 3)
        end
        profile = rec.profile
    end

    local noise = z2k_clamp(arg.noise, 0, 3, 1)
    local pad_min = z2k_clamp(arg.pad_min, 0, 512, 8)
    local pad_max = z2k_clamp(arg.pad_max, 0, 1024, 64)
    local live_chance = z2k_clamp(arg.live_chance, 0, 100, 0)
    local rs = z2k_rawsend_ctx(desync, 1)
    local base_payload = desync.dis.payload or ""

    if noise > 0 then
        for i = 1, noise do
            local fake = deepcopy(desync.dis)
            fake.payload = z2k_payload_pad(base_payload, pad_min, pad_max)
            fake.payload = z2k_quic_morph_payload(fake.payload, arg)
            rawsend_dissect(fake, rs, { badsum = true })
        end
    end

    local out_dis = deepcopy(desync.dis)
    if live_chance > 0 and math.random(100) <= live_chance then
        out_dis.payload = z2k_quic_morph_payload(out_dis.payload, arg)
    end
    local ipfrag = nil
    if profile == 1 then
        ipfrag = {
            ipfrag = "z2k_ipfrag3_tiny",
            ipfrag_pos_udp = z2k_align8(z2k_clamp(arg.ipfrag_pos_udp, 8, 1024, 8)),
            ipfrag_pos2 = z2k_align8(z2k_clamp(arg.ipfrag_pos2, 16, 4096, 32)),
            ipfrag_overlap12 = z2k_align8(z2k_clamp(arg.ipfrag_overlap12, 0, 512, 8)),
            ipfrag_overlap23 = z2k_align8(z2k_clamp(arg.ipfrag_overlap23, 0, 512, 8)),
            ipfrag_disorder = true,
            ipfrag_next2 = tonumber(arg.ipfrag_next2) or 255
        }
    elseif profile == 2 then
        ipfrag = {
            ipfrag = "z2k_ipfrag3",
            ipfrag_pos_udp = z2k_align8(z2k_clamp(arg.ipfrag_pos_udp, 8, 1024, 16)),
            ipfrag_pos2 = z2k_align8(z2k_clamp(arg.ipfrag_pos2, 24, 4096, 56)),
            ipfrag_overlap12 = z2k_align8(z2k_clamp(arg.ipfrag_overlap12, 0, 512, 16)),
            ipfrag_overlap23 = z2k_align8(z2k_clamp(arg.ipfrag_overlap23, 0, 512, 8)),
            ipfrag_disorder = true,
            ipfrag_next2 = tonumber(arg.ipfrag_next2) or 0
        }
    else
        ipfrag = {
            ipfrag_pos_udp = z2k_align8(z2k_clamp(arg.ipfrag_pos_udp, 8, 1024, 16)),
            ipfrag_disorder = true,
            ipfrag_next = tonumber(arg.ipfrag_next) or 255
        }
    end

    local ok = pcall(rawsend_dissect_ipfrag, out_dis, {
        rawsend = rs,
        ipfrag = ipfrag
    })
    if not ok then
        return
    end

    if arg.nodrop == nil then
        return VERDICT_DROP
    end
end

-- ---------------------------------------------------------------------------
-- z2k_game_udp: UDP fake-injection desync for game/unknown protocols.
-- ---------------------------------------------------------------------------
-- Problem this solves
--   nfqws2's built-in `fake` action (zapret-antidpi.lua:fake) calls
--   rawsend_payload_segmented(desync, fake_payload) WITHOUT options and without
--   apply_fooling(), so BOTH `ip_ttl` AND `repeats` are silently dropped for
--   UDP fakes. That made it impossible to replicate the classic nfqws1 recipe
--
--       --dpi-desync=fake
--       --dpi-desync-any-protocol=1
--       --dpi-desync-fake-unknown-udp=<blob>
--       --dpi-desync-ttl=4
--       --dpi-desync-repeats=10
--
--   which works reliably for Roblox and other low-latency UDP game protocols
--   behind Russian DPI on Keenetic.
--
-- What this handler does
--   For each outgoing UDP datagram that matches the payload filter:
--     1. deepcopy the current dissect
--     2. replace the L7 payload with the configured blob
--     3. apply_fooling(..)     — honours ip_ttl / ip6_ttl / ip_autottl / tcp_*
--     4. apply_ip_id(..)       — keeps ip_id sane
--     5. rawsend_dissect_ipfrag with desync_opts(desync) so `repeats=N` from
--        the command line actually takes effect
--   The original packet is kept (no drop), matching nfqws1's fake behaviour
--   where the real packet is allowed through after the fakes.
--
-- Args (all optional unless noted)
--   blob=<name>         REQUIRED. fake payload blob (e.g. quic_initial_www_google_com)
--   ip_ttl=<int>        IPv4 TTL for the fake packet (e.g. 4)
--   ip6_ttl=<int>       IPv6 hop limit for the fake packet
--   ip_autottl=<spec>   auto-derived TTL (see zapret-lib parse_autottl)
--   repeats=<int>       how many copies of the fake to emit per real packet
--   dir=out|in|any      direction filter (default: out)
--   payload=<list>      comma-separated l7 filter (default: all)
--   optional            skip silently if blob is missing
--   badsum              send with deliberately bad L4 checksum (DPI fooling)
--
-- Usage example (place in /opt/zapret2/init.d/<platform>/custom.d/)
--   NFQWS_OPT_DESYNC_GAME="--filter-udp=1024-65535 ${GAME_IPSET_OPT}\
--     --in-range=a --out-range=-n2 --payload=all \
--     --lua-desync=z2k_game_udp:dir=out:blob=quic_initial_www_google_com:ip_ttl=4:repeats=10"
--
-- Mirrors nfqws1 cutoff=n2 via --out-range=-n2 at the wrapper level, and
-- repeats=10 / ip_ttl=4 / blob=... via the handler args.

function z2k_game_udp(ctx, desync)
    -- Always fire on outgoing side by default; cut off opposite direction so
    -- the instance doesn't waste cycles on inbound replies.
    direction_cutoff_opposite(ctx, desync)

    -- Only UDP. For related icmp packets (e.g. ICMP unreachable) pass through
    -- without cutting off the instance, mirroring fake()/rst() in zapret-antidpi.
    if not desync.dis.udp then
        if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
        return
    end

    if not (direction_check(desync) and payload_check(desync, "all")) then
        return
    end

    -- Only emit fakes on the first replay pass (mirrors built-in fake).
    if not replay_first(desync) then
        DLOG("z2k_game_udp: not acting on further replay pieces")
        return
    end

    if not desync.arg.blob then
        error("z2k_game_udp: 'blob' arg required")
    end

    if desync.arg.optional and not blob_exist(desync, desync.arg.blob) then
        DLOG("z2k_game_udp: blob '"..desync.arg.blob.."' not found. skipped")
        return
    end

    local fake_payload = blob(desync, desync.arg.blob)
    if b_debug then
        DLOG("z2k_game_udp: blob="..desync.arg.blob.." ttl="..tostring(desync.arg.ip_ttl).." repeats="..tostring(desync.arg.repeats))
    end

    -- Build the fake packet from the current dissect. deepcopy so we don't
    -- perturb the real packet the kernel will deliver afterwards.
    local dis = deepcopy(desync.dis)
    dis.payload = fake_payload

    -- Apply ip_ttl / ip_autottl / ip6_ttl / badsum etc. Crucially, this is
    -- where ip_ttl actually gets written to dis.ip.ip_ttl — the built-in
    -- fake() skips this step, which is the whole reason we exist.
    apply_fooling(desync, dis)
    apply_ip_id(desync, dis, nil, "none")

    -- rawsend_dissect_ipfrag honours options.rawsend.repeats, so supplying
    -- the full desync_opts bundle makes `repeats=N` on the command line
    -- emit N copies per real packet.
    rawsend_dissect_ipfrag(dis, desync_opts(desync))
end
