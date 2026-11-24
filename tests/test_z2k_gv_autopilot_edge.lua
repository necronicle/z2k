-- Edge-case regression tests for z2k-gv-autopilot + z2k-preflight v2.0
-- luacheck: globals DLOG bitand u32 u32add seq_ge bu8 bu32 find_tcp_option deepcopy blob tls_mod resolve_multi_pos delete_pos_1 rawsend_dissect rawsend reconstruct_dissect instance_cutoff_shim execution_plan_cancel direction_cutoff_opposite payload_check replay_first clock_getfloattime timer_set timer_del VERDICT_DROP VERDICT_PASS VERDICT_MODIFY TH_FIN TH_SYN TH_RST TH_PUSH TH_ACK TCP_KIND_NOOP TCP_KIND_MSS TCP_KIND_SCALE TCP_KIND_TS z2k_preflight z2k_preflight_giveup_timer z2k_autopilot_observe z2k_autopilot_stall_guard z2k_autopilot_stall_timer z2k_autopilot_reset z2k_autopilot_set_paths
-- luacheck: ignore 122

local ROOT = arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$") or "."
package.path = ROOT .. "/files/lua/?.lua;" .. ROOT .. "/tests/?.lua;" .. package.path

local PASS, FAIL = 0, 0
local function is(name, want, got)
    if want == got then
        PASS = PASS + 1
        io.write("[PASS] " .. name .. "\n")
    else
        FAIL = FAIL + 1
        io.write(string.format("[FAIL] %s: want=%s got=%s\n", name, tostring(want), tostring(got)))
    end
end

local tmp_dir = os.getenv("TMPDIR") or "/tmp"
local stamp = tostring(os.time())
local pol_file = tmp_dir .. "/z2k_edge_policy_" .. stamp .. ".dat"
local obs_file = tmp_dir .. "/z2k_edge_obs_" .. stamp .. ".tsv"
local neu_file = tmp_dir .. "/z2k_edge_neutral_" .. stamp .. ".txt"

local clock_now = os.time()
local orig_os_time = os.time
-- luacheck: ignore 122
os.time = function() return math.floor(clock_now) end
local timers = {}
local rawsend_dissects = {}
local cancels = 0
local cutoffs = 0

VERDICT_PASS, VERDICT_MODIFY, VERDICT_DROP = 0, 1, 2
TH_FIN, TH_SYN, TH_RST, TH_PUSH, TH_ACK = 1, 2, 4, 8, 16
TCP_KIND_NOOP, TCP_KIND_MSS, TCP_KIND_SCALE, TCP_KIND_TS = 1, 2, 3, 8

