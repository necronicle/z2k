-- tests/test_alert_detector.lua
-- Юнит-тесты обёртки z2k_fail_tls_alert (files/lua/z2k-alert.lua).
--
-- Запуск: lua tests/test_alert_detector.lua
--
-- Обёртка родилась из двух полевых замеров 2026-08-18 (боевой роутер):
--   1. нерабочая страта не ротировалась вовсе — сервер подтверждал
--      ClientHello, отвечал семибайтовым фатальным алертом и закрывался по
--      FIN; у штатного детектора для такого нет ни одного события;
--   2. рабочая страта уезжала сама — телефон переслал пакет TLS application
--      data в живой сессии, штатный детектор засчитал это провалом.
--
-- Здесь сторожим ровно контракт обёртки, а не поведение штатного детектора:
-- он подменён трассирующей заглушкой, чтобы было видно, звали его или нет.

local PASS, FAIL = 0, 0
local function ok(m) PASS = PASS + 1; print("[PASS] " .. m) end
local function no(m, want, got)
    FAIL = FAIL + 1
    print(string.format("[FAIL] %s (want=%s got=%s)", m, tostring(want), tostring(got)))
end

-- ----- окружение движка (минимальные заглушки) ------------------------------
function DLOG() end
TH_FIN = 0x01
TH_RST = 0x04
function bitand(a, b)
    local r, p = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end

local std_calls = 0
local std_result = false
function standard_failure_detector()
    std_calls = std_calls + 1
    return std_result
end

local pos_value = 1
function pos_get() return pos_value end

-- Признак ретрансмиссии в движке — позиция пакета не выше уже виденного
-- максимума (lua/zapret-lib.lua). В тесте задаём его явно.
local retrans_flag = false
function is_retransmission() return retrans_flag end

-- Хост-запись: обёртка ведёт в ней счёт живых ответов, чтобы не уводить
-- страту с хоста, который прямо сейчас нормально отвечает.
local hrec = {}
function automate_host_record() return hrec end
local function reset_host() hrec = {} end

local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "tests"
dofile(here .. "/../files/lua/z2k-alert.lua")

-- ----- конструкторы пакетов --------------------------------------------------
local function alert(level, desc)
    -- запись TLS alert: 15 03 03 00 02 <level> <desc>
    return string.char(0x15, 0x03, 0x03, 0x00, 0x02, level, desc)
end

local function incoming(payload)
    return { outgoing = false, l7payload = "unknown", arg = {},
             dis = { tcp = {}, payload = payload } }
end

-- Сегмент с данными в пуле видео: позиция в потоке плюс ключ и планка успеха.
-- retrans=false — сегмент пришёл впервые.
local function seg_gv(bytes, bar, key, retrans)
    pos_value = bytes
    retrans_flag = (retrans ~= false)
    return { outgoing = false, l7payload = "unknown",
             arg = { key = key or "gv_tcp", inseq = tostring(bar or 24000) },
             dis = { tcp = { th_flags = 0x18 }, payload = string.rep("y", 1400) } }
end

local function outgoing(l7)
    return { outgoing = true, l7payload = l7, arg = {},
             dis = { tcp = {}, payload = string.rep("x", 300) } }
end

-- crec — запись соединения; в ней обёртка ведёт счёт повторов сегмента.
-- По умолчанию каждый вызов = новое соединение; для проверки ретрансмитов
-- передаём одну и ту же таблицу.
local function run(desync, crec)
    std_calls = 0
    return z2k_fail_tls_alert(desync, crec or {}), std_calls
end

-- ----- 1. исходящее: штатный зовём только на ClientHello ---------------------
std_result = true   -- штатный «нашёл провал» — проверяем, дадут ли ему слово

pos_value = 1
local fired, calls = run(outgoing("tls_client_hello"))
if fired and calls == 1 then
    ok("ретрансмит ClientHello уходит в штатный детектор и считается провалом")
else
    no("ClientHello делегируется", "true/1", tostring(fired) .. "/" .. calls)
end

fired, calls = run(outgoing("unknown"))
if not fired and calls == 0 then
    ok("ретрансмит данных живой сессии не доходит до штатного детектора")
else
    no("app data не считается провалом", "false/0", tostring(fired) .. "/" .. calls)
end

-- HTTP-пул (http_rkn) работает с http_req: для него это тот же первый запрос,
-- что ClientHello для TLS, и его ретрансмит так же означает, что запрос не
-- дошёл. Без этого обёртку нельзя надеть на http_rkn, не потеряв детект
-- молчаливого дропа.
fired, calls = run(outgoing("http_req"))
if fired and calls == 1 then
    ok("ретрансмит HTTP-запроса уходит в штатный детектор и считается провалом")
else
    no("http_req делегируется", "true/1", tostring(fired) .. "/" .. calls)
