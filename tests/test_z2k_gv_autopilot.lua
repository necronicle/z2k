-- tests/test_z2k_gv_autopilot.lua — модульные и интеграционные тесты автопилота
-- (files/lua/z2k-gv-autopilot.lua + z2k-preflight.lua 2.0 + z2k-quic-reject.lua).
-- luacheck: globals DLOG bitand u32 u32add seq_ge bu8 bu32 find_tcp_option deepcopy blob tls_mod resolve_multi_pos delete_pos_1 rawsend_dissect rawsend reconstruct_dissect instance_cutoff_shim execution_plan_cancel direction_cutoff_opposite payload_check replay_first clock_getfloattime timer_set timer_del VERDICT_DROP VERDICT_PASS VERDICT_MODIFY TH_FIN TH_SYN TH_RST TH_PUSH TH_ACK TCP_KIND_NOOP TCP_KIND_MSS TCP_KIND_SCALE TCP_KIND_TS z2k_pf_flows z2k_preflight z2k_preflight_syn_timer z2k_preflight_giveup_timer z2k_quic_reject z2k_quic_reject_packet z2k_quic_reject_send z2k_autopilot_quic z2k_autopilot_tcp_fastfail z2k_autopilot_stall_guard z2k_autopilot_stall_timer z2k_autopilot_observe z2k_autopilot_reset z2k_autopilot_set_paths z2k_autopilot_parse_ip z2k_autopilot_mask_prefix z2k_autopilot_lookup_raw z2k_autopilot_lookup_dis z2k_autopilot_lookup_text z2k_autopilot_safety_fuse
-- luacheck: ignore 122

local PASS, FAIL = 0, 0
local function ok(m) PASS = PASS + 1; print("[PASS] " .. m) end
local function no(m, want, got)
    FAIL = FAIL + 1
    print(string.format("[FAIL] %s (want=%s got=%s)", m, tostring(want), tostring(got)))
end
local function is(m, want, got) if want == got then ok(m) else no(m, want, got) end end

-- ----- заглушки ядра nfqws2 / zapret-lib --------------------------------------
VERDICT_PASS, VERDICT_DROP, VERDICT_MODIFY = 0, 2, 1
TH_FIN, TH_SYN, TH_RST, TH_PUSH, TH_ACK = 1, 2, 4, 8, 16
TCP_KIND_NOOP, TCP_KIND_MSS, TCP_KIND_SCALE, TCP_KIND_TS = 1, 2, 3, 8

local fake_now = 1795470000.0
clock_getfloattime = function() return fake_now end
function DLOG() end

bitand = function(a, b)
    local r, bit = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return r
end
u32 = function(s)
    local b1, b2, b3, b4 = string.byte(s, 1, 4)
    return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end
u32add = function(a, b) return (a + b) % 4294967296 end
seq_ge = function(a, b) return (a - b) % 4294967296 < 2147483648 end
bu8 = function(v) return string.char(v % 256) end
bu32 = function(v)
    return string.char(
        math.floor(v / 16777216) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 256) % 256,
        v % 256
    )
end
find_tcp_option = function(opts, kind)
    if not opts then return nil end
    for i, o in ipairs(opts) do if o.kind == kind then return i end end
    return nil