DLOG = function() end
clock_getfloattime = function() return clock_now end
bitand = function(a, b)
    local r, p = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
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
deepcopy = function(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, val in pairs(v) do t[k] = deepcopy(val) end
    return t
end
blob = function(_, name) return "BLOB[" .. name .. "]" end
tls_mod = function(b, opts) return b .. "(" .. opts .. ")" end
resolve_multi_pos = function(data) return { math.floor(#data / 2) + 1 } end
delete_pos_1 = function(a) if a[1] == 1 then table.remove(a, 1) end end
direction_cutoff_opposite = function() end
payload_check = function(desync, def)
    local want = (desync.arg and desync.arg.payload) or def
    return want == "all" or want == desync.l7payload
end
replay_first = function(desync) return not desync.replay or desync.replay_piece == 1 end
instance_cutoff_shim = function() cutoffs = cutoffs + 1 end
execution_plan_cancel = function() cancels = cancels + 1 end
rawsend = function() return true end
rawsend_dissect = function(dis, opts)
    rawsend_dissects[#rawsend_dissects + 1] = { dis = deepcopy(dis), opts = deepcopy(opts or {}) }
    return true
end
reconstruct_dissect = function(dis)
    if dis.raw then return dis.raw end
    if dis.ip6 then return string.char(0x60, 0, 0, 0, 0, 20, 17, 64) .. dis.ip6.ip6_src .. dis.ip6.ip6_dst .. "UDP" end
    return string.char(0x45, 0, 0, 60, 1, 2, 0, 0, 64, 17, 0, 0) .. dis.ip.ip_src .. dis.ip.ip_dst .. "UDP"
end
timer_set = function(name, cb, ms, oneshot, data)
    timers[name] = { name = name, cb = cb, ms = ms, oneshot = oneshot, data = data }
    return true
end
timer_del = function(name)
    timers[name] = nil
end

dofile(ROOT .. "/files/lua/z2k-quic-reject.lua")
dofile(ROOT .. "/files/lua/z2k-gv-autopilot.lua")
dofile(ROOT .. "/files/lua/z2k-preflight.lua")

z2k_autopilot_set_paths(pol_file, obs_file, neu_file)

local function ip4_bytes(a, b, c, d)
    return string.char(a, b, c, d)
end

local CLI4 = ip4_bytes(192, 168, 1, 10)
local IP_ISP = ip4_bytes(10, 88, 1, 10)
local IP_GFE = ip4_bytes(142, 250, 74, 14)
local IP_YT = ip4_bytes(142, 250, 74, 20)
local IP_PFX_ONLY = ip4_bytes(185, 40, 12, 99)
local IP_BAD_BYP = ip4_bytes(203, 0, 113, 55)

local function tcp4(src, dst, sport, dport, flags, seq, ack, payload)
    return {
        ip = { ip_src = src, ip_dst = dst, ip_p = 6, ip_ttl = 64, ip_v = 4, ip_hl = 5 },
        tcp = {
            th_sport = sport,
            th_dport = dport,
            th_flags = flags,
            th_seq = seq or 1000,
            th_ack = ack or 0,
            th_win = 65535,
            th_off = 5,
            options = { { kind = TCP_KIND_MSS, data = "\5\180" }, { kind = TCP_KIND_TS, data = bu32(1) .. bu32(0) } },
        },
        payload = payload or "",
    }
end

local function u16be(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function make_tls_ch(sni)
    local host_entry = "\0" .. u16be(#sni) .. sni
    local sni_list = u16be(#host_entry) .. host_entry
    local sni_ext = "\0\0" .. u16be(#sni_list) .. sni_list
    local exts = u16be(#sni_ext) .. sni_ext
    local body = "\3\3" .. string.rep("\1", 32) .. "\0" .. "\0\2\19\1" .. "\1\0" .. exts
    local hs = "\1\0" .. u16be(#body) .. body
    return "\22\3\1" .. u16be(#hs) .. hs
end

local function write_policy(lines)
    local f = assert(io.open(pol_file, "w"))
    for _, ln in ipairs(lines) do
        f:write(ln .. "\n")
    end
    f:close()
    z2k_autopilot_reset()
    z2k_autopilot_set_paths(pol_file, obs_file, neu_file)
end

local function read_observed()
    local f = io.open(obs_file, "r")
    if not f then return "" end
    local s = f:read("*a") or ""
    f:close()
    return s
end

local function reset_state()
    clock_now = clock_now + 5
    timers = {}
    rawsend_dissects = {}
    cancels = 0
    cutoffs = 0
    os.remove(obs_file)
    os.remove(neu_file)
    local reset_pf = rawget(_G, "z2k_preflight_reset")
    if reset_pf then reset_pf() end
end

local function invoke_timer(tname, tinfo)
    if not tinfo then return end
    local fn = type(tinfo.cb) == "function" and tinfo.cb or _G[tinfo.cb]
    if fn then fn(tname, tinfo.data) end
end

local function find_timer(prefix)
    for k, v in pairs(timers) do
        if k:sub(1, #prefix) == prefix then
            return k, v
        end
    end
    return nil, nil
end

write_policy({
    string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=1\tusable_v6=1\tglobal_quic_blocked=0\tpreflight_sni=alt.white.ru\tresyn_delay_ms=140\tpreflight_giveup_ms=1200\tggc_stall_guard_ms=1800",
        clock_now
    ),
    "type=prefix\taddr=185.40.12.0/24\tkind=google\tverdict=good_direct\tquic_ok=1",
    "type=ip\taddr=10.88.1.10\tkind=isp\tverdict=good_ggc\tquic_ok=0\tstall_ms=1900",
    "type=ip\taddr=142.250.74.14\tkind=gfe\tverdict=good_direct\tquic_ok=0",
    "type=ip\taddr=142.250.74.20\tkind=yt\tverdict=good_direct\tquic_ok=0",
    "type=ip\taddr=203.0.113.55\tkind=google\tverdict=bad_bypassable\tquic_ok=0\tpreflight_sni=alt.white.ru\tresyn_delay_ms=140\tgiveup_ms=1200",
})

-- 1. observe_packet MUST log *.googlevideo.com even when IP was classified as gfe or yt
reset_state()
local ch_gfe = make_tls_ch("rr1---sn-test.googlevideo.com")
local ch_yt = make_tls_ch("rr2---sn-test.googlevideo.com")
z2k_autopilot_observe({}, {
    outgoing = true,
    l7payload = "tls_client_hello",
    track = { hostname = "rr1---sn-test.googlevideo.com", lua_state = {} },
    dis = tcp4(CLI4, IP_GFE, 40001, 443, TH_ACK + TH_PUSH, 10, 20, ch_gfe),
})
z2k_autopilot_observe({}, {
    outgoing = true,
    l7payload = "tls_client_hello",
    track = { hostname = "rr2---sn-test.googlevideo.com", lua_state = {} },
    dis = tcp4(CLI4, IP_YT, 40002, 443, TH_ACK + TH_PUSH, 10, 20, ch_yt),
})
local obs_data = read_observed()
is("gfe exact IP still logs googlevideo SNI", true, obs_data:find("142.250.74.14\trr1---sn-test.googlevideo.com", 1, true) ~= nil)
is("yt exact IP still logs googlevideo SNI", true, obs_data:find("142.250.74.20\trr2---sn-test.googlevideo.com", 1, true) ~= nil)

-- 2. stall_guard does NOT cut off google/play on SYN before ClientHello is observed (/24 prefix match)
reset_state()
local track_pfx = { hostname = "rr3---sn-pfx.googlevideo.com", lua_state = {} }
local ch_pfx = make_tls_ch("rr3---sn-pfx.googlevideo.com")
z2k_autopilot_stall_guard({}, {
    outgoing = true,
    track = track_pfx,
    dis = tcp4(CLI4, IP_PFX_ONLY, 41001, 443, TH_SYN, 100, 0, ""),
})
is("prefix google SYN does not cut off before ClientHello", 0, cutoffs)
z2k_autopilot_stall_guard({}, {
    outgoing = true,
    l7payload = "tls_client_hello",
    track = track_pfx,
    dis = tcp4(CLI4, IP_PFX_ONLY, 41001, 443, TH_ACK + TH_PUSH, 101, 200, ch_pfx),
})
is("prefix google ClientHello logs new neighbor IP", true, read_observed():find("185.40.12.99\trr3---sn-pfx.googlevideo.com", 1, true) ~= nil)
is("prefix google ClientHello cuts off after observe", 1, cutoffs)

-- 3. stall_guard TLS 1.2 sequence: CKE+CCS+Finished (0x16/0x14) must NOT arm; server CCS+Finished must NOT mark done!
reset_state()
local tls_ch_rec = "\22\3\3\0\4\1\0\0\0"
local tls_sh_rec = "\22\3\3\0\4\2\0\0\0"
local tls12_cli_cke_ccs_fin = "\22\3\3\0\4\16\0\0\0" .. "\20\3\3\0\1\1" .. "\22\3\3\0\4\20\0\0\0"
local tls12_srv_ccs_fin = "\20\3\3\0\1\1" .. "\22\3\3\0\4\20\0\0\0"
local tls12_cli_appdata = "\23\3\3\0\5hello"
local tls12_srv_appdata = "\23\3\3\0\5world"

local track12 = { lua_state = {} }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000,
    l7payload = "tls_client_hello", track = track12,
    dis = tcp4(CLI4, IP_ISP, 42001, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false,
    l7payload = "tls_server_hello", track = track12,
    dis = tcp4(IP_ISP, CLI4, 443, 42001, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000,
    l7payload = "unknown", track = track12,
    dis = tcp4(CLI4, IP_ISP, 42001, 443, TH_ACK + TH_PUSH, 109, 209, tls12_cli_cke_ccs_fin),
})
is("TLS 1.2 CKE+CCS+Fin does not arm stall timer", nil, next(timers))
z2k_autopilot_stall_guard({}, {
    outgoing = false,
    l7payload = "unknown", track = track12,
    dis = tcp4(IP_ISP, CLI4, 443, 42001, TH_ACK + TH_PUSH, 209, 133, tls12_srv_ccs_fin),
})
is("TLS 1.2 server CCS+Fin does not set z2k_sg_done", nil, track12.lua_state.z2k_sg_done)
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000,
    l7payload = "unknown", track = track12,
    dis = tcp4(CLI4, IP_ISP, 42001, 443, TH_ACK + TH_PUSH, 133, 224, tls12_cli_appdata),
})
local tn12, ti12 = next(timers)
is("TLS 1.2 client AppData arms stall timer", true, tn12 ~= nil)
is("TLS 1.2 stall timer delay matches 1900ms", 1900, ti12 and ti12.ms or -1)
z2k_autopilot_stall_guard({}, {
    outgoing = false,
    l7payload = "unknown", track = track12,
    dis = tcp4(IP_ISP, CLI4, 443, 42001, TH_ACK + TH_PUSH, 209, 133, tls12_srv_ccs_fin),
})
is("TLS 1.2 server CCS while armed keeps timer alive", true, timers[tn12] ~= nil)
z2k_autopilot_stall_guard({}, {
    outgoing = false,
    l7payload = "unknown", track = track12,
    dis = tcp4(IP_ISP, CLI4, 443, 42001, TH_ACK + TH_PUSH, 224, 143, tls12_srv_appdata),
})
is("TLS 1.2 server AppData cancels stall timer", nil, timers[tn12])
is("TLS 1.2 server AppData marks z2k_sg_done", true, track12.lua_state.z2k_sg_done)
is("TLS 1.2 server AppData calls cutoff", 1, cutoffs)

-- 4. TLS 1.3 bare CCS before AppData + TCP RST cleanup while armed
reset_state()
local track13 = { lua_state = {} }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000,
    l7payload = "tls_client_hello", track = track13,
    dis = tcp4(CLI4, IP_ISP, 43001, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false,
    l7payload = "tls_server_hello", track = track13,
    dis = tcp4(IP_ISP, CLI4, 443, 43001, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000,
    l7payload = "unknown", track = track13,
    dis = tcp4(CLI4, IP_ISP, 43001, 443, TH_ACK + TH_PUSH, 109, 209, "\20\3\3\0\1\1"),
})
is("TLS 1.3 bare CCS does not arm stall timer", nil, next(timers))
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000,
    l7payload = "unknown", track = track13,
    dis = tcp4(CLI4, IP_ISP, 43001, 443, TH_ACK + TH_PUSH, 115, 209, tls12_cli_appdata),
})
local tn13, ti13 = next(timers)
is("TLS 1.3 AppData arms stall timer", true, tn13 ~= nil)
z2k_autopilot_stall_guard({}, {
    outgoing = false,
    track = track13,
    dis = tcp4(IP_ISP, CLI4, 443, 43001, TH_RST, 209, 125, ""),
})
is("TCP RST (plen=0) cancels armed stall timer", nil, timers[tn13])
is("TCP RST marks z2k_sg_done", true, track13.lua_state.z2k_sg_done)
invoke_timer(tn13, ti13)
is("late stall callback after TCP RST sends 0 RSTs", 0, #rawsend_dissects)

-- 4b. TLS 1.3 CCS+ClientFinished (64B) не ставит таймер; следующий реальный AppData ставит;
-- прогресс th_ack от клиента (ответ сервера скрыт connbytes) снимает таймер;
-- при >=7 входящих пакетах (порог connbytes 0:10) таймер не ставится.
reset_state()
local track13fin = { lua_state = {} }
local tls13_ccs_fin = "\20\3\3\0\1\1\23\3\3\0\53" .. string.rep("f", 53)
local tls13_http_req = "\23\3\3\0\120" .. string.rep("r", 120)
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000,
    l7payload = "tls_client_hello", track = track13fin,
    dis = tcp4(CLI4, IP_ISP, 43011, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false,
    l7payload = "tls_server_hello", track = track13fin,
    dis = tcp4(IP_ISP, CLI4, 443, 43011, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000,
    l7payload = "unknown", track = track13fin,
    dis = tcp4(CLI4, IP_ISP, 43011, 443, TH_ACK + TH_PUSH, 109, 209, tls13_ccs_fin),
})
is("TLS 1.3 CCS+ClientFinished (64B) does not arm stall timer", nil, next(timers))
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", fwmark = 0x40000000,
    l7payload = "unknown", track = track13fin,
    dis = tcp4(CLI4, IP_ISP, 43011, 443, TH_ACK + TH_PUSH, 173, 209, tls13_http_req),
})
local tn_fin, ti_fin = next(timers)
is("TLS 1.3 real HTTP request after ClientFinished arms timer", true, tn_fin ~= nil)
-- Повторный пакет с тем же ack=209 НЕ снимает таймер
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track13fin,
    dis = tcp4(CLI4, IP_ISP, 43011, 443, TH_ACK, 298, 209, tls12_cli_appdata),
})
is("same client th_ack keeps stall timer alive", true, timers[tn_fin] ~= nil)
-- Клиент подтвердил новые байты от сервера (ack=498 > 209) -> сервер ответил за пределами connbytes!
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track13fin,
    dis = tcp4(CLI4, IP_ISP, 43011, 443, TH_ACK + TH_PUSH, 308, 498, "\23\3\3\0\19" .. string.rep("c", 19)),
})
is("client th_ack progress cancels stall timer", nil, timers[tn_fin])
is("client th_ack progress marks z2k_sg_done", true, track13fin.lua_state.z2k_sg_done)
invoke_timer(tn_fin, ti_fin)
is("stale timer after client th_ack progress sends 0 RSTs", 0, #rawsend_dissects)

-- 1) 9 пустых dup-ACK на фейки + 4 сегмента ServerHello + 4 replay (in_total=14, in_data=4, srv_bytes=4486)
-- взводят stall_guard и отменяются пустым ACK клиента с продвинутым th_ack.
reset_state()
local track_dup = { lua_state = {} }
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "empty", track = track_dup,
    dis = tcp4(IP_ISP, CLI4, 443, 43012, TH_SYN + TH_ACK, 199, 100, ""),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_dup,
    dis = tcp4(CLI4, IP_ISP, 43012, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
for _ = 1, 9 do
    z2k_autopilot_stall_guard({}, {
        outgoing = false, l7payload = "empty", track = track_dup,
        dis = tcp4(IP_ISP, CLI4, 443, 43012, TH_ACK, 200, 100, ""),
    })
end
local sh_segs = {
    { seq = 200, len = 1400, l7 = "tls_server_hello", data = tls_sh_rec .. string.rep("s", 1400 - #tls_sh_rec) },
    { seq = 1600, len = 1400, l7 = "unknown", data = string.rep("s", 1400) },
    { seq = 3000, len = 1400, l7 = "unknown", data = string.rep("s", 1400) },
    { seq = 4400, len = 286, l7 = "unknown", data = string.rep("s", 286) },
}
for _, s in ipairs(sh_segs) do
    z2k_autopilot_stall_guard({}, {
        outgoing = false, l7payload = s.l7, track = track_dup,
        dis = tcp4(IP_ISP, CLI4, 443, 43012, TH_ACK + TH_PUSH, s.seq, 109, s.data),
    })
    z2k_autopilot_stall_guard({}, {
        outgoing = false, replay = true, l7payload = s.l7, track = track_dup,
        dis = tcp4(IP_ISP, CLI4, 443, 43012, TH_ACK + TH_PUSH, s.seq, 109, s.data),
    })
end
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_dup,
    dis = tcp4(CLI4, IP_ISP, 43012, 443, TH_ACK + TH_PUSH, 109, 4686, tls13_http_req),
})
local tn_d, ti_d = find_timer("z2k_sg_")
is("9 empty dup-ACKs + 4 ServerHello segs (in_data=4, in_total=14) arms stall guard", true, tn_d ~= nil)
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "empty", track = track_dup,
    dis = tcp4(CLI4, IP_ISP, 43012, 443, TH_ACK, 234, 4900, ""),
})
is("empty client ACK progress cancels dup-ACK armed stall timer", nil, timers[tn_d])
invoke_timer(tn_d, ti_d)
is("stale timer after dup-ACK empty ACK sends 0 RSTs", 0, #rawsend_dissects)

-- 2) Относительная ориентация track.pos в nfqws2: на outgoing=true pos.reverse — входящие, pos.direct — исходящие
reset_state()
local track_pcnt = { lua_state = {}, pos = { direct = { pcounter = 1, pdcounter = 0 }, reverse = { pcounter = 0, pdcounter = 0 } } }
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "empty", track = track_pcnt,
    dis = tcp4(IP_ISP, CLI4, 443, 43013, TH_SYN + TH_ACK, 999, 100, ""),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_pcnt,
    dis = tcp4(CLI4, IP_ISP, 43013, 443, TH_ACK + TH_PUSH, 100, 1000, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "tls_server_hello", track = track_pcnt,
    dis = tcp4(IP_ISP, CLI4, 443, 43013, TH_ACK + TH_PUSH, 1000, 109, string.rep("x", 4487)),
})
track_pcnt.pos.reverse = { pcounter = 15, pdcounter = 4 }
track_pcnt.pos.direct = { pcounter = 11, pdcounter = 3 }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_pcnt,
    dis = tcp4(CLI4, IP_ISP, 43013, 443, TH_ACK + TH_PUSH, 109, 5487, tls13_http_req),
})
local tn_p, ti_p = find_timer("z2k_sg_")
is("reverse={pcnt=15,pdcnt=4} / direct={pcnt=11,pdcnt=3} arms stall guard", true, tn_p ~= nil)
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_pcnt,
    dis = tcp4(CLI4, IP_ISP, 43013, 443, TH_ACK, 234, 6200, ""),
})
is("client ACK progress cancels stall timer after pcounter arming", nil, timers[tn_p])
invoke_timer(tn_p, ti_p)
is("stale timer after pcounter client ACK sends 0 RSTs", 0, #rawsend_dissects)

-- 3) in_data_pkts >= 10 (10 входящих пакетов с plen > 0) пропускает взведение и ставит z2k_sg_done
reset_state()
local track_in_cap = { lua_state = {} }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_in_cap,
    dis = tcp4(CLI4, IP_ISP, 43014, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "tls_server_hello", track = track_in_cap,
    dis = tcp4(IP_ISP, CLI4, 443, 43014, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
for seg = 1, 9 do
    z2k_autopilot_stall_guard({}, {
        outgoing = false, l7payload = "unknown", track = track_in_cap,
        dis = tcp4(IP_ISP, CLI4, 443, 43014, TH_ACK + TH_PUSH, 200 + seg * 100, 109, string.rep("d", 100)),
    })
end
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_in_cap,
    dis = tcp4(CLI4, IP_ISP, 43014, 443, TH_ACK + TH_PUSH, 109, 1200, tls13_http_req),
})
is("stall guard skips arming when in_data_pkts >= 10", nil, next(timers))
is("stall guard marks done when in_data_pkts >= 10", true, track_in_cap.lua_state.z2k_sg_done)

