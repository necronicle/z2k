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

z2k_autopilot_set_paths(pol_file, obs_file)

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
    z2k_autopilot_set_paths(pol_file, obs_file)
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

-- luacheck: ignore 122
os.time = orig_os_time
os.remove(pol_file)
os.remove(obs_file)
io.write(string.format("\nPASSED: %d\nFAILED: %d\n", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
