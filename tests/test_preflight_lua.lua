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
seq_ge = function(a, b) return u32add(a, -b) < 2147483648 end
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
-- Пробный ClientHello: содержимое не важно, проверяем байты и границы сегментов.
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
local function out(dis, arg) return z2k_preflight(nil, {dis = dis, outgoing = true, ifout = "ppp0", arg = arg or {}}) end
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

-- Целая проба по ntc.party #1374; повторы используют тот же путь отправки.
do
    local arg = {pos = "none"}
    start_probe(arg)
    reset_calls()
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1), arg)
    local _, st = next(z2k_pf_flows)
    is("pos=none: ACK и один сегмент ClientHello", 2, #sent)
    is("pos=none: отдельный ACK без данных", "", sent[1] and sent[1].payload)
    is("pos=none: целый ClientHello", st.hello, sent[2] and sent[2].payload)
    is("pos=none: seq начала ClientHello", ISN + 1, sent[2] and sent[2].tcp.th_seq)
    for _, confirmed in ipairs({0, 7}) do
        if confirmed > 0 then inc(dis_in(TH_ACK, 5001, ISN + 1 + confirmed), arg) end
        reset_calls()
        is("pos=none: повтор SYN скрыт", VERDICT_DROP, out(dis_out(TH_SYN, ISN), arg))
        is("pos=none: повтор ACK и одного сегмента", 2, #sent)
        is("pos=none: точные неподтверждённые байты", st.hello:sub(confirmed + 1), sent[2] and sent[2].payload)
        is("pos=none: seq неподтверждённого начала", ISN + 1 + confirmed, sent[2] and sent[2].tcp.th_seq)
    end
end

-- ----- 3b. Ограниченное восстановление (10.11.2026, 58976 / 58983) ---------
-- Фильтр позволяет отдельно проверить падение каждого сценария на старом Lua.
local function recovery_case(name, run)
    if not os.getenv("PF_RECOVERY_CASE") or os.getenv("PF_RECOVERY_CASE") == name then
        run()
    end
end
local function ts_options(value, echo)
    return {{kind = TCP_KIND_TS, data = bu32(value) .. bu32(echo or 0)}}
end
local function packet_ts(packet)
    local i = packet and find_tcp_option(packet.tcp.options, TCP_KIND_TS)
    return i and u32(packet.tcp.options[i].data:sub(1, 4))
end

recovery_case("timestamp", function()
    local arg = {keepts = true}
    start_probe(arg)
    out(dis_out(TH_SYN, ISN, nil, ts_options(1111)), arg)
    reset_calls()
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1, nil, ts_options(9000, 1111)), arg)
    is("58976: ACK от TS повторного SYN", 1112, packet_ts(sent[1]))
    local previous = 1111
    for _, packet in ipairs(sent) do
        local value = packet_ts(packet)
        is("58976: TS не откатывается", true, value ~= nil and seq_ge(value, previous))
        previous = value or previous
    end
    reset_calls()
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1, nil, ts_options(9001, 111)), arg)
    is("58976: повтор SYN-ACK восстановлен", 3, #sent)
    for _, packet in ipairs(sent) do
        local value = packet_ts(packet)
        is("58976: старый ecr не откатывает TS", true, value ~= nil and seq_ge(value, previous))
        previous = value or previous
    end
    -- Задержавшийся SYN-ACK может подтверждать первый SYN, а не последний.
    start_probe(arg)
    out(dis_out(TH_SYN, ISN, nil, ts_options(1111)), arg)
    reset_calls()
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1, nil, ts_options(9000, 111)), arg)
    is("TS именно подтверждённого SYN", 112, packet_ts(sent[1]))
end)