-- 4) out_pkts >= 24 (pos.direct.pcounter = 24 на outgoing=true) пропускает взведение и ставит z2k_sg_done;
-- при out_pkts = 16 (многопакетный ~10КБ SABR POST /videoplayback) взводится при наличии запаса окна.
reset_state()
local track_out_sabr = { lua_state = {}, pos = { direct = { pcounter = 16, pdcounter = 14 }, reverse = { pcounter = 5, pdcounter = 4 } } }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_out_sabr,
    dis = tcp4(CLI4, IP_ISP, 430150, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "tls_server_hello", track = track_out_sabr,
    dis = tcp4(IP_ISP, CLI4, 443, 430150, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_out_sabr,
    dis = tcp4(CLI4, IP_ISP, 430150, 443, TH_ACK + TH_PUSH, 109, 209, tls13_http_req),
})
is("stall guard still arms for direct.pcounter=16 (SABR POST)", true, next(timers) ~= nil)

reset_state()
local track_out_cap = { lua_state = {}, pos = { direct = { pcounter = 24, pdcounter = 3 }, reverse = { pcounter = 5, pdcounter = 4 } } }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_out_cap,
    dis = tcp4(CLI4, IP_ISP, 43015, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "tls_server_hello", track = track_out_cap,
    dis = tcp4(IP_ISP, CLI4, 443, 43015, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_out_cap,
    dis = tcp4(CLI4, IP_ISP, 43015, 443, TH_ACK + TH_PUSH, 109, 209, tls13_http_req),
})
is("stall guard skips arming when direct.pcounter >= 24", nil, next(timers))
is("stall guard marks done when direct.pcounter >= 24", true, track_out_cap.lua_state.z2k_sg_done)