end

fired, calls = run(outgoing("http_reply"))
if not fired and calls == 0 then
    ok("прочие исходящие пейлоады не считаются")
else
    no("http_reply не считается", "false/0", tostring(fired) .. "/" .. calls)
end

-- ----- 2. входящее: штатный вызывается всегда --------------------------------
std_result = true
fired, calls = run(incoming(""))
if fired and calls == 1 then
    ok("входящее: вердикт штатного детектора (RST/редирект) уважается")
else
    no("входящее делегируется", "true/1", tostring(fired) .. "/" .. calls)
end

-- ----- 3. фатальный алерт до ServerHello -------------------------------------
std_result = false  -- штатный молчит, событие должна дать только обёртка

pos_value = 1
fired = run(incoming(alert(2, 40)))
if fired then
    ok("фатальный алерт (уровень 2) до ServerHello = провал")
else
    no("fatal alert считается провалом", "true", tostring(fired))
end

fired = run(incoming(alert(1, 0)))
if not fired then
    ok("close_notify (уровень 1) провалом не считается")
else
    no("warning-алерт игнорируется", "false", tostring(fired))
end

pos_value = 20000
fired = run(incoming(alert(2, 40)))
if not fired then
    ok("алерт после реального ответа сервера не считается провалом")
else
    no("алерт за порогом позиции игнорируется", "false", tostring(fired))
end

pos_value = 1
fired = run(incoming(string.char(0x17, 0x03, 0x03, 0x00, 0x35, 0x7B, 0x41)))
if not fired then
    ok("application data (0x17) не путается с алертом")
else
    no("не срабатывать на app data", "false", tostring(fired))
end

fired = run(incoming(string.char(0x15, 0x03)))
if not fired then
    ok("обрезанная запись короче 7 байт не роняет детектор")
else
    no("короткая запись игнорируется", "false", tostring(fired))
end

-- ----- 4. живой хост не ротируем -------------------------------------------
-- Пойманный полевой случай: три поддельных RST на фоне девяти нормальных
-- соединений к тому же хосту уводили рабочую страту.
reset_host()
std_result = true
pos_value = 1

-- три живых ответа сервера подряд
for _ = 1, 3 do run(incoming("HTTP/2 payload")) end

fired = run(incoming(""))     -- RST: штатный детектор говорит «провал»
if not fired then
    ok("провал подавлен: хост в этом же окне трижды ответил живьём")
else
    no("живой хост не ротируется", "false", tostring(fired))
end

-- тот же RST на хосте, который ничем себя не проявил
reset_host()
fired = run(incoming(""))
if fired then
    ok("на молчащем хосте провал засчитывается как раньше")
else
    no("молчащий хост ротируется", "true", tostring(fired))
end

-- живость протухает: успехи старше окна не защищают
reset_host()
for _ = 1, 3 do run(incoming("HTTP/2 payload")) end
hrec.z2k_ok_last = os.time() - 600
fired = run(incoming(""))
if fired then
    ok("протухшие успехи не защищают страту")
else
    no("устаревание живости", "true", tostring(fired))
end

-- фатальный алерт сам живым ответом не считается
reset_host()
std_result = false
pos_value = 1
run(incoming(alert(2, 40)))
run(incoming(alert(2, 40)))
run(incoming(alert(2, 40)))
fired = run(incoming(alert(2, 40)))
if fired then
    ok("серия фатальных алертов не создаёт ложной живости")
else
    no("алерты не считаются живостью", "true", tostring(fired))
end

-- ----- 5. вставший входящий поток (только пулы видео) ---------------------
-- Полевой случай LG webOS на нерабочей 20-й стратегии: сервер отдаёт 4482
-- байта и дальше шлёт один и тот же сегмент 15-16 раз, телевизор не
-- подтверждает. Ни RST, ни FIN, ни исходящих ретрансмитов — детектор молчал.
--
-- Признак — ОСТАНОВКА потока, а не факт повтора. Первая редакция считала любой
-- входящий ретрансмит в пределах inseq и 19.08.2026 увела gv_tcp с первой
-- стратегии на четвёртую без единого реального блока: под планкой inseq=24000
-- лежит не хендшейк, а первые 24 КБ видеопотока, где телевизор по вайфаю
-- штатно теряет пакеты.
reset_host()
std_result = false

-- первое появление сегмента и пять повторов — ещё не приговор
local conn = {}
fired = run(seg_gv(4482, 24000, nil, false), conn)
if not fired then
    ok("первый приход сегмента провалом не считается")
else
    no("первый приход", "false", tostring(fired))
end
local early = false
for _ = 1, 5 do
    if run(seg_gv(4482, 24000), conn) then early = true end
end
if not early then
    ok("пять повторов подряд — ещё не провал")
else
    no("порог не срабатывает раньше шести", "false", "true")
