-- z2k: детектор неудач для пулов QUIC.
--
-- ЗАЧЕМ ОН ЕСТЬ. Штатный детектор считает провалом ситуацию «отослано >=udp_out
-- пакетов, принято <=udp_in». Для современного QUIC-клиента эта посылка неверна.
-- Замер 2026-08-19 на боевом роутере, 1646 потоков:
--
--   мёртвые (ответа нет вовсе, 402)   живые (до третьего входящего, 1239)
--     1 пакет   57                      1 пакет   14
--     2 пакета 222                      2 пакета 524
--     3         26                      3        278
--     4         11                      4        308
--     5         64                      5         93
--
-- Мёртвый поток шлёт МЕНЬШЕ пакетов, чем живой: браузер не долбится в стену, он
-- отправляет Initial, ждёт и уходит на TCP. Порогом по числу исходящих эти два
-- класса не разделяются вообще — проверены все значения от 2 до 12, всюду либо
-- ловится единицы процентов мёртвых, либо ложно падает большинство живых.
--
-- Разделяет их ВРЕМЯ, а не счёт. Здоровый поток отвечает за десятки
-- миллисекунд; мёртвый молчит вечно. Мануал, раздел «Таймеры»: «Таймеры могут
-- быть полезны для обработки ситуаций отсутствия реакции из сети на отсылаемые
-- пакеты». Ровно этим и пользуемся.
--
-- КАК УСТРОЕНО. На первом исходящем пакете потока взводим одноразовый таймер.
-- Каждый входящий пакет ставит в записи соединения отметку «ответили». Когда
-- таймер срабатывает, отметки либо есть, либо нет: нет — засчитываем провал
-- через штатный automate_failure_counter и, если счётчик добрал до fails,
-- двигаем стратегию той же формулой, что и circular.
--
-- Одноразовый таймер на поток — штатная идиома движка, так же сделан send с
-- аргументом delay в lua/zapret-antidpi.lua («oneshot timer, auto deletes»).

-- Сколько ждём ответа. Одна секунда — типичный первый PTO у QUIC-клиента, то
-- есть к этому моменту здоровый поток уже давно получил ответ, а мёртвый как
-- раз готовится к первой ретрансмиссии. Две секунды берём с запасом на
-- медленный мобильный аплинк и на то, что таймеры вызываются между блоками
-- пакетов, а не точно в срок.
local Z2K_QUIC_WAIT_MS = 2000

-- Пулы, где правило работает. QUIC к видео либо идёт, либо не идёт;
-- промежуточных «маленьких правильных ответов» там не бывает.
local Z2K_QUIC_POOLS = { yt_quic = true, gv_quic = true }

-- Провал засчитывается, только если исходящих было не меньше. Одиночный
-- пакет — это может быть что угодно, вплоть до случайного зонда.
local Z2K_QUIC_MIN_OUT = 2

-- Сработал таймер: смотрим, ответил ли кто-нибудь за окно ожидания.
--
-- data.crec и data.hrec — те же таблицы, что видел детектор: crec живёт в
-- desync.track.lua_state, hrec в глобальном autostate. timer_set кладёт data в
-- реестр Lua через luaL_ref, поэтому ссылки остаются валидными.
function z2k_quic_silence_timer(name, data)
    local crec, hrec = data.crec, data.hrec
    if not crec or not hrec then return end

    -- Ответ пришёл — поток живой, делать нечего. Счётчик неудач при этом НЕ
    -- сбрасываем: сброс это дело детектора удач, а он у пула свой и работает
    -- по своим порогам. Молча уходим, чтобы не спорить с ним за одну переменную.
    if crec.z2k_quic_answered then return end

    -- За время ожидания движок мог сам вынести вердикт по этому потоку
    -- (штатный детектор удач или неудач ставит nocheck). Тогда не лезем.
    if crec.nocheck then
        DLOG("z2k_quic_silence: " .. name .. " — вердикт уже вынесен движком, пропускаем")
        return
    end
    crec.nocheck = true

    local fails = tonumber(data.fails) or 3
    local maxtime = tonumber(data.maxtime) or 60

    DLOG("z2k_quic_silence: " .. name .. " — за " .. Z2K_QUIC_WAIT_MS ..
         " мс ни одного входящего пакета -> failure")

    -- Штатный счётчик: он же сам защищает от двойного счёта по одному
    -- соединению (crec.failure) и сам сбрасывается по maxtime.
    if not automate_failure_counter(hrec, crec, fails, maxtime) then return end

    -- Порог добран — крутим стратегию ровно так же, как это делает circular.
    -- ctstrategy и final заполняет он сам на первом пакете потока, поэтому к
    -- моменту срабатывания таймера они уже есть.
    if not hrec.ctstrategy or hrec.ctstrategy < 1 then return end
    if hrec.final and hrec.final == hrec.nstrategy then
        DLOG("z2k_quic_silence: стратегия " .. tostring(hrec.final) ..
             " финальная, дальше не крутим")
        return
    end
    hrec.nstrategy = ((hrec.nstrategy or 1) % hrec.ctstrategy) + 1
    DLOG("z2k_quic_silence: rotate strategy to " .. hrec.nstrategy)
end

-- Детектор неудач. Ставится как failure_detector= у circular пула QUIC.
--
-- Сам по себе он почти всегда возвращает false: вердикт выносит таймер. Здесь
-- только два дела — отметить входящие и взвести ожидание на первом исходящем.
function z2k_fail_quic_silence(desync, crec)
    if not desync.dis or not desync.dis.udp then
        -- не наш протокол — отдаём штатному, пусть решает как раньше
        return standard_failure_detector(desync, crec)
    end
    if not Z2K_QUIC_POOLS[desync.arg.key] then
        return standard_failure_detector(desync, crec)
    end
    if not crec then return false end

    if not desync.outgoing then
        crec.z2k_quic_answered = true
        return false
    end

    -- Дальше только исходящее.
    if crec.z2k_quic_armed then return false end
    if not desync.track then return false end

    local out_n = pos_get(desync, 'n') or 0
    if out_n < Z2K_QUIC_MIN_OUT then return false end

    local hrec = automate_host_record(desync)
    if not hrec then return false end

    crec.z2k_quic_armed = true
    -- Имя таймера — по пятёрке адрес-порт, БЕЗ счётчика пакетов. Штатный
    -- desync_timer_name добавляет pcounter и потому уникален на пакет; нам
    -- нужен один таймер на поток, иначе каждый следующий Initial перезаводил бы
    -- отсчёт и вердикт не наступил бы никогда.
    local tname = "z2kqs_" .. dis_timer_name(desync.dis)
    timer_set(tname, "z2k_quic_silence_timer", Z2K_QUIC_WAIT_MS, true, {
        crec = crec,
        hrec = hrec,
        fails = desync.arg.fails,
        maxtime = desync.arg.time,
    })
    DLOG("z2k_quic_silence: жду ответа " .. Z2K_QUIC_WAIT_MS .. " мс по " .. tname)
    return false
end