-- 5) srv_bytes > 16384 (th_ack ушёл >16 КБ от srv_base_seq) пропускает взведение и ставит z2k_sg_done
reset_state()
local track_bytes_cap = { lua_state = {}, pos = { direct = { pcounter = 4, pdcounter = 2 }, reverse = { pcounter = 5, pdcounter = 4 } } }
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "empty", track = track_bytes_cap,
    dis = tcp4(IP_ISP, CLI4, 443, 43016, TH_SYN + TH_ACK, 199, 100, ""),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_bytes_cap,
    dis = tcp4(CLI4, IP_ISP, 43016, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "tls_server_hello", track = track_bytes_cap,
    dis = tcp4(IP_ISP, CLI4, 443, 43016, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_bytes_cap,
    dis = tcp4(CLI4, IP_ISP, 43016, 443, TH_ACK + TH_PUSH, 109, 20200, tls13_http_req),
})
is("stall guard skips arming when srv_bytes > 16384", nil, next(timers))
is("stall guard marks done when srv_bytes > 16384", true, track_bytes_cap.lua_state.z2k_sg_done)

-- 6) Воспроизведение кейса 49780: out_pkts=11, in_total=14, in_data=4 (est_out=20).
-- При узком окне out_limit=20 не взводится (иначе ACK ответа отрежет ядро),
-- а при штатном окне 30 успешно взводится и отменяется пустым ACK клиента.
reset_state()
local track_49780_narrow = { lua_state = {}, pos = { direct = { pcounter = 11, pdcounter = 3 }, reverse = { pcounter = 14, pdcounter = 4 } } }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", arg = { out_limit = 20 },
    l7payload = "tls_client_hello", track = track_49780_narrow,
    dis = tcp4(CLI4, IP_ISP, 43017, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, arg = { out_limit = 20 }, l7payload = "tls_server_hello", track = track_49780_narrow,
    dis = tcp4(IP_ISP, CLI4, 443, 43017, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", arg = { out_limit = 20 },
    l7payload = "unknown", track = track_49780_narrow,
    dis = tcp4(CLI4, IP_ISP, 43017, 443, TH_ACK + TH_PUSH, 109, 209, tls13_http_req),
})
is("stall guard skips arming for est_out=20 at out_limit=20", nil, next(timers))
is("stall guard marks done for est_out=20 at out_limit=20", true, track_49780_narrow.lua_state.z2k_sg_done)

