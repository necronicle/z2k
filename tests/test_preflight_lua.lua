-- tests/test_preflight_lua.lua — проверка DPI отдельным соединением
-- (files/lua/z2k-preflight.lua): конечный автомат пробы целиком.
-- luacheck: globals DLOG bitand u32 u32add seq_ge bu8 bu32 find_tcp_option deepcopy blob tls_mod resolve_multi_pos delete_pos_1 rawsend_dissect instance_cutoff_shim execution_plan_cancel VERDICT_DROP VERDICT_PASS VERDICT_MODIFY TH_FIN TH_SYN TH_RST TH_PUSH TH_ACK TCP_KIND_NOOP TCP_KIND_MSS TCP_KIND_SCALE TCP_KIND_TS z2k_pf_flows z2k_preflight
-- luacheck: ignore 122
--
-- Запуск: lua tests/test_preflight_lua.lua
--
-- Что здесь сторожится и почему именно это:
--   * клиент НЕ ВИДИТ пробу — все её пакеты уходят в drop, а клиентский SYN
--     отдаётся серверу с окном 1 (иначе сервер сразу пришлёт весь ServerHello
--     и ждать первых байтов будет нечего);
--   * после передачи клиенту ПЛЕЧИ РАБОТАЮТ — шаг снимает блок по адресу, но
--     не по имени (play.google.com), и без плеч такие имена отвалятся;
--   * когда проба не удалась, шаг сдаётся и пускает соединение плечам, а не
--     оставляет клиента без ответа;
--   * чужое соединение (не IPv4 TCP, или профиль вступил посреди соединения)
--     шаг не трогает вовсе.
--
-- Движок (C-часть) заменён заглушками: предмет теста — решения автомата, а не
-- разбор TLS. Заглушки записывают вызовы, поэтому «плечи не отменены» и
-- «пакет отправлен» — исполняемые проверки, а не совпадение строк.

local PASS, FAIL = 0, 0
local function ok(m) PASS = PASS + 1; print("[PASS] " .. m) end
local function no(m, want, got)
    FAIL = FAIL + 1
    print(string.format("[FAIL] %s (want=%s got=%s)", m, tostring(want), tostring(got)))
end
local function is(m, want, got) if want == got then ok(m) else no(m, want, got) end end

-- ----- заглушки движка -------------------------------------------------------
VERDICT_DROP, VERDICT_PASS, VERDICT_MODIFY = 1, 0, 2
TH_FIN, TH_SYN, TH_RST, TH_PUSH, TH_ACK = 1, 2, 4, 8, 16
TCP_KIND_NOOP, TCP_KIND_MSS, TCP_KIND_SCALE, TCP_KIND_TS = 1, 2, 3, 8

function DLOG() end
bitand = function(a, b)
    local r, bit = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return r
end
u32add = function(a, b) return (a + b) % 4294967296 end
u32 = function(s) return (string.byte(s, 1) * 16777216) + (string.byte(s, 2) * 65536)
    + (string.byte(s, 3) * 256) + string.byte(s, 4) end
seq_ge = function(a, b) return a >= b end
bu8 = function(v) return string.char(v % 256) end
bu32 = function(v)
    local b = {}
    for i = 4, 1, -1 do b[i] = string.char(math.floor(v / 256 ^ (4 - i)) % 256) end
    return table.concat(b)
end
function find_tcp_option(options, kind)
    for i, o in ipairs(options or {}) do if o.kind == kind then return i end end
    return nil
end
function deepcopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepcopy(v) end
    return c
