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

local std_calls = 0
local std_result = false
function standard_failure_detector()
    std_calls = std_calls + 1
    return std_result
end

local pos_value = 1
function pos_get() return pos_value end

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
    return { outgoing = false, l7payload = "unknown",
             dis = { tcp = {}, payload = payload } }
end

local function outgoing(l7)
    return { outgoing = true, l7payload = l7,
             dis = { tcp = {}, payload = string.rep("x", 300) } }
end

local function run(desync)
    std_calls, pos_value = 0, pos_value
    return z2k_fail_tls_alert(desync, {}), std_calls
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

print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