reset_state()
local track_49780_wide = { lua_state = {}, pos = { direct = { pcounter = 11, pdcounter = 3 }, reverse = { pcounter = 14, pdcounter = 4 } } }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_49780_wide,
    dis = tcp4(CLI4, IP_ISP, 43018, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "tls_server_hello", track = track_49780_wide,
    dis = tcp4(IP_ISP, CLI4, 443, 43018, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_49780_wide,
    dis = tcp4(CLI4, IP_ISP, 43018, 443, TH_ACK + TH_PUSH, 109, 209, tls13_http_req),
})
local tn_w, ti_w = find_timer("z2k_sg_")
is("stall guard arms for est_out=20 at default window 45", true, tn_w ~= nil)
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "empty", track = track_49780_wide,
    dis = tcp4(CLI4, IP_ISP, 43018, 443, TH_ACK, 234, 300, ""),
})
is("stall guard cancels on client ACK progress at default window 45", nil, timers[tn_w])
invoke_timer(tn_w, ti_w)
is("stale timer after est_out=20 client ACK sends 0 RSTs", 0, #rawsend_dissects)

-- 7) Отмена уже взведённого таймера при приближении к границе connbytes (45) без продвижения ACK
reset_state()
local track_bnd = { lua_state = {}, pos = { direct = { pcounter = 10, pdcounter = 2 }, reverse = { pcounter = 10, pdcounter = 3 } } }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_bnd,
    dis = tcp4(CLI4, IP_ISP, 43019, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "tls_server_hello", track = track_bnd,
    dis = tcp4(IP_ISP, CLI4, 443, 43019, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_bnd,
    dis = tcp4(CLI4, IP_ISP, 43019, 443, TH_ACK + TH_PUSH, 109, 209, tls13_http_req),
})
local tn_b, ti_b = find_timer("z2k_sg_")
is("stall guard arms before connbytes boundary", true, tn_b ~= nil)
track_bnd.pos.direct = { pcounter = 38, pdcounter = 4 }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "empty", track = track_bnd,
    dis = tcp4(CLI4, IP_ISP, 43019, 443, TH_ACK, 234, 209, ""),
})
is("stall guard cancels at connbytes boundary without ACK progress", nil, timers[tn_b])
is("stall guard marks done at connbytes boundary", true, track_bnd.lua_state.z2k_sg_done)
invoke_timer(tn_b, ti_b)
is("stale timer after connbytes boundary cancel sends 0 RSTs", 0, #rawsend_dissects)

-- 8) Пропуск собственной активной пробы Контура-2 демона gvsub (.neutral, ifin="")
reset_state()
local nf = assert(io.open(neu_file, "w"))
nf:write("probe 0a58010a\n")
nf:close()
z2k_autopilot_set_paths(pol_file, obs_file, neu_file)
local track_probe = { lua_state = {} }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = nil, ifout = "eth3",
    l7payload = "empty", track = track_probe,
    dis = tcp4(CLI4, IP_ISP, 43020, 443, TH_SYN, 100, 0, ""),
})
is("stall guard marks done on active gvsub probe SYN", true, track_probe.lua_state.z2k_sg_done)
is("stall guard skips timer on active gvsub probe", nil, next(timers))
is("stall guard calls instance cutoff on active gvsub probe", 1, cutoffs)

