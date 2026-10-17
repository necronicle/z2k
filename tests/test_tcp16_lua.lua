-- tests/test_tcp16_lua.lua
-- Юнит-тесты рантайма обхода обрыва на 16 КБ (files/lua/z2k-tcp16.lua).
--
-- Запуск: lua tests/test_tcp16_lua.lua
--
-- С 10.09.2026 файл — только подстановка имени по карте от пробы: ни сторожа
-- обрыва, ни поштучного перебора. Здесь сторожим ровно это: карта «сеть → имя»
-- читается и применяется по адресу назначения, ручное закрепление действует
-- только без карты, а десинк-функция кладёт блоб лишь когда имя есть.

local PASS, FAIL = 0, 0
local function ok(m) PASS = PASS + 1; print("[PASS] " .. m) end
local function no(m, want, got)
    FAIL = FAIL + 1
    print(string.format("[FAIL] %s (want=%s got=%s)", m, tostring(want), tostring(got)))
end
local function is(m, want, got) if want == got then ok(m) else no(m, want, got) end end

-- ----- заглушки движка -------------------------------------------------------
function DLOG() end
b_debug = false
function direction_cutoff_opposite() end
function direction_check() return true end
function payload_check() return true end
function replay_first() return true end
function blob(_, name) return "CH:" .. name end
function tls_mod(base, mods) return base .. "|" .. mods end
-- Штатный клонировщик hello (zapret-antidpi.lua): фейк = настоящий hello с
-- заменённым именем. Мок возвращает исходник и что в нём поменяли, чтобы
-- проверить, что имя подставляется именно клону, а не чужому блобу.
function tls_client_hello_mod(payload, mods)
    return "CLONE:" .. payload .. "|sni_del=" .. tostring(mods.sni_del) .. ",sni_first=" .. mods.sni_first
        .. ",sni_snt_new=" .. tostring(mods.sni_snt_new)
end

local FAKE_NOW = 1700000000
os.time = function() return FAKE_NOW end

local function load_with(env)
    local real_getenv = os.getenv
    os.getenv = function(k)
        if env[k] ~= nil then return env[k] end
        return real_getenv(k)
    end
    dofile("files/lua/z2k-tcp16.lua")
    return function() os.getenv = real_getenv end
end

