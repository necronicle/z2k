-- z2k: поправки к штатному детектору неудач. Все четыре — по замерам на боевом
-- роутере 18.08.2026. Логика bol-van вызывается как есть, мы только сужаем
-- вход, добавляем сигналы и держим политику «живой хост не ротируем».
--
-- 1. РЕТРАНСМИТ СЧИТАЕМ ТОЛЬКО НА ClientHello.
--    standard_failure_detector считает провалом ЛЮБУЮ исходящую
--    ретрансмиссию в пределах maxseq. Пойманный случай: телефон по вайфаю
--    переслал пакет TLS application data (17 03 03 ...) в УЖЕ РАБОТАЮЩЕЙ
--    сессии, payload_type 'unknown', и это засчиталось в провал страты.
--
-- 2. ФАТАЛЬНЫЙ TLS-АЛЕРТ ДО ServerHello — ПРОВАЛ.
--    Сервер подтверждает ClientHello целиком, отвечает семибайтовой записью
--    alert и закрывается по FIN. Ретрансмитить нечего, RST нет — штатный
--    детектор слеп, страта не ротируется никогда.
--
-- 3. ЖИВОЙ ХОСТ НЕ РОТИРУЕМ.
--    Пойманная ложная ротация: ТСПУ шлёт поддельный RST (ttl=126, два хопа —
--    настоящий ответ Меты пришёл бы с TTL около полусотни) на первом байте
--    ответа. Три таких за минуту уводят страту, при том что в том же окне
--    девять соединений к тому же хосту прошли нормально:
--      LUA: standard_failure_detector: incoming RST s1 in range s26000
--      LUA: automate: failure counter 3-9(succ)=net -6/3 content_fresh=false
--      LUA: circular: rotate strategy to 2
--    В движке защита по успехам есть, но в нативном режиме мертва: её
--    пропускает вперёд `not content_fresh`, а content-gate заполняется только
--    в снятой ветке r-49. Поэтому считаем живые ответы сами, здесь.
--
-- 4. ВХОДЯЩИЙ РЕТРАНСМИТ — ПРОВАЛ. Только пулы видео.
--    LG webOS на заведомо нерабочей 20-й стратегии: соединение к googlevideo
--    поднимается, сервер отдаёт 4482 байта и дальше шлёт один и тот же сегмент
--    15-16 раз, телевизор не подтверждает ни разу. RST нет, FIN нет,
--    исходящих ретрансмитов нет — 676 вызовов детектора и ноль событий, страта
--    стоит вечно, видео не грузится. Штатный детектор смотрит только
--    ИСХОДЯЩИЕ ретрансмиты, входящих не видит вовсе.

-- Окно и порог. Окно совпадает с `time=` у circular (60 с по умолчанию):
-- дольше держать нельзя, иначе вчерашние успехи защищают сегодня умерший хост.
local Z2K_OK_WINDOW = 60
-- Сколько живых ответов за окно считаем доказательством, что страта рабочая.
-- Три: одиночный ответ бывает и на пути, который DPI рвёт через раз.
local Z2K_OK_MIN = 3

local function host_record(desync)
	local ok, hrec = pcall(automate_host_record, desync)
	if ok then return hrec end
	return nil
end

-- Живой ответ = сервер прислал непустой пейлоад, который не является
-- фатальным алертом. Считаем по хосту, а не по соединению: ложная ротация
-- как раз и складывается из нескольких соединений.
local function note_alive(desync, is_fatal_alert)
	if is_fatal_alert then return end
	local p = desync.dis and desync.dis.payload
	if not p or #p == 0 then return end
	local hrec = host_record(desync)
	if not hrec then return end
	local now = os.time()
	if hrec.z2k_ok_last and (now - hrec.z2k_ok_last) > Z2K_OK_WINDOW then
		hrec.z2k_ok_n = nil
	end
	hrec.z2k_ok_n = (hrec.z2k_ok_n or 0) + 1
	hrec.z2k_ok_last = now
end

-- true, если хост прямо сейчас доказал, что работает.
local function host_alive(desync)
	local hrec = host_record(desync)
	if not hrec or not hrec.z2k_ok_last then return false end
	if (os.time() - hrec.z2k_ok_last) > Z2K_OK_WINDOW then
		hrec.z2k_ok_n = nil
		return false
	end
	return (hrec.z2k_ok_n or 0) >= Z2K_OK_MIN
end

-- Пулы, где входящий ретрансмит считается провалом. Видео и картинки ютуба:
-- там поток либо идёт, либо не идёт, промежуточных «маленьких правильных
-- ответов» не бывает. РКН сюда не включён намеренно — там на одном хосте
-- живут и API-ответы в пару килобайт, и страницы, и рвать рабочую страту из-за
-- одного залипшего соединения нельзя.
local Z2K_RETRANS_POOLS = { yt_tcp = true, gv_tcp = true }
-- Сколько повторов одного и того же сегмента считаем доказательством смерти.
-- Полевой замер 18.08.2026, LG webOS на заведомо нерабочей 20-й стратегии:
-- на КАЖДОМ соединении к googlevideo сервер слал один и тот же seq 15-16 раз,
-- телевизор не подтверждал ни разу, RST и FIN не приходили вовсе. Здоровый
-- поток повторяет сегмент один-два раза, три — уже не случайность.
local Z2K_RETRANS_MIN = 3

