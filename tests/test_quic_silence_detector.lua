-- tests/test_quic_silence_detector.lua
-- Юнит-тесты детектора молчания QUIC (files/lua/z2k-quic-silence.lua).
--
-- Запуск: lua tests/test_quic_silence_detector.lua
--
-- Детектор появился потому, что штатный для QUIC не работает в принципе. Замер
-- 2026-08-19, 1646 потоков: мёртвый поток шлёт МЕНЬШЕ пакетов, чем живой
-- (браузер не ретрансмитит Initial, а уходит на TCP), поэтому правило «отослано
-- много, принято мало» их не различает ни при каком пороге.
--
-- Здесь сторожим контракт обёртки: когда она взводит таймер, что делает при
-- молчании, и главное — чего она НЕ делает на живом потоке.

local PASS, FAIL = 0, 0
local function ok(m) PASS = PASS + 1; print("[PASS] " .. m) end
local function no(m, want, got)
    FAIL = FAIL + 1
    print(string.format("[FAIL] %s (want=%s got=%s)", m, tostring(want), tostring(got)))
end

-- ----- окружение движка ------------------------------------------------------
function DLOG() end

local std_calls = 0
function standard_failure_detector() std_calls = std_calls + 1; return false end

local pos_value = 2
function pos_get() return pos_value end

function dis_timer_name() return "1.2.3.4->5.6.7.8_udp_1234_443" end

local hrec
function automate_host_record() return hrec end

-- Счёт неудач ведём как движок: реализация из lua/zapret-auto.lua, упрощённая
-- до того, что нужно тесту (без окна времени — его проверяет сам движок).
local counter_calls = 0
function automate_failure_counter(h, c, fails)
    counter_calls = counter_calls + 1
    if c and c.failure then return false end
    if c then c.failure = true end
    h.failure_counter = (h.failure_counter or 0) + 1
    if h.failure_counter >= (fails or 3) then
        h.failure_counter = nil
        return true
    end
    return false
end

-- Ловим взведённые таймеры вместо реального движка.
local timers = {}
function timer_set(name, func, period, oneshot, data)
    timers[name] = { func = func, period = period, oneshot = oneshot, data = data }
end

local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "tests"
dofile(here .. "/../files/lua/z2k-quic-silence.lua")

-- ----- конструкторы ----------------------------------------------------------
local function reset()
    timers, counter_calls, std_calls = {}, 0, 0
    hrec = { nstrategy = 1, ctstrategy = 13 }
end

local function pkt(outgoing, key)
    return { outgoing = outgoing, arg = { key = key or "yt_quic", fails = 3, time = 60 },
             track = {}, dis = { udp = {}, payload = "x" } }
end

local function tcp_pkt()
    return { outgoing = true, arg = { key = "rkn_tcp" }, track = {},
             dis = { tcp = {}, payload = "x" } }
end

local function fire(name)
    local t = timers[name]
    if not t then return false end
    _G[t.func](name, t.data)
    return true
end

local TNAME = "z2kqs_1.2.3.4->5.6.7.8_udp_1234_443"

-- ----- 1. взведение таймера --------------------------------------------------
reset()
local crec = {}
pos_value = 1
z2k_fail_quic_silence(pkt(true), crec)
if not timers[TNAME] then
    ok("на первом же исходящем пакете таймер не взводится")
else
    no("порог по числу исходящих", "нет таймера", "есть")
end

pos_value = 2
z2k_fail_quic_silence(pkt(true), crec)
local t = timers[TNAME]
if t then
    ok("на втором исходящем таймер взведён")
else
    no("таймер взводится", "есть", "нет")
end
if t and t.oneshot == true and t.period >= 1000 and t.period <= 5000 then
    ok("таймер одноразовый, окно ожидания " .. t.period .. " мс")
else
    no("параметры таймера", "oneshot, 1000..5000 мс",
       t and (tostring(t.oneshot) .. "/" .. tostring(t.period)) or "нет таймера")
end

-- повторные исходящие не должны переводить отсчёт
local first = timers[TNAME]
pos_value = 7
z2k_fail_quic_silence(pkt(true), crec)
if timers[TNAME] == first then
    ok("повторные исходящие отсчёт не перезаводят")
