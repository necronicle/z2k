-- z2k-tcp16.lua — обрыв на 16 КБ: подстановка белого имени по сети.
--
-- Класс блокировки: коробка провайдера пропускает рукопожатие и первые
-- 15-16 КБ ответа, дальше поток встаёт. Перебором стратегий он не лечится
-- (рукопожатие проходит), а пробивается фейковым ClientHello с именем из белого
-- списка провайдера рядом с настоящим.
--
-- Этот файл — ТОЛЬКО рантайм. Ничего не детектирует и в ротации не участвует
-- (решение Марка 10.09.2026): есть ли блок на линии и какое имя берёт какую
-- сеть, выясняет проба (files/z2k-tcp16-probe.sh, z2k-detect tcp16), а сюда
-- приходит готовая карта «AS → имя». Здесь: адрес назначения → AS по карте
-- сетей → имя по карте имён → блоб z2k_ch, который шлёт штатный fake:optional.
--
-- Файлы (пути переопределяются переменными окружения — так тесты подсовывают
-- свои):
--   state/tcp16_asn.txt   — AS, где блок подтверждён (Z2K_TCP16_ASN)
--   lists/tcp16_nets.txt  — «AS<TAB>префикс», огрублено до /16 и /32 (Z2K_TCP16_NETS)
--   state/tcp16_sni.txt   — «AS<TAB>имя» (Z2K_TCP16_SNI)
--   lists/sni_wl_pin.txt  — ручное закрепление одного имени на всю линию
--                           (Z2K_SNI_PIN); действует, только когда карты имён нет
--
-- Грузится ПОСЛЕ zapret-lib.lua и zapret-antidpi.lua: нужны blob, tls_mod,
-- tls_client_hello_mod, direction_check, payload_check, replay_first.

-- КОМУ СТАВИТЬ ИМЯ: ТОЛЬКО СЕТЯМ, ГДЕ БЛОК НАЙДЕН.
--
-- Без этого имя уходило всему пулу подряд: замер 30.08.2026 — linode, cdn77,
-- aws и scaleway доезжают целиком и без имени, то есть платили за лишний фейк
-- в каждом рукопожатии зря.
--
-- Огрубление до /16 (v4) и /32 (v6) намеренное: точных префиксов у этих AS
-- около 52 тысяч, а огрублённых — 6 тысяч. Цена — имя достанется соседям по
-- /16; замерено, что лишний фейк рабочим сайтам не мешает.
local z2k_nets, z2k_nets_loaded = nil, false
local function z2k_nets_load()
	if z2k_nets_loaded then return z2k_nets end
	z2k_nets_loaded = true
	local asnpath = os.getenv("Z2K_TCP16_ASN") or "/opt/zapret2/state/tcp16_asn.txt"
	local f = io.open(asnpath, "r")
	if not f then return nil end
	local want, n = {}, 0
	for line in f:lines() do
		local a = line:match("^(%d+)")
		if a then want[a] = true; n = n + 1 end
	end
	f:close()
	if n == 0 then return nil end

	local netpath = os.getenv("Z2K_TCP16_NETS") or "/opt/zapret2/lists/tcp16_nets.txt"
	local nf = io.open(netpath, "r")
	if not nf then return nil end
	local set, cnt = {}, 0
	for line in nf:lines() do
		local a, p = line:match("^(%d+)\t([^%s]+)")
		if a and p and want[a] then
			-- v4 «a.b.0.0/16» кладём ключом a*256+b, v6 «xxxx:yyyy::/32» —
			-- первыми двумя группами. Сравнение потом идёт по тому же ключу.
			local o1, o2 = p:match("^(%d+)%.(%d+)%.")
			if o1 then
				set[tonumber(o1) * 256 + tonumber(o2)] = a
				cnt = cnt + 1
			else
				local g1 = p:match("^(%x+)::")
				if g1 then
					set[string.lower(g1) .. ":0"] = a
					cnt = cnt + 1
				else
					local a1, a2 = p:match("^(%x+):(%x+):")
					if a1 then
						local n2 = a2:gsub("^0+", "")
						set[string.lower(a1) .. ":" .. string.lower(n2 ~= "" and n2 or "0")] = a
						cnt = cnt + 1
					end
				end
			end
		end
	end
	nf:close()
	if cnt == 0 then return nil end
	DLOG("z2k_tcp16: карта сетей загружена, " .. cnt .. " записей")
	z2k_nets = set
	return set
end

-- Какой AS принадлежит адрес назначения.
local function z2k_asn_of(desync)
	local set = z2k_nets_load()
	if not set then return nil end
	local d = desync and desync.dis
	if not d then return nil end
	if d.ip and d.ip.ip_dst then
		local b = d.ip.ip_dst
		if #b >= 2 then return set[b:byte(1) * 256 + b:byte(2)] end
	elseif d.ip6 and d.ip6.ip6_dst then
		local b = d.ip6.ip6_dst
		if #b >= 4 then
			local g1 = string.format("%x", b:byte(1) * 256 + b:byte(2))
			local g2 = string.format("%x", b:byte(3) * 256 + b:byte(4))
			return set[g1 .. ":" .. g2]
		end
	end
	return nil
end