end
fired = run(seg_gv(4482, 24000), conn)
if fired then
    ok("шесть повторов одного сегмента без продвижения = провал")
else
    no("порог шести повторов", "true", tostring(fired))
end

-- ГЛАВНОЕ. Поток теряет пакеты, но едет: за повтором приходят новые данные.
-- Ровно это давал телевизор на РАБОЧЕЙ стратегии, и ровно это уводило gv_tcp.
-- Двадцать ретрансмитов в окне не должны дать ни одного события.
conn = {}
local pos = 1400
local retrans_seen = 0
fired = false
for _ = 1, 10 do
    if run(seg_gv(pos, 24000, nil, false), conn) then fired = true end   -- новые данные
    if run(seg_gv(pos, 24000), conn) then fired = true end               -- потеря, повтор
    if run(seg_gv(pos, 24000), conn) then fired = true end               -- и ещё один
    retrans_seen = retrans_seen + 2
    pos = pos + 1400
end
if not fired and retrans_seen == 20 then
    ok("поток с потерями, но идущий вперёд, провалом не считается (20 ретрансмитов)")
else
    no("продвижение обнуляет счёт", "false", tostring(fired))
end

-- поток, который движется вперёд без единого повтора, тем более молчит
conn = {}
for _, p in ipairs({1400, 2800, 4200, 5600, 7000}) do
    fired = run(seg_gv(p, 24000, nil, false), conn)
end
if not fired then
    ok("поток без повторов провалом не считается")
else
    no("движение вперёд провалом не считается", "false", tostring(fired))
end

-- сервер отъезжает назад по окну на РАЗНЫЕ сегменты — это не залипание
conn = {}
fired = false
for _ = 1, 4 do
    for _, p in ipairs({4482, 5882, 7282}) do
        if run(seg_gv(p, 24000), conn) then fired = true end
    end
end
if not fired then
    ok("повторы разных сегментов не складываются в залипание")
else
    no("залипание = один и тот же сегмент", "false", tostring(fired))
end

-- повторы за планкой успеха — обычная потеря пакетов, не наше дело
conn = {}
for _ = 1, 12 do fired = run(seg_gv(30000, 24000), conn) end
if not fired then
    ok("повторы выше планки успеха провалом не считаются")
else
    no("выше планки — не провал", "false", tostring(fired))
end

-- чистые ACK стоят на одной позиции: их повторами считать нельзя
conn = {}
local ack = seg_gv(4482, 24000); ack.dis.payload = ""
for _ = 1, 12 do fired = run(ack, conn) end
if not fired then
    ok("серия пустых ACK на одной позиции провалом не считается")
else
    no("пустые ACK не считаются", "false", tostring(fired))
end

-- ключ yt_tcp тоже под правилом: картинки и страницы ютуба залипают так же
conn = {}
fired = false
for _ = 1, 7 do if run(seg_gv(4482, 18000, "yt_tcp"), conn) then fired = true end end
if fired then
    ok("правило работает и в пуле yt_tcp")
else
    no("yt_tcp под правилом", "true", tostring(fired))
end

-- РКН не трогаем намеренно: там на одном хосте и API-ответы, и страницы
conn = {}
for _ = 1, 12 do fired = run(seg_gv(4482, 26000, "rkn_tcp"), conn) end
if not fired then
    ok("в пуле rkn_tcp правило молчит")
else
    no("правило только для видео", "false", tostring(fired))
end

-- гвард по живости здесь НЕ применяется: залипшее соединение само же и
-- отдаёт те килобайты, по которым хост считается живым
reset_host()
for _ = 1, 3 do run(incoming("HTTP/2 payload")) end
conn = {}
fired = false
for _ = 1, 7 do if run(seg_gv(4482, 24000), conn) then fired = true end end
if fired then
    ok("залипание засчитывается даже когда хост считается живым")
else
    no("живость не подавляет залипание", "true", tostring(fired))
end

-- одно соединение — одно событие. Сервер повторяет сегмент пятнадцать раз;
-- если считать каждый повтор, один мёртвый поток набирает ротатору всю норму
-- провалов и уводит страту, работающую для остальных соединений.
conn = {}
local fires = 0
for _ = 1, 16 do
    if run(seg_gv(4482, 24000), conn) then fires = fires + 1 end
end
if fires == 1 then
    ok("шестнадцать повторов одного потока дают ровно одно событие")
else
    no("одно соединение — одно событие", "1", fires)
end

-- счёт ведётся по соединению, а не по хосту: два разных залипших потока
-- не должны складываться в одно событие раньше времени
local c1, c2 = {}, {}
fired = false
for _ = 1, 5 do
    if run(seg_gv(4482, 24000), c1) then fired = true end
    if run(seg_gv(4482, 24000), c2) then fired = true end