recovery_case("stalled_ack", function()
    start_probe({})
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1))
    local initial = deepcopy(sent)
    local base = ISN + 1
    reset_calls()
    -- Чужие ACK вне отправленного диапазона не должны вызывать восстановление.
    for _ = 1, 4 do
        inc(dis_in(TH_ACK, 5001, base - 1))
        inc(dis_in(TH_ACK, 5001, base + 10000))
    end
    for _ = 1, 2 do inc(dis_in(TH_ACK, 5001, base)) end
    is("58983: до третьего дубля нет отправок", 0, #sent)
    inc(dis_in(TH_ACK, 5001, base))
    is("58983: третий дубль повторяет ACK и части", 3, #sent)
    for n, packet in ipairs(sent) do
        local expected_seq = n == 1 and initial[2].tcp.th_seq + #initial[2].payload or initial[n].tcp.th_seq
        is("58983: прежний порядок и seq " .. n, expected_seq, packet.tcp.th_seq)
        is("58983: прежние байты " .. n, initial[n].payload, packet.payload)
        is("58983: прежний порт " .. n, SPORT, packet.tcp.th_sport)
        is("без keepts нет TS " .. n, nil, packet_ts(packet))
    end
    -- ACK в середине первой части: повторить её хвост, вторую целиком.
    reset_calls()
    inc(dis_in(TH_ACK, 5001, base + 2))
    for _ = 1, 2 do inc(dis_in(TH_ACK, 5001, base + 2)) end
    is("продвижение ACK сбрасывает дубли", 0, #sent)
    inc(dis_in(TH_ACK, 5001, base + 2))
    is("частичный ACK: ACK и две оставшиеся части", 3, #sent)
    is("хвостовая часть сохраняется", initial[2].payload, sent[2] and sent[2].payload)
    is("подтверждённое начало не повторяется", initial[3].payload:sub(3), sent[3] and sent[3].payload)
    is("seq с подтверждённого места", base + 2, sent[3] and sent[3].tcp.th_seq)
    reset_flows()
    reset_calls()
    local wrap_isn = 4294967290
    out(dis_out(TH_SYN, wrap_isn))
    inc(dis_in(TH_SYN + TH_ACK, 5000, u32add(wrap_isn, 1)))
    local hello = sent[3].payload .. sent[2].payload
    reset_calls()
    inc(dis_in(TH_ACK, 5001, 2))
    for _ = 1, 3 do inc(dis_in(TH_ACK, 5001, 2)) end
    is("wrap ACK: сохранены обе оставшиеся части", 3, #sent)
    is("wrap ACK: повтор с подтверждённого байта", 2, sent[3] and sent[3].tcp.th_seq)
    local remaining = sent[3] and sent[2] and sent[3].payload .. sent[2].payload
    is("wrap ACK: точные неподтверждённые байты", hello:sub(8), remaining)
end)

recovery_case("client_syn_stalled", function()
    start_probe({})
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1))
    local initial = deepcopy(sent)
    local st = select(2, next(z2k_pf_flows))
    local started = st.t
    reset_calls()
    -- 58983: один ACK с SACK хвоста, затем молчание до повтора SYN macOS.
    -- SACK не разбирается: повторяем все части от cumulative ACK.
    inc(dis_in(TH_ACK, 5001, ISN + 1, nil,
        {{kind = 5, data = bu32(ISN + 133) .. bu32(ISN + 678)}}))
    is("58983: один дубль ACK не вызывает отправок", 0, #sent)
    is("58983: повтор SYN остаётся в drop", VERDICT_DROP, out(dis_out(TH_SYN, ISN)))
    is("58983: SYN повторяет ACK и обе части", 3, #sent)
    for n = 2, 3 do
        is("58983 SYN: seq части " .. n, initial[n].tcp.th_seq, sent[n] and sent[n].tcp.th_seq)
        is("58983 SYN: байты части " .. n, initial[n].payload, sent[n] and sent[n].payload)
    end
    is("58983 SYN: seq ACK", st.cli_next, sent[1] and sent[1].tcp.th_seq)
    reset_calls()
    inc(dis_in(TH_ACK, 5001, ISN + 3))
    out(dis_out(TH_SYN, ISN))
    is("SYN после частичного ACK: ACK и две части", 3, #sent)
    is("SYN после частичного ACK: хвост первой части", initial[3].payload:sub(3), sent[3] and sent[3].payload)
    is("SYN после частичного ACK: seq от подтверждения", ISN + 3, sent[3] and sent[3].tcp.th_seq)
    reset_calls()
    out(dis_out(TH_SYN, ISN))
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1))
    for _ = 1, 3 do inc(dis_in(TH_ACK, 5001, ISN + 3)) end
    is("SYN, SYN-ACK и ACK делят бюджет два", 0, #sent)
    is("SYN не продлевает timeout", started, st.t)
end)

recovery_case("client_syn_confirmed", function()
    start_probe({})
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1))
    local st = select(2, next(z2k_pf_flows))
    reset_calls()
    -- Сначала убеждаемся, что триггер работает; после полного ACK он молчит,
    -- хотя в бюджете ещё остался один повтор.
    out(dis_out(TH_SYN, ISN))
    is("до полного ACK: SYN вызывает повтор", 3, #sent)
    reset_calls()
    inc(dis_in(TH_ACK, 5001, st.cli_next))
    local retries = st.retries
    for _ = 1, 3 do
        is("полный ACK: повтор SYN дропается", VERDICT_DROP, out(dis_out(TH_SYN, ISN)))
    end
    is("полный ACK: повтор SYN без отправок", 0, #sent)
    is("полный ACK: бюджет не расходуется", retries, st.retries)
    is("полный ACK: ждём ответ в probe_data", "probe_data", st.stage)
end)

recovery_case("retry_budget", function()
    start_probe({})
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1))
    local started = select(2, next(z2k_pf_flows)).t
    reset_calls()
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1))
    is("первый повтор по SYN-ACK", 3, #sent)
    for _ = 1, 3 do inc(dis_in(TH_ACK, 5001, ISN + 1)) end
    is("второй повтор по дублям ACK", 6, #sent)
    for _ = 1, 15 do
        inc(dis_in(TH_ACK, 5001, ISN + 1))
        inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1))
    end
    is("общий предел два при смешанных триггерах", 6, #sent)
    inc(dis_in(TH_ACK, 5001, ISN + 2))
    for _ = 1, 6 do inc(dis_in(TH_ACK, 5001, ISN + 2)) end
    is("новый ACK не возобновляет бюджет", 6, #sent)
    is("повторы не продлевают timeout", started, select(2, next(z2k_pf_flows)).t)
end)

recovery_case("success", function()
    local arg = {pieces = 2}
    start_probe(arg)
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1), arg)
    local edge = sent[2].tcp.th_seq + #sent[2].payload
    local split = sent[2].tcp.th_seq
    reset_calls()
    -- Подтверждена первая часть: повтор SYN-ACK должен повторить только вторую.
    inc(dis_in(TH_ACK, 5001, split), arg)
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1), arg)
    is("успех: восстановление началось", 2, #sent)
    is("успех: повтор только неподтверждённой части", split, sent[2] and sent[2].tcp.th_seq)
    is("повтор SYN-ACK: завершающий ACK рукопожатия", ISN + 1, sent[1] and sent[1].tcp.th_seq)
    reset_calls()
    for _ = 1, 8 do inc(dis_in(TH_ACK, 5001, edge), arg) end
    is("успех: полный cumulative ACK не вызывает повторов", 0, #sent)
    inc(dis_in(TH_ACK, 5001, edge, "ab"), arg)
    is("успех: только обычный ACK данных", 1, #sent)
    inc(dis_in(TH_ACK, 5003, edge, "cd"), arg)
    is("успех: только RST и исходный SYN при завершении", 3, #sent)
    reset_calls()
    inc(dis_in(TH_SYN + TH_ACK, 7000, ISN + 1), arg)
    inc(dis_in(TH_ACK, 7001, edge), arg)
    is("успех: после handover отправок нет", 0, #sent)
    -- Обычная удачная проба вообще не нуждается в восстановлении.
    start_probe(arg)
    reset_calls()
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1), arg)
    is("обычный успех: только начальные ACK и части", 3, #sent)
    edge = sent[2].tcp.th_seq + #sent[2].payload
    reset_calls()
    for _ = 1, 6 do inc(dis_in(TH_ACK, 5001, edge), arg) end
    inc(dis_in(TH_ACK, 5001, edge, "ab"), arg)
    inc(dis_in(TH_ACK, 5003, edge, "cd"), arg)
    is("обычный успех: ACK, RST и SYN без повторов", 3, #sent)
end)

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

-- ----- 4b. Только новые байты непрерывного диапазона продвигают пробу ------
-- Каждая строка: seq, payload, ожидаемые srv_next, pieces, bytes.
local function check_reply_sequence(name, server_isn, packets)
    local arg = {pieces = 3, open = 2}
    start_probe(arg)
    inc(dis_in(TH_SYN + TH_ACK, server_isn, ISN + 1), arg)
    local st = select(2, next(z2k_pf_flows))
    for n, packet in ipairs(packets) do
        reset_calls()
        local label = name .. ": пакет " .. n
        is(label .. " скрыт от клиента", VERDICT_DROP,
            inc(dis_in(TH_ACK, packet[1], 1, packet[2]), arg))
        is(label .. " srv_next", packet[3], st.srv_next)
        is(label .. " pieces", packet[4], st.pieces)
        is(label .. " bytes", packet[5], st.bytes)
        if packet[4] < arg.pieces then
            is(label .. " проба продолжается", "probe_data", st.stage)
            is(label .. " один ACK", 1, #sent)
            is(label .. " флаг ACK", TH_ACK, sent[1] and sent[1].tcp.th_flags)
            is(label .. " ACK непрерывного диапазона", packet[3], sent[1] and sent[1].tcp.th_ack)
            is(label .. " окно по новым частям", packet[4] < arg.open and 1 or 65535, st.wsize)
        else
            is(label .. " порог достигнут", "resyn", st.stage)
            is(label .. " RST и исходный SYN", 2, #sent)
            is(label .. " RST", TH_RST, sent[1] and sent[1].tcp.th_flags)
            is(label .. " исходный SYN", TH_SYN, sent[2] and sent[2].tcp.th_flags)
        end
    end
end

do
    check_reply_sequence("дубликат", 5000, {
        {5001, "ab", 5003, 1, 2},
        {5001, "ab", 5003, 1, 2},
        {5000, "x", 5003, 1, 2},
        {5003, "cd", 5005, 2, 4},
        {5005, "ef", 5007, 3, 6},
    })
end

do
    check_reply_sequence("перекрытие", 5000, {
        {5001, "abcd", 5005, 1, 4},
        {5003, "cdef", 5007, 2, 6},
        {5007, "gh", 5009, 3, 8},
    })
end

do
    check_reply_sequence("дыра", 5000, {
        {5003, "cd", 5001, 0, 0},
        {5001, "ab", 5003, 1, 2},
        {5005, "ef", 5003, 1, 2},
        {5003, "cd", 5005, 2, 4},
        -- Пакет за дырой не буферизуется: сервер должен повторить его.
        {5005, "ef", 5007, 3, 6},
    })
end

do
    check_reply_sequence("wrap", 4294967292, {
        {4294967293, "ab", 4294967295, 1, 2},
        {4294967294, "bcde", 2, 2, 5},
        {4294967295, "cde", 2, 2, 5},
        {4, "hi", 2, 2, 5},
        {2, "fg", 4, 3, 7},
    })
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

-- 61167: поздний SYN после handover не должен снова отбирать соединение.
do
    local arg = {pieces = 1}
    start_probe(arg)
    inc(dis_in(TH_SYN + TH_ACK, 5000, ISN + 1), arg)
    inc(dis_in(TH_ACK, 5001, ISN + 1, "ab"), arg)
    inc(dis_in(TH_SYN + TH_ACK, 7000, ISN + 1), arg)
    local key, st = next(z2k_pf_flows)
    for _, age in ipairs({0, st.timeout + 1}) do
        st.t = os.time() - age
        reset_calls()
        local syn = dis_out(TH_SYN, ISN)
        is("61167: поздний SYN пропущен", VERDICT_PASS, out(syn, arg))
        is("61167: окно позднего SYN сохранено", 65535, syn.tcp.th_win)
        is("61167: состояние не заменено", st, z2k_pf_flows[key])
        is("61167: стадия остаётся done", "done", z2k_pf_flows[key].stage)
        is("61167: нет отправок", 0, #sent)
        is("61167: плечи продолжают работать", 0, cancelled)
    end
    reset_calls()
    local syn = dis_out(TH_SYN, ISN + 100)
    is("новый ISN после done запускает пробу", VERDICT_MODIFY, out(syn, arg))
    is("новый ISN: состояние заменено", false, st == z2k_pf_flows[key])
    is("новый ISN: сохранён новый номер", ISN + 100, z2k_pf_flows[key].isn)
    is("новый ISN: стадия probe_syn", "probe_syn", z2k_pf_flows[key].stage)
    is("новый ISN: пробное окно", 1, syn.tcp.th_win)
    is("новый ISN: плечи отменены", 1, cancelled)
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

    -- Очередь на входе (mangle PREROUTING) — так идут соединения, которые
    -- служба подмены переадресовала на рабочий адрес: выходного интерфейса
    -- ещё нет, и проба им не нужна.
    reset_flows()
    reset_calls()
    is("SYN из очереди на входе шаг не берёт", nil,
        z2k_preflight(nil, {dis = dis_out(TH_SYN, ISN), outgoing = true, arg = {}}))
    is("очередь на входе: инстанс отдан дальше", 1, cutoff)
    is("очередь на входе: проба не начата", nil, next(z2k_pf_flows))
end


-- ----- 10. IPv6 с разрешением init: полный цикл пробы ----------------------
do
    reset_flows()
    reset_calls()
    local C6 = "\42\3" .. string.rep("\0", 13) .. "\1"
    local S6 = "\42\0\20\80\64\5\0\2" .. string.rep("\0", 7) .. "\7"
    local function o6(flags, seq, payload)
        return {ip6 = {ip6_src = C6, ip6_dst = S6, ip6_flow = 5},
            tcp = {th_sport = SPORT, th_dport = 443, th_flags = flags, th_seq = seq,
                th_ack = 0, th_win = 65535, options = {}}, payload = payload or ""}
    end
    local function i6(flags, seq, ack, payload)
        return {ip6 = {ip6_src = S6, ip6_dst = C6, ip6_flow = 9},
            tcp = {th_sport = 443, th_dport = SPORT, th_flags = flags, th_seq = seq,
                th_ack = ack, th_win = 65535, options = {}}, payload = payload or ""}
    end
    local a = {v6 = true}
    local syn = o6(TH_SYN, ISN)
    is("IPv6 с v6: пробный SYN", VERDICT_MODIFY,
        z2k_preflight(nil, {dis = syn, outgoing = true, ifout = "ppp0", arg = a}))
    is("IPv6 с v6: окно пробы 1", 1, syn.tcp.th_win)
    is("IPv6 с v6: SYN,ACK сервера забран", VERDICT_DROP,
        z2k_preflight(nil, {dis = i6(TH_SYN + TH_ACK, 5000, ISN + 1), outgoing = false, arg = a}))
    local probe = sent[#sent]
    is("IPv6: пакеты пробы идут по IPv6", true, probe.ip6 ~= nil and probe.ip == nil)
    for n = 1, 2 do
        z2k_preflight(nil, {dis = i6(TH_PUSH + TH_ACK, 5001 + (n - 1) * 2, ISN + 1, "ab"), outgoing = false, arg = a})
    end
    local last = sent[#sent]
    is("IPv6: после кусков ответа — исходный SYN клиента", TH_SYN, last.tcp.th_flags)
    local st = select(2, next(z2k_pf_flows))
    is("IPv6: адрес в журнале записан как IPv6", "2a00:1450:4005:2:0:0:0:7", st.ip)
end

print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
