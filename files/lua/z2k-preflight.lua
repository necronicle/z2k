-- z2k-preflight.lua — проверка DPI отдельным соединением перед настоящим.
--
-- Класс блока (замеры 06–07.11.2026): часть зарубежных адресов googlevideo
-- режется ПО ОТВЕТУ СЕРВЕРА. Соединение
-- устанавливается, ClientHello уходит целиком, а ServerHello не приходит
-- никогда. Плечи здесь бессильны: расщеплять и подделывать нечего, DPI смотрит
-- не на запрос клиента. Но если по той же четвёрке адрес-порт одно соединение
-- уже прошло проверку, следующее DPI пропускает.
--
-- Поэтому проверку проходит движок, своим соединением, и отдаёт клиенту чистое:
--
-- Клиент  --SYN-->  [движок] --SYN(окно 1:1)-->  сервер
--                   [движок] <--SYN,ACK--        сервер    клиент его не видит
--                   [движок] --ACK, ClientHello кусками--> сервер
--                   [движок] <--первые байты ответа--      сервер
--                   [движок] --RST, исходный SYN-->        сервер
-- Клиент  <--SYN,ACK-------- [движок] <--SYN,ACK-- сервер  дальше без вмешательства
--
-- Окно 1:1 нужно, чтобы ответ сервера приходил маленькими кусками: ждать
-- приходится только начало ответа, а не весь ServerHello с сертификатом.
-- Клиент пробного соединения не видит, он просто получает SYN,ACK на 1-2 секунды позже.
--
-- ТОЛЬКО IPv4 И ТОЛЬКО TCP: пробное соединение ставит движок, а повторный
-- исходный SYN выходит с меткой движка и получает NAT отдельным правилом
-- (S99zapret2, z2k_udp_masquerade_fix_start). Для IPv6 правила нет, для QUIC
-- приём неприменим вовсе — ни окна, ни RST с повторным SYN там нет.
--
-- Стоит в профиле googlevideo ПЕРЕД ротатором. На SYN профиль выбирается по
-- имени из --ipcache-hostname, поэтому самое первое соединение с новым адресом
-- сюда на SYN не попадает и идёт обычным плечом. Пока идёт проба, инстансы
-- дальше по профилю отменяются (execution_plan_cancel): плечам нечего делать с
-- пакетами пробы. После передачи клиенту соединение идёт через плечи как
-- обычно — там, где шаг не помог, они остаются запасным путём.
--
-- Состояние лежит в общей таблице, а не в track.lua_state: повторный SYN
-- сбрасывает запись conntrack движка вместе с lua_state.
--
-- arg: pieces - сколько кусков ответа сервера дождаться (по умолчанию 2)
-- arg: open - после скольких кусков расширить окно, чтобы ответ пришёл быстрее
-- arg: openwin - окно после расширения (по умолчанию 65535)
-- arg: wsize, scale - окно пробного соединения (по умолчанию 1 и 1)
-- arg: pos - разрез пробного ClientHello (по умолчанию 1,midsld)
-- arg: blob - пробный ClientHello (по умолчанию fake_default_tls)
-- arg: sni - имя в пробном ClientHello
-- arg: keepts - оставить опции клиента и вести timestamp
-- arg: timeout - через сколько секунд сдаться на повторе SYN клиента (по умолчанию 3)

z2k_pf_flows = z2k_pf_flows or {}
local flows = z2k_pf_flows

local function ip_text(raw)
	return string.format("%d.%d.%d.%d", string.byte(raw, 1, 4))
end

local function log(st, text)
	DLOG("z2k_preflight: "..st.ip..":"..st.port.." "..st.stage.." "..text)
end

local function sweep(now)
	for k, st in pairs(flows) do
		if now - st.t > 60 then flows[k] = nil end
	end
end

local function flow_key(dis, outgoing)
	local tcp = dis.tcp
	if outgoing then
		return dis.ip.ip_src..dis.ip.ip_dst..tcp.th_sport..":"..tcp.th_dport
	end
	return dis.ip.ip_dst..dis.ip.ip_src..tcp.th_dport..":"..tcp.th_sport
end

