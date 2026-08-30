-- tests/test_stall_detector.lua
-- Юнит-тесты детектора обрыва потока посреди TLS-записи
-- (files/lua/z2k-alert.lua: z2k_tls_frame_feed, z2k_stall_timer).
--
-- Запуск: lua tests/test_stall_detector.lua
--
-- Повод — замер 30.08.2026 на боевом роутере. hetzner.com отдавал ровно
-- 15994 байта и вставал; дамп зависшего потока (19 сегментов, 22286 байт)
-- показал: последняя TLS-запись объявила 16401 байт, доехало 2309.
-- Завершённый ответ всегда кончается на границе записи, усечённый — нет.
-- Здесь сторожим ровно этот разделитель и три условия срабатывания.

local PASS, FAIL = 0, 0
local function ok(m) PASS = PASS + 1; print("[PASS] " .. m) end
local function no(m, want, got)
    FAIL = FAIL + 1
    print(string.format("[FAIL] %s (want=%s got=%s)", m, tostring(want), tostring(got)))
end
local function is(m, want, got) if want == got then ok(m) else no(m, want, got) end end

-- ----- заглушки движка -------------------------------------------------------
local DLOGS = {}
function DLOG(s) DLOGS[#DLOGS + 1] = tostring(s) end
function DLOG_ERR() end
b_debug = false
autostate = {}
-- Поштучный перебор по умолчанию выключен (его сменило закрепление на линию).
-- Тесты проверяют ИМЕННО его, поэтому включаем явно — и заодно сторожим, что
-- выключатель существует и читается из окружения.
local real_getenv0 = os.getenv
os.getenv = function(k) if k == "Z2K_SNI_PERHOST" then return "1" end return real_getenv0(k) end

local FAKE_NOW = 1700000000
local real_time = os.time
os.time = function() return FAKE_NOW end

-- Всё, что файл трогает на верхнем уровне и чего мы здесь не проверяем.
function standard_failure_detector() return false end
function standard_success_detector() return false end
function automate_host_record() return nil end
function pos_get() return 0 end
function pos_get_pos() return 0 end
function is_retransmission() return false end
function dis_timer_name() return "flow" end
function timer_set() end
function timer_del() end
function dissect_nld(s) return s end
function http_dissect_reply() return nil end
function is_dpi_redirect() return false end
function find_tcp_option() return nil end
TH_FIN, TH_SYN, TH_RST, TH_PUSH, TH_ACK = 0x01, 0x02, 0x04, 0x08, 0x10
function bitand(a, b)
    local r, p = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end

dofile("files/lua/z2k-alert.lua")

-- ----- вспомогательное -------------------------------------------------------
-- Собрать TLS-запись: тип 23 (application data), версия 0x0303, длина, тело.
local function rec(len, body_byte)
    return string.char(23, 3, 3, math.floor(len / 256), len % 256) ..
           string.rep(string.char(body_byte or 65), len)
end
local function feed(st, ...)
    for _, chunk in ipairs({ ... }) do z2k_tls_frame_feed(st, chunk) end
    return ((st.need or 0) > 0) or (st.hdr ~= nil and #st.hdr > 0)
end

-- ----- машинка кадрирования --------------------------------------------------
is("целая запись — не посреди записи", false, feed({}, rec(10)))
is("две целых записи подряд — не посреди", false, feed({}, rec(10) .. rec(20)))

-- Ровно случай hetzner: запись объявлена длинной, доехал кусок.
local st = {}
is("усечённая запись — ПОСРЕДИ записи", true,
   feed(st, string.char(23, 3, 3, 0x40, 0x11) .. string.rep("A", 2309)))
is("недостача посчитана верно", 16401 - 2309, st.need)

-- Запись, поделённая между пакетами: собирается и закрывается.
is("запись через два пакета закрывается", false,
   feed({}, string.char(23, 3, 3, 0, 10) .. "ABCDE", "FGHIJ"))

-- Пятибайтовый заголовок, разорванный посередине, — самое злое место.
is("заголовок разорван 2+3 — длина прочитана", false,
   feed({}, string.char(23, 3), string.char(3, 0, 4) .. "WXYZ"))
local st2 = {}
feed(st2, string.char(23, 3, 3), string.char(0))
is("заголовок недобран — считается серединой", true, ((st2.need or 0) > 0) or (st2.hdr ~= nil))

-- Хвост записи и начало следующей в одном пакете.
is("хвост + новая целая запись в одном пакете", false,
   feed({}, string.char(23, 3, 3, 0, 6) .. "AB", "CDEF" .. rec(3)))

-- ----- вердикт таймера -------------------------------------------------------
local function fire(mid, high)
    local hrec = {}
    z2k_stall_timer("t", { st = { mid = mid, high = high }, hrec = hrec })
    return hrec.z2k_stall_at
end
-- Обрыв обязан сдвигать ИМЯ, а не счётчик провалов: ротация плеча этот класс
-- не лечит (несущая часть — имя), и засчёт провала только зря крутил бы пул.
local function fire_name(mid, high)
    local hrec = {}
    z2k_stall_timer("t", { st = { mid = mid, high = high }, hrec = hrec })
    return hrec.z2k_sni
end
is("посреди записи и в окне — обрыв засчитан", FAKE_NOW, fire(true, 15994))
is("на границе записи — обрыва нет", nil, fire(false, 15994))
is("выше потолка видимости — обрыва нет", nil, fire(true, 26000))
is("ровно на потолке — обрыва нет", nil, fire(true, 24000))
is("без hrec не падает", nil, (function()
    z2k_stall_timer("t", { st = { mid = true, high = 15994 } }); return nil
end)())

-- ----- список кандидатов и перебор ------------------------------------------
-- Разбор бьём по временному файлу: в список уезжают имена, которые пойдут в
-- фейковый ClientHello, и мусор оттуда уже не выковырять.
local tmp = os.tmpname()
local f = io.open(tmp, "w")
f:write("# комментарий\n")
f:write("\n")
f:write("  disk.rzd.ru  \n")          -- пробелы по краям срезаются
f:write("bad name.ru\n")              -- пробел внутри — не имя хоста
f:write("плохое.рф\n")                -- не ASCII
f:write("300.ya.ru # хвостовой комментарий\n")
f:write("vk.com\n")
f:close()

-- Подменяем путь через окружение, как это делает сам файл.
local real_getenv = os.getenv
os.getenv = function(k) if k == "Z2K_SNI_LIST" then return tmp end return real_getenv(k) end
-- Сбрасываем ленивую загрузку: файл уже мог её выполнить.
package.loaded["z2k-alert"] = nil
dofile("files/lua/z2k-alert.lua")

local list = z2k_sni_candidates()
is("мусорные строки отброшены", 3, list and #list or 0)
is("пробелы по краям срезаны", "disk.rzd.ru", list and list[1])
is("хвостовой комментарий срезан", "300.ya.ru", list and list[2])

local h = {}
is("первое имя", "disk.rzd.ru", z2k_sni_next(h))
is("второе имя", "300.ya.ru", z2k_sni_next(h))
is("третье имя", "vk.com", z2k_sni_next(h))
is("список кончился — nil, а не круг", nil, z2k_sni_next(h))
is("выбранное имя лежит в записи хоста", "vk.com", h.z2k_sni)

-- Обрыв двигает имя на следующее.
is("обрыв сдвигает имя", "disk.rzd.ru", fire_name(true, 15994))
is("на границе записи имя не двигается", nil, fire_name(false, 15994))

-- Рукопожатие не состоялось — тоже приговор кандидату и запуск перебора.
-- Без этого исхода механизм не стартовал там, где хост валится ещё на hello,
-- и залипал намертво, когда неподходящее имя ломало соединение совсем.
--
-- Но НЕ с первой неудачи: сразу после перезапуска отметки живости нет ни у
-- кого, и один случайный неудачный коннект вешал чужое имя рабочему сайту
-- (замер 30.08.2026, chatgpt.com). Поэтому первая неудача только считается.
local function fire_name2(mid, high)
    local hrec = {}
    z2k_stall_timer("t", { st = { mid = mid, high = high }, hrec = hrec })
    z2k_stall_timer("t", { st = { mid = mid, high = high }, hrec = hrec })
    return hrec.z2k_sni
end
is("одна неудача рукопожатия имя НЕ выбирает", nil, fire_name(true, 0))
is("две подряд — подбор начинается", "disk.rzd.ru", fire_name2(true, 0))
is("граница записи для этого исхода не важна", "disk.rzd.ru", fire_name2(false, 300))

-- Один поток судится один раз: иначе повторные срабатывания таймера пролистали
-- бы список за одно соединение.
local st_once = { mid = true, high = 0 }
local h_once = { z2k_hs_fails = 1 }
z2k_stall_timer("t", { st = st_once, hrec = h_once })
z2k_stall_timer("t", { st = st_once, hrec = h_once })
is("поток судится один раз", 1, h_once.z2k_sni_idx)

-- Живой хост подбор НЕ начинает. Одно неудачное рукопожатие бывает у любого
-- работающего сайта, а подставленное после этого чужое имя способно его
-- сломать: замер показал, как неудачное имя увело hetzner с 15994 байт на ноль.
-- Живость отмечается ЗАВЕРШЁННЫМ ответом, а не фактом пришедших байтов:
-- зарезанный поток тоже приносит данные (hetzner на втором плече отдаёт 15994
-- байта и встаёт), и по «пришли байты» подбор заглушился бы там, где он нужен.
local h_done = {}
z2k_stall_timer("t", { st = { mid = false, high = 15994 }, hrec = h_done })
is("завершённый ответ отмечает живость", FAKE_NOW, h_done.z2k_alive_at)
local h_cut = {}
z2k_stall_timer("t", { st = { mid = true, high = 15994 }, hrec = h_cut })
is("усечённый ответ живость НЕ отмечает", nil, h_cut.z2k_alive_at)
is("и при этом двигает имя", "disk.rzd.ru", h_cut.z2k_sni)

local h_alive = { z2k_alive_at = FAKE_NOW - 10 }
z2k_stall_timer("t", { st = { mid = true, high = 0 }, hrec = h_alive })
is("живой хост подбор не начинает", nil, h_alive.z2k_sni)
local h_stale = { z2k_alive_at = FAKE_NOW - 301, z2k_hs_fails = 1 }
z2k_stall_timer("t", { st = { mid = true, high = 0 }, hrec = h_stale })
is("замолчавший давно — подбор начинается", "disk.rzd.ru", h_stale.z2k_sni)

-- ПОТОЛОК ВИДИМОСТИ В ПАКЕТАХ. Байтовая планка не спасает: за горизонт поток
-- уходит на фиксированном ЧИСЛЕ пакетов, а не на объёме, и мелкие пакеты
-- уводят его туда куда раньше. Замер 30.08.2026: chatgpt.com отдал 340 КБ, а
-- видно было 17137 Б на пятидесяти пакетах — ровно потолок очереди. Рабочему
-- хосту записалось чужое имя.
local h_blind = {}
z2k_stall_timer("t", { st = { mid = true, high = 17137, rx = 50, cap = 50 }, hrec = h_blind })
is("упёрлись в потолок очереди — не судим", nil, h_blind.z2k_sni)
-- Потолок при данных отмечает живость: хост, чьи ответы всегда крупнее нашей
-- видимости, иначе не признавался бы живым НИКОГДА, и одно неудачное
-- рукопожатие запускало бы ему подбор. Замер: instagram отдал 404 КБ.
is("потолок при данных отмечает живость", FAKE_NOW, h_blind.z2k_alive_at)
local h_blind0 = {}
z2k_stall_timer("t", { st = { mid = true, high = 200, rx = 50, cap = 50 }, hrec = h_blind0 })
is("потолок без данных живость НЕ отмечает", nil, h_blind0.z2k_alive_at)

-- НО САМ ПО СЕБЕ ПОТОЛОК ИМЯ НЕ ОПРАВДЫВАЕТ. Замер 30.08.2026: hcaptcha.com
-- попал в файл как доказанное имя только потому, что поток успел набрать
-- килобайты и упереться в потолок, — а сайт не открывался вовсе.
local h_noproof = { z2k_sni = "hcaptcha.com" }
z2k_stall_timer("t", { st = { mid = true, high = 17137, rx = 50, cap = 50 }, hrec = h_noproof })
is("потолок имя НЕ оправдывает", nil, h_noproof.z2k_sni_ok)

-- А вот закрывающий пакет далеко за разобранным хвостом — оправдывает: поток
-- ехал, пока мы не смотрели. Замер здоровой загрузки: разобрано 8321 Б, FIN
-- пришёл с позицией 168082.
local h_jump = { z2k_sni = "300.ya.ru" }
z2k_stall_timer("t", { st = { mid = true, high = 8321, hi_seen = 168082, rx = 50, cap = 50 }, hrec = h_jump })
is("поток ехал за горизонтом — имя оправдано", true, h_jump.z2k_sni_ok)
is("и хост отмечен живым", FAKE_NOW, h_jump.z2k_alive_at)

-- Отрыв меньше планки доказательством не считается: одна TLS-запись бывает
-- до 16 КБ, и хвост записи объясняет небольшой разрыв сам по себе.
local h_nojump = { z2k_sni = "hcaptcha.com" }
z2k_stall_timer("t", { st = { mid = true, high = 15994, hi_seen = 16500, rx = 20, cap = 50 }, hrec = h_nojump })
is("малый отрыв имя не оправдывает", nil, h_nojump.z2k_sni_ok)
is("и это по-прежнему обрыв", "disk.rzd.ru", h_nojump.z2k_sni)

-- ГВАРД ЖИВОСТИ СТЕРЕЖЁТ СТАРТ, А НЕ ХОД ПОДБОРА. Пока кандидат не оправдан,
-- отметка живости от соседнего соединения не должна морозить перебор: замер
-- 30.08.2026 — 79 соединений браузера, 58 подстановок, ОДИН сдвиг за пять
-- минут, потому что живость обновлялась быстрее, чем шёл перебор.
local h_run = { z2k_sni = "disk.rzd.ru", z2k_sni_idx = 1, z2k_alive_at = FAKE_NOW - 10 }
z2k_stall_timer("t", { st = { mid = true, high = 0 }, hrec = h_run })
is("подбор в ходу — живость его не морозит", "300.ya.ru", h_run.z2k_sni)

-- ЗАВЕРШЁННЫЙ ОТВЕТ СНИМАЕТ ЛИШНИЙ ПОДБОР. Хост ответил целиком в пределах
-- нашей видимости — по объёму его не режут, имя ему не нужно, и держать чужое
-- в каждом хелло рабочего сайта незачем.
local h_done2 = { z2k_sni = "hcaptcha.com", z2k_sni_idx = 1 }
z2k_stall_timer("t", { st = { mid = false, high = 8484 }, hrec = h_done2 })
is("завершённый ответ снимает неоправданного кандидата", nil, h_done2.z2k_sni)
is("и отматывает перебор к началу", 0, h_done2.z2k_sni_idx)
is("а хост отмечен живым", FAKE_NOW, h_done2.z2k_alive_at)

-- Оправданное имя завершённый ответ не трогает: за ним как раз и стоит то,
-- что маленькие страницы у заблокированного хоста доезжают целиком.
local h_keep = { z2k_sni = "300.ya.ru", z2k_sni_ok = true, z2k_sni_idx = 5 }
z2k_stall_timer("t", { st = { mid = false, high = 8484 }, hrec = h_keep })
is("оправданное имя завершённый ответ сохраняет", "300.ya.ru", h_keep.z2k_sni)

-- А оправданное имя живость по-прежнему защищает: там перебору делать нечего.
local h_okname = { z2k_sni = "300.ya.ru", z2k_sni_ok = true, z2k_alive_at = FAKE_NOW - 10 }
z2k_stall_timer("t", { st = { mid = true, high = 0 }, hrec = h_okname })
is("оправданное имя при живом хосте не трогаем", "300.ya.ru", h_okname.z2k_sni)

local h_seen = {}
z2k_stall_timer("t", { st = { mid = true, high = 15994, rx = 18, cap = 50 }, hrec = h_seen })
is("поток кончился задолго до потолка — судим", "disk.rzd.ru", h_seen.z2k_sni)

-- Граница запаса: шесть пакетов до потолка уже считаем слепотой.
local h_edge = {}
z2k_stall_timer("t", { st = { mid = true, high = 15994, rx = 44, cap = 50 }, hrec = h_edge })
is("запас в шесть пакетов соблюдён", nil, h_edge.z2k_sni)
local h_edge2 = {}
z2k_stall_timer("t", { st = { mid = true, high = 15994, rx = 43, cap = 50 }, hrec = h_edge2 })
is("на пакет ниже запаса — судим", "disk.rzd.ru", h_edge2.z2k_sni)

-- Потолок не объявлен (инстанс без cap) — ведём себя как раньше.
local h_nocap = {}
z2k_stall_timer("t", { st = { mid = true, high = 15994, rx = 200 }, hrec = h_nocap })
is("без объявленного потолка судим по-старому", "disk.rzd.ru", h_nocap.z2k_sni)

-- ДОКАЗАВШЕЕ СЕБЯ ИМЯ не отдаём за один провал. Перезапуск стирает память, и
-- раньше одна неудачная попытка после рестарта выбрасывала уже найденное имя:
-- замер 30.08.2026 — hetzner с найденным 300.ya.ru ушёл на hcaptcha.com и
-- прошёл весь перебор заново.
local h_pr = { z2k_sni = "300.ya.ru", z2k_sni_ok = true }
z2k_stall_timer("t1", { st = { mid = true, high = 0 }, hrec = h_pr })
is("первый провал доказанное имя не сдвигает", "300.ya.ru", h_pr.z2k_sni)
z2k_stall_timer("t2", { st = { mid = true, high = 0 }, hrec = h_pr })
is("второй тоже", "300.ya.ru", h_pr.z2k_sni)
z2k_stall_timer("t3", { st = { mid = true, high = 0 }, hrec = h_pr })
is("на третьем сдаёмся и идём дальше по списку", "disk.rzd.ru", h_pr.z2k_sni)

-- Ответ хоста обнуляет счёт провалов: доказанное имя не должно накапливать
-- отказы месяцами и однажды слететь на ровном месте.
local h_pr2 = { z2k_sni = "300.ya.ru", z2k_sni_ok = true }
z2k_stall_timer("t4", { st = { mid = true, high = 0 }, hrec = h_pr2 })
z2k_stall_timer("t5", { st = { mid = false, high = 15994 }, hrec = h_pr2 })
is("успешный ответ обнулил счёт провалов", 0, h_pr2.z2k_sni_fails)
z2k_stall_timer("t6", { st = { mid = true, high = 0 }, hrec = h_pr2 })
z2k_stall_timer("t7", { st = { mid = true, high = 0 }, hrec = h_pr2 })
is("после обнуления имя снова держится", "300.ya.ru", h_pr2.z2k_sni)

-- Потолок перебора: дальше него не идём, чтобы не гонять человека по 188
-- неудачным загрузкам.
local h_cap = { z2k_sni_idx = 24 }
z2k_stall_timer("t", { st = { mid = true, high = 0 }, hrec = h_cap })
is("потолок перебора соблюдён", 24, h_cap.z2k_sni_idx)
-- ЗАКРЕПЛЁННОЕ ИМЯ ЛИНИИ. Блок по объёму — свойство линии, а не хоста: проба
-- 30.08.2026 нашла его в 34 AS из 43, включая Cloudflare. Значит одно имя
-- годится для всех, и перебирать по хостам незачем.
do
    local pinfile = os.tmpname()
    local real_getenv2 = os.getenv
    os.getenv = function(k)
        if k == "Z2K_SNI_PIN" then return pinfile end
        if k == "Z2K_PIN_RECHECK" then return "0" end
        return real_getenv2(k)
    end
    package.loaded["z2k-alert"] = nil
    dofile("files/lua/z2k-alert.lua")

    local f = io.open(pinfile, "w"); f:write("  300.ya.ru  # выбрано пробой\n"); f:close()
    is("имя читается, пробелы и комментарий срезаны", "300.ya.ru", z2k_sni_pinned())

    f = io.open(pinfile, "w"); f:write("плохое имя с пробелом\n"); f:close()
    is("мусор в файле закрепления игнорируется", nil, z2k_sni_pinned())

    os.remove(pinfile)
    is("нет файла — нет закрепления", nil, z2k_sni_pinned())

    -- ЗАМОК ПОДБОРА. Пока он стоит, поштучный перебор не работает: подбор на
    -- первом шаге снимает закрепление, и без замка старый путь успевает
    -- повесить своего первого кандидата на посторонний хост. Замер
    -- 30.08.2026: так chatgpt получил hcaptcha.com посреди прогона подбора.
    is("без файла замка перебор разрешён", false, z2k_sni_locked())
    local lf = io.open(pinfile .. ".lock", "w"); lf:write(""); lf:close()
    is("замок виден", true, z2k_sni_locked())
    os.remove(pinfile .. ".lock")
    is("замок снят", false, z2k_sni_locked())
    os.getenv = real_getenv2
    package.loaded["z2k-alert"] = nil
    dofile("files/lua/z2k-alert.lua")
end

-- КАЖДОЙ СЕТИ — СВОЁ ИМЯ. Замер 30.08.2026: hcaptcha.com бьёт двадцать AS, но
-- НЕ Hetzner; Hetzner, DigitalOcean и OVH берёт 300.ya.ru; семь AS не берёт
-- ничто. Одного имени на всех не бывает, и подставлять чужое бессмысленно.
do
    local asnf, netf, snif = os.tmpname(), os.tmpname(), os.tmpname()
    local f = io.open(asnf, "w"); f:write("# найдено\n24940\n13335\n51167\n"); f:close()
    f = io.open(netf, "w")
    f:write("24940\t91.98.0.0/16\n24940\t46.62.0.0/16\n")
    f:write("13335\t104.21.0.0/16\n")
    f:write("51167\t161.97.0.0/16\n")           -- блок есть, имени нет
    f:write("16509\t52.94.0.0/16\n")            -- AS без блока
    f:close()
    f = io.open(snif, "w")
    f:write("# карта\n24940\t300.ya.ru\n13335\thcaptcha.com\n")
    f:close()

    local rg = os.getenv
    os.getenv = function(k)
        if k == "Z2K_TCP16_ASN"  then return asnf end
        if k == "Z2K_TCP16_NETS" then return netf end
        if k == "Z2K_TCP16_SNI"  then return snif end
        if k == "Z2K_SNI_PERHOST" then return "1" end
        return rg(k)
    end
    package.loaded["z2k-alert"] = nil
    dofile("files/lua/z2k-alert.lua")

    local function v4(a, b) return { dis = { ip = { ip_dst = string.char(a, b, 0, 1) } } } end
    is("Hetzner получает своё имя", "300.ya.ru", z2k_sni_for(v4(91, 98), "общее"))
    is("вторая сеть Hetzner — то же имя", "300.ya.ru", z2k_sni_for(v4(46, 62), "общее"))
    is("Cloudflare получает ДРУГОЕ имя", "hcaptcha.com", z2k_sni_for(v4(104, 21), "общее"))
    is("сеть с блоком, но без имени — не подставляем", nil, z2k_sni_for(v4(161, 97), "общее"))
    is("сеть без блока — не подставляем", nil, z2k_sni_for(v4(52, 94), "общее"))
    is("адрес вне карты — не подставляем", nil, z2k_sni_for(v4(8, 8), "общее"))

    os.remove(snif)
    package.loaded["z2k-alert"] = nil
    dofile("files/lua/z2k-alert.lua")
    -- Карты имён нет вовсе: работаем как до поимённого подбора, по общему
    -- закреплению. Ломать переход нельзя.
    is("без карты имён работает общее закрепление", "общее", z2k_sni_for(v4(91, 98), "общее"))

    os.remove(asnf); os.remove(netf)
    os.getenv = rg
    package.loaded["z2k-alert"] = nil
    dofile("files/lua/z2k-alert.lua")
end

-- ПЕРВЫЙ HELLO ПОСЛЕ ПЕРЕЗАПУСКА. Селектор стоит в профиле ПЕРЕД circular, а
-- запись хоста засевается с диска внутри circular — поэтому имя он обязан
-- подтянуть сам. Иначе после каждого рестарта человек получает одну заведомо
-- неудачную загрузку (замер 30.08.2026: 0 байт, потом 163654).
do
    local seeded_hrec = {}
    local seed_calls = 0
    function direction_cutoff_opposite() end
    function payload_check() return true end
    function direction_check() return true end
    function timer_set() end
    function replay_first() return true end
    function blob() return string.rep("\0", 64) end
    function tls_mod() return nil end          -- дальше сборки фейка не идём
    automate_host_record = function() return seeded_hrec end
    z2k_state_persist = {
        get_record = function(_, do_seed)
            seed_calls = seed_calls + 1
            if do_seed then seeded_hrec.z2k_sni = "300.ya.ru" end
        end,
    }
    local desync = {
        outgoing = true, arg = { key = "rkn_tcp" },
        dis = { tcp = {} },
        track = { lua_state = {} },
    }
    z2k_sni_pick({}, desync)
    is("селектор сам сеет запись с диска", 1, seed_calls)
    is("и имя оказывается на месте до сборки фейка", "300.ya.ru", seeded_hrec.z2k_sni)

    -- Имя уже в памяти — на диск не ходим: это путь КАЖДОГО hello.
    seed_calls = 0
    z2k_sni_pick({}, desync)
    is("при готовом имени диск не трогаем", 0, seed_calls)
end

os.getenv = real_getenv
os.remove(tmp)

os.time = real_time
print(string.format("\nPASSED: %d\nFAILED: %d", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