local function v4(a, b) return { dis = { ip = { ip_dst = string.char(a, b, 0, 1) }, tcp = {} }, arg = {} } end
local function v6(g1, g2)
    return { dis = { ip6 = { ip6_dst = string.char(g1 // 256, g1 % 256, g2 // 256, g2 % 256) .. string.rep("\0", 12) }, tcp = {} }, arg = {} }
end

-- ----- ручное закрепление ----------------------------------------------------
do
    local pinfile = os.tmpname()
    local restore = load_with({ Z2K_SNI_PIN = pinfile, Z2K_PIN_RECHECK = "0" })

    local f = io.open(pinfile, "w"); f:write("  300.ya.ru  # выбрано руками\n"); f:close()
    is("закрепление читается, пробелы и комментарий срезаны", "300.ya.ru", z2k_sni_pinned())
    f = io.open(pinfile, "w"); f:write("плохое имя с пробелом\n"); f:close()
    is("мусор в файле закрепления игнорируется", nil, z2k_sni_pinned())
    os.remove(pinfile)
    is("нет файла — нет закрепления", nil, z2k_sni_pinned())
    restore()
end

-- ----- карта «сеть → имя» ------------------------------------------------------
-- Замер 30.08.2026: hcaptcha.com бьёт двадцать AS, но НЕ Hetzner; Hetzner берёт
-- 300.ya.ru. Одного имени на всех не бывает, и подставлять чужое бессмысленно.
do
    local asnf, netf, snif = os.tmpname(), os.tmpname(), os.tmpname()
    local f = io.open(asnf, "w"); f:write("# найдено\n24940\n13335\n51167\n"); f:close()
    f = io.open(netf, "w")
    f:write("24940\t91.98.0.0/16\n24940\t46.62.0.0/16\n")
    f:write("13335\t104.21.0.0/16\n")
    f:write("13335\t2606:4700::/32\n")
    f:write("13335\t2620::/32\n")
    f:write("51167\t161.97.0.0/16\n")           -- блок есть, имени нет
    f:write("16509\t52.94.0.0/16\n")            -- AS без блока
    f:close()
    f = io.open(snif, "w"); f:write("# карта\n24940\t300.ya.ru\n13335\thcaptcha.com\n"); f:close()

    local restore = load_with({ Z2K_TCP16_ASN = asnf, Z2K_TCP16_NETS = netf, Z2K_TCP16_SNI = snif })
    is("Hetzner получает своё имя", "300.ya.ru", z2k_sni_for(v4(91, 98), "общее"))
    is("вторая сеть Hetzner — то же имя", "300.ya.ru", z2k_sni_for(v4(46, 62), "общее"))
    is("Cloudflare получает ДРУГОЕ имя", "hcaptcha.com", z2k_sni_for(v4(104, 21), "общее"))
    is("Cloudflare по IPv6 — то же имя", "hcaptcha.com", z2k_sni_for(v6(0x2606, 0x4700), "общее"))
    is("сжатый префикс 2620::/32 матчит ровно 2620:0::/32", "hcaptcha.com", z2k_sni_for(v6(0x2620, 0x0000), "общее"))
    is("сжатый префикс 2620::/32 НЕ захватывает соседние /32 в 2620::/16", nil, z2k_sni_for(v6(0x2620, 0x01ec), "общее"))
    is("сеть с блоком, но без имени — не подставляем", nil, z2k_sni_for(v4(161, 97), "общее"))
    is("сеть без блока — не подставляем", nil, z2k_sni_for(v4(52, 94), "общее"))
    is("адрес вне карты — не подставляем", nil, z2k_sni_for(v4(8, 8), "общее"))
    is("закрепление при живой карте не действует", nil, z2k_sni_for(v4(8, 8), "общее"))

    -- Десинк-функция: блоб кладётся только когда имя есть, и с именем внутри.
    -- Основной путь — КЛОН настоящего hello (решение 11.09.2026): в фейке
    -- собранный hello человека (reasm_data), а не встроенный блоб.
    local d = v4(91, 98); d.reasm_data = "HELLO-REASM"; d.dis.payload = "HELLO-PKT"
    z2k_sni_pick(nil, d)
    is("z2k_sni_pick положил клон собранного hello с именем сети и декорацией rnd,dupsid",
        "CLONE:HELLO-REASM|sni_del=true,sni_first=300.ya.ru,sni_snt_new=0|rnd,dupsid", d.z2k_ch)
    local d1 = v4(91, 98); d1.dis.payload = "HELLO-PKT"
    z2k_sni_pick(nil, d1)
    is("без сборки клонируется payload самого пакета",
        "CLONE:HELLO-PKT|sni_del=true,sni_first=300.ya.ru,sni_snt_new=0|rnd,dupsid", d1.z2k_ch)
    local d2 = v4(8, 8); d2.dis.payload = "HELLO-PKT"
    z2k_sni_pick(nil, d2)
    is("адрес вне карты — блоба нет", nil, d2.z2k_ch)
    local d3 = v4(104, 21); d3.dis.payload = "HELLO-PKT"; d3.arg = { blob = "my_ch" }
    z2k_sni_pick(nil, d3)
    is("имя блоба берётся из аргументов инстанса",
        "CLONE:HELLO-PKT|sni_del=true,sni_first=hcaptcha.com,sni_snt_new=0|rnd,dupsid", d3.my_ch)
    -- Запасной путь: hello не разобрался (клонировщик отказал) — прежняя
    -- подстановка имени во встроенный блоб через tls_mod, а не тишина.
    local real_clone = tls_client_hello_mod
    tls_client_hello_mod = function() error("not a client hello") end
    local d4 = v4(104, 21); d4.dis.payload = "GARBAGE"; d4.arg = { blob = "my_ch", mods = "rnd", src = "fake_x" }
    z2k_sni_pick(nil, d4)
    is("hello не разобрался — запасной путь: встроенный блоб + tls_mod", "CH:fake_x|rnd,sni=hcaptcha.com", d4.my_ch)
    tls_client_hello_mod = function() return nil end
    local d5 = v4(91, 98); d5.dis.payload = "GARBAGE"
    z2k_sni_pick(nil, d5)
    is("клонировщик вернул nil — тот же запасной путь", "CH:fake_default_tls|rnd,dupsid,sni=300.ya.ru", d5.z2k_ch)
    tls_client_hello_mod = real_clone
    restore()

    -- Карты имён нет вовсе: работает ручное закрепление.
    os.remove(snif)
    restore = load_with({ Z2K_TCP16_ASN = asnf, Z2K_TCP16_NETS = netf, Z2K_TCP16_SNI = snif })
    is("без карты имён работает общее закрепление", "общее", z2k_sni_for(v4(91, 98), "общее"))
    restore()
    os.remove(asnf); os.remove(netf)
end

-- ----- файл не даёт ничего лишнего --------------------------------------------
-- Сторож обрыва и перебор имён сняты 10.09.2026 вместе с остальными
-- нештатными детекторами; их возвращение — регрессия, а не улучшение.
do
    load_with({})()
    is("сторожа обрыва нет", nil, _G.z2k_stall_watch)
    is("перебора имён нет", nil, _G.z2k_sni_next)
    is("детектора TLS-алертов нет", nil, _G.z2k_fail_tls_alert)
end

print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