end
if not fired then
    ok("повторы разных соединений не складываются")
else
    no("счёт по соединению", "false", tostring(fired))
end

-- ----- 6. RST от самого сервера (сверка TTL) --------------------------------
-- Полевой случай 19.08.2026: apple.com уехал с рабочей первой стратегии на
-- нерабочую вторую. За 4.5 часа отладки все 15 событий детектора — incoming
-- RST, и два прошедших были на s7488, то есть после 7.4 КБ доставленных
-- данных. Это разрыв со стороны сервера, а не DPI. Планку inseq снижать
-- нельзя (на ней держится детект байтового гейта ТСПУ на 12-18К), поэтому
-- различаем по TTL.
reset_host()

local function srv_data(ttl, hlim)
    local d = { outgoing = false, l7payload = "unknown", arg = {},
                dis = { tcp = { th_flags = 0x18 }, payload = string.rep("z", 1400) } }
    if hlim then d.dis.ip6 = { ip6_hlim = hlim } else d.dis.ip = { ip_ttl = ttl } end
    return d
end
local function srv_rst(ttl, hlim)
    local d = { outgoing = false, l7payload = "unknown", arg = {},
                dis = { tcp = { th_flags = TH_RST }, payload = "" } }
    if hlim then d.dis.ip6 = { ip6_hlim = hlim } else d.dis.ip = { ip_ttl = ttl } end
    return d
end

-- сервер отдал данные и сам же закрылся: TTL тот же
reset_host(); conn = {}
std_result = false; pos_value = 1400
run(srv_data(52), conn)
std_result = true; pos_value = 7488
fired = run(srv_rst(52), conn)
if not fired then
    ok("RST с TTL потока = разрыв сервера, страту не уводит")
else
    no("RST сервера не провал", "false", tostring(fired))
end

-- ТСПУ в двух хопах от нас: данные сервера ttl 52, инжект ttl 126
reset_host(); conn = {}
std_result = false; pos_value = 1400
run(srv_data(52), conn)
std_result = true; pos_value = 14000
fired = run(srv_rst(126), conn)
if fired then
    ok("инжектированный RST (TTL 126 против 52) остаётся провалом")
else
    no("байтовый гейт ТСПУ ловится", "true", tostring(fired))
end

-- эталона нет — данных сервер не присылал вовсе: классический сброс на
-- хендшейке, судить не по чему, считаем провалом как раньше
reset_host(); conn = {}
std_result = true; pos_value = 1
fired = run(srv_rst(126), conn)
if fired then
    ok("RST до первого байта данных считается провалом (эталона нет)")
else
    no("сброс на хендшейке ловится", "true", tostring(fired))
end

-- балансир CDN отвечает с соседней машины: хоп-другой разницы — всё ещё сервер
reset_host(); conn = {}
std_result = false; pos_value = 1400
run(srv_data(52), conn)
std_result = true; pos_value = 9000
fired = run(srv_rst(50), conn)
if not fired then
    ok("разброс TTL в пределах двух хопов — всё ещё сервер")
else
    no("допуск на балансир", "false", tostring(fired))
end

-- а вот три хопа разницы — уже не тот путь
reset_host(); conn = {}
std_result = false; pos_value = 1400
run(srv_data(52), conn)
std_result = true; pos_value = 9000
fired = run(srv_rst(56), conn)
if fired then
    ok("разброс больше двух хопов считается провалом")
else
    no("порог допуска", "true", tostring(fired))
end

-- IPv6: то же самое по ip6_hlim
reset_host(); conn = {}
std_result = false; pos_value = 1400
run(srv_data(nil, 54), conn)
std_result = true; pos_value = 7488
fired = run(srv_rst(nil, 54), conn)
if not fired then
    ok("сверка работает и по IPv6 (ip6_hlim)")
else
    no("IPv6 hop limit", "false", tostring(fired))
end

-- провал не по RST (DPI-редирект) сверкой TTL не подавляется
reset_host(); conn = {}
std_result = false; pos_value = 1400
run(srv_data(52), conn)
std_result = true; pos_value = 2000
local redirect = srv_data(52); redirect.dis.tcp.th_flags = 0x18
fired = run(redirect, conn)
if fired then
    ok("не-RST провал (редирект) сверкой TTL не подавляется")
else
    no("редирект остаётся провалом", "true", tostring(fired))
end

-- пакет без IP-заголовка в дизассемблере не роняет детектор
reset_host(); conn = {}
std_result = false; pos_value = 1400
run(srv_data(52), conn)
std_result = true; pos_value = 7488
local bare = srv_rst(52); bare.dis.ip = nil
fired = run(bare, conn)
if fired then
    ok("RST без разобранного IP-заголовка судится по-старому")
else
    no("нет TTL — нет подавления", "true", tostring(fired))
end

print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