end
deepcopy = function(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do copy[k] = deepcopy(v) end
    return copy
end

local last_tls_mod_args = {}
blob = function(_, name) return "BLOB[" .. name .. "]" end
tls_mod = function(b, opts)
    last_tls_mod_args[#last_tls_mod_args + 1] = opts
    return b .. "(" .. opts .. ")"
end
resolve_multi_pos = function(data) return { math.floor(#data / 2) + 1 } end
delete_pos_1 = function(a) if a[1] == 1 then table.remove(a, 1) end end

local rawsend_pkts = {}
local rawsend_dissects = {}
local cutoffs = 0
local cancels = 0
local timers = {}

rawsend = function(pkt, opts)
    rawsend_pkts[#rawsend_pkts + 1] = { pkt = pkt, opts = opts }
    return true
end
rawsend_dissect = function(dis, opts)
    rawsend_dissects[#rawsend_dissects + 1] = { dis = deepcopy(dis), opts = deepcopy(opts) }
    return true
end
reconstruct_dissect = function(dis, opts)
    assert(opts and opts.keepsum)
    if dis.raw then return dis.raw end
    if dis.ip6 then return string.char(0x60, 0, 0, 0, 0, 20, 17, 64) .. dis.ip6.ip6_src .. dis.ip6.ip6_dst .. "UDP" end
    return string.char(0x45, 0, 0, 60, 1, 2, 0, 0, 64, 17, 0, 0) .. dis.ip.ip_src .. dis.ip.ip_dst .. "UDP"
end
direction_cutoff_opposite = function() end
payload_check = function(desync, def)
    local want = (desync.arg and desync.arg.payload) or def
    return want == "all" or want == desync.l7payload
end
replay_first = function(desync) return not desync.replay or desync.replay_piece == 1 end
instance_cutoff_shim = function() cutoffs = cutoffs + 1 end
execution_plan_cancel = function() cancels = cancels + 1 end
timer_set = function(name, cb, ms, oneshot, data)
    timers[name] = { name = name, cb = cb, ms = ms, oneshot = oneshot, data = data }
end
timer_del = function(name)
    timers[name] = nil
end

dofile("files/lua/z2k-quic-reject.lua")
dofile("files/lua/z2k-gv-autopilot.lua")
dofile("files/lua/z2k-preflight.lua")

local tmp_base = os.tmpname()
os.remove(tmp_base)
local pol_path = tmp_base .. ".policy.dat"
local obs_path = tmp_base .. ".observed.tsv"
local neutral_path = tmp_base .. ".gvsub.neutral"
z2k_autopilot_set_paths(pol_path, obs_path, neutral_path)

local function write_file(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function clear_files()
    os.remove(pol_path)
    os.remove(obs_path)
    os.remove(neutral_path)
end

local function reset_all()
    rawsend_pkts = {}
    rawsend_dissects = {}
    last_tls_mod_args = {}
    cutoffs = 0
    cancels = 0
    timers = {}
    for k in pairs(z2k_pf_flows) do z2k_pf_flows[k] = nil end
    z2k_autopilot_reset()
end

local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function csum_ok(data)
    local sum = 0
    for i = 1, #data, 2 do sum = sum + data:byte(i) * 256 + (data:byte(i + 1) or 0) end
    return sum > 0 and sum % 0xFFFF == 0
end

local CLI4 = "\192\168\1\50"
local CLI4B = "\192\168\1\51"
local SRV4 = "\74\125\100\17"
local CLI6 = assert(z2k_autopilot_parse_ip("2001:db8:1::50"))
local SRV6 = assert(z2k_autopilot_parse_ip("2a00:1450:4005:2::7"))

local function tcp4_dis(src, dst, sport, dport, flags, seq, ack, payload)
    return {
        ip = { ip_src = src, ip_dst = dst, ip_id = 11, ip_ttl = 64, ip_p = 6 },
        tcp = {
            th_sport = sport, th_dport = dport,
            th_seq = seq, th_ack = ack or 0,
            th_flags = flags, th_win = 65535,
            options = {
                { kind = TCP_KIND_MSS, data = "\5\180" },
                { kind = TCP_KIND_SCALE, data = "\7" },
            },
        },
        payload = payload or "",
    }
end

local function tcp6_dis(src, dst, sport, dport, flags, seq, ack, payload)
    return {
        ip6 = { ip6_src = src, ip6_dst = dst, ip6_nxt = 6, ip6_hlim = 64 },
        tcp = {
            th_sport = sport, th_dport = dport,
            th_seq = seq, th_ack = ack or 0,
            th_flags = flags, th_win = 65535,
            options = {
                { kind = TCP_KIND_MSS, data = "\5\160" },
                { kind = TCP_KIND_SCALE, data = "\7" },
            },
        },
        payload = payload or "",
    }
end

local function udp_dis(is_v6, src, dst, dport)
    if is_v6 then
        return { ip6 = { ip6_src = src, ip6_dst = dst }, udp = { uh_sport = 50000, uh_dport = dport or 443 } }
    end
    return { ip = { ip_src = src, ip_dst = dst }, udp = { uh_sport = 50000, uh_dport = dport or 443 } }
end

-- ===== 1. Каноническая нормализация IPv4 / IPv6 и CIDR-маскирование =========
do
    local b4, fam4 = z2k_autopilot_parse_ip("74.125.100.17")
    is("v4 parse family", "v4", fam4)
    is("v4 parse bytes", "\74\125\100\17", b4)
    is("v4 reject >255", nil, z2k_autopilot_parse_ip("256.1.1.1"))
    is("v4 reject leading zero", nil, z2k_autopilot_parse_ip("01.2.3.4"))
    is("v4 reject short", nil, z2k_autopilot_parse_ip("1.2.3"))

    local v6_comp = assert(z2k_autopilot_parse_ip("2a00:1450:4005:2::7"))
    local v6_full = assert(z2k_autopilot_parse_ip("2A00:1450:4005:0002:0000:0000:0000:0007"))
    local v6_half = assert(z2k_autopilot_parse_ip("2a00:1450:4005:2:0:0:0:7"))
    is("v6 compressed == expanded", v6_full, v6_comp)
    is("v6 compressed == 0-groups", v6_half, v6_comp)
    is("v6 ::1 == expanded", z2k_autopilot_parse_ip("0:0:0:0:0:0:0:1"), z2k_autopilot_parse_ip("::1"))
    is("v6 mapped IPv4", z2k_autopilot_parse_ip("::ffff:c000:201"), z2k_autopilot_parse_ip("::ffff:192.0.2.1"))
    is("v6 zone stripped", z2k_autopilot_parse_ip("fe80::1"), z2k_autopilot_parse_ip("fe80::1%eth0"))
    is("v6 invalid triple colon", nil, z2k_autopilot_parse_ip("2001:::1"))
    is("v6 invalid double ::", nil, z2k_autopilot_parse_ip("2001::1::2"))
    is("v6 invalid 9 groups", nil, z2k_autopilot_parse_ip("1:2:3:4:5:6:7:8:9"))

    is("v4 /24 mask", z2k_autopilot_parse_ip("74.125.100.0"), z2k_autopilot_mask_prefix(b4, 24))
    is("v6 /48 mask", z2k_autopilot_parse_ip("2a00:1450:4005::"), z2k_autopilot_mask_prefix(v6_comp, 48))
    is("v6 /64 mask", z2k_autopilot_parse_ip("2a00:1450:400f:6::"), z2k_autopilot_mask_prefix(z2k_autopilot_parse_ip("2a00:1450:400f:6::abcd"), 64))
    is("v4 /25 bit mask", z2k_autopilot_parse_ip("10.0.0.128"), z2k_autopilot_mask_prefix(z2k_autopilot_parse_ip("10.0.0.255"), 25))
end

-- ===== 2. Кэш политики, приоритет IP > Prefix, TTL, откат часов, fail-open ====
do
    clear_files()
    reset_all()
    local e, h = z2k_autopilot_lookup_text("74.125.100.17")
    is("absent policy -> nil entry", nil, e)
    is("absent policy -> nil header", nil, h)

    write_file(pol_path, "")
    z2k_autopilot_reset()
    is("empty policy -> fail open", nil, z2k_autopilot_lookup_text("74.125.100.17"))

    write_file(pol_path, "type=ip\taddr=74.125.100.17\tkind=google\tverdict=dead_l3\n")
    z2k_autopilot_reset()
    is("missing header -> fail open", nil, z2k_autopilot_lookup_text("74.125.100.17"))

    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=2\tusable_v6=0\n"
        .. "type=ip\taddr=74.125.100.17\tkind=google\tverdict=dead_l3\n",
        math.floor(fake_now) - 600
    ))
    z2k_autopilot_reset()
    is("stale updated -> fail open", nil, z2k_autopilot_lookup_text("74.125.100.17"))

    -- Актуальная политика + IP > Prefix + расширенный IPv6 в файле == сжатый в пакете
    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=3\tusable_v6=1\tbaseline_rtt_ms=35\tggc_rtt_ms=12\tglobal_quic_blocked=0\tpreflight_sni=cdn.ok.ru\tresyn_delay_ms=140\tpreflight_giveup_ms=1700\tggc_stall_guard_ms=2100\n"
        .. "type=prefix\taddr=74.125.100.0/24\tkind=google\tverdict=bad_bypassable\tquic_ok=0\trtt_ms=90\tresyn_delay_ms=150\tgiveup_ms=1800\tstall_ms=1900\n"
        .. "type=ip\taddr=74.125.100.17\tkind=google\tverdict=good_direct\tquic_ok=1\trtt_ms=30\tresyn_delay_ms=80\tgiveup_ms=1200\tstall_ms=1600\n"
        .. "type=prefix\taddr=2a00:1450:4005:0000::/48\tkind=google\tverdict=dead_l3\tquic_ok=0\n"
        .. "type=prefix\taddr=2a00:1450:400f:6::/64\tkind=google\tverdict=good_ggc\tquic_ok=0\n"
        .. "type=prefix\taddr=2a00:1450:400f:7::/64\tkind=google\tverdict=bad_bypassable\tquic_ok=0\n"
        .. "type=ip\taddr=2A00:1450:4005:0002:0000:0000:0000:0007\tkind=google\tverdict=good_direct\tquic_ok=1\n",
        math.floor(fake_now)
    ))
    z2k_autopilot_reset()

    local e_ip, h_ip = z2k_autopilot_lookup_text("74.125.100.17")
    is("exact IP overrides /24 prefix", "good_direct", e_ip.verdict)
    is("exact IP quic_ok=1", 1, e_ip.quic_ok)
    is("header preflight_sni", "cdn.ok.ru", h_ip.preflight_sni)

    local e_pfx = z2k_autopilot_lookup_text("74.125.100.99")
    is("/24 fallback for neighbor IP", "bad_bypassable", e_pfx.verdict)

    local e_v6 = z2k_autopilot_lookup_raw(SRV6)
    is("expanded IPv6 in policy matches compressed raw IPv6", "good_direct", e_v6.verdict)
    local e_v6_pfx = z2k_autopilot_lookup_text("2a00:1450:4005:9999::1")
    is("IPv6 /48 prefix fallback", "dead_l3", e_v6_pfx.verdict)
    local e_v6_64a = z2k_autopilot_lookup_text("2a00:1450:400f:6::42")
    is("IPv6 /64 cluster A", "good_ggc", e_v6_64a.verdict)
    local e_v6_64b = z2k_autopilot_lookup_text("2a00:1450:400f:7::42")
    is("IPv6 /64 cluster B", "bad_bypassable", e_v6_64b.verdict)

    -- Проверка 1с TTL и отката часов
    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=3\tusable_v6=1\n"
        .. "type=ip\taddr=74.125.100.17\tkind=google\tverdict=dead_l3\n",
        math.floor(fake_now)
    ))
    is("within 1s TTL uses RAM cache", "good_direct", z2k_autopilot_lookup_text("74.125.100.17").verdict)
    fake_now = fake_now + 1.1
    is("after 1s TTL reloads new file", "dead_l3", z2k_autopilot_lookup_text("74.125.100.17").verdict)

    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=3\tusable_v6=1\n"
        .. "type=ip\taddr=74.125.100.17\tkind=google\tverdict=good_direct\n",
        math.floor(fake_now)
    ))
    fake_now = fake_now - 5.0
    is("clock rollback invalidates cache immediately", "good_direct", z2k_autopilot_lookup_text("74.125.100.17").verdict)
    fake_now = 1795470000.0