-- 5. Preflight 2.0 giveup timer cleanup on replace and timeout
reset_state()
local syn_rep1 = tcp4(CLI4, IP_BAD_BYP, 44001, 443, TH_SYN, 5000, 0, "")
z2k_preflight({}, { outgoing = true, ifout = "eth3", dis = syn_rep1, arg = { timeout = 4 } })
local g_name1, g_info1 = find_timer("z2k_pf_giveup_")
is("giveup timer created on first SYN", true, g_name1 ~= nil)
local syn_rep2 = tcp4(CLI4, IP_BAD_BYP, 44001, 443, TH_SYN, 6000, 0, "")
z2k_preflight({}, { outgoing = true, ifout = "eth3", dis = syn_rep2, arg = { timeout = 4 } })
local g_name2, _ = find_timer("z2k_pf_giveup_")
rawsend_dissects = {}
invoke_timer(g_name1, g_info1)
is("replaced giveup callback sends 0 packets", 0, #rawsend_dissects)
clock_now = clock_now + 5.0
z2k_preflight({}, { outgoing = true, ifout = "eth3", dis = tcp4(CLI4, IP_BAD_BYP, 44001, 443, TH_SYN, 6000, 0, ""), arg = { timeout = 4 } })
is("timeout cancels giveup timer", nil, timers[g_name2])

-- Sweep (>60s TTL) cancels giveup timer on forgotten flow
local syn_sw = tcp4(CLI4, IP_BAD_BYP, 44002, 443, TH_SYN, 7000, 0, "")
z2k_preflight({}, { outgoing = true, ifout = "eth3", dis = syn_sw, arg = { timeout = 4 } })
local g_sw, _ = find_timer("z2k_pf_giveup_")
is("sweep test giveup timer created", true, g_sw ~= nil)
clock_now = clock_now + 65.0
-- Touch fresh policy so autopilot lookup doesn't bypass on stale
write_policy({
    string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=1\tusable_v6=1\tglobal_quic_blocked=0\tpreflight_sni=alt.white.ru\tresyn_delay_ms=140\tpreflight_giveup_ms=1200\tggc_stall_guard_ms=1800",
        clock_now
    ),
    "type=ip\taddr=203.0.113.55\tkind=google\tverdict=bad_bypassable\tquic_ok=0\tpreflight_sni=alt.white.ru\tresyn_delay_ms=140\tgiveup_ms=1200",
})
z2k_preflight({}, { outgoing = true, ifout = "eth3", dis = tcp4(CLI4, IP_BAD_BYP, 44003, 443, TH_SYN, 8000, 0, ""), arg = { timeout = 4 } })
is("sweep removes expired flow giveup timer", nil, timers[g_sw])

-- 9) DoH heartbeat (600s) для уже классифицированного IP на длинных сессиях (30-60+ мин)
reset_state()
local hb_ip = ip4_bytes(10, 88, 1, 20)
local hb_host = "rr5---sn-hb.googlevideo.com"
local ch_hb = make_tls_ch(hb_host)
local function write_hb_policy(ts)
    local pf = assert(io.open(pol_file, "w"))
    pf:write(string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=1\tusable_v6=1\tglobal_quic_blocked=0\tpreflight_sni=alt.white.ru\tresyn_delay_ms=140\tpreflight_giveup_ms=1200\tggc_stall_guard_ms=1800\n"
        .. "type=ip\taddr=10.88.1.20\tkind=isp\tverdict=good_ggc\tquic_ok=1\tstall_ms=1900\n",
        math.floor(ts)
    ))
    pf:close()