else
    no("таймер взводится один раз", "тот же", "заменён")
end

-- ----- 2. молчание = провал --------------------------------------------------
reset()
crec = {}
pos_value = 2
z2k_fail_quic_silence(pkt(true), crec)
fire(TNAME)
if hrec.failure_counter == 1 then
    ok("молчание засчитано как провал")
else
    no("провал по молчанию", "1", tostring(hrec.failure_counter))
end
if hrec.nstrategy == 1 then
    ok("на первом провале стратегия не двигается")
else
    no("одного провала мало", "1", tostring(hrec.nstrategy))
end

-- три провала подряд крутят стратегию
reset()
for _ = 1, 3 do
    local c = {}
    pos_value = 2
    z2k_fail_quic_silence(pkt(true), c)
    fire(TNAME)
end
if hrec.nstrategy == 2 then
    ok("три молчащих потока переключают стратегию")
else
    no("ротация на трёх провалах", "2", tostring(hrec.nstrategy))
end

-- ----- 3. ответ пришёл — тишины нет ------------------------------------------
reset()
crec = {}
pos_value = 2
z2k_fail_quic_silence(pkt(true), crec)
z2k_fail_quic_silence(pkt(false), crec)   -- входящий
fire(TNAME)
if not hrec.failure_counter and counter_calls == 0 then
    ok("ответивший поток провалом не считается")
else
    no("живой поток не трогаем", "0 вызовов счётчика", counter_calls)
end

-- одного входящего достаточно, даже если исходящих было много
reset()
crec = {}
pos_value = 2
z2k_fail_quic_silence(pkt(true), crec)
z2k_fail_quic_silence(pkt(false), crec)
pos_value = 9
z2k_fail_quic_silence(pkt(true), crec)
fire(TNAME)
if counter_calls == 0 then
    ok("отметка об ответе переживает последующие исходящие")
else
    no("отметка не сбрасывается", "0", counter_calls)
end

-- ----- 4. чужие вердикты уважаем ---------------------------------------------
reset()
crec = {}
pos_value = 2
z2k_fail_quic_silence(pkt(true), crec)
crec.nocheck = true          -- движок уже решил судьбу потока
fire(TNAME)
if counter_calls == 0 then
    ok("вердикт, уже вынесенный движком, не переигрываем")
else
    no("уважать nocheck", "0", counter_calls)
end

-- финальная стратегия блокирует дальнейшее кручение
reset()
hrec.final = 1
for _ = 1, 3 do
    local c = {}
    pos_value = 2
    z2k_fail_quic_silence(pkt(true), c)
    fire(TNAME)
end
if hrec.nstrategy == 1 then
    ok("финальная стратегия не крутится дальше")
else
    no("уважать final", "1", tostring(hrec.nstrategy))
end

-- ----- 5. границы применимости ------------------------------------------------
reset()
crec = {}
pos_value = 2
z2k_fail_quic_silence(pkt(true, "discord_udp"), crec)
if not timers[TNAME] then
    ok("в чужом udp-пуле таймер не взводится")
else
    no("только пулы видео", "нет таймера", "есть")
end

reset()
crec = {}
std_calls = 0
z2k_fail_quic_silence(tcp_pkt(), crec)
if std_calls == 1 and not timers[TNAME] then
    ok("tcp уходит штатному детектору без изменений")
else
    no("tcp делегируется", "1 вызов, нет таймера", std_calls)
end

-- ----- 6. таймер не падает на мусоре -----------------------------------------
reset()
local okcall = pcall(z2k_quic_silence_timer, "t", {})
if okcall then
    ok("таймер без crec/hrec не роняет движок")
else
    no("устойчивость таймера", "без ошибки", "error")
end

-- Ошибка в таймер-функции приводит к её принудительному снятию движком
-- (мануал: «Если таймер-функция вываливается с error, таймер удаляется»),
-- то есть детектор молча перестал бы работать. Поэтому и проверяем.
reset()
okcall = pcall(z2k_quic_silence_timer, "t", { crec = {}, hrec = { nstrategy = 1 } })
if okcall then
    ok("таймер без ctstrategy тоже не падает")
else
    no("устойчивость без ctstrategy", "без ошибки", "error")
end

print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