end

-- ===== 3. DoH/DoT Observation Logger (/tmp/z2k-gv-observed.tsv) ===============
do
    clear_files()
    reset_all()
    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=2\tusable_v6=0\n"
        .. "type=prefix\taddr=74.125.100.0/24\tkind=google\tverdict=good_direct\n"
        .. "type=ip\taddr=74.125.100.17\tkind=google\tverdict=good_direct\n"
        .. "type=ip\taddr=74.125.100.20\tkind=google\tverdict=unknown\n",
        math.floor(fake_now)
    ))

    local unclass_ip = assert(z2k_autopilot_parse_ip("74.125.100.18"))
    local known_ip = SRV4
    local unk_ip = assert(z2k_autopilot_parse_ip("74.125.100.20"))

    -- Уже классифицированный exact type=ip (good_direct) НЕ пишется
    z2k_autopilot_observe({}, {
        outgoing = true, l7payload = "tls_client_hello",
        dis = tcp4_dis(CLI4, known_ip, 50001, 443, TH_ACK, 10, 20, "ch"),
        track = { hostname = "rr1---sn-known.googlevideo.com" },
    })
    is("classified exact IP not logged", nil, read_file(obs_path))

    -- .c.youtube.com, www.youtube.com, hostname_is_ip=true НЕ пишутся
    z2k_autopilot_observe({}, {
        outgoing = true, l7payload = "tls_client_hello",
        dis = tcp4_dis(CLI4, unclass_ip, 50002, 443, TH_ACK, 10, 20, "ch"),
        track = { hostname = "rr1---sn-yt.c.youtube.com" },
    })
    z2k_autopilot_observe({}, {
        outgoing = true, l7payload = "tls_client_hello",
        dis = tcp4_dis(CLI4, unclass_ip, 50003, 443, TH_ACK, 10, 20, "ch"),
        track = { hostname = "www.youtube.com" },
    })
    z2k_autopilot_observe({}, {
        outgoing = true, l7payload = "tls_client_hello",
        dis = tcp4_dis(CLI4, unclass_ip, 50004, 443, TH_ACK, 10, 20, "ch"),
        track = { hostname = "74.125.100.18", hostname_is_ip = true },
    })
    is("c.youtube.com / non-target not logged", nil, read_file(obs_path))

    -- Новый IP (только /24 prefix) для *.googlevideo.com и IP с verdict=unknown для *.gvt1.com пишутся
    z2k_autopilot_observe({}, {
        outgoing = true, l7payload = "tls_client_hello",
        dis = tcp4_dis(CLI4, unclass_ip, 50005, 443, TH_ACK, 10, 20, "ch"),
        track = { hostname = "RR2---SN-NEW.GOOGLEVIDEO.COM." },
    })
    z2k_autopilot_observe({}, {
        outgoing = true, l7payload = "quic_initial",
        dis = udp_dis(false, CLI4, unk_ip, 443),
        track = { hostname = "r4---sn-play.gvt1.com" },
    })
    -- IPv6 unclassified
    z2k_autopilot_observe({}, {
        outgoing = true, l7payload = "tls_client_hello",
        dis = tcp6_dis(CLI6, SRV6, 50006, 443, TH_ACK, 10, 20, "ch"),
        track = { hostname = "rr3---sn-v6.googlevideo.com" },
    })

    local obs = read_file(obs_path)
    is("observed logs normalized googlevideo", true, obs:find("74.125.100.18\trr2---sn-new.googlevideo.com\n", 1, true) ~= nil)
    is("observed logs unknown-verdict gvt1", true, obs:find("74.125.100.20\tr4---sn-play.gvt1.com\n", 1, true) ~= nil)
    is("observed logs IPv6 canonical", true, obs:find("2a00:1450:4005:2::7\trr3---sn-v6.googlevideo.com\n", 1, true) ~= nil)

    -- Дедупликация 120с
    local before_len = #obs
    fake_now = fake_now + 30
    z2k_autopilot_observe({}, {
        outgoing = true, l7payload = "tls_client_hello",
        dis = tcp4_dis(CLI4, unclass_ip, 50007, 443, TH_ACK, 10, 20, "ch"),
        track = { hostname = "rr2---sn-new.googlevideo.com" },
    })
    is("observed dedupes within 120s", before_len, #read_file(obs_path))
    fake_now = fake_now + 95
    z2k_autopilot_observe({}, {
        outgoing = true, l7payload = "tls_client_hello",
        dis = tcp4_dis(CLI4, unclass_ip, 50008, 443, TH_ACK, 10, 20, "ch"),
        track = { hostname = "rr2---sn-new.googlevideo.com" },
    })
    is("observed writes again after 120s", true, #read_file(obs_path) > before_len)

    -- Ограничение размера / числа строк (300 записей -> <= 256 строк и <= 32 KiB)
    clear_files()
    z2k_autopilot_reset()
    for i = 1, 300 do
        local ip4_i = string.char(10, 20, math.floor(i / 250) % 256, (i % 250) + 1)
        z2k_autopilot_observe({}, {
            outgoing = true, l7payload = "tls_client_hello",
            dis = tcp4_dis(CLI4, ip4_i, 40000 + i, 443, TH_ACK, 1, 1, "ch"),
            track = { hostname = "rr1---sn-cap" .. i .. ".googlevideo.com" },
        })
    end
    local capped = assert(read_file(obs_path))
    local nlines = 0
    for _ in capped:gmatch("[^\n]+") do nlines = nlines + 1 end
    is("observed cap <= 256 lines", true, nlines <= 256)
    is("observed cap <= 32768 bytes", true, #capped <= 32768)
    is("observed cap keeps newest entry #300", true, capped:find("rr1---sn-cap300.googlevideo.com", 1, true) ~= nil)
end

-- ===== 4. Guard 1: z2k_autopilot_quic =======================================
do
    clear_files()
    reset_all()
    local d_cold = { outgoing = true, l7payload = "quic_initial", ifin = "br0", dis = udp_dis(false, CLI4, SRV4), track = { hostname = "rr1---sn-cold.googlevideo.com" } }
    is("QUIC fail-open when policy absent", nil, z2k_autopilot_quic({}, d_cold))
    is("QUIC fail-open sends 0 ICMP", 0, #rawsend_pkts)

    -- Холодный старт (policy есть с usable_v4=0, usable_v6=0; узел ещё без quic_ok=1)
    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=0\tusable_v6=0\tglobal_quic_blocked=0\n"
        .. "type=ip\taddr=74.125.100.18\tkind=google\tverdict=good_direct\tquic_ok=1\n"
        .. "type=ip\taddr=74.125.100.19\tkind=play\tverdict=good_direct\tquic_ok=0\n"
        .. "type=ip\taddr=2a00:1450:4005:2::7\tkind=google\tverdict=bad_bypassable\tquic_ok=0\n",
        math.floor(fake_now)
    ))
    reset_all()
    is("cold googlevideo QUIC rejected -> DROP", VERDICT_DROP, z2k_autopilot_quic({}, d_cold))
    is("cold googlevideo QUIC cancels execution plan", 1, cancels)
    is("cold googlevideo QUIC sends ICMPv4", 1, #rawsend_pkts)
    is("ICMPv4 ifout == br0", "br0", rawsend_pkts[1].opts.ifout)
    is("ICMPv4 Type 3 Code 3", true, rawsend_pkts[1].pkt:byte(21) == 3 and rawsend_pkts[1].pkt:byte(22) == 3)
    is("ICMPv4 non-zero ip_id", true, u16(rawsend_pkts[1].pkt, 5) > 0)
    is("ICMPv4 length matches", #rawsend_pkts[1].pkt, u16(rawsend_pkts[1].pkt, 3))
    is("ICMPv4 valid header checksum", true, csum_ok(rawsend_pkts[1].pkt:sub(1, 20)))

    -- Play (gvt1.com) с quic_ok=0 отвергается (через ICMP, БЕЗ RST), а googlevideo с quic_ok=1 проходит!
    reset_all()
    local play_ip = assert(z2k_autopilot_parse_ip("74.125.100.19"))
    local d_play = { outgoing = true, l7payload = "quic_initial", ifin = "", dis = udp_dis(false, CLI4, play_ip), track = { hostname = "rr4---sn-play.gvt1.com" } }
    is("play quic_ok=0 -> DROP via ICMP", VERDICT_DROP, z2k_autopilot_quic({}, d_play))
    is("empty ifin -> opts.ifout=nil", nil, rawsend_pkts[1].opts.ifout)

    reset_all()
    local ok_ip = assert(z2k_autopilot_parse_ip("74.125.100.18"))
    local d_ok = { outgoing = true, l7payload = "quic_initial", ifin = "br0", dis = udp_dis(false, CLI4, ok_ip), track = { hostname = "rr1---sn-ok.googlevideo.com" } }
    is("googlevideo quic_ok=1 -> PASS", nil, z2k_autopilot_quic({}, d_ok))
    is("googlevideo quic_ok=1 sends 0 ICMP", 0, #rawsend_pkts)
    is("googlevideo quic_ok=1 does not cancel plan", 0, cancels)

    -- IPv6 QUIC reject
    reset_all()
    local d_v6 = { outgoing = true, l7payload = "quic_initial", ifin = "br0", dis = udp_dis(true, CLI6, SRV6), track = { hostname = "rr1---sn-v6.googlevideo.com" } }
    is("IPv6 quic_ok=0 -> DROP", VERDICT_DROP, z2k_autopilot_quic({}, d_v6))
    is("ICMPv6 Type 1 Code 4", true, rawsend_pkts[1].pkt:byte(41) == 1 and rawsend_pkts[1].pkt:byte(42) == 4)

    -- Не-GV домен на общем IP не режется при global_quic_blocked=0, но режется при global_quic_blocked=1
    reset_all()
    local d_other = { outgoing = true, l7payload = "quic_initial", ifin = "br0", dis = udp_dis(false, CLI4, ok_ip), track = { hostname = "www.youtube.com" } }
    is("other domain passes when global_quic_blocked=0", nil, z2k_autopilot_quic({}, d_other))

    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=2\tusable_v6=0\tglobal_quic_blocked=1\n"
        .. "type=ip\taddr=74.125.100.18\tkind=google\tverdict=good_direct\tquic_ok=1\n",
        math.floor(fake_now)
    ))
    z2k_autopilot_reset()
    is("other domain rejected when global_quic_blocked=1", VERDICT_DROP, z2k_autopilot_quic({}, d_other))
    is("googlevideo quic_ok=1 still allowed even if global_quic_blocked=1", nil, z2k_autopilot_quic({}, d_ok))

    -- Активный probe-маркер gvsub в .neutral пропускает локальные QUIC-зонды (ifin=""/nil),
    -- но НЕ открывает доступ LAN-клиентам (ifin="br0") и не засоряет observed.tsv.
    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=2\tusable_v6=1\tglobal_quic_blocked=1\n"
        .. "type=ip\taddr=74.125.100.19\tkind=google\tverdict=good_direct\tquic_ok=0\n"
        .. "type=ip\taddr=2a00:1450:4005:2::99\tkind=google\tverdict=good_direct\tquic_ok=0\n",
        math.floor(fake_now)
    ))
    write_file(neutral_path, "probe 4a7d6413\nprobe 4a7d6414\nprobe 2A001450400500020000000000000099\n")
    os.remove(obs_path)
    reset_all()
    local probe_v4 = assert(z2k_autopilot_parse_ip("74.125.100.19"))
    local probe_unk = assert(z2k_autopilot_parse_ip("74.125.100.20"))
    local probe_v6 = assert(z2k_autopilot_parse_ip("2a00:1450:4005:2::99"))
    local d_probe_local = { outgoing = true, l7payload = "quic_initial", ifin = "", dis = udp_dis(false, CLI4, probe_v4), track = { hostname = "rr4---sn-probe.googlevideo.com" } }
    local d_probe_unk = { outgoing = true, l7payload = "quic_initial", dis = udp_dis(false, CLI4, probe_unk), track = { hostname = "rr2---sn-probe.googlevideo.com" } }
    local d_probe_lan = { outgoing = true, l7payload = "quic_initial", ifin = "br0", dis = udp_dis(false, CLI4, probe_v4), track = { hostname = "rr4---sn-probe.googlevideo.com" } }
    local d_probe_v6_local = { outgoing = true, l7payload = "quic_initial", ifin = "", dis = udp_dis(true, CLI6, probe_v6), track = { hostname = "rr5---sn-probe.googlevideo.com" } }
    local d_probe_v6_lan = { outgoing = true, l7payload = "quic_initial", ifin = "br0", dis = udp_dis(true, CLI6, probe_v6), track = { hostname = "rr5---sn-probe.googlevideo.com" } }

    is("gvsub local IPv4 QUIC probe bypasses quic_ok=0 & global=1", nil, z2k_autopilot_quic({}, d_probe_local))
    is("gvsub local unknown QUIC probe bypasses", nil, z2k_autopilot_quic({}, d_probe_unk))
    is("gvsub local QUIC probe sends 0 ICMP", 0, #rawsend_pkts)
    is("gvsub local QUIC probe does not cancel plan", 0, cancels)
    is("gvsub local QUIC probe does not write observed.tsv", nil, read_file(obs_path))
    is("LAN IPv4 client still blocked during active probe", VERDICT_DROP, z2k_autopilot_quic({}, d_probe_lan))
    is("LAN IPv4 client got ICMP during probe", 1, #rawsend_pkts)
    is("gvsub local IPv6 QUIC probe (uppercase hex) bypasses", nil, z2k_autopilot_quic({}, d_probe_v6_local))
    is("LAN IPv6 client still blocked during active probe", VERDICT_DROP, z2k_autopilot_quic({}, d_probe_v6_lan))

    -- После снятия маркера probe из .neutral и истечения 0.5s TTL локальный QUIC снова блокируется
    write_file(neutral_path, "")
    fake_now = fake_now + 0.6
    reset_all()
    is("local IPv4 QUIC blocked again after probe TTL expires", VERDICT_DROP, z2k_autopilot_quic({}, d_probe_local))
end

-- ===== 5. Guard 2: TCP Fast-Fail + Safety Fuse + Anti-Storm ================
do
    clear_files()
    reset_all()
    local ip_dead_g = assert(z2k_autopilot_parse_ip("172.217.10.1"))
    local ip_dead_isp = assert(z2k_autopilot_parse_ip("46.61.136.10"))
    local ip_unbyp = assert(z2k_autopilot_parse_ip("172.217.10.2"))
    local ip_play = assert(z2k_autopilot_parse_ip("172.217.10.3"))
    local ip_gfe = assert(z2k_autopilot_parse_ip("172.217.10.4"))
    local ip_yt = assert(z2k_autopilot_parse_ip("172.217.10.5"))
    local ip_good = assert(z2k_autopilot_parse_ip("172.217.10.6"))

    local function pol_with_usable(u4, u6)
        write_file(pol_path, string.format(
            "type=header\tversion=1\tupdated=%d\tusable_v4=%d\tusable_v6=%d\n"
            .. "type=ip\taddr=172.217.10.1\tkind=google\tverdict=dead_l3\n"
            .. "type=ip\taddr=46.61.136.10\tkind=isp\tverdict=dead_ggc\n"
            .. "type=ip\taddr=172.217.10.2\tkind=google\tverdict=bad_unbypassable\n"
            .. "type=ip\taddr=172.217.10.3\tkind=play\tverdict=dead_l3\n"
            .. "type=ip\taddr=172.217.10.4\tkind=gfe\tverdict=dead_l3\n"
            .. "type=ip\taddr=172.217.10.5\tkind=yt\tverdict=dead_l3\n"
            .. "type=ip\taddr=172.217.10.6\tkind=google\tverdict=good_direct\n"
            .. "type=ip\taddr=2a00:1450:4005:2::7\tkind=google\tverdict=dead_l3\n",
            math.floor(fake_now), u4, u6
        ))
    end

    -- Safety Fuse = 0 (usable_v4=0, usable_v6=0) -> НИКОГДА RST
    pol_with_usable(0, 0)
    z2k_autopilot_reset()
    is("Safety Fuse 0+0 blocks fastfail RST", nil, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, ip_dead_g, 40001, 443, TH_SYN, 1000)
    }))
    is("Safety Fuse 0+0 sent 0 RST", 0, #rawsend_dissects)

    -- Cross-stack Safety Fuse (usable_v4=0, usable_v6=1) -> разрешает fastfail на IPv4!
    pol_with_usable(0, 1)
    z2k_autopilot_reset()
    is("Cross-stack 0+1 enables IPv4 fastfail", VERDICT_DROP, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, ip_dead_g, 40002, 443, TH_SYN, 2000)
    }))
    is("fastfail cancels execution plan", 1, cancels)
    is("fastfail sends 1 TCP RST,ACK", 1, #rawsend_dissects)
    local rst = rawsend_dissects[1]
    is("RST ip_src == server", ip_dead_g, rst.dis.ip.ip_src)
    is("RST ip_dst == client", CLI4, rst.dis.ip.ip_dst)
    is("RST sport/dport swapped", true, rst.dis.tcp.th_sport == 443 and rst.dis.tcp.th_dport == 40002)
    is("RST flags == RST+ACK", TH_RST + TH_ACK, rst.dis.tcp.th_flags)
    is("RST seq=0, ack=ISN+1", true, rst.dis.tcp.th_seq == 0 and rst.dis.tcp.th_ack == 2001)
    is("RST ifout == br0", "br0", rst.opts.ifout)

    -- isp dead_ggc & google bad_unbypassable & IPv6 dead_l3
    reset_all()
    is("isp dead_ggc fastfails", VERDICT_DROP, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, ip_dead_isp, 40003, 443, TH_SYN, 3000)
    }))
    is("google bad_unbypassable fastfails", VERDICT_DROP, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, ip_unbyp, 40004, 443, TH_SYN, 4000)
    }))
    is("IPv6 google dead_l3 fastfails", VERDICT_DROP, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp6_dis(CLI6, SRV6, 40005, 443, TH_SYN, 5000)
    }))
    is("IPv6 RST dst == CLI6", CLI6, rawsend_dissects[3].dis.ip6.ip6_dst)

    -- НИКОГДА RST для play, gfe, yt, unknown, good_direct, не-SYN
    reset_all()
    for _, case in ipairs({
        { "play NEVER RST", ip_play },
        { "gfe NEVER RST", ip_gfe },
        { "yt NEVER RST", ip_yt },
        { "unknown IP NEVER RST", assert(z2k_autopilot_parse_ip("1.2.3.4")) },
        { "good_direct NEVER RST", ip_good },
    }) do
        is(case[1], nil, z2k_autopilot_tcp_fastfail({}, {
            outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, case[2], 40010, 443, TH_SYN, 100)
        }))
    end
    is("non-SYN (SYN+ACK) ignored", nil, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, ip_dead_g, 40011, 443, TH_SYN + TH_ACK, 100, 1)
    }))
    is("0 RST sent on protected/non-SYN classes", 0, #rawsend_dissects)

    -- Anti-storm (< 6 RSTs per 3s per client ip_src)
    reset_all()
    for n = 1, 5 do
        is("antistorm allow #" .. n, VERDICT_DROP, z2k_autopilot_tcp_fastfail({}, {
            outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, ip_dead_g, 41000 + n, 443, TH_SYN, 7000 + n)
        }))
    end
    is("antistorm blocks 6th RST in 3s", nil, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, ip_dead_g, 41006, 443, TH_SYN, 7006)
    }))
    is("antistorm keeps 5 RSTs", 5, #rawsend_dissects)
    -- Другой клиент в ту же секунду не страдает
    is("other client unaffected by antistorm", VERDICT_DROP, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4B, ip_dead_g, 41007, 443, TH_SYN, 8000)
    }))
    -- Через > 3.0с окно скользит
    fake_now = fake_now + 3.1
    is("antistorm slides open after 3.1s", VERDICT_DROP, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, ip_dead_g, 41008, 443, TH_SYN, 9000)
    }))

    -- Активный probe-маркер gvsub пропускает локальную перепроверку dead/unbypassable TCP (ifin=""),
    -- но сохраняет мгновенный fastfail RST для LAN-клиентов (ifin="br0").
    write_file(neutral_path, "probe acd90a01\n")
    reset_all()
    is("gvsub local dead_l3 TCP re-probe bypasses fastfail", nil, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "", dis = tcp4_dis(CLI4, ip_dead_g, 41009, 443, TH_SYN, 9100)
    }))
    is("gvsub local TCP re-probe sends 0 RST", 0, #rawsend_dissects)
    is("LAN client dead_l3 STILL fastfails during active probe", VERDICT_DROP, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "br0", dis = tcp4_dis(CLI4, ip_dead_g, 41010, 443, TH_SYN, 9200)
    }))
    write_file(neutral_path, "")
    fake_now = fake_now + 0.6
    is("local dead_l3 TCP fastfails again after probe clears and 0.5s TTL expires", VERDICT_DROP, z2k_autopilot_tcp_fastfail({}, {
        outgoing = true, ifin = "", dis = tcp4_dis(CLI4, ip_dead_g, 41011, 443, TH_SYN, 9300)
    }))