end
-- Пробный ClientHello: содержимое не важно, важна длина и то, что он резан.
function blob(_, name) return "CH(" .. name .. ")" .. string.rep("x", 60) end
function tls_mod(base, mods) return base .. "|" .. mods end
-- Ядро отдаёт позиции разреза; шаг обязан выкинуть позицию 1 и дописать конец.
function resolve_multi_pos(data, _, _) return {1, math.floor(#data / 2)} end
function delete_pos_1(pos)
    for i = #pos, 1, -1 do if pos[i] == 1 then table.remove(pos, i) end end
end

local sent, cutoff, cancelled = {}, 0, 0
function rawsend_dissect(dis, _) sent[#sent + 1] = dis; return true end
function instance_cutoff_shim() cutoff = cutoff + 1 end
function execution_plan_cancel() cancelled = cancelled + 1 end

dofile("files/lua/z2k-preflight.lua")

-- ----- синтетические пакеты --------------------------------------------------
local CLIENT, SERVER = "\192\168\1\10", "\74\125\110\38"
local ISN, SPORT = 1000, 50000

local function reset_calls() sent, cutoff, cancelled = {}, 0, 0 end

-- Таблицу состояний чистим НА МЕСТЕ. Модуль держит на неё свою ссылку
-- (local flows = z2k_pf_flows), поэтому присваивание новой таблицы в глобаль
-- шаг бы не затронуло: тест видел бы пустоту, а код — состояние прошлой пробы.
local function reset_flows()
    for k in pairs(z2k_pf_flows) do z2k_pf_flows[k] = nil end
end

local function dis_out(flags, seq, payload, options)
    return {ip = {ip_src = CLIENT, ip_dst = SERVER, ip_id = 7},
        tcp = {th_sport = SPORT, th_dport = 443, th_flags = flags, th_seq = seq,
            th_ack = 0, th_win = 65535, options = options or {}},
        payload = payload or ""}
end
local function dis_in(flags, seq, ack, payload, options)
    return {ip = {ip_src = SERVER, ip_dst = CLIENT, ip_id = 9},
        tcp = {th_sport = 443, th_dport = SPORT, th_flags = flags, th_seq = seq,
            th_ack = ack, th_win = 65535, options = options or {}},
        payload = payload or ""}
end
local function out(dis, arg) return z2k_preflight(nil, {dis = dis, outgoing = true, arg = arg or {}}) end
local function inc(dis, arg) return z2k_preflight(nil, {dis = dis, outgoing = false, arg = arg or {}}) end

-- Доводит соединение до состояния «ждём ответ сервера».
local function start_probe(arg)
    reset_flows()
    reset_calls()
    local syn = dis_out(TH_SYN, ISN, nil,
        {{kind = TCP_KIND_MSS, data = "\5\180"}, {kind = TCP_KIND_SCALE, data = "\7"},
         {kind = TCP_KIND_TS, data = bu32(111) .. bu32(0)}})
    local v = out(syn, arg)
    return syn, v
end

-- ----- 1. Пробный SYN вместо клиентского ------------------------------------
do
    local syn, v = start_probe({})
    is("клиентский SYN уходит изменённым", VERDICT_MODIFY, v)
    is("окно пробы 1", 1, syn.tcp.th_win)
    local kinds = {}
    for i, o in ipairs(syn.tcp.options) do kinds[i] = o.kind end
    is("в пробном SYN остались только MSS и масштаб", "2,3", table.concat(kinds, ","))
    is("на пробе плечи отменены", 1, cancelled)
    is("шаг не отдал пакет чужим инстансам", 0, cutoff)
end

-- ----- 2. keepts сохраняет опции клиента ------------------------------------
do
    local syn = start_probe({keepts = true})
    local kinds = {}
    for i, o in ipairs(syn.tcp.options) do kinds[i] = o.kind end
    is("keepts: опции клиента на месте", "2,3,8", table.concat(kinds, ","))
    is("keepts: окно всё равно своё", 1, syn.tcp.th_win)
end

-- ----- 3. SYN,ACK сервера клиенту не виден, ClientHello уходит кусками ------
do
    start_probe({})
    reset_calls()
    local v = inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1))
    is("SYN,ACK пробы не доходит до клиента", VERDICT_DROP, v)
    is("отправлены ACK и два куска hello", 3, #sent)
    is("первым идёт ACK без данных", 0, #sent[1].payload)
    -- Куски уходят в обратном порядке, последний байт первого куска < второго.
    local a, b = sent[2], sent[3]
    is("куски hello непустые", true, #a.payload > 0 and #b.payload > 0)
    is("второй кусок имеет меньший seq, чем первый отправленный", true, b.tcp.th_seq < a.tcp.th_seq)
end

-- ----- 4. Ответ сервера: кусками до порога, потом RST и исходный SYN --------
do
    start_probe({pieces = 2})
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1), {pieces = 2})
    reset_calls()
    local v = inc(dis_in(TH_ACK, 5001, 1, "ab"), {pieces = 2})
    is("первый кусок ответа: клиенту не отдаём", VERDICT_DROP, v)
    is("на первый кусок отвечаем ACK", 1, #sent)
    reset_calls()
    v = inc(dis_in(TH_ACK, 5003, 1, "cd"), {pieces = 2})
    is("порог кусков достигнут: пакет всё ещё не клиенту", VERDICT_DROP, v)
    is("отправлены RST пробы и исходный SYN", 2, #sent)
    is("первым идёт RST", TH_RST, sent[1].tcp.th_flags)
    is("вторым — исходный SYN клиента", TH_SYN, sent[2].tcp.th_flags)
    is("исходный SYN с исходным номером", ISN, sent[2].tcp.th_seq)
    is("исходный SYN с окном клиента", 65535, sent[2].tcp.th_win)
end

-- ----- 5. Передача клиенту: плечи после неё РАБОТАЮТ ------------------------
do
    start_probe({pieces = 1})
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1), {pieces = 1})
    inc(dis_in(TH_ACK, 5001, 1, "ab"), {pieces = 1})
    reset_calls()
    local v = inc(dis_in(TH_SYN + TH_ACK, 7000, ISN + 1), {pieces = 1})
    is("SYN,ACK на исходный SYN отдан клиенту", VERDICT_PASS, v)
    is("после передачи плечи НЕ отменены", 0, cancelled)
    reset_calls()
    is("данные клиента после передачи идут мимо шага", nil, out(dis_out(TH_PUSH + TH_ACK, ISN + 1, "hello"), {pieces = 1}))
    is("после передачи плечи НЕ отменены и на данных", 0, cancelled)
end

-- ----- 6. Сервер помнит пробу: отвечаем RST и повторяем исходный SYN --------
do
    start_probe({pieces = 1})
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1), {pieces = 1})
    inc(dis_in(TH_ACK, 5001, 1, "ab"), {pieces = 1})
    reset_calls()
    local v = inc(dis_in(TH_ACK, 5003, 777), {pieces = 1})
    is("устаревший ACK клиенту не отдаём", VERDICT_DROP, v)
    is("на устаревший ACK — RST и повтор исходного SYN", 2, #sent)
    is("RST с номером из ACK сервера", 777, sent[1].tcp.th_seq)
end

-- ----- 7. Проба не удалась: шаг сдаётся и пускает соединение плечам ---------
do
    start_probe({timeout = 3})
    local fixed = 1700000000
    local real_time = os.time
    os.time = function() return fixed end
    reset_flows()
    reset_calls()
    out(dis_out(TH_SYN, ISN, nil, {{kind = TCP_KIND_MSS, data = "\5\180"}}), {timeout = 3})
    -- Сервер молчит; клиент повторяет SYN позже таймаута.
    fixed = fixed + 4
    reset_calls()
    local late = dis_out(TH_SYN, ISN, nil, {{kind = TCP_KIND_MSS, data = "\5\180"}})
    local v = out(late, {timeout = 3})
    os.time = real_time
    is("после таймаута SYN клиента уходит как есть", VERDICT_PASS, v)
    is("сдавшись, шаг НЕ отменяет плечи", 0, cancelled)
    is("сдавшись, шаг не переписывает окно клиента", 65535, late.tcp.th_win)
    -- Сервер не ответил на пробный SYN: рвать нечего, лишний RST не нужен.
    is("проба без ответа: шаг ничего не отправляет", 0, #sent)
end

-- ----- 7b. Сервер замолчал посреди пробы: соединение надо прибрать ----------
do
    local fixed = 1700000000
    local real_time = os.time
    os.time = function() return fixed end
    reset_flows()
    reset_calls()
    local arg = {timeout = 3, pieces = 6}
    out(dis_out(TH_SYN, ISN, nil, {{kind = TCP_KIND_MSS, data = "\5\180"}}), arg)
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1), arg)
    -- Пробное соединение установлено, hello ушёл, а ответа так и нет.
    fixed = fixed + 4
    reset_calls()
    local v = out(dis_out(TH_SYN, ISN, nil, {{kind = TCP_KIND_MSS, data = "\5\180"}}), arg)
    os.time = real_time
    is("замолчавший сервер: SYN клиента уходит как есть", VERDICT_PASS, v)
    is("замолчавший сервер: плечи не отменены", 0, cancelled)
    is("замолчавший сервер: пробное соединение прибрано RST", TH_RST, sent[1] and sent[1].tcp.th_flags)
    is("замолчавший сервер: ровно один RST", 1, #sent)
end

-- ----- 8. Повтор клиентского SYN до таймаута становится новой пробой --------
do
    start_probe({timeout = 30})
    reset_calls()
    local again = dis_out(TH_SYN, ISN, nil, {{kind = TCP_KIND_MSS, data = "\5\180"}})
    local v = out(again, {timeout = 30})
    is("пробный SYN потерян — повтор клиента становится пробой", VERDICT_MODIFY, v)
    is("окно повтора тоже 1", 1, again.tcp.th_win)
end

-- ----- 9. Чужие соединения шаг не трогает -----------------------------------
do
    reset_flows()
    reset_calls()
    local v6 = {ip6 = {}, tcp = {th_flags = TH_SYN, th_sport = 1, th_dport = 443, options = {}}, payload = ""}
    is("IPv6 шаг не берёт", nil, z2k_preflight(nil, {dis = v6, outgoing = true, arg = {}}))
    is("IPv6: инстанс отдан дальше", 1, cutoff)
    is("IPv6: плечи не отменены", 0, cancelled)

    reset_calls()
    is("соединение без состояния на не-SYN не начинаем", nil,
        out(dis_out(TH_PUSH + TH_ACK, 555, "data")))
    is("середина соединения: инстанс отдан дальше", 1, cutoff)
    is("середина соединения: проба не начата", nil, next(z2k_pf_flows))
end

print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