end
write_hb_policy(clock_now)
z2k_autopilot_reset()
z2k_autopilot_set_paths(pol_file, obs_file, neu_file)

local hb_t0 = clock_now
local function send_hb(ts, ifin_val, ip_raw, host_name, ch_buf)
    clock_now = ts
    write_hb_policy(ts)
    z2k_autopilot_observe({}, {
        outgoing = true,
        ifin = ifin_val,
        l7payload = "tls_client_hello",
        track = { hostname = host_name, lua_state = {} },
        dis = tcp4(CLI4, ip_raw, 45001, 443, TH_ACK + TH_PUSH, 100, 200, ch_buf),
    })
end

send_hb(hb_t0, "br0", hb_ip, hb_host, ch_hb)
is("classified IP first observe does not write disk", "", read_observed())
send_hb(hb_t0 + 250, "br0", hb_ip, hb_host, ch_hb)
is("classified IP within 250s does not write heartbeat", "", read_observed())
send_hb(hb_t0 + 599, "br0", hb_ip, hb_host, ch_hb)
is("classified IP at 599s still skips heartbeat", "", read_observed())
send_hb(hb_t0 + 605, "br0", hb_ip, hb_host, ch_hb)
local obs_hb1 = read_observed()
is("classified IP after 600s writes DoH heartbeat", true, obs_hb1:find("10.88.1.20\trr5---sn-hb.googlevideo.com\n", 1, true) ~= nil)
send_hb(hb_t0 + 900, "br0", hb_ip, hb_host, ch_hb)
is("classified IP at 900s does not duplicate heartbeat", #obs_hb1, #read_observed())
send_hb(hb_t0 + 1210, "br0", hb_ip, hb_host, ch_hb)
is("classified IP after next 600s writes second heartbeat", true, #read_observed() > #obs_hb1)

-- 10) Собственные зонды Контура-2 gvsub (.neutral probe, ifin=""/nil) не засоряют observed.tsv
reset_state()
local obs_probe_ip = ip4_bytes(10, 88, 1, 33) -- hex 0a580121
local np_obs = assert(io.open(neu_file, "w"))
np_obs:write("probe 0a580121\n")
np_obs:close()
send_hb(clock_now + 2, "", obs_probe_ip, "rr1---sn-c2probe.googlevideo.com", make_tls_ch("rr1---sn-c2probe.googlevideo.com"))
send_hb(clock_now + 2, nil, obs_probe_ip, "rr2---sn-c2probe.googlevideo.com", make_tls_ch("rr2---sn-c2probe.googlevideo.com"))
is("active gvsub probe (ifin empty/nil) skips observed.tsv", "", read_observed())
send_hb(clock_now + 2, "br0", obs_probe_ip, "rr1---sn-c2probe.googlevideo.com", make_tls_ch("rr1---sn-c2probe.googlevideo.com"))
is("LAN client on same IP logs immediately after probe skipped", true, read_observed():find("10.88.1.33\trr1---sn-c2probe.googlevideo.com\n", 1, true) ~= nil)

-- 11) Ретрансмиссия хвоста 2-пакетного PQ ClientHello (tls=other, c_next == cli_next_seq) после ServerHello
-- на preconnect-сокете НЕ должна взводить stall_guard; последующий реальный HTTP GET — должен.
reset_state()
write_policy({
    string.format(
        "type=header\tversion=1\tupdated=%d\tusable_v4=1\tusable_v6=1\tglobal_quic_blocked=0\tpreflight_sni=alt.white.ru\tresyn_delay_ms=140\tpreflight_giveup_ms=1200\tggc_stall_guard_ms=1800",
        math.floor(clock_now)
    ),
    "type=prefix\taddr=185.40.12.0/24\tkind=google\tverdict=good_direct\tquic_ok=1",
    "type=ip\taddr=10.88.1.10\tkind=isp\tverdict=good_ggc\tquic_ok=0\tstall_ms=1900",
    "type=ip\taddr=142.250.74.14\tkind=gfe\tverdict=good_direct\tquic_ok=0",
    "type=ip\taddr=142.250.74.20\tkind=yt\tverdict=good_direct\tquic_ok=0",
    "type=ip\taddr=203.0.113.55\tkind=google\tverdict=bad_bypassable\tquic_ok=0\tpreflight_sni=alt.white.ru\tresyn_delay_ms=140\tgiveup_ms=1200",
})
local track_pq_retx = { lua_state = {} }
local pq_ch1 = "\22\3\1\7\25\1\0" .. string.rep("a", 1393) -- len=1400, seq 1000..2400
local pq_ch2 = string.rep("b", 422)                         -- len=422, seq 2400..2822 (tls=other)
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_pq_retx,
    dis = tcp4(CLI4, IP_ISP, 46001, 443, TH_ACK, 1000, 5000, pq_ch1),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_pq_retx,
    dis = tcp4(CLI4, IP_ISP, 46001, 443, TH_ACK + TH_PUSH, 2400, 5000, pq_ch2),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "tls_server_hello", track = track_pq_retx,
    dis = tcp4(IP_ISP, CLI4, 443, 46001, TH_ACK + TH_PUSH, 5000, 2822, tls_sh_rec),
})
-- RACK/TLP ретрансмит pq_ch2 (seq=2400, len=422 -> c_next=2822 == cli_next_seq) + TLS 1.3 ClientFinished (64B)
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_pq_retx,
    dis = tcp4(CLI4, IP_ISP, 46001, 443, TH_ACK + TH_PUSH, 2400, 5009, pq_ch2),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_pq_retx,
    dis = tcp4(CLI4, IP_ISP, 46001, 443, TH_ACK + TH_PUSH, 2822, 5009, tls13_ccs_fin),
})
is("PQ CH2 retransmission sees ServerHello for ISP GGC", true, track_pq_retx.lua_state.z2k_sg ~= nil and track_pq_retx.lua_state.z2k_sg.saw_server_hello)
is("PQ CH2 retransmission keeps z2k_sg_done nil", nil, track_pq_retx.lua_state.z2k_sg_done)
is("PQ CH2 retransmission after ServerHello + ClientFinished does NOT arm stall_guard", nil, next(timers))
is("PQ preconnect idle sends 0 RSTs", 0, #rawsend_dissects)

-- Повтор с реальным HTTP GET (seq=2886, len=125 -> c_next=3011 > 2886) после ретрансмита CH2: ДОЛЖЕН взвестись
reset_state()
local track_pq_http = { lua_state = {} }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "tls_client_hello", track = track_pq_http,
    dis = tcp4(CLI4, IP_ISP, 46002, 443, TH_ACK, 1000, 5000, pq_ch1),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, l7payload = "tls_server_hello", track = track_pq_http,
    dis = tcp4(IP_ISP, CLI4, 443, 46002, TH_ACK + TH_PUSH, 5000, 2822, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_pq_http,
    dis = tcp4(CLI4, IP_ISP, 46002, 443, TH_ACK + TH_PUSH, 2400, 5009, pq_ch2),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_pq_http,
    dis = tcp4(CLI4, IP_ISP, 46002, 443, TH_ACK + TH_PUSH, 2822, 5009, tls13_ccs_fin),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3",
    l7payload = "unknown", track = track_pq_http,
    dis = tcp4(CLI4, IP_ISP, 46002, 443, TH_ACK + TH_PUSH, 2886, 5009, tls13_http_req),
})
is("real HTTP GET after CH2 retransmission and ClientFinished DOES arm stall_guard", true, next(timers) ~= nil)

