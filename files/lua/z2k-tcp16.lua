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
-- сетей → имя по карте имён → компактный фейк с проверкой размера пакета.
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
-- direction_check, payload_check, replay_first и функции подготовки/отправки.

-- КОМУ СТАВИТЬ ИМЯ: ТОЛЬКО СЕТЯМ, ГДЕ БЛОК НАЙДЕН.
--
-- Без этого имя уходило всему пулу подряд: замер 30.08.2026 — linode, cdn77,
-- aws и scaleway доезжают целиком и без имени, то есть платили за лишний фейк
-- в каждом рукопожатии зря.
--
-- Огрубление до /16 (v4) и /32 (v6) намеренное: точных префиксов у этих AS
-- около 52 тысяч, а огрублённых — 6 тысяч. Цена — имя достанется соседям по
-- /16; замерено, что лишний фейк рабочим сайтам не мешает.
-- КАРТЫ ПЕРЕЧИТЫВАЮТСЯ, А НЕ ГРУЗЯТСЯ РАЗ НА ВЕСЬ ПРОЦЕСС.
--
-- Проба обновляет список сетей и карту имён каждую ночь, но службу
-- перезапускает только когда механизм появляется в конфиге или уходит из
-- него. Рантайм же читал карты однажды — и ночная замена протухшего имени не
-- действовала до случайного перезапуска (ревью 25.10.2026). Теперь проба
-- после каждой подмены пишет в state/tcp16.ver отметку времени, а здесь не
-- чаще раза в Z2K_TCP16_RECHECK секунд читается одна её строка: сменилась —
-- карты перечитываются. На горячем пути это сравнение двух чисел.
local Z2K_TCP16_RECHECK = tonumber(os.getenv("Z2K_TCP16_RECHECK")) or 10
local z2k_ver_seen, z2k_ver_at = nil, nil
local z2k_nets, z2k_nets_loaded = nil, false
local z2k_asn_sni, z2k_asn_sni_loaded = nil, false

local function z2k_maps_refresh()
	local now = os.time()
	if z2k_ver_at and now < z2k_ver_at + Z2K_TCP16_RECHECK then return end
	z2k_ver_at = now
	local path = os.getenv("Z2K_TCP16_VER") or "/opt/zapret2/state/tcp16.ver"
	local f = io.open(path, "r")
	local v = f and f:read("*l") or ""
	if f then f:close() end
	if v ~= z2k_ver_seen then
		if z2k_ver_seen ~= nil then
			DLOG("z2k_tcp16: карты обновлены пробой — перечитываю")
		end
		z2k_ver_seen = v
		z2k_nets, z2k_nets_loaded = nil, false
		z2k_asn_sni, z2k_asn_sni_loaded = nil, false
	end
end

-- КЛЮЧИ ОТДЕЛЬНО ДЛЯ v4 И v6, И ОБА ЧИСЛОВЫЕ.
--
-- Прежде v6-префикс «2620::/32» клался ключом «2620:» (вторая группа пустая),
-- а поиск строил «2620:0» и не находил его — выручал запасной ключ «g1:»,
-- который накрывал ВЕСЬ /16: адрес Microsoft 2620:1ec:: получал имя Fastly из
-- соседней /32 (ревью 25.10.2026). Числовой ключ из двух первых групп снимает
-- и промах, и запасной ключ. Разные таблицы — чтобы ключи v4 и v6 не могли
-- совпасть в принципе.
local function v6key(g1, g2) return g1 * 65536 + g2 end

-- Первые две группы IPv6-префикса «a:b::/n», «a::/n», «a:b:c::/n».
local function v6groups(p)
	local addr = p:match("^([^/]+)") or p
	local head = addr:match("^(.-)::") or addr
	local g1s, g2s = head:match("^(%x+):(%x*)")
	if not g1s then g1s = head:match("^(%x+)$") end
	if not g1s then return nil end
	return tonumber(g1s, 16), tonumber(g2s or "", 16) or 0
end