-- Пробный SYN: своё окно и только MSS с масштабом, без timestamp.
-- Иначе каждому нашему пакету пришлось бы вести timestamp сервера.
local function make_probe_syn(dis, arg)
	local wsize = tonumber(arg.wsize) or 1
	local scale = tonumber(arg.scale) or 1
	if arg.keepts then
		-- Все опции как у клиента: меняются только окно и масштаб.
		local i = find_tcp_option(dis.tcp.options, TCP_KIND_SCALE)
		if i then dis.tcp.options[i].data = bu8(scale) end
		dis.tcp.th_win = wsize
		return
	end
	local options = {}
	for _, opt in ipairs(dis.tcp.options) do
		if opt.kind == TCP_KIND_MSS then
			options[#options + 1] = opt
		elseif opt.kind == TCP_KIND_SCALE then
			options[#options + 1] = {kind = TCP_KIND_SCALE, data = bu8(scale)}
		end
	end
	dis.tcp.options = options
	dis.tcp.th_win = wsize
end

local function make_packet(st, flags, seq, ack, payload)
	local dis = deepcopy(st.orig)
	dis.tcp.th_flags = flags
	dis.tcp.th_seq = seq
	dis.tcp.th_ack = ack
	dis.tcp.th_win = st.wsize
	st.ip_id = bitand(st.ip_id + 1, 0xFFFF)
	dis.ip.ip_id = st.ip_id
	dis.tcp.options = {}
	if st.ts_val then
		dis.tcp.options = {
			{kind = TCP_KIND_NOOP}, {kind = TCP_KIND_NOOP},
			{kind = TCP_KIND_TS, data = bu32(st.ts_val)..bu32(st.ts_ecr)},
		}
	end
	dis.payload = payload or ""
	return dis
end

local function send(st, dis)
	local ok = rawsend_dissect(dis, {ifout = st.ifout, fwmark = st.fwmark})
	if not ok then log(st, "rawsend failed") end
	return ok
end

local function send_probe_hello(st)
	local data = st.hello
	local pos = resolve_multi_pos(data, "tls_client_hello", st.pos)
	delete_pos_1(pos)
	pos[#pos + 1] = #data + 1
	local base = u32add(st.isn, 1)
	local parts = {}
	local from = 1
	for _, p in ipairs(pos) do
		parts[#parts + 1] = {from = from, to = p - 1}
		from = p
	end
	for i = #parts, 1, -1 do
		local part = parts[i]
		send(st, make_packet(st, TH_PUSH + TH_ACK, u32add(base, part.from - 1), st.srv_next,
			string.sub(data, part.from, part.to)))
	end
	st.cli_next = u32add(base, #data)
	log(st, "sent hello "..#data.." bytes in "..#parts.." parts")
end

local function teardown(st)
	send(st, make_packet(st, TH_RST, st.cli_next, 0))
	send(st, st.orig)
	st.stage = "resyn"
	log(st, "reset after "..st.pieces.." pieces, "..st.bytes.." bytes, original SYN sent")
end

local function step(ctx, desync)
	local dis = desync.dis
	local tcp = dis.tcp
	local now = os.time()
	local key = flow_key(dis, desync.outgoing)
	local st = flows[key]
	local syn = bitand(tcp.th_flags, TH_SYN) ~= 0
	local ack = bitand(tcp.th_flags, TH_ACK) ~= 0
	local rst = bitand(tcp.th_flags, TH_RST) ~= 0

	if desync.outgoing then
		if syn and not ack then
			if not st or st.stage == "done" or st.isn ~= tcp.th_seq then
				sweep(now)
				local hello = blob(desync, desync.arg.blob or "fake_default_tls")
				if desync.arg.sni then
					hello = tls_mod(hello, "rnd,sni="..desync.arg.sni)
				else
					hello = tls_mod(hello, "rnd")
				end
				st = {
					stage = "probe_syn", t = now, isn = tcp.th_seq, orig = deepcopy(dis),
					ip = ip_text(dis.ip.ip_dst), port = tcp.th_sport,
					ifout = desync.ifout, fwmark = desync.fwmark, hello = hello,
					wsize = tonumber(desync.arg.wsize) or 1,
					pieces_need = tonumber(desync.arg.pieces) or 2,
					pos = desync.arg.pos or "1,midsld",
					timeout = tonumber(desync.arg.timeout) or 3,
					open = tonumber(desync.arg.open),
					openwin = tonumber(desync.arg.openwin) or 65535,
					pieces = 0, bytes = 0, ip_id = dis.ip.ip_id, resets = 0,
				}
				flows[key] = st
				make_probe_syn(dis, desync.arg)
				log(st, "probe SYN")
				return VERDICT_MODIFY
			end
			if now - st.t >= st.timeout then
				log(st, "timeout, giving up")
				-- Сервер не должен держать пробное соединение с тем же портом.
				if st.cli_next then send(st, make_packet(st, TH_RST, st.cli_next, 0)) end
				st.stage = "done"
				st.gave_up = true
				return VERDICT_PASS
			end
			-- Пока идёт передача, повтор SYN клиента ничем не отличается от нашего.
			if st.stage == "resyn" then return VERDICT_PASS end
			-- Пробный SYN потерян: повтор клиента становится новым пробным SYN.
			if st.stage == "probe_syn" then
				make_probe_syn(dis, desync.arg)
				log(st, "probe SYN retransmit")
				return VERDICT_MODIFY
			end
			log(st, "client SYN retransmit dropped")
			return VERDICT_DROP
		end
		if st and st.stage ~= "done" then
			log(st, "client packet before handover dropped")
			return VERDICT_DROP
		end
		return
	end

	if not st or st.stage == "done" then return end

	if st.stage == "resyn" then
		if syn and ack and tcp.th_ack == u32add(st.isn, 1) then
			st.stage = "done"
			log(st, "handover to client")
			return VERDICT_PASS
		end
		-- Сервер ещё помнит пробное соединение и отвечает ACK на новый SYN.
		if not syn and ack and not rst and st.resets < 5 then
			st.resets = st.resets + 1
			send(st, make_packet(st, TH_RST, tcp.th_ack, 0))
			send(st, st.orig)
			log(st, "stale ack, reset "..st.resets)
		end
		return VERDICT_DROP
	end

	if rst then
		log(st, "server RST during probe")
		st.stage = "resyn"
		send(st, st.orig)
		return VERDICT_DROP
	end

	if st.stage == "probe_syn" then
		if syn and ack then
			st.srv_next = u32add(tcp.th_seq, 1)
			if desync.arg.keepts then
				local c = find_tcp_option(st.orig.tcp.options, TCP_KIND_TS)
				local s = find_tcp_option(tcp.options, TCP_KIND_TS)
				if c and s then
					st.ts_val = u32add(u32(string.sub(st.orig.tcp.options[c].data, 1, 4)), 1)
					st.ts_ecr = u32(string.sub(tcp.options[s].data, 1, 4))
				end
			end
			send(st, make_packet(st, TH_ACK, u32add(st.isn, 1), st.srv_next))
			send_probe_hello(st)
			st.stage = "probe_data"
		end
		return VERDICT_DROP
	end

	if st.stage == "probe_data" then
		local len = #dis.payload
		if len > 0 then
			local edge = u32add(tcp.th_seq, len)
			if seq_ge(edge, st.srv_next) then st.srv_next = edge end
			st.pieces = st.pieces + 1
			st.bytes = st.bytes + len
			log(st, "server piece "..len.." bytes")
			if st.ts_val then
				local s = find_tcp_option(tcp.options, TCP_KIND_TS)
				if s then st.ts_ecr = u32(string.sub(tcp.options[s].data, 1, 4)) end
			end
			if st.pieces >= st.pieces_need then
				teardown(st)
			else
				if st.open and st.pieces >= st.open then st.wsize = st.openwin end
				send(st, make_packet(st, TH_ACK, st.cli_next, st.srv_next))
			end
		end
		return VERDICT_DROP
	end
end

function z2k_preflight(ctx, desync)
	local dis = desync.dis
	-- Не IPv4 TCP: повторный SYN уйдёт без NAT, поэтому не вмешиваемся вовсе.
	if not dis.tcp or not dis.ip then
		instance_cutoff_shim(ctx, desync)
		return
	end
	local st = flows[flow_key(dis, desync.outgoing)]
	local syn_only = bitand(dis.tcp.th_flags, TH_SYN) ~= 0 and bitand(dis.tcp.th_flags, TH_ACK) == 0
	-- Профиль получил управление не с начала: имя стало известно только сейчас,
	-- SYN прошёл мимо нас, и начинать пробу посреди соединения нечем.
	if not st and not (syn_only and desync.outgoing) then
		instance_cutoff_shim(ctx, desync)
		return
	end
	local verdict = step(ctx, desync)
	st = flows[flow_key(dis, desync.outgoing)]
	-- Пока идёт проба, плечи не трогают её пакеты. После передачи настоящее соединение
	-- идёт через плечи как обычно: там, где шаг не помог, они остаются запасным путём.
	if st and not st.gave_up and st.stage ~= "done" then execution_plan_cancel(ctx) end
	return verdict
end