-- 12) Ограничитель двунаправленного окна PPE connskip (est_bidir = est_out + in_total):
-- (a) Skip arming когда est_out=20 < out_limit-4 (41), но est_bidir=35 > connskip_limit-6 (24)
reset_state()
local track_bidir_skip = { lua_state = {}, pos = { direct = { pcounter = 10, pdcounter = 2 }, reverse = { pcounter = 15, pdcounter = 4 } } }
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", arg = { out_limit = 45, connskip_limit = 30 },
    l7payload = "tls_client_hello", track = track_bidir_skip,
    dis = tcp4(CLI4, IP_ISP, 46003, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, arg = { out_limit = 45, connskip_limit = 30 },
    l7payload = "tls_server_hello", track = track_bidir_skip,
    dis = tcp4(IP_ISP, CLI4, 443, 46003, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", arg = { out_limit = 45, connskip_limit = 30 },
    l7payload = "unknown", track = track_bidir_skip,
    dis = tcp4(CLI4, IP_ISP, 46003, 443, TH_ACK + TH_PUSH, 109, 209, tls13_http_req),
})
is("stall guard skips arming when est_bidir=35 > connskip_limit-6 (24)", nil, next(timers))
is("stall guard marks done when est_bidir nears connskip_limit", true, track_bidir_skip.lua_state.z2k_sg_done)

-- (b) Cancel timer когда поток взвёлся при est_bidir=22 < 24, а последующие POST-сегменты подняли est_bidir=28 >= 30-2
reset_state()
local track_bidir_cancel = { lua_state = {}, pos = { direct = { pcounter = 7, pdcounter = 2 }, reverse = { pcounter = 10, pdcounter = 4 } } }
-- in_empty=5, est_out=12, est_bidir=22 (<=24, arms)
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", arg = { out_limit = 45, connskip_limit = 30 },
    l7payload = "tls_client_hello", track = track_bidir_cancel,
    dis = tcp4(CLI4, IP_ISP, 46004, 443, TH_ACK + TH_PUSH, 100, 200, tls_ch_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = false, arg = { out_limit = 45, connskip_limit = 30 },
    l7payload = "tls_server_hello", track = track_bidir_cancel,
    dis = tcp4(IP_ISP, CLI4, 443, 46004, TH_ACK + TH_PUSH, 200, 109, tls_sh_rec),
})
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", arg = { out_limit = 45, connskip_limit = 30 },
    l7payload = "unknown", track = track_bidir_cancel,
    dis = tcp4(CLI4, IP_ISP, 46004, 443, TH_ACK + TH_PUSH, 109, 209, tls13_http_req),
})
local tn_bc, ti_bc = find_timer("z2k_sg_")
is("stall guard arms at est_bidir=22 (< 30-6)", true, tn_bc ~= nil)
track_bidir_cancel.pos.direct = { pcounter = 13, pdcounter = 8 } -- est_out=18 (<44), est_bidir=28 (>=30-2)
z2k_autopilot_stall_guard({}, {
    outgoing = true, ifin = "br0", ifout = "eth3", arg = { out_limit = 45, connskip_limit = 30 },
    l7payload = "unknown", track = track_bidir_cancel,
    dis = tcp4(CLI4, IP_ISP, 46004, 443, TH_ACK + TH_PUSH, 234, 209, tls13_http_req),
})
is("stall guard cancels timer at est_bidir=28 >= connskip_limit-2", nil, timers[tn_bc])
is("stall guard marks done at bidir connskip boundary", true, track_bidir_cancel.lua_state.z2k_sg_done)
invoke_timer(tn_bc, ti_bc)
is("stale timer after bidir connskip boundary cancel sends 0 RSTs", 0, #rawsend_dissects)

-- luacheck: ignore 122
os.time = orig_os_time
os.remove(pol_file)
os.remove(obs_file)
io.write(string.format("\nPASSED: %d\nFAILED: %d\n", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
