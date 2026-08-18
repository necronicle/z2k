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

fired, calls = run(outgoing("http_req"))
if not fired and calls == 0 then
    ok("прочие исходящие пейлоады тоже не считаются")
else
    no("http_req не считается", "false/0", tostring(fired) .. "/" .. calls)
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

-- ----- 5. входящий ретрансмит (только пулы видео) -------------------------
-- Полевой случай LG webOS на нерабочей 20-й стратегии: сервер отдаёт 4482
-- байта и дальше шлёт один и тот же сегмент 15-16 раз, телевизор не
-- подтверждает. Ни RST, ни FIN, ни исходящих ретрансмитов — детектор молчал.
reset_host()
std_result = false

-- первое появление сегмента и два повтора — ещё не приговор
local conn = {}
fired = run(seg_gv(4482, 24000, nil, false), conn)
if not fired then
    ok("первый приход сегмента провалом не считается")
else
    no("первый приход", "false", tostring(fired))
end
fired = run(seg_gv(4482, 24000), conn)
if not fired then ok("один повтор — ещё не провал")
else no("один повтор", "false", tostring(fired)) end
fired = run(seg_gv(4482, 24000), conn)
if not fired then ok("два повтора — ещё не провал")
else no("два повтора", "false", tostring(fired)) end
fired = run(seg_gv(4482, 24000), conn)
if fired then
    ok("три повтора одного сегмента = провал")
else
    no("порог трёх повторов", "true", tostring(fired))
end

-- поток, который движется вперёд, повторов не даёт вовсе
conn = {}
for _, pos in ipairs({1400, 2800, 4200, 5600, 7000}) do
    fired = run(seg_gv(pos, 24000, nil, false), conn)
end
if not fired then
    ok("поток, идущий вперёд, провалом не считается")
else
    no("движение вперёд провалом не считается", "false", tostring(fired))
end

-- повторы за планкой успеха — обычная потеря пакетов, не наше дело
conn = {}
for _ = 1, 6 do fired = run(seg_gv(30000, 24000), conn) end
if not fired then
    ok("повторы выше планки успеха провалом не считаются")
else
    no("выше планки — не провал", "false", tostring(fired))
end

-- чистые ACK стоят на одной позиции: их повторами считать нельзя
conn = {}
local ack = seg_gv(4482, 24000); ack.dis.payload = ""
for _ = 1, 8 do fired = run(ack, conn) end
if not fired then
    ok("серия пустых ACK на одной позиции провалом не считается")
else
    no("пустые ACK не считаются", "false", tostring(fired))
end

-- ключ yt_tcp тоже под правилом: картинки и страницы ютуба залипают так же
conn = {}
fired = false
for _ = 1, 4 do if run(seg_gv(4482, 18000, "yt_tcp"), conn) then fired = true end end
if fired then
    ok("правило работает и в пуле yt_tcp")
else
    no("yt_tcp под правилом", "true", tostring(fired))
end

-- РКН не трогаем намеренно: там на одном хосте и API-ответы, и страницы
conn = {}
for _ = 1, 8 do fired = run(seg_gv(4482, 26000, "rkn_tcp"), conn) end
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
for _ = 1, 4 do if run(seg_gv(4482, 24000), conn) then fired = true end end
if fired then
    ok("ретрансмит засчитывается даже когда хост считается живым")
else
    no("живость не подавляет ретрансмит", "true", tostring(fired))
end

-- одно соединение — одно событие. Сервер повторяет сегмент пятнадцать раз;
-- если считать каждый повтор, один мёртвый поток набирает ротатору всю норму
-- провалов и уводит страту, работающую для остальных соединений.
conn = {}
local fires = 0
for _ = 1, 12 do
    if run(seg_gv(4482, 24000), conn) then fires = fires + 1 end
end
if fires == 1 then
    ok("двенадцать повторов одного потока дают ровно одно событие")
else
    no("одно соединение — одно событие", "1", fires)
end

-- счёт ведётся по соединению, а не по хосту: два разных залипших потока
-- не должны складываться в одно событие раньше времени
local c1, c2 = {}, {}
run(seg_gv(4482, 24000), c1)
run(seg_gv(4482, 24000), c2)
fired = run(seg_gv(4482, 24000), c1)
if not fired then
    ok("повторы разных соединений не складываются")
else
    no("счёт по соединению", "false", tostring(fired))
end

print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