end

-- ===== 6. Guard 4: ISP GGC Stall Guard ======================================
do
    clear_files()
    reset_all()
    local ip_isp = assert(z2k_autopilot_parse_ip("46.61.136.174"))
    local ip_google = assert(z2k_autopilot_parse_ip("74.125.100.17"))
    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=2\tusable_v6=0\tggc_stall_guard_ms=2200\n"
        .. "type=ip\taddr=46.61.136.174\tkind=isp\tverdict=good_ggc\tstall_ms=1950\n"
        .. "type=ip\taddr=74.125.100.17\tkind=google\tverdict=good_direct\tstall_ms=1950\n",
        math.floor(fake_now)
    ))

    -- google НЕ ставит stall guard
    local g_track = { lua_state = {} }
    z2k_autopilot_stall_guard({}, { outgoing = true, l7payload = "tls_client_hello", ifin = "br0", ifout = "eth3", dis = tcp4_dis(CLI4, ip_google, 52001, 443, TH_ACK, 100, 200, "CH"), track = g_track })
    z2k_autopilot_stall_guard({}, { outgoing = false, l7payload = "tls_server_hello", dis = tcp4_dis(ip_google, CLI4, 443, 52001, TH_ACK, 200, 102, "SH"), track = g_track })
    z2k_autopilot_stall_guard({}, { outgoing = true, l7payload = "unknown", ifin = "br0", ifout = "eth3", dis = tcp4_dis(CLI4, ip_google, 52001, 443, TH_ACK, 102, 202, "GET"), track = g_track })
    is("google node never arms stall guard", nil, next(timers))

    -- isp: нормальный ответ сервера снимает таймер
    local tr_ok = { lua_state = {} }
    z2k_autopilot_stall_guard({}, { outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000, dis = tcp4_dis(CLI4, ip_isp, 52002, 443, TH_SYN, 1000, 0), track = tr_ok })
    z2k_autopilot_stall_guard({}, { outgoing = false, ifin = "eth3", ifout = "br0", dis = tcp4_dis(ip_isp, CLI4, 443, 52002, TH_SYN + TH_ACK, 5000, 1001), track = tr_ok })
    z2k_autopilot_stall_guard({}, { outgoing = true, l7payload = "tls_client_hello", ifin = "br0", ifout = "eth3", fwmark = 0x40000000, dis = tcp4_dis(CLI4, ip_isp, 52002, 443, TH_ACK, 1001, 5001, "CH"), track = tr_ok })
    z2k_autopilot_stall_guard({}, { outgoing = false, l7payload = "tls_server_hello", dis = tcp4_dis(ip_isp, CLI4, 443, 52002, TH_ACK, 5001, 1003, "SH"), track = tr_ok })
    is("stall guard not armed before app data", nil, next(timers))
    z2k_autopilot_stall_guard({}, { outgoing = true, l7payload = "unknown", ifin = "br0", ifout = "eth3", fwmark = 0x40000000, dis = tcp4_dis(CLI4, ip_isp, 52002, 443, TH_ACK, 1003, 5003, "GET /video"), track = tr_ok })
    local tname, tinfo = next(timers)
    is("stall guard armed on app data", true, tname ~= nil)
    is("stall guard uses policy stall_ms=1950", 1950, tinfo.ms)
    is("stall guard oneshot=true", true, tinfo.oneshot)
    -- Повторный исходящий пакет не перезапускает таймер и оставляет его
    z2k_autopilot_stall_guard({}, { outgoing = true, l7payload = "unknown", ifin = "br0", ifout = "eth3", dis = tcp4_dis(CLI4, ip_isp, 52002, 443, TH_ACK, 1013, 5003, "MORE"), track = tr_ok })
    is("second app data preserves timer", true, timers[tname] ~= nil)
    -- Входящий ответ сервера снимает таймер
    z2k_autopilot_stall_guard({}, { outgoing = false, l7payload = "unknown", dis = tcp4_dis(ip_isp, CLI4, 443, 52002, TH_ACK, 5003, 1017, "VIDEO"), track = tr_ok })
    is("server reply deletes stall timer", nil, next(timers))
    is("server reply sets z2k_sg_done=true", true, tr_ok.lua_state.z2k_sg_done)
    -- Запоздалый callback ничего не шлёт
    z2k_autopilot_stall_timer(tname, tinfo.data)
    is("stale stall timer callback sends 0 RST", 0, #rawsend_dissects)

    -- isp: зависание -> таймер шлёт двунаправленный RST
    reset_all()
    local tr_stall = { lua_state = {} }
    z2k_autopilot_stall_guard({}, { outgoing = true, l7payload = "tls_client_hello", ifin = "br0", ifout = "eth3", fwmark = 0x40000000, dis = tcp4_dis(CLI4, ip_isp, 52003, 443, TH_ACK, 2000, 9000, "CH"), track = tr_stall })
    z2k_autopilot_stall_guard({}, { outgoing = false, l7payload = "tls_server_hello", dis = tcp4_dis(ip_isp, CLI4, 443, 52003, TH_ACK, 9000, 2002, "SH"), track = tr_stall })
    z2k_autopilot_stall_guard({}, { outgoing = true, l7payload = "unknown", ifin = "br0", ifout = "eth3", fwmark = 0x40000000, dis = tcp4_dis(CLI4, ip_isp, 52003, 443, TH_ACK, 2002, 9002, "GET"), track = tr_stall })
    local sname, sinfo = next(timers)
    z2k_autopilot_stall_timer(sname, sinfo.data)
    is("stall timeout sends bidirectional RST (2 packets)", 2, #rawsend_dissects)
    is("cli RST seq/ack", true, rawsend_dissects[1].dis.tcp.th_seq == 9002 and rawsend_dissects[1].dis.tcp.th_ack == 2005)
    is("cli RST ifout == br0", "br0", rawsend_dissects[1].opts.ifout)
    is("srv RST seq/ack", true, rawsend_dissects[2].dis.tcp.th_seq == 2005 and rawsend_dissects[2].dis.tcp.th_ack == 9002)
    is("srv RST fwmark preserved", 0x40000000, rawsend_dissects[2].opts.fwmark)
    is("srv RST ifout == eth3", "eth3", rawsend_dissects[2].opts.ifout)

    -- Safety Fuse=0 к моменту срабатывания таймера блокирует двунаправленный RST
    reset_all()
    local tr_fuse = { lua_state = {} }
    z2k_autopilot_stall_guard({}, { outgoing = true, l7payload = "tls_client_hello", ifin = "br0", ifout = "eth3", dis = tcp4_dis(CLI4, ip_isp, 52004, 443, TH_ACK, 3000, 4000, "CH"), track = tr_fuse })
    z2k_autopilot_stall_guard({}, { outgoing = false, l7payload = "tls_server_hello", dis = tcp4_dis(ip_isp, CLI4, 443, 52004, TH_ACK, 4000, 3002, "SH"), track = tr_fuse })
    z2k_autopilot_stall_guard({}, { outgoing = true, l7payload = "unknown", ifin = "br0", ifout = "eth3", dis = tcp4_dis(CLI4, ip_isp, 52004, 443, TH_ACK, 3002, 4002, "GET"), track = tr_fuse })
    local fname, finfo = next(timers)
    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=0\tusable_v6=0\n"
        .. "type=ip\taddr=46.61.136.174\tkind=isp\tverdict=good_ggc\n",
        math.floor(fake_now)
    ))
    z2k_autopilot_reset()
    z2k_autopilot_stall_timer(fname, finfo.data)
    is("stall timer respects Safety Fuse=0", 0, #rawsend_dissects)
end

-- ===== 7. Preflight 2.0 + Autopilot интеграция ==============================
do
    clear_files()
    reset_all()
    local ip_good = assert(z2k_autopilot_parse_ip("142.250.74.1"))
    local ip_good_ggc = assert(z2k_autopilot_parse_ip("46.61.136.1"))
    local ip_isp_cold = assert(z2k_autopilot_parse_ip("46.61.136.2"))
    local ip_bad_byp = assert(z2k_autopilot_parse_ip("142.250.74.2"))
    write_file(pol_path, string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=2\tusable_v6=0\tpreflight_sni=white.example.org\tresyn_delay_ms=180\tpreflight_giveup_ms=1450\n"
        .. "type=ip\taddr=142.250.74.1\tkind=google\tverdict=good_direct\n"
        .. "type=ip\taddr=46.61.136.1\tkind=isp\tverdict=good_ggc\n"
        .. "type=ip\taddr=46.61.136.2\tkind=isp\tverdict=unknown\n"
        .. "type=ip\taddr=142.250.74.2\tkind=google\tverdict=bad_bypassable\tresyn_delay_ms=210\tgiveup_ms=1300\n",
        math.floor(fake_now)
    ))

    -- Мгновенный байпас 0ms для good_direct, good_ggc, cold isp+unknown
    for _, case in ipairs({
        { "preflight 2.0 bypass good_direct", ip_good, 53001 },
        { "preflight 2.0 bypass good_ggc", ip_good_ggc, 53002 },
        { "preflight 2.0 bypass cold isp+unknown", ip_isp_cold, 53003 },
    }) do
        reset_all()
        local syn = tcp4_dis(CLI4, case[2], case[3], 443, TH_SYN, 10000)
        local v = z2k_preflight({}, { outgoing = true, ifout = "eth3", dis = syn, arg = { sni = "www.google.com", timeout = 4 } })
        is(case[1] .. " verdict=nil", nil, v)
        is(case[1] .. " cutoff=1", 1, cutoffs)
        is(case[1] .. " cancel=0", 0, cancels)
        is(case[1] .. " no flows state", nil, next(z2k_pf_flows))
    end

    -- При bad_bypassable: адаптивный SNI, resyn_delay_ms=210, активный giveup_ms=1300
    reset_all()
    local syn_b = tcp4_dis(CLI4, ip_bad_byp, 53010, 443, TH_SYN, 20000)
    local v_b = z2k_preflight({}, { outgoing = true, ifout = "eth3", fwmark = 0x40000000, dis = syn_b, arg = { sni = "www.google.com", timeout = 4 } })
    is("bad_bypassable enters probe_syn", VERDICT_MODIFY, v_b)
    is("adaptive preflight_sni overrides www.google.com", "rnd,sni=white.example.org", last_tls_mod_args[1])
    local gname, ginfo = next(timers)
    is("active giveup timer armed", true, gname ~= nil and ginfo.ms == 1300 and ginfo.oneshot == true)

    -- Если проба успела до resyn (SYN,ACK -> ClientHello -> ServerHello piece), resyn использует 210ms и снимает giveup timer
    z2k_preflight({}, { outgoing = false, dis = tcp4_dis(ip_bad_byp, CLI4, 443, 53010, TH_SYN + TH_ACK, 80000, 20001), arg = {} })
    z2k_preflight({}, { outgoing = false, dis = tcp4_dis(ip_bad_byp, CLI4, 443, 53010, TH_ACK, 80001, 20001, "SH"), arg = {} })
    is("giveup timer cancelled on teardown", nil, timers[gname])
    local _, rinfo = next(timers)
    is("resyn timer uses adaptive 210ms", 210, rinfo.ms)
    -- Запоздалый вызов giveup ничего не портит
    z2k_preflight_giveup_timer(gname, ginfo.data)
    is("late giveup callback after resyn is no-op", "resyn", select(2, next(z2k_pf_flows)).stage)

    -- Активный giveup в probe_syn (нет SYN,ACK от сервера): БЕЗ RST на пробу, шлёт сохранённый orig SYN
    reset_all()
    local syn_g1 = tcp4_dis(CLI4, ip_bad_byp, 53011, 443, TH_SYN, 30000)
    z2k_preflight({}, { outgoing = true, ifout = "eth3", fwmark = 0x40000000, dis = syn_g1, arg = { sni = "explicit.custom.net", timeout = 4 } })
    is("explicit non-default arg.sni kept", "rnd,sni=explicit.custom.net", last_tls_mod_args[1])
    local g1n, g1i = next(timers)
    rawsend_dissects = {}
    z2k_preflight_giveup_timer(g1n, g1i.data)
    is("giveup in probe_syn sends 1 orig SYN (no RST)", 1, #rawsend_dissects)
    is("giveup orig SYN keeps win=65535 and seq=30000", true,
        rawsend_dissects[1].dis.tcp.th_win == 65535 and rawsend_dissects[1].dis.tcp.th_seq == 30000)
    is("giveup marks done + gave_up", true, g1i.data.stage == "done" and g1i.data.gave_up == true)

    -- Активный giveup в probe_data (SYN,ACK был, ServerHello нет): шлёт RST на пробу + сохранённый orig SYN
    reset_all()
    local syn_g2 = tcp4_dis(CLI4, ip_bad_byp, 53012, 443, TH_SYN, 40000)
    z2k_preflight({}, { outgoing = true, ifout = "eth3", fwmark = 0x40000000, dis = syn_g2, arg = { timeout = 4 } })
    local g2n, g2i = next(timers)
    z2k_preflight({}, { outgoing = false, dis = tcp4_dis(ip_bad_byp, CLI4, 443, 53012, TH_SYN + TH_ACK, 90000, 40001), arg = {} })
    rawsend_dissects = {}
    z2k_preflight_giveup_timer(g2n, g2i.data)
    is("giveup in probe_data sends RST + orig SYN", 2, #rawsend_dissects)
    is("giveup pkt 1 is probe RST", TH_RST, rawsend_dissects[1].dis.tcp.th_flags)
    is("giveup pkt 2 is orig SYN", TH_SYN, rawsend_dissects[2].dis.tcp.th_flags)
    -- Последующий SYN,ACK от сервера проходит к клиенту без execution_plan_cancel
    cancels = 0
    local v_after = z2k_preflight({}, { outgoing = false, dis = tcp4_dis(ip_bad_byp, CLI4, 443, 53012, TH_SYN + TH_ACK, 95000, 40001), arg = {} })
    is("server SYN,ACK after giveup passes", nil, v_after)
    is("server SYN,ACK after giveup does not cancel circular", 0, cancels)

    -- :autopilot=0 на z2k_preflight отключает интеграцию с policy.dat
    reset_all()
    local syn_off = tcp4_dis(CLI4, ip_good, 53020, 443, TH_SYN, 50000)
    local v_off = z2k_preflight({}, { outgoing = true, ifout = "eth3", dis = syn_off, arg = { autopilot = "0", sni = "www.google.com", timeout = 4 } })
    is("autopilot=0 does not bypass good_direct", VERDICT_MODIFY, v_off)
    is("autopilot=0 keeps www.google.com SNI", "rnd,sni=www.google.com", last_tls_mod_args[1])
end

clear_files()
print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