-- КАЖДОЙ СЕТИ — СВОЁ ИМЯ.
--
-- Одного имени на всех не бывает. Замер 30.08.2026 на линии владельца:
-- hcaptcha.com бьёт двадцать AS, но НЕ Hetzner; Hetzner, DigitalOcean и OVH
-- берёт 300.ya.ru; Melbicom — ad.adriver.ru; семь AS не берёт ничто из списка.
local z2k_asn_sni, z2k_asn_sni_loaded = nil, false
local function z2k_asn_sni_load()
	if z2k_asn_sni_loaded then return z2k_asn_sni end
	z2k_asn_sni_loaded = true
	local path = os.getenv("Z2K_TCP16_SNI") or "/opt/zapret2/state/tcp16_sni.txt"
	local f = io.open(path, "r")
	if not f then return nil end
	local m, n = {}, 0
	for line in f:lines() do
		local a, nm = line:match("^(%d+)\t([%w%.%-]+)")
		if a and nm then m[a] = nm; n = n + 1 end
	end
	f:close()
	if n == 0 then return nil end
	DLOG("z2k_tcp16: карта имён по сетям загружена, " .. n .. " сетей")
	z2k_asn_sni = m
	return m
end

-- ЗАКРЕПЛЁННОЕ ИМЯ ЛИНИИ — ручной рычаг.
--
-- Один файл, одно имя. Годится, чтобы прижать линию к одному имени руками,
-- пока карта имён не собрана. Читаем не чаще раза в секунду: это путь КАЖДОГО
-- исходящего хелло, а один io.open в секунду на весь роутер не стоит ничего.
local z2k_pin_name, z2k_pin_at = nil, 0
local Z2K_PIN_RECHECK = tonumber(os.getenv("Z2K_PIN_RECHECK")) or 1
function z2k_sni_pinned()
	local now = os.time()
	if now < (z2k_pin_at + Z2K_PIN_RECHECK) then return z2k_pin_name end
	z2k_pin_at = now
	z2k_pin_name = nil
	local path = os.getenv("Z2K_SNI_PIN") or "/opt/zapret2/lists/sni_wl_pin.txt"
	local f = io.open(path, "r")
	if not f then return nil end
	local raw = f:read("*l")
	f:close()
	if not raw then return nil end
	local nm = raw:gsub("#.*", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if nm == "" or #nm > 253 or nm:find("[^%w%.%-]") then return nil end
	z2k_pin_name = nm
	return nm
end

-- Имя для этого адреса: своё для его AS; карты нет вовсе — закрепление.
-- AS известна, а имени для неё нет — значит проба его не нашла, и подставлять
-- чужое незачем. Адрес вне карты — сети с блоком его не покрывают, имя не нужно.
function z2k_sni_for(desync, pin)
	local m = z2k_asn_sni_load()
	if not m then return pin end
	local asn = z2k_asn_of(desync)
	if asn and m[asn] then return m[asn] end
	return nil
end

-- ПОДСТАНОВКА ИМЕНИ В ФЕЙКОВЫЙ ClientHello.
--
-- Сам не отправляет: готовит блоб и кладёт его в поле desync, а шлёт штатный
-- fake с флагом optional. Так мы не повторяем своими руками ttl, badsum,
-- tcp_ts и repeats — всё это остаётся в ведении движка, — а optional даёт
-- тихий пропуск, когда имени для этой сети нет.
--
-- Ставится ДО circular и БЕЗ strategy=N: инстанс без этого аргумента circular
-- не вызывает вовсе, его исполняет линейный оркестратор. Значит имя
-- подставляется на ЛЮБОМ плече, а разрез продолжает ротироваться штатно —
-- имя и разрез это разные оси.
function z2k_sni_pick(ctx, desync)
	direction_cutoff_opposite(ctx, desync)
	if not desync.dis or not desync.dis.tcp then return end
	if not (direction_check(desync) and payload_check(desync)) then return end
	if not replay_first(desync) then return end

	local name = z2k_sni_for(desync, z2k_sni_pinned())
	if not name then return end

	-- КЛОН НАСТОЯЩЕГО HELLO, а не чужое тело с подменённым именем (решение
	-- Марка 11.09.2026, как и во всех плечах): берём собранный ClientHello
	-- самого человека и меняем в нём только имя — у фейка тот же отпечаток,
	-- что у реального трафика этого устройства. Замер 10.09 на линии
	-- владельца: как фейк клон открыл то, что встроенный блоб не открыл.
	-- Если hello не разобрался — прежний путь: встроенный блоб + tls_mod.
	local ch
	local okc, cloned = pcall(tls_client_hello_mod, desync.reasm_data or desync.dis.payload,
		{ sni_del = true, sni_first = name, sni_snt_new = 0 })
	if okc and cloned then
		-- Та же декорация, что у штатных плеч: random случайный, session id
		-- настоящий. Клон без неё несёт random настоящего hello, и DPI видит
		-- два hello с одним random и разным именем (r-84, 11.09.2026).
		local okm, mod = pcall(tls_mod, cloned, "rnd,dupsid", desync.reasm_data or desync.dis.payload)
		ch = (okm and mod) or cloned
	else
		local base = blob(desync, desync.arg.src or "fake_default_tls")
		if not base then return end
		local mods = (desync.arg.mods or "rnd,dupsid") .. ",sni=" .. name
		local okm, mod = pcall(tls_mod, base, mods, desync.reasm_data)
		if not okm or not mod then return end
		ch = mod
	end
	desync[desync.arg.blob or "z2k_ch"] = ch
	if b_debug then
		DLOG("z2k_sni_pick: подставлено имя " .. name)
	end
end
