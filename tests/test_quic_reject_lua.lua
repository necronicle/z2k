-- tests/test_quic_reject_lua.lua — отказ QUIC (files/lua/z2k-quic-reject.lua).
-- luacheck: globals DLOG VERDICT_DROP direction_cutoff_opposite payload_check replay_first reconstruct_dissect rawsend execution_plan_cancel z2k_quic_reject z2k_quic_reject_packet z2k_quic_reject_send
--
-- Запуск: lua tests/test_quic_reject_lua.lua
--
-- Что сторожится:
--   * клиент получает ICMP «порт недоступен» (v4 3/3, v6 1/4) ОТ АДРЕСА СЕРВЕРА,
--     с исходным пакетом внутри байт в байт — по вложенным адресам и портам
--     клиент находит свой сокет; контрольные суммы сверяются здесь независимо
--     (сумма в обратном коде по всему сообщению с полем суммы = 0xFFFF);
--   * размер ответа в пределах RFC 1812 / RFC 4443 (576 / 1280 байт);
--   * исходный пакет клиента выкидывается всегда, даже если отказ не ушёл;
--   * отказ уходит в интерфейс клиента (ifin), без метки пакета клиента;
--   * встречное направление и не-Initial не трогаются; у ClientHello из
--     нескольких пакетов отказ один, выкидываются все куски.

local PASS, FAIL = 0, 0
local function ok(m) PASS = PASS + 1; print("[PASS] " .. m) end
local function no(m, want, got)
    FAIL = FAIL + 1
    print(string.format("[FAIL] %s (want=%s got=%s)", m, tostring(want), tostring(got)))
end
local function is(m, want, got) if want == got then ok(m) else no(m, want, got) end end

-- ----- заглушки движка -------------------------------------------------------
VERDICT_DROP = 1
function DLOG() end
function direction_cutoff_opposite() end
function payload_check(desync, def)
    local want = desync.arg.payload or def
    return want == "all" or want == desync.l7payload