-- Провал по входящему ретрансмиту. Считаем по СОЕДИНЕНИЮ (crec), а не по хосту:
-- залипает именно поток, и пятнадцать повторов в нём — законченное событие.
--
-- Гвард по живости сюда намеренно не применяется. Такое соединение как раз и
-- отдаёт первые килобайты данных, то есть по меркам гварда хост «живой» —
-- и настоящий провал был бы подавлен своим же ответом. Для пулов видео живость
-- определяется не байтами, а тем, доехал ли поток до планки успеха.
local function incoming_retrans_failure(desync, crec)
	if not crec then return false end
	if not Z2K_RETRANS_POOLS[desync.arg.key] then return false end

	-- Одно соединение — одно событие. Дальше порога не считаем: сервер долбит
	-- мёртвый поток по пятнадцать раз, и без этого стопа он в одиночку набирает
	-- ротатору всю норму провалов, уводя страту, которая для остальных
	-- соединений работает. Тот же стоп стоит у bol-van в штатном детекторе
	-- (`(crec.retrans or 0) < arg.retrans`, lua/zapret-auto.lua).
	if (crec.z2k_in_retrans or 0) >= Z2K_RETRANS_MIN then return false end

	local p = desync.dis.payload
	-- Чистые ACK данных не несут, повторами их считать нечего.
	if not p or #p == 0 then return false end

	-- Тот же признак, которым движок ловит ИСХОДЯЩИЕ ретрансмиты: позиция
	-- пакета не выше уже виденного максимума. Своего счёта позиций не заводим,
	-- иначе разойдёмся с движком на переупорядоченных и частично перекрытых
	-- сегментах.
	if not is_retransmission(desync) then return false end

	-- Поток, пробивший планку успеха, ротировать не за что: страта своё дело
	-- сделала, а повторы там — обычная потеря пакетов по дороге.
	local s = pos_get(desync, 's') or 0
	local bar = tonumber(desync.arg.inseq) or 0
	if bar > 0 and s >= bar then return false end

	crec.z2k_in_retrans = (crec.z2k_in_retrans or 0) + 1
	if crec.z2k_in_retrans < Z2K_RETRANS_MIN then return false end

	DLOG("z2k_fail_tls_alert: входящий ретрансмит на s" .. s .. ", повтор " ..
	     crec.z2k_in_retrans .. "/" .. Z2K_RETRANS_MIN .. " -> failure")
	return true
end

local function suppressed(desync, why)
	if host_alive(desync) then
		DLOG("z2k_fail_tls_alert: " .. why .. " подавлен — хост отвечает живьём в текущем окне")
		return true
	end
	return false
end

function z2k_fail_tls_alert(desync, crec)
	-- Исходящее: в штатный детектор пускаем только ClientHello. Ретрансмиты
	-- живой сессии — не признак негодной стратегии.
	if desync.outgoing then
		if desync.l7payload ~= "tls_client_hello" then return false end
		if not standard_failure_detector(desync, crec) then return false end
		if suppressed(desync, "ретрансмит ClientHello") then return false end
		return true
	end

	if not desync.dis or not desync.dis.tcp then return false end

	local p = desync.dis.payload
	local fatal_alert = false
	if p and #p >= 7
	   and p:byte(1) == 0x15          -- content type alert
	   and p:byte(2) == 0x03          -- major version TLS
	   and p:byte(6) == 2 then        -- уровень 2 = fatal; 1 (close_notify) — норма
		-- только до ServerHello: алерт после реального ответа сервера — другой
		-- случай (политика сервера либо инжект), его сюда не мешаем.
		local s = pos_get(desync, 's') or 0
		fatal_alert = (s <= 1024)
	end

	note_alive(desync, fatal_alert)

	-- Входящее: штатный детектор (входящий RST, DPI-редирект), окно 16К-гейта
	-- по inseq — его же.
	if standard_failure_detector(desync, crec) then
		if suppressed(desync, "входящий провал") then return false end
		return true
	end

	-- 4. ВХОДЯЩИЙ РЕТРАНСМИТ — ПРОВАЛ. Только пулы видео.
	if incoming_retrans_failure(desync, crec) then return true end

	if fatal_alert then
		if suppressed(desync, "фатальный алерт") then return false end
		DLOG("z2k_fail_tls_alert: fatal alert desc=" .. tostring(p:byte(7)) .. " -> failure")
		return true
	end

	return false
end