local function z2k_nets_load()
	z2k_maps_refresh()
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
	-- ОДНА СЕТЬ — НЕСКОЛЬКО AS. Огрубление до /16 склеивает соседей: 2066
	-- подсетей общие у двух и более AS, и прежняя запись «последняя по файлу
	-- выигрывает» отдавала адрес соседу вместе с его именем. Теперь при
	-- совпадении ключа храним список, а выбирает его тот, кто ищет имя.
	local set4, set6, cnt = {}, {}, 0
	local function put(set, k, a)
		local cur = set[k]
		if cur == nil then set[k] = a; cnt = cnt + 1; return end
		if type(cur) == "string" then
			if cur ~= a then set[k] = { cur, a } end
			return
		end
		for _, x in ipairs(cur) do if x == a then return end end
		cur[#cur + 1] = a
	end
	for line in nf:lines() do
		local a, p = line:match("^(%d+)\t([^%s]+)")
		if a and p and want[a] then
			local o1, o2 = p:match("^(%d+)%.(%d+)%.")
			if o1 then
				put(set4, tonumber(o1) * 256 + tonumber(o2), a)
			else
				local g1, g2 = v6groups(p)
				if g1 then put(set6, v6key(g1, g2), a) end
			end
		end
	end
	nf:close()
	if cnt == 0 then return nil end
	DLOG("z2k_tcp16: карта сетей загружена, " .. cnt .. " записей")
	z2k_nets = { v4 = set4, v6 = set6 }
	return z2k_nets
end

-- Какой AS принадлежит адрес назначения: имя AS, список имён (когда /16
-- общая) либо nil.
local function z2k_asn_of(desync)
	local set = z2k_nets_load()
	if not set then return nil end
	local d = desync and desync.dis
	if not d then return nil end
	if d.ip and d.ip.ip_dst then
		local b = d.ip.ip_dst
		if #b >= 2 then return set.v4[b:byte(1) * 256 + b:byte(2)] end
	elseif d.ip6 and d.ip6.ip6_dst then
		local b = d.ip6.ip6_dst
		if #b >= 4 then
			return set.v6[v6key(b:byte(1) * 256 + b:byte(2), b:byte(3) * 256 + b:byte(4))]
		end
	end
	return nil
end

-- КАЖДОЙ СЕТИ — СВОЁ ИМЯ.
--
-- Одного имени на всех не бывает. Замер 30.08.2026 на линии владельца:
-- hcaptcha.com бьёт двадцать AS, но НЕ Hetzner; Hetzner, DigitalOcean и OVH
-- берёт 300.ya.ru; Melbicom — ad.adriver.ru; семь AS не берёт ничто из списка.
local function z2k_asn_sni_load()
	z2k_maps_refresh()
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
	if asn == nil then return nil end
	if type(asn) == "string" then return m[asn] end
	-- Общая /16 у нескольких AS: берём имя первой, для которой оно известно.
	-- Порядок — как в карте сетей; имя соседа лучше, чем ничего, но имя
	-- «своей» AS встретится раньше, если она в карте есть.
	for _, a in ipairs(asn) do
		if m[a] then return m[a] end
	end
	return nil
end

-- Совместимость со старым сгенерированным конфигом: следующий optional fake
-- не должен получать клон. Функция намеренно не меняет штатные плечи пула.
-- Наличие имени в карте ещё не подтверждает работоспособность обхода.
function z2k_sni_pick(ctx, desync)
    desync[desync.arg.blob or "z2k_ch"] = nil
end

-- Фейк независим от размера настоящего ClientHello. reasm_data используется
-- tls_mod только для dupsid, а не как тело фейка. После всех модификаций
-- проверяем тот же бюджет MSS, который использует штатный отправитель.
local function send_compact_sni(ctx, desync)
    direction_cutoff_opposite(ctx, desync)
    if not desync.dis or not desync.dis.tcp then return end
    if not (direction_check(desync) and payload_check(desync) and replay_first(desync)) then return end
    -- Timestamp может отсутствовать у клиента. Без независимой защиты
    -- чужой ClientHello отправлять нельзя.
    if not desync.arg.tcp_md5 then return end
    local mss = tonumber(desync.tcp_mss)
    if not mss or not (mss > 0) then return end
    local name = z2k_sni_for(desync, z2k_sni_pinned())
    if not name then return end
    local base = blob(desync, "fake_default_tls")
    if not base then return end
    local payload = tls_mod(base, "rnd,dupsid,sni=" .. name,
                            desync.reasm_data or desync.dis.payload)
    -- Не отправляем исходный шаблон при ошибке подмены имени.
    if type(payload) ~= "string" or #payload == 0 then return end
    local dis = deepcopy(desync.dis)
    dis.payload = payload
    local options = desync_opts(desync)
    apply_fooling(desync, dis, options.fooling)
    if #dis.payload > mss - l3l4_extra_len(dis) then return end
    apply_ip_id(desync, dis, options.ipid, "none")
    -- Намеренно без сегментации и фрагментации. repeats повторяет этот
    -- целый пакет. Возврат отправки не является вердиктом для настоящего.
    rawsend_dissect(dis, options.rawsend, options.reconstruct)
end

function z2k_sni_fake(ctx, desync)
    local ok, err = pcall(send_compact_sni, ctx, desync)
    if not ok and b_debug then DLOG("z2k_sni_fake: skipped: " .. tostring(err)) end
end