end
function replay_first(desync) return not desync.replay or desync.replay_piece == 1 end
local sent, send_result = {}, true
function rawsend(pkt, opts) sent[#sent + 1] = { pkt = pkt, opts = opts }; return send_result end
function reconstruct_dissect(dis, opts)
    if dis.broken then error("invalid dissect data") end
    assert(opts and opts.keepsum, "исходный пакет нужен с исходными суммами")
    return dis.raw
end

dofile("files/lua/z2k-quic-reject.lua")

-- ----- независимая проверка ---------------------------------------------------
local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function csum_ok(data)
    local sum = 0
    for i = 1, #data, 2 do sum = sum + data:byte(i) * 256 + (data:byte(i + 1) or 0) end
    return sum > 0 and sum % 0xFFFF == 0
end
local function be16(v) return string.char(math.floor(v / 256), v % 256) end

local C4, S4 = string.char(192, 168, 1, 117), string.char(142, 250, 74, 46)
local C6 = string.char(0x2a, 0x02, 0x06, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x17)
local S6 = string.char(0x2a, 0x00, 0x14, 0x50, 0x40, 0x0f, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0e)

local function initial(n) -- QUIC long header Initial + шум
    local t = { string.char(0xc3, 0, 0, 0, 1) }
    for i = 1, n - 5 do t[#t + 1] = string.char((i * 37) % 256) end
    return table.concat(t)
end
local function udp(payload)
    return be16(51234) .. be16(443) .. be16(8 + #payload) .. be16(0xbeef) .. payload
end
local function ip4(payload)
    local u = udp(payload)
    return string.char(0x45, 0) .. be16(20 + #u) .. string.char(0x12, 0x34, 0x40, 0, 63, 17, 0xab, 0xcd)
        .. C4 .. S4 .. u
end
local function ip6(payload)
    local u = udp(payload)
    return string.char(0x60, 0, 0, 0) .. be16(#u) .. string.char(17, 63) .. C6 .. S6 .. u
end
local function desync4(raw, extra)
    local d = { outgoing = true, l7payload = "quic_initial", arg = {}, ifin = "br0",
        ifout = "ppp0", fwmark = 0x2000,
        dis = { raw = raw, ip = { ip_src = C4, ip_dst = S4 }, udp = {} } }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end
local function desync6(raw)
    return { outgoing = true, l7payload = "quic_initial", arg = {}, ifin = "br0",
        ifout = "ppp0", fwmark = 0x2000,
        dis = { raw = raw, ip6 = { ip6_src = C6, ip6_dst = S6 }, udp = {} } }
end

-- 1. IPv4, полноразмерный Initial
do
    sent = {}
    local raw = ip4(initial(1250))
    local v = z2k_quic_reject({}, desync4(raw))
    is("v4: исходный пакет выкинут", VERDICT_DROP, v)
    is("v4: отправлен ровно один отказ", 1, #sent)
    local p = sent[1].pkt
    is("v4: IPv4 без опций", 0x45, p:byte(1))
    is("v4: длина в заголовке = длине пакета", #p, u16(p, 3))
    is("v4: не длиннее 576 байт (RFC 1812)", 576, #p)
    is("v4: протокол ICMP", 1, p:byte(10))
    is("v4: источник — сервер", S4, p:sub(13, 16))
    is("v4: получатель — клиент", C4, p:sub(17, 20))
    is("v4: сумма IP-заголовка верна", true, csum_ok(p:sub(1, 20)))
    is("v4: тип 3 (недоступно)", 3, p:byte(21))
    is("v4: код 3 (порт)", 3, p:byte(22))
    is("v4: сумма ICMP верна", true, csum_ok(p:sub(21)))
    is("v4: внутри — начало исходного пакета байт в байт", raw:sub(1, 548), p:sub(29))
    is("v4: отказ уходит в интерфейс клиента", "br0", sent[1].opts.ifout)
    is("v4: метка пакета клиента не наследуется", nil, sent[1].opts.fwmark)
end

-- 2. IPv4, короткий пакет нечётной длины: вложен целиком, сумма с хвостовым байтом
do
    sent = {}
    local raw = ip4(initial(73))
    z2k_quic_reject({}, desync4(raw))
    local p = sent[1].pkt
    is("v4 нечётный: вложен весь пакет", raw, p:sub(29))
    is("v4 нечётный: сумма ICMP верна", true, csum_ok(p:sub(21)))
    is("v4 нечётный: длина в заголовке", #p, u16(p, 3))
end

-- 3. IPv6, полноразмерный Initial
do
    sent = {}
    local raw = ip6(initial(1350))
    local v = z2k_quic_reject({}, desync6(raw))
    is("v6: исходный пакет выкинут", VERDICT_DROP, v)
    local p = sent[1].pkt
    is("v6: версия 6", 0x60, p:byte(1))
    is("v6: не длиннее 1280 байт (RFC 4443)", 1280, #p)
    is("v6: длина нагрузки", #p - 40, u16(p, 5))
    is("v6: следующий заголовок ICMPv6", 58, p:byte(7))
    is("v6: источник — сервер", S6, p:sub(9, 24))
    is("v6: получатель — клиент", C6, p:sub(25, 40))
    is("v6: тип 1 (недоступно)", 1, p:byte(41))
    is("v6: код 4 (порт)", 4, p:byte(42))
    local pseudo = S6 .. C6 .. string.char(0, 0) .. be16(#p - 40) .. string.char(0, 0, 0, 58)
    is("v6: сумма ICMPv6 с псевдозаголовком верна", true, csum_ok(pseudo .. p:sub(41)))
    is("v6: внутри — начало исходного пакета байт в байт", raw:sub(1, 1232), p:sub(49))
end

-- 4. Чужое не трогается
do
    sent = {}
    local d = desync4(ip4(initial(100))); d.outgoing = false
    is("встречный пакет: вердикт не меняется", nil, z2k_quic_reject({}, d))
    d = desync4(ip4(initial(100))); d.l7payload = "quic_short"
    is("не Initial: вердикт не меняется", nil, z2k_quic_reject({}, d))
    d = desync4(ip4(initial(100))); d.dis.udp = nil; d.dis.tcp = {}
    is("TCP: вердикт не меняется", nil, z2k_quic_reject({}, d))
    is("ни на что из этого отказ не ушёл", 0, #sent)
end

-- 5. ClientHello из двух пакетов: оба выкинуты, отказ один
do
    sent = {}
    local a = z2k_quic_reject({}, desync4(ip4(initial(1250)), { replay = true, replay_piece = 1 }))
    local b = z2k_quic_reject({}, desync4(ip4(initial(1250)), { replay = true, replay_piece = 2 }))
    is("кусок 1 выкинут", VERDICT_DROP, a)
    is("кусок 2 выкинут", VERDICT_DROP, b)
    is("отказ один на оба куска", 1, #sent)
end

-- 6. Отказ не ушёл — пакет всё равно выкидывается (прежнее поведение)
do
    sent, send_result = {}, false
    is("отправка не удалась: пакет выкинут", VERDICT_DROP, z2k_quic_reject({}, desync4(ip4(initial(200)))))
    send_result = true
    sent = {}
    local d = desync4(ip4(initial(200))); d.dis.broken = true
    is("пакет не собрать: выкинут", VERDICT_DROP, z2k_quic_reject({}, d))
    is("пакет не собрать: отказ не шлётся", 0, #sent)
end

-- 7. Общий хелпер z2k_quic_reject_send: ip_id, нормализация пустого ifin, execution_plan_cancel
do
    local cancelled = 0
    execution_plan_cancel = function() cancelled = cancelled + 1 end
    sent, send_result = {}, true
    local d = {
        outgoing = true,
        l7payload = "quic_initial",
        ifin = "",
        arg = {},
        dis = {
            ip = { ip_src = "\192\168\1\50", ip_dst = "\142\250\74\46" },
            udp = {},
            raw = string.char(0x45, 0, 0, 128) .. string.rep("\0", 124),
        },
    }
    local v = z2k_quic_reject_send({ id = 1 }, d)
    is("z2k_quic_reject_send: VERDICT_DROP", VERDICT_DROP, v)
    is("z2k_quic_reject_send: вызван execution_plan_cancel", 1, cancelled)
    is("z2k_quic_reject_send: пустой ifin -> ifout=nil", nil, sent[1].opts.ifout)
    local id1 = u16(sent[1].pkt, 5)
    is("z2k_quic_reject_send: ненулевой IPv4 ip_id", true, id1 > 0)
    is("z2k_quic_reject_send: сумма IPv4 с ненулевым ip_id верна", true, csum_ok(sent[1].pkt:sub(1, 20)))
    z2k_quic_reject_send({ id = 2 }, d)
    local id2 = u16(sent[2].pkt, 5)
    is("z2k_quic_reject_send: ip_id меняется между пакетами", true, id2 ~= id1)
    execution_plan_cancel = nil
end

print(string.format("\nИТОГ: %d PASS, %d FAIL", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
