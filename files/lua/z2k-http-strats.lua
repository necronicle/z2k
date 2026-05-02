-- z2k-http-strats.lua
-- HTTP-bypass strategy primitives, ported from
-- github.com/ALFiX01/GoodbyeZapret/blob/main/Project/bin/lua/custom_funcs.lua
--
-- 33 функции с z2k_http_-префиксом — расширяет небольшой http_rkn arm
-- (был 7 стратегий) арсеналом разнообразных HTTP-обходов: methodeol-варианты,
-- header injection, host case modification, pipeline fake, seqovl host
-- attacks, MGTS-специфика, version downgrade, byte-split в Host value,
-- IP fragmentation, syndata, aggressive multi-disorder и super-decoy.
--
-- Field-driven: реальная HTTP-жалоба от пользователя — base http_rkn не
-- пробивает на его ISP. AutoCircular ротирует через все варианты пока
-- какой-то не сработает.
--
-- Зависимости (load order через --lua-init):
--   zapret-lib.lua, zapret-antidpi.lua, zapret-auto.lua — provide
--   apply_fooling / rawsend_dissect / rawsend_payload_segmented /
--   replay_first / replay_drop / direction_check / payload_check /
--   instance_cutoff_shim / http_dissect_req / array_field_search.
-- Этот файл подключается в S99zapret2.new ПОСЛЕ z2k-modern-core.lua.
--
-- Globals (z2k_http_*) перечислены в .luacheckrc для luacheck-режима.

-- AGGRESSIVE HTTP BYPASS for stubborn DPI (like porno365)
-- Combines multiple techniques: fake flood + disorder + host splitting
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- arg : fakes=N - number of fake packets to send (default 5)
-- arg : ttl_start=N - starting TTL for fakes (default 1)
-- arg : ttl_step=N - TTL increment for each fake (default 1)
-- arg : split_host - additionally split inside hostname
-- arg : disorder - send parts in reverse order
function z2k_http_aggressive(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)
	
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			-- Parse HTTP request
			local hdis = http_dissect_req(data)
			if not hdis or not hdis.headers.host then
				DLOG("http_aggressive: cannot parse HTTP request or no Host header")
				return
			end
			
			local host_pos = hdis.headers.host
			-- pos_end points to end of line (before \r\n), pos_value_start to start of value
			local host_value = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)
			
			DLOG("http_aggressive: detected Host: "..host_value)
			
			-- Options for fake packets (will die before reaching server)
			local opts_fake = {
				rawsend = rawsend_opts(desync), 
				reconstruct = reconstruct_opts(desync), 
				ipfrag = {}, 
				ipid = desync.arg, 
				fooling = desync.arg
			}
			
			-- Options for real packets (no fooling except tcp_ts_up)
			local opts_orig = {
				rawsend = rawsend_opts_base(desync), 
				reconstruct = {}, 
				ipfrag = {}, 
				ipid = desync.arg, 
				fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
			}
			
			local num_fakes = tonumber(desync.arg.fakes) or 5
			local ttl_start = tonumber(desync.arg.ttl_start) or 1
			local ttl_step = tonumber(desync.arg.ttl_step) or 1
			
			-- Generate fake HTTP request with different host
			local fake_host = "www.google.com"
			local fake_data = string.sub(data, 1, host_pos.pos_value_start-1) .. 
							  fake_host .. 
							  string.sub(data, host_pos.pos_end+1)
			
			-- STEP 1: Send multiple fake packets with low TTL (will die before DPI or server)
			for i=1,num_fakes do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data
				
				-- Set low TTL so packet dies before reaching server
				local ttl = ttl_start + (i-1) * ttl_step
				if fake_dis.ip then
					fake_dis.ip.ip_ttl = ttl
				end
				if fake_dis.ip6 then
					fake_dis.ip6.ip6_hlim = ttl
				end
				
				-- Add badseq to confuse DPI further
				if fake_dis.tcp then
					fake_dis.tcp.th_ack = fake_dis.tcp.th_ack - 66000
				end
				
				if b_debug then DLOG("http_aggressive: sending fake #"..i.." TTL="..ttl) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end
			
			-- STEP 2: Split real request into parts
			-- Split points: before "Host:", middle of host, after host value
			local split_positions = {}
			
			-- Always split before "Host:" header
			table.insert(split_positions, host_pos.pos_start)
			
			-- Optionally split in the middle of hostname
			if desync.arg.split_host then
				local host_mid = host_pos.pos_value_start + math.floor(#host_value / 2)
				if host_mid > host_pos.pos_value_start and host_mid < host_pos.pos_end then
					table.insert(split_positions, host_mid)
				end
			end
			
			-- Split after Host header value
			table.insert(split_positions, host_pos.pos_end + 1)
			
			-- Sort positions
			table.sort(split_positions)
			
			-- Create parts
			local parts = {}
			local prev_pos = 1
			for i, pos in ipairs(split_positions) do
				if pos > prev_pos and pos <= #data then
					table.insert(parts, {
						data = string.sub(data, prev_pos, pos-1),
						offset = prev_pos - 1
					})
					prev_pos = pos
				end
			end
			-- Add remaining part
			if prev_pos <= #data then
				table.insert(parts, {
					data = string.sub(data, prev_pos),
					offset = prev_pos - 1
				})
			end
			
			if b_debug then 
				DLOG("http_aggressive: split into "..#parts.." parts")
				for i, p in ipairs(parts) do
					DLOG("http_aggressive: part "..i.." offset="..p.offset.." len="..#p.data)
				end
			end
			
			-- STEP 3: Send parts (optionally in disorder)
			if desync.arg.disorder and #parts > 1 then
				-- Send in reverse order (disorder)
				for i=#parts,1,-1 do
					if b_debug then DLOG("http_aggressive: sending part "..i.." (disorder)") end
					if not rawsend_payload_segmented(desync, parts[i].data, parts[i].offset, opts_orig) then
						return VERDICT_PASS
					end
				end
			else
				-- Send in normal order
				for i=1,#parts do
					if b_debug then DLOG("http_aggressive: sending part "..i) end
					if not rawsend_payload_segmented(desync, parts[i].data, parts[i].offset, opts_orig) then
						return VERDICT_PASS
					end
				end
			end
			
			-- STEP 4: Send more fakes after real data (sandwich technique)
			for i=1,math.floor(num_fakes/2) do
				local fake_dis = deepcopy(desync.dis)
				fake_dis.payload = fake_data
				if fake_dis.ip then
					fake_dis.ip.ip_ttl = ttl_start
				end
				if fake_dis.ip6 then
					fake_dis.ip6.ip6_hlim = ttl_start
				end
				if fake_dis.tcp then
					fake_dis.tcp.th_ack = fake_dis.tcp.th_ack - 66000
				end
				if b_debug then DLOG("http_aggressive: sending trailing fake #"..i) end
				rawsend_dissect(fake_dis, opts_fake.rawsend)
			end
			
			replay_drop_set(desync)
			return VERDICT_DROP
		else
			DLOG("http_aggressive: not acting on further replay pieces")
		end
		
		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end

-- HTTP SYNDATA - Send HTTP request in SYN packet (most aggressive)
-- This bypasses DPI that only inspects data after handshake
-- standard args : fooling, rawsend, reconstruct, ipfrag
-- arg : blob=<blob> - HTTP request template (optional, will use current payload if available)
function z2k_http_syndata(ctx, desync)
	if desync.dis.tcp then
		if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK)==TH_SYN then
			local dis = deepcopy(desync.dis)
			
			-- Try to get HTTP request from conntrack or use template
			local http_req = desync.arg.blob and blob(desync, desync.arg.blob) or 
				"GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
			
			dis.payload = http_req
			apply_fooling(desync, dis)
			
			if b_debug then DLOG("http_syndata: sending SYN with HTTP payload len="..#http_req) end
			if rawsend_dissect_ipfrag(dis, desync_opts(desync)) then
				return VERDICT_DROP
			end
		else
			instance_cutoff(ctx)
		end
	else
		instance_cutoff(ctx)
	end
end

-- HTTP with multiple disorder splits at critical positions
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
-- Splits at: method, path, host header name, host value (multiple cuts)
function z2k_http_multidisorder(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)
	
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			-- Generate split positions for HTTP
			local positions = {}
			
			-- Split at position 1 (after first byte)
			table.insert(positions, 2)
			
			-- Find key positions in HTTP request
			local method_end = string.find(data, " ")
			if method_end then
				table.insert(positions, method_end)
				table.insert(positions, method_end + 1)
			end
			
			-- Find Host: header
			local host_start = string.find(data, "\r\nHost: ", 1, true)
			if host_start then
				table.insert(positions, host_start + 2) -- before "Host:"
				table.insert(positions, host_start + 8) -- after "Host: "
				
				-- Find end of host value
				local host_end = string.find(data, "\r\n", host_start + 8, true)
				if host_end then
					-- Split in middle of host value
					local mid = host_start + 8 + math.floor((host_end - host_start - 8) / 2)
					table.insert(positions, mid)
					table.insert(positions, host_end)
				end
			end
			
			-- Remove duplicates and sort
			local unique_pos = {}
			local seen = {}
			for _, p in ipairs(positions) do
				if p > 1 and p <= #data and not seen[p] then
					table.insert(unique_pos, p)
					seen[p] = true
				end
			end
			table.sort(unique_pos)
			
			if b_debug then DLOG("http_multidisorder: split positions: "..table.concat(unique_pos, ",")) end
			
			local opts_orig = {
				rawsend = rawsend_opts_base(desync), 
				reconstruct = {}, 
				ipfrag = {}, 
				ipid = desync.arg, 
				fooling = {tcp_ts_up = desync.arg.tcp_ts_up}
			}
			
			-- Create and send parts in reverse order
			local parts = {}
			local prev = 1
			for _, pos in ipairs(unique_pos) do
				if pos > prev then
					table.insert(parts, {string.sub(data, prev, pos-1), prev-1})
					prev = pos
				end
			end
			if prev <= #data then
				table.insert(parts, {string.sub(data, prev), prev-1})
			end
			
			-- Send in reverse order (disorder)
			for i=#parts,1,-1 do
				if b_debug then DLOG("http_multidisorder: sending part "..i.." offset="..parts[i][2].." len="..#parts[i][1]) end
				if not rawsend_payload_segmented(desync, parts[i][1], parts[i][2], opts_orig) then
					return VERDICT_PASS
				end
			end
			
			replay_drop_set(desync)
			return VERDICT_DROP
		else
			DLOG("http_multidisorder: not acting on further replay pieces")
		end
		
		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end

-- Улучшенный methodeol - добавляет больше мусора в начало
function z2k_http_methodeol_v2(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    if desync.l7payload=="http_req" and direction_check(desync) then
        local hdis = http_dissect_req(desync.dis.payload)
        local ua = hdis.headers["user-agent"]
        if ua then
            -- Добавляем несколько пустых строк и пробелы
            local garbage = "\r\n \r\n\t\r\n"
            desync.dis.payload = garbage .. string.sub(desync.dis.payload,1,ua.pos_end-2) .. (string.sub(desync.dis.payload,ua.pos_end+1) or "")
            DLOG("http_methodeol_v2: applied with extra garbage")
            return VERDICT_MODIFY
        end
    end
end

-- Methodeol + изменение регистра Host
function z2k_http_methodeol_hostcase(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    if desync.l7payload=="http_req" and direction_check(desync) then
        local payload = desync.dis.payload
        
        -- Меняем Host: на HoSt:
        payload = string.gsub(payload, "\r\nHost:", "\r\nHoSt:")
        
        -- Добавляем мусор в начало
        payload = "\r\n" .. payload
        
        desync.dis.payload = payload
        DLOG("http_methodeol_hostcase: applied")
        return VERDICT_MODIFY
    end
end

-- MGTS HTTP BYPASS STRATEGIES - специально для обхода умного DPI МГТС
-- ============================================================================

-- HTTP seqovl Host Override
-- Отправляем фейковый Host с seqovl, потом реальный который "перезаписывает"
-- DPI видит первый (фейковый), сервер принимает второй (реальный) по TCP reassembly
-- standard args : direction, payload, rawsend, reconstruct
-- arg : fake_host=<str> - фейковый хост (default google.com)
-- arg : seqovl=N - размер перекрытия (default = длина Host value)
function z2k_http_seqovl_host(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)
	
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			local hdis = http_dissect_req(data)
			if not hdis or not hdis.headers.host then
				DLOG("http_seqovl_host: no Host header found")
				return
			end
			
			local host_pos = hdis.headers.host
			local real_host = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)
			local fake_host = desync.arg.fake_host or "google.com"
			
			DLOG("http_seqovl_host: real_host='"..real_host.."' fake_host='"..fake_host.."'")
			
			-- Создаём фейковый HTTP запрос с fake_host
			-- Нужно чтобы fake_host был той же длины что и real_host для точного seqovl
			if #fake_host < #real_host then
				fake_host = fake_host .. string.rep("x", #real_host - #fake_host)
			elseif #fake_host > #real_host then
				fake_host = string.sub(fake_host, 1, #real_host)
			end
			
			local fake_data = string.sub(data, 1, host_pos.pos_value_start-1) .. 
							  fake_host .. 
							  string.sub(data, host_pos.pos_end+1)
			
			local opts_orig = {
				rawsend = rawsend_opts_base(desync), 
				reconstruct = {}, 
				ipfrag = {}, 
				fooling = {}
			}
			
			-- Позиция начала Host value
			local host_value_pos = host_pos.pos_value_start - 1  -- 0-based
			
			-- STEP 1: Отправляем часть ДО Host value
			local before_host = string.sub(data, 1, host_pos.pos_value_start-1)
			if b_debug then DLOG("http_seqovl_host: sending before_host len="..#before_host) end
			if not rawsend_payload_segmented(desync, before_host, 0, opts_orig) then
				return VERDICT_PASS
			end
			
			-- STEP 2: Отправляем ФЕЙКОВЫЙ Host value (DPI увидит это первым)
			if b_debug then DLOG("http_seqovl_host: sending FAKE host '"..fake_host.."'") end
			if not rawsend_payload_segmented(desync, fake_host, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end
			
			-- STEP 3: Отправляем РЕАЛЬНЫЙ Host value с тем же offset (seqovl!)
			-- TCP стек сервера должен принять этот пакет и перезаписать фейковый
			if b_debug then DLOG("http_seqovl_host: sending REAL host '"..real_host.."' (seqovl)") end
			if not rawsend_payload_segmented(desync, real_host, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end
			
			-- STEP 4: Отправляем остаток ПОСЛЕ Host value
			local after_host = string.sub(data, host_pos.pos_end+1)
			if b_debug then DLOG("http_seqovl_host: sending after_host len="..#after_host) end
			if not rawsend_payload_segmented(desync, after_host, host_pos.pos_end, opts_orig) then
				return VERDICT_PASS
			end
			
			replay_drop_set(desync)
			return VERDICT_DROP
		else
			DLOG("http_seqovl_host: not acting on further replay pieces")
		end
		
		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end

-- HTTP with IP fragmentation
-- Разбивает IP пакет на фрагменты - DPI может не уметь их собирать
-- standard args : direction, payload, rawsend
-- arg : frag_size=N - размер первого фрагмента (default 24 - разрежет внутри Host)
function z2k_http_ipfrag(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)
	
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			local frag_size = tonumber(desync.arg.frag_size) or 24
			
			DLOG("http_ipfrag: fragmenting at IP level, frag_size="..frag_size)
			
			-- Используем встроенную IP фрагментацию
			local opts = {
				rawsend = rawsend_opts(desync),
				reconstruct = {},
				ipfrag = {
					ipfrag_pos_tcp = frag_size
				}
			}
			
			if rawsend_dissect_ipfrag(desync.dis, opts) then
				replay_drop_set(desync)
				return VERDICT_DROP
			end
		else
			DLOG("http_ipfrag: not acting on further replay pieces")
		end
		
		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end

-- HTTP Host case modification
-- Меняет регистр "Host:" header - некоторые DPI чувствительны к регистру
-- standard args : direction, payload
-- arg : case=<str> - "lower", "upper", "mixed", "space" (default mixed)
function z2k_http_hostmod(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)
	
	if desync.l7payload=="http_req" and direction_check(desync) then
		local case_type = desync.arg.case or "mixed"
		local new_host_header
		
		if case_type == "lower" then
			new_host_header = "host"
		elseif case_type == "upper" then
			new_host_header = "HOST"
		elseif case_type == "mixed" then
			new_host_header = "HoSt"
		elseif case_type == "space" then
			new_host_header = "Host "  -- пробел после
		elseif case_type == "tab" then
			new_host_header = "Host\t"  -- таб после
		else
			new_host_header = case_type  -- custom
		end
		
		-- Найти и заменить "Host:" на новый вариант
		local host_start = string.find(desync.dis.payload, "\r\nHost:", 1, true)
		if host_start then
			host_start = host_start + 2  -- skip \r\n
			local new_payload = string.sub(desync.dis.payload, 1, host_start-1) ..
							   new_host_header .. ":" ..
							   string.sub(desync.dis.payload, host_start + 5)  -- skip "Host:"
			desync.dis.payload = new_payload
			DLOG("http_hostmod: changed 'Host:' to '"..new_host_header..":' ")
			return VERDICT_MODIFY
		else
			DLOG("http_hostmod: Host header not found")
		end
	end
end

-- HTTP with absolute URL
-- Использует абсолютный URL в запросе: GET http://host/path HTTP/1.1
-- Некоторые DPI не парсят URL, только Host header
-- standard args : direction, payload
-- arg : fake_host=<str> - фейковый хост для Host header (default google.com)
function z2k_http_absolute_url(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)
	
	if desync.l7payload=="http_req" and direction_check(desync) then
		local hdis = http_dissect_req(desync.dis.payload)
		if not hdis or not hdis.headers.host then
			DLOG("http_absolute_url: cannot parse HTTP")
			return
		end
		
		local real_host = string.sub(desync.dis.payload, hdis.headers.host.pos_value_start, hdis.headers.host.pos_end)
		local fake_host = desync.arg.fake_host or "google.com"
		local path = hdis.path or "/"
		
		-- Создаём новый запрос с абсолютным URL
		-- GET http://real_host/path HTTP/1.1\r\nHost: fake_host\r\n...
		local abs_url = "http://" .. real_host .. path
		local new_request = hdis.method .. " " .. abs_url .. " " .. hdis.version .. "\r\n"
		
		-- Добавляем headers, но меняем Host на фейковый
		for name, header in pairs(hdis.headers) do
			if name == "host" then
				new_request = new_request .. "Host: " .. fake_host .. "\r\n"
			else
				local header_value = string.sub(desync.dis.payload, header.pos_value_start, header.pos_end)
				new_request = new_request .. header.name .. ": " .. header_value .. "\r\n"
			end
		end
		new_request = new_request .. "\r\n"
		
		-- Добавляем body если есть
		if hdis.body_start and hdis.body_start <= #desync.dis.payload then
			new_request = new_request .. string.sub(desync.dis.payload, hdis.body_start)
		end
		
		desync.dis.payload = new_request
		DLOG("http_absolute_url: rewrote to absolute URL, Host header now '"..fake_host.."'")
		return VERDICT_MODIFY
	end
end

-- HTTP Triple seqovl attack
-- Отправляет 3 версии Host value с одинаковым seq number
-- 1. Fake host (DPI кеширует)
-- 2. Garbage (сбивает DPI)
-- 3. Real host (сервер принимает последний по TCP)
-- standard args : direction, payload, rawsend, reconstruct
-- arg : fake_host=<str> - фейковый хост
function z2k_http_triple_seqovl(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)
	
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			local hdis = http_dissect_req(data)
			if not hdis or not hdis.headers.host then
				DLOG("http_triple_seqovl: no Host header")
				return
			end
			
			local host_pos = hdis.headers.host
			local real_host = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)
			local host_len = #real_host
			local fake_host = desync.arg.fake_host or "www.google.com"
			
			-- Подгоняем длину
			if #fake_host < host_len then
				fake_host = fake_host .. string.rep(".", host_len - #fake_host)
			else
				fake_host = string.sub(fake_host, 1, host_len)
			end
			
			local garbage = string.rep("X", host_len)
			
			local opts_orig = {
				rawsend = rawsend_opts_base(desync), 
				reconstruct = {}, 
				ipfrag = {}, 
				fooling = {}
			}
			
			local host_value_pos = host_pos.pos_value_start - 1
			
			-- Отправляем часть ДО Host value
			local before_host = string.sub(data, 1, host_pos.pos_value_start-1)
			if not rawsend_payload_segmented(desync, before_host, 0, opts_orig) then
				return VERDICT_PASS
			end
			
			-- АТАКА: 3 пакета с одинаковым seq
			-- 1. Fake host
			if b_debug then DLOG("http_triple_seqovl: [1] FAKE host '"..fake_host.."'") end
			if not rawsend_payload_segmented(desync, fake_host, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end
			
			-- 2. Garbage (сбивает кеш DPI)
			if b_debug then DLOG("http_triple_seqovl: [2] GARBAGE") end
			if not rawsend_payload_segmented(desync, garbage, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end
			
			-- 3. Real host (последний - сервер примет его)
			if b_debug then DLOG("http_triple_seqovl: [3] REAL host '"..real_host.."'") end
			if not rawsend_payload_segmented(desync, real_host, host_value_pos, opts_orig) then
				return VERDICT_PASS
			end
			
			-- Отправляем остаток
			local after_host = string.sub(data, host_pos.pos_end+1)
			if not rawsend_payload_segmented(desync, after_host, host_pos.pos_end, opts_orig) then
				return VERDICT_PASS
			end
			
			replay_drop_set(desync)
			return VERDICT_DROP
		end
		
		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end

-- HTTP Disorder + seqovl combo for MGTS
-- Комбинирует disorder с seqovl специально для Host header
-- standard args : direction, payload, rawsend
-- arg : fake_host=<str>
function z2k_http_mgts_combo(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)
	
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
		if replay_first(desync) then
			local hdis = http_dissect_req(data)
			if not hdis or not hdis.headers.host then
				DLOG("http_mgts_combo: no Host header")
				return
			end
			
			local host_pos = hdis.headers.host
			local real_host = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)
			local fake_host = desync.arg.fake_host or "www.google.com"
			
			-- Подгоняем длину
			local host_len = #real_host
			if #fake_host < host_len then
				fake_host = fake_host .. string.rep("x", host_len - #fake_host)
			else
				fake_host = string.sub(fake_host, 1, host_len)
			end
			
			local opts = {
				rawsend = rawsend_opts_base(desync), 
				reconstruct = {}, 
				ipfrag = {}, 
				fooling = {}
			}
			
			-- Разбиваем на 4 части:
			-- 1. До "Host: "
			-- 2. "Host: " + fake_host (seqovl с реальным)
			-- 3. real_host (перезаписывает)
			-- 4. После host value до конца
			
			local part1 = string.sub(data, 1, host_pos.pos_start - 1)  -- до "Host:"
			local part2_fake = "Host: " .. fake_host
			local part3_real = real_host
			local part4 = string.sub(data, host_pos.pos_end + 1)  -- после host value
			
			local pos_host_start = host_pos.pos_start - 1  -- 0-based
			local pos_host_value = host_pos.pos_value_start - 1
			local pos_after_host = host_pos.pos_end  -- 0-based (после последнего символа host)
			
			-- DISORDER: отправляем в обратном порядке
			-- 4 -> 3 -> 2 -> 1
			
			if b_debug then DLOG("http_mgts_combo: [4] after_host len="..#part4) end
			if not rawsend_payload_segmented(desync, part4, pos_after_host, opts) then
				return VERDICT_PASS
			end
			
			-- Реальный host (будет принят сервером)
			if b_debug then DLOG("http_mgts_combo: [3] REAL '"..part3_real.."'") end
			if not rawsend_payload_segmented(desync, part3_real, pos_host_value, opts) then
				return VERDICT_PASS
			end
			
			-- Фейковый "Host: fake" с seqovl (DPI увидит)
			if b_debug then DLOG("http_mgts_combo: [2] FAKE '"..part2_fake.."' (seqovl)") end
			if not rawsend_payload_segmented(desync, part2_fake, pos_host_start, opts) then
				return VERDICT_PASS
			end
			
			-- Начало запроса
			if b_debug then DLOG("http_mgts_combo: [1] before_host len="..#part1) end
			if not rawsend_payload_segmented(desync, part1, 0, opts) then
				return VERDICT_PASS
			end
			
			replay_drop_set(desync)
			return VERDICT_DROP
		end
		
		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end

-- NEW HTTP BYPASS STRATEGIES - Для обхода умного DPI (MTS/MGTS)
-- ============================================================================

-- HTTP Garbage Prefix - Много мусора перед запросом
-- DPI часто парсит только начало пакета, мусор может сбить парсер
-- standard args : direction, payload
-- arg : mode=<str> - "crlf", "spaces", "tabs", "mixed", "nulls" (default mixed)
-- arg : amount=N - количество мусора в байтах (default 50)
function z2k_http_garbage_prefix(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local mode = desync.arg.mode or "mixed"
        local amount = tonumber(desync.arg.amount) or 50
        local garbage = ""
        
        if mode == "crlf" then
            -- Много \r\n подряд
            garbage = string.rep("\r\n", math.floor(amount / 2))
        elseif mode == "spaces" then
            -- Пробелы с \r\n
            garbage = string.rep(" \r\n", math.floor(amount / 3))
        elseif mode == "tabs" then
            -- Табы с \r\n  
            garbage = string.rep("\t\r\n", math.floor(amount / 3))
        elseif mode == "mixed" then
            -- Смешанный мусор: пробелы, табы, \r\n
            for i = 1, math.floor(amount / 4) do
                local r = i % 4
                if r == 0 then garbage = garbage .. "\r\n"
                elseif r == 1 then garbage = garbage .. " \r\n"
                elseif r == 2 then garbage = garbage .. "\t\r\n"
                else garbage = garbage .. "  \r\n"
                end
            end
        elseif mode == "headers" then
            -- Фейковые заголовки в начале (невалидные)
            garbage = "X-Fake: garbage\r\n" .. 
                      "X-Ignore: me\r\n" ..
                      string.rep("\r\n", 5)
        end
        
        desync.dis.payload = garbage .. desync.dis.payload
        DLOG("http_garbage_prefix: added "..#garbage.." bytes of '"..mode.."' garbage")
        return VERDICT_MODIFY
    end
end

-- HTTP Pipeline Fake - Отправить два запроса, первый фейковый
-- DPI может кэшировать домен из первого запроса
-- standard args : direction, payload, rawsend
-- arg : fake_host=<str> - хост для фейкового запроса (default www.google.com)
function z2k_http_pipeline_fake(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff(ctx)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    local data = desync.reasm_data or desync.dis.payload
    if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
        if replay_first(desync) then
            local fake_host = desync.arg.fake_host or "www.google.com"
            
            -- Создаём фейковый HTTP запрос (очень короткий)
            local fake_request = "GET / HTTP/1.1\r\n" ..
                                "Host: " .. fake_host .. "\r\n" ..
                                "Connection: keep-alive\r\n" ..
                                "\r\n"
            
            local opts = {
                rawsend = rawsend_opts_base(desync), 
                reconstruct = {}, 
                ipfrag = {}, 
                fooling = {}
            }
            
            -- Отправляем ФЕЙКОВЫЙ запрос сначала
            if b_debug then DLOG("http_pipeline_fake: sending FAKE request to "..fake_host) end
            if not rawsend_payload_segmented(desync, fake_request, 0, opts) then
                return VERDICT_PASS
            end
            
            -- Потом РЕАЛЬНЫЙ запрос с offset = длина фейкового
            if b_debug then DLOG("http_pipeline_fake: sending REAL request") end
            if not rawsend_payload_segmented(desync, data, #fake_request, opts) then
                return VERDICT_PASS
            end
            
            replay_drop_set(desync)
            return VERDICT_DROP
        end
        
        if replay_drop(desync) then
            return VERDICT_DROP
        end
    end
end

-- HTTP Header Shuffle - Перемешать заголовки и добавить фейковые Host
-- Добавляет фейковый Host ДО реального, надеясь что DPI возьмёт первый
-- standard args : direction, payload
-- arg : fake_host=<str>
-- arg : add_x_host - также добавить X-Host с реальным хостом
function z2k_http_header_shuffle(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local hdis = http_dissect_req(desync.dis.payload)
        if not hdis or not hdis.headers.host then
            DLOG("http_header_shuffle: no Host header")
            return
        end
        
        local host_pos = hdis.headers.host
        local real_host = string.sub(desync.dis.payload, host_pos.pos_value_start, host_pos.pos_end)
        local fake_host = desync.arg.fake_host or "www.google.com"
        
        -- Находим конец первой строки (после GET / HTTP/1.1)
        local first_line_end = string.find(desync.dis.payload, "\r\n", 1, true)
        if not first_line_end then
            DLOG("http_header_shuffle: cannot find end of first line")
            return
        end
        
        -- Собираем новый запрос:
        -- 1. Первая строка (GET / HTTP/1.1)
        -- 2. FAKE Host header
        -- 3. Остальные заголовки (включая реальный Host)
        local new_payload = string.sub(desync.dis.payload, 1, first_line_end + 1) ..  -- включая \r\n
                           "Host: " .. fake_host .. "\r\n" ..  -- Фейковый Host ПЕРВЫМ
                           string.sub(desync.dis.payload, first_line_end + 2)  -- остаток
        
        -- Опционально добавить X-Host с реальным хостом
        if desync.arg.add_x_host then
            -- Вставляем перед реальным Host
            local real_host_pos = string.find(new_payload, "\r\nHost: "..real_host, 1, true)
            if real_host_pos then
                new_payload = string.sub(new_payload, 1, real_host_pos + 1) ..
                             "X-Real-Host: " .. real_host .. "\r\n" ..
                             string.sub(new_payload, real_host_pos + 2)
            end
        end
        
        desync.dis.payload = new_payload
        DLOG("http_header_shuffle: added fake Host '"..fake_host.."' before real '"..real_host.."'")
        return VERDICT_MODIFY
    end
end

-- HTTP Method Obfuscation - Обфускация HTTP метода
-- Некоторые DPI парсят только GET/POST, другие методы могут не блокироваться
-- standard args : direction, payload
-- arg : method=<str> - "lowercase", "padding", "fake" (default lowercase)
function z2k_http_method_obfuscate(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local mode = desync.arg.method or "lowercase"
        local payload = desync.dis.payload
        
        if mode == "lowercase" then
            -- GET -> get (некоторые серверы принимают)
            payload = string.gsub(payload, "^GET ", "get ")
            payload = string.gsub(payload, "^POST ", "post ")
            payload = string.gsub(payload, "^HEAD ", "head ")
        elseif mode == "padding" then
            -- GET -> GET  (доп пробелы)
            payload = string.gsub(payload, "^GET ", "GET  ")
            payload = string.gsub(payload, "^POST ", "POST  ")
        elseif mode == "fake" then
            -- Добавить фейковый метод перед реальным
            payload = "X " .. payload
        elseif mode == "case" then
            -- GET -> GeT
            payload = string.gsub(payload, "^GET ", "GeT ")
            payload = string.gsub(payload, "^POST ", "PoSt ")
        end
        
        desync.dis.payload = payload
        DLOG("http_method_obfuscate: applied mode '"..mode.."'")
        return VERDICT_MODIFY
    end
end

-- HTTP Absolute URI - Использовать абсолютный URI в запросе
-- GET http://real-host.com/ HTTP/1.1 вместо GET / HTTP/1.1
-- Host header ставим фейковый
-- standard args : direction, payload
-- arg : fake_host=<str>
function z2k_http_absolute_uri_v2(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local hdis = http_dissect_req(desync.dis.payload)
        if not hdis or not hdis.headers.host then
            DLOG("http_absolute_uri_v2: cannot parse")
            return
        end
        
        local host_pos = hdis.headers.host
        local real_host = string.sub(desync.dis.payload, host_pos.pos_value_start, host_pos.pos_end)
        local fake_host = desync.arg.fake_host or "www.google.com"
        
        -- Ищем начало пути (после GET )
        local method_end = string.find(desync.dis.payload, " ", 1, true)
        local path_end = string.find(desync.dis.payload, " HTTP/", 1, true)
        
        if method_end and path_end and path_end > method_end then
            local method = string.sub(desync.dis.payload, 1, method_end - 1)
            local path = string.sub(desync.dis.payload, method_end + 1, path_end - 1)
            
            -- Создаём абсолютный URI
            local abs_uri = "http://" .. real_host .. path
            
            -- Новый запрос с абсолютным URI и фейковым Host
            local new_payload = method .. " " .. abs_uri .. 
                               string.sub(desync.dis.payload, path_end)
            
            -- Заменяем Host на фейковый
            new_payload = string.gsub(new_payload, 
                                     "\r\nHost: " .. real_host, 
                                     "\r\nHost: " .. fake_host)
            
            desync.dis.payload = new_payload
            DLOG("http_absolute_uri_v2: uri="..abs_uri.." fake_host="..fake_host)
            return VERDICT_MODIFY
        end
    end
end

-- HTTP Split At Host Byte - Побайтовый split внутри Host value
-- Разрезает Host value на отдельные байты и отправляет с задержкой
-- standard args : direction, payload, rawsend
-- arg : max_parts=N - максимум частей для Host (default 5)
function z2k_http_host_bytesplit(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff(ctx)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    local data = desync.reasm_data or desync.dis.payload
    if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
        if replay_first(desync) then
            local hdis = http_dissect_req(data)
            if not hdis or not hdis.headers.host then
                DLOG("http_host_bytesplit: no Host header")
                return
            end
            
            local host_pos = hdis.headers.host
            local max_parts = tonumber(desync.arg.max_parts) or 5
            
            local opts = {
                rawsend = rawsend_opts_base(desync), 
                reconstruct = {}, 
                ipfrag = {}, 
                fooling = {}
            }
            
            -- Часть 1: До Host value
            local before = string.sub(data, 1, host_pos.pos_value_start - 1)
            if b_debug then DLOG("http_host_bytesplit: [1] before len="..#before) end
            if not rawsend_payload_segmented(desync, before, 0, opts) then
                return VERDICT_PASS
            end
            
            -- Части 2..N: Host value побайтово
            local host_value = string.sub(data, host_pos.pos_value_start, host_pos.pos_end)
            local chunk_size = math.max(1, math.floor(#host_value / max_parts))
            local pos = 0
            local part_num = 2
            
            while pos < #host_value do
                local chunk_end = math.min(pos + chunk_size, #host_value)
                local chunk = string.sub(host_value, pos + 1, chunk_end)
                local offset = host_pos.pos_value_start - 1 + pos
                
                if b_debug then DLOG("http_host_bytesplit: ["..part_num.."] chunk='"..chunk.."'") end
                if not rawsend_payload_segmented(desync, chunk, offset, opts) then
                    return VERDICT_PASS
                end
                
                pos = chunk_end
                part_num = part_num + 1
            end
            
            -- Последняя часть: После Host value
            local after = string.sub(data, host_pos.pos_end + 1)
            if b_debug then DLOG("http_host_bytesplit: ["..part_num.."] after len="..#after) end
            if not rawsend_payload_segmented(desync, after, host_pos.pos_end, opts) then
                return VERDICT_PASS
            end
            
            replay_drop_set(desync)
            return VERDICT_DROP
        end
        
        if replay_drop(desync) then
            return VERDICT_DROP
        end
    end
end

-- HTTP Fake Continuation - Отправить фейковый "продолжение" соединения
-- DPI может не парсить keep-alive запросы
-- standard args : direction, payload, rawsend
-- arg : fake_host=<str>
function z2k_http_fake_continuation(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff(ctx)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    local data = desync.reasm_data or desync.dis.payload
    if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
        if replay_first(desync) then
            local fake_host = desync.arg.fake_host or "www.google.com"
            
            local opts = {
                rawsend = rawsend_opts_base(desync), 
                reconstruct = {}, 
                ipfrag = {}, 
                fooling = {}
            }
            
            -- Отправляем "фейковый ответ" (DPI может подумать что это продолжение)
            local fake_response = "HTTP/1.1 200 OK\r\n" ..
                                 "Content-Length: 0\r\n" ..
                                 "Connection: keep-alive\r\n" ..
                                 "\r\n"
            
            -- Сначала "ответ"
            if b_debug then DLOG("http_fake_continuation: sending fake response") end
            if not rawsend_payload_segmented(desync, fake_response, 0, opts) then
                return VERDICT_PASS
            end
            
            -- Потом реальный запрос
            if b_debug then DLOG("http_fake_continuation: sending real request") end
            if not rawsend_payload_segmented(desync, data, #fake_response, opts) then
                return VERDICT_PASS
            end
            
            replay_drop_set(desync)
            return VERDICT_DROP
        end
        
        if replay_drop(desync) then
            return VERDICT_DROP
        end
    end
end

-- HTTP Version Downgrade - Понизить версию HTTP
-- Некоторые DPI не парсят HTTP/1.0
-- standard args : direction, payload
-- arg : version=<str> - "1.0" или "0.9" (default 1.0)
function z2k_http_version_downgrade(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local version = desync.arg.version or "1.0"
        local payload = desync.dis.payload
        
        if version == "1.0" then
            payload = string.gsub(payload, "HTTP/1.1", "HTTP/1.0")
            -- Убираем Host header для HTTP/1.0 (опционально)
            -- payload = string.gsub(payload, "\r\nHost: [^\r\n]+", "")
        elseif version == "0.9" then
            -- HTTP/0.9: только "GET /path" без версии и заголовков
            local path_start = string.find(payload, " ", 1, true)
            local path_end = string.find(payload, " HTTP/", 1, true)
            if path_start and path_end then
                local method = string.sub(payload, 1, path_start - 1)
                local path = string.sub(payload, path_start + 1, path_end - 1)
                payload = method .. " " .. path .. "\r\n"
            end
        end
        
        desync.dis.payload = payload
        DLOG("http_version_downgrade: changed to HTTP/"..version)
        return VERDICT_MODIFY
    end
end

-- HTTP Pipeline Fake v2 - Фейковый запрос умирает, реальный доходит
-- Фейковый запрос отправляется с badsum/низким TTL - сервер его отбросит
-- DPI видит фейковый хост, сервер получает только реальный запрос
-- standard args : direction, payload, rawsend, fooling
-- arg : fake_host=<str> - хост для фейкового запроса (default www.google.com)
-- arg : ttl=N - TTL для фейкового пакета (default 1)
-- arg : badsum - использовать неверную checksum для fake (рекомендуется)
function z2k_http_pipeline_fake_v2(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff(ctx)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    local data = desync.reasm_data or desync.dis.payload
    if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
        if replay_first(desync) then
            local fake_host = desync.arg.fake_host or "www.google.com"
            local fake_ttl = tonumber(desync.arg.ttl) or 1
            
            -- Создаём фейковый HTTP запрос
            local fake_request = "GET / HTTP/1.1\r\n" ..
                                "Host: " .. fake_host .. "\r\n" ..
                                "Connection: keep-alive\r\n" ..
                                "\r\n"
            
            -- Опции для ФЕЙКОВОГО пакета (badsum/низкий TTL - не дойдёт до сервера)
            local opts_fake = {
                rawsend = rawsend_opts(desync),
                reconstruct = reconstruct_opts(desync),
                ipfrag = {},
                fooling = {
                    badsum = desync.arg.badsum or true,  -- неверная checksum
                }
            }
            
            -- Опции для РЕАЛЬНОГО пакета (нормальные)
            local opts_real = {
                rawsend = rawsend_opts_base(desync), 
                reconstruct = {}, 
                ipfrag = {}, 
                fooling = {}
            }
            
            -- Отправляем ФЕЙКОВЫЙ запрос (с badsum - сервер отбросит, DPI увидит)
            local fake_dis = deepcopy(desync.dis)
            fake_dis.payload = fake_request
            
            -- Устанавливаем низкий TTL
            if fake_dis.ip then
                fake_dis.ip.ip_ttl = fake_ttl
            end
            if fake_dis.ip6 then
                fake_dis.ip6.ip6_hlim = fake_ttl
            end
            
            if b_debug then DLOG("http_pipeline_fake_v2: sending FAKE (TTL="..fake_ttl..", badsum) to "..fake_host) end
            rawsend_dissect(fake_dis, opts_fake.rawsend)
            
            -- Отправляем РЕАЛЬНЫЙ запрос (нормальный, дойдёт до сервера)
            if b_debug then DLOG("http_pipeline_fake_v2: sending REAL request") end
            if not rawsend_payload_segmented(desync, data, 0, opts_real) then
                return VERDICT_PASS
            end
            
            replay_drop_set(desync)
            return VERDICT_DROP
        end
        
        if replay_drop(desync) then
            return VERDICT_DROP
        end
    end
end

-- HTTP Fake Header Inject - Добавляет фейковый X-Host заголовок
-- Сервер игнорирует X-Host, но DPI может его прочитать
-- standard args : direction, payload
-- arg : fake_host=<str>
function z2k_http_fake_xhost(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local fake_host = desync.arg.fake_host or "www.google.com"
        local payload = desync.dis.payload
        
        -- Находим конец первой строки
        local first_line_end = string.find(payload, "\r\n", 1, true)
        if first_line_end then
            -- Вставляем X-Host ПЕРЕД настоящим Host (DPI может взять первый "Host"-подобный)
            -- Некоторые DPI ищут просто "Host:" без проверки что это заголовок
            local fake_header = "X-Host: " .. fake_host .. "\r\n" ..
                               "X-Forwarded-Host: " .. fake_host .. "\r\n"
            
            payload = string.sub(payload, 1, first_line_end + 1) ..
                     fake_header ..
                     string.sub(payload, first_line_end + 2)
            
            desync.dis.payload = payload
            DLOG("http_fake_xhost: added fake X-Host: "..fake_host)
            return VERDICT_MODIFY
        end
    end
end

-- HTTP with OOB byte - Добавляет TCP OOB байт перед запросом
-- Некоторые DPI не обрабатывают urgent data правильно
-- standard args : direction, payload
function z2k_http_oob_prefix(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        -- Добавляем мусорный байт в начало - сервера часто игнорируют лишние байты
        -- перед GET/POST
        desync.dis.payload = "\n" .. desync.dis.payload
        DLOG("http_oob_prefix: added \\n prefix")
        return VERDICT_MODIFY
    end
end

-- Безопасный methodeol - только добавляет \r\n в начало, ничего не обрезает
-- Некоторые серверы принимают \r\n перед GET
function z2k_http_methodeol_safe(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        -- Просто добавляем \r\n в начало (без обрезания User-Agent)
        desync.dis.payload = "\r\n" .. desync.dis.payload
        DLOG("http_methodeol_safe: added \\r\\n prefix only")
        return VERDICT_MODIFY
    end
end

-- Ещё безопаснее - добавить пустую строку внутри заголовков (не в начале)
-- Вставляет пустой X-заголовок который nginx игнорирует
function z2k_http_inject_safe_header(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local payload = desync.dis.payload
        
        -- Находим позицию перед Host:
        local host_pos = string.find(payload, "\r\nHost:", 1, true)
        if host_pos then
            -- Вставляем безопасный заголовок перед Host
            payload = string.sub(payload, 1, host_pos + 1) ..
                     "X-Padding: " .. string.rep("x", 50) .. "\r\n" ..
                     string.sub(payload, host_pos + 2)
            desync.dis.payload = payload
            DLOG("http_inject_safe_header: added X-Padding header")
            return VERDICT_MODIFY
        end
    end
end

-- Вариант 2: Пробел перед GET (некоторые серверы принимают)
-- " GET / HTTP/1.1" вместо "GET / HTTP/1.1"
function z2k_http_space_prefix(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        desync.dis.payload = " " .. desync.dis.payload
        DLOG("http_space_prefix: added space prefix")
        return VERDICT_MODIFY
    end
end

-- Вариант 3: \n вместо \r\n (Unix-style line ending)
function z2k_http_lf_prefix(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        desync.dis.payload = "\n" .. desync.dis.payload
        DLOG("http_lf_prefix: added \\n prefix")
        return VERDICT_MODIFY
    end
end

-- Вариант 4: Таб перед GET
function z2k_http_tab_prefix(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        desync.dis.payload = "\t" .. desync.dis.payload
        DLOG("http_tab_prefix: added tab prefix")
        return VERDICT_MODIFY
    end
end

-- Вариант 5: Добавить безопасный X-заголовок (100% совместимо)
-- X-Padding header игнорируется сервером но сбивает парсер DPI
function z2k_http_xpadding(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local payload = desync.dis.payload
        
        -- Находим конец первой строки (GET / HTTP/1.1\r\n)
        local first_line_end = string.find(payload, "\r\n", 1, true)
        if first_line_end then
            -- Вставляем длинный X-заголовок сразу после первой строки
            local padding = string.rep("x", 100)  -- 100 символов мусора
            payload = string.sub(payload, 1, first_line_end + 1) ..
                     "X-Pad: " .. padding .. "\r\n" ..
                     string.sub(payload, first_line_end + 2)
            desync.dis.payload = payload
            DLOG("http_xpadding: added X-Pad header with 100 bytes")
            return VERDICT_MODIFY
        end
    end
end

-- Вариант 6: Несколько \r\n подряд (агрессивнее)
-- arg : count=N - количество \r\n (default 3)
function z2k_http_multi_crlf(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local count = tonumber(desync.arg.count) or 3
        local prefix = string.rep("\r\n", count)
        desync.dis.payload = prefix .. desync.dis.payload
        DLOG("http_multi_crlf: added "..count.." x \\r\\n prefix")
        return VERDICT_MODIFY
    end
end

-- Вариант 7: Комбинация - \r\n + пробелы
function z2k_http_mixed_prefix(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        -- \r\n потом пробелы потом таб
        desync.dis.payload = "\r\n \t" .. desync.dis.payload
        DLOG("http_mixed_prefix: added mixed whitespace prefix")
        return VERDICT_MODIFY
    end
end

-- SUPER ADVANCED DECOY + HOST SPLIT + MIXCASE
-- ============================================================================

-- standard args : direction, payload, rawsend, reconstruct, ipfrag
-- arg : decoys=N - количество фейковых запросов (default 3)
-- arg : decoy_hosts=<str> - список фейковых хостов через запятую (default: google.com,yandex.ru,vk.com)
-- arg : disorder=N - отправлять части в обратном порядке (default enabled)
-- arg : mixcase - включить замену Host на hoSt (по умолчанию включено)
function z2k_http_super_decoy(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff(ctx)
        return
    end
    direction_cutoff_opposite(ctx, desync)

    local data = desync.reasm_data or desync.dis.payload
    
    -- Проверяем, что это HTTP запрос
    if #data > 0 and desync.l7payload == "http_req" and direction_check(desync) then
        if replay_first(desync) then
            -- == НАСТРОЙКИ ==
            local num_decoys = tonumber(desync.arg.decoys) or 3
            local decoy_hosts_str = desync.arg.decoy_hosts or "google.com,facebook.com,twitter.com,drive.google.com"
            local use_disorder = desync.arg.disorder ~= "false" -- включено по умолчанию
            local use_mixcase = desync.arg.mixcase ~= "false"   -- включено по умолчанию
            
            -- Парсинг списка хостов
            local decoy_hosts = {}
            for host in string.gmatch(decoy_hosts_str, "[^,]+") do
                table.insert(decoy_hosts, host)
            end

            -- Парсим реальный запрос
            local hdis = http_dissect_req(data)
            local real_host = "example.com"
            local host_pos_start = 0
            local host_pos_end = 0
            local host_header_pos = 0 -- позиция слова "Host:"
            
            if hdis and hdis.headers.host then
                host_pos_start = hdis.headers.host.pos_value_start
                host_pos_end = hdis.headers.host.pos_end
                host_header_pos = hdis.headers.host.pos_key_start
                real_host = string.sub(data, host_pos_start, host_pos_end)
            end

            -- == ГЕНЕРАЦИЯ ФЕЙКОВ (DECOYS) ==
            local opts_decoy = {
                rawsend = rawsend_opts(desync),
                fooling = { badsum = true, md5sig = true } -- Badsum + TCP MD5 (если поддерживается)
            }

            local user_agents = {
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
            }

            for i = 1, num_decoys do
                local fake_host = decoy_hosts[(i % #decoy_hosts) + 1]
                local ua = user_agents[(i % #user_agents) + 1]
                
                -- Создаем реалистичный фейковый запрос
                local fake_request = "GET /search?q=".. os.time() .. " HTTP/1.1\r\n" ..
                                   "Host: " .. fake_host .. "\r\n" ..
                                   "User-Agent: " .. ua .. "\r\n" ..
                                   "Accept: text/html,application/xhtml+xml\r\n" ..
                                   "Connection: close\r\n\r\n"

                local fake_dis = deepcopy(desync.dis)
                fake_dis.payload = fake_request

                -- TTL: Чередуем очень низкий (не дойдет) и чуть повыше (дойдет, но будет отброшен из-за badsum)
                if fake_dis.ip then fake_dis.ip.ip_ttl = (i % 2 == 0) and 3 or 5 end
                if fake_dis.ip6 then fake_dis.ip6.ip6_hlim = (i % 2 == 0) and 3 or 5 end

                if b_debug then DLOG("SuperDecoy: sending fake -> "..fake_host) end
                rawsend_dissect(fake_dis, opts_decoy.rawsend)
            end

            -- == МОДИФИКАЦИЯ РЕАЛЬНОГО ЗАПРОСА ==
            
            -- 1. MixCase: меняем Host: -> hoSt: (если включено и найден заголовок)
            if use_mixcase and host_header_pos > 0 then
                -- Патчим байты в payload ("Host" -> "hoSt")
                -- Lua строки неизменяемы, собираем новую
                local prefix = string.sub(data, 1, host_header_pos - 1)
                local suffix = string.sub(data, host_header_pos + 4)
                data = prefix .. "hoSt" .. suffix
                -- Смещаем позиции, так как мы изменили data, но длина не поменялась
            end

            -- 2. Разбиение (Segmentation)
            -- Стратегия: 
            -- Часть 1: Начало ... середина домена
            -- Часть 2: Оставшаяся часть домена ... конец
            
            local parts = {}
            local split_point = 0

            if host_pos_start > 0 and host_pos_end > 0 then
                -- Режем посередине домена (например, yout|ube.com)
                local host_len = host_pos_end - host_pos_start
                local half_host = math.floor(host_len / 2)
                split_point = host_pos_start + half_host
            else
                -- Fallback: просто пополам
                split_point = math.floor(#data / 2)
            end

            -- Формируем части
            local part1 = string.sub(data, 1, split_point)
            local part2 = string.sub(data, split_point + 1)
            
            table.insert(parts, {data=part1, offset=0})
            table.insert(parts, {data=part2, offset=#part1})

            -- Опции отправки реальных данных
            local opts_real = {
                rawsend = rawsend_opts_base(desync),
                reconstruct = {}, -- не пересчитываем payload (мы его уже собрали)
                -- Включаем IP фрагментацию на уровне шлюза/пакета
                ipfrag = { 
                    ipfrag_pos_tcp = 24 -- Маленький первый IP фрагмент для еще большего запутывания
                } 
            }

            -- == ОТПРАВКА (DISORDER) ==
            if use_disorder then
                -- Отправляем задом наперед: Часть 2, затем Часть 1
                -- DPI видит "ube.com HTTP/..." (сирота), затем "GET... Host: yout"
                -- Сервер собирает по SEQ номерам.
                if b_debug then DLOG("SuperDecoy: Sending DISORDER split at "..split_point) end
                
                -- Отправляем вторую часть
                if not rawsend_payload_segmented(desync, parts[2].data, parts[2].offset, opts_real) then return VERDICT_PASS end
                -- Отправляем первую часть
                if not rawsend_payload_segmented(desync, parts[1].data, parts[1].offset, opts_real) then return VERDICT_PASS end
            else
                -- Обычный порядок (просто сплит + ipfrag)
                if b_debug then DLOG("SuperDecoy: Sending ORDERED split") end
                for _, part in ipairs(parts) do
                    if not rawsend_payload_segmented(desync, part.data, part.offset, opts_real) then return VERDICT_PASS end
                end
            end

            -- Песочный эффект: еще один фейк в конце
            local fake_dis = deepcopy(desync.dis)
            fake_dis.payload = "GET / HTTP/1.1\r\nHost: " .. real_host .. "\r\n\r\n"
            if fake_dis.ip then fake_dis.ip.ip_ttl = 3 end
            rawsend_dissect(fake_dis, opts_decoy.rawsend)

            replay_drop_set(desync)
            return VERDICT_DROP
        end
        
        if replay_drop(desync) then
            return VERDICT_DROP
        end
    end
end

-- HTTP combo bypass v2 - исправлена ошибка с tcp_seq
function z2k_http_combo_bypass(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff(ctx)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    local data = desync.reasm_data or desync.dis.payload
    if #data>0 and desync.l7payload=="http_req" and direction_check(desync) then
        if replay_first(desync) then
            local fake_host = desync.arg.fake_host or "www.iana.org"
            local repeats = tonumber(desync.arg.repeats) or 15
            local prefix = desync.arg.prefix or "\r\n"
            local hostcase = desync.arg.hostcase or "HoSt"
            
            -- 1. ОТПРАВЛЯЕМ FAKE ПАКЕТЫ
            local fake_http = "GET / HTTP/1.1\r\nHost: " .. fake_host .. 
                             "\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\n" ..
                             "Connection: keep-alive\r\n\r\n"
            
            local opts_fake = {
                rawsend = rawsend_opts(desync),
                reconstruct = reconstruct_opts(desync),
                ipfrag = {},
                fooling = { badsum = true }
            }
            opts_fake.rawsend.repeats = repeats
            
            local fake_dis = deepcopy(desync.dis)
            fake_dis.payload = fake_http
            if fake_dis.ip then fake_dis.ip.ip_ttl = 2 end
            if fake_dis.ip6 then fake_dis.ip6.ip6_hlim = 2 end
            
            DLOG("http_combo_bypass: sending "..repeats.." fake packets")
            rawsend_dissect(fake_dis, opts_fake.rawsend)
            
            -- 2. МОДИФИЦИРУЕМ PAYLOAD
            local modified = data
            
            if prefix and #prefix > 0 then
                modified = prefix .. modified
            end
            
            if hostcase then
                modified = string.gsub(modified, "Host:", hostcase..":", 1)
            end
            
            -- 3. ОТПРАВЛЯЕМ КАК ЕДИНЫЙ ПАКЕТ (без split)
            local opts_real = {
                rawsend = rawsend_opts_base(desync),
                reconstruct = {},
                ipfrag = {},
                fooling = {}
            }
            
            local real_dis = deepcopy(desync.dis)
            real_dis.payload = modified
            
            DLOG("http_combo_bypass: sending modified request, len="..#modified)
            rawsend_dissect(real_dis, opts_real.rawsend)
            
            replay_drop_set(desync)
            return VERDICT_DROP
        end
        
        if replay_drop(desync) then
            return VERDICT_DROP
        end
    end
end

-- Упрощённая версия - только \r\n + hostcase, без split
-- Для серверов которые чувствительны к split
function z2k_http_simple_bypass(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    
    if desync.l7payload=="http_req" and direction_check(desync) then
        local prefix = desync.arg.prefix or "\r\n"
        local hostcase = desync.arg.hostcase or "HoSt"
        
        local payload = desync.dis.payload
        
        -- Добавляем \r\n в начало
        payload = prefix .. payload
        
        -- Меняем Host: на HoSt:
        payload = string.gsub(payload, "Host:", hostcase..":", 1)
        
        desync.dis.payload = payload
        DLOG("http_simple_bypass: prefix + hostcase applied")
        return VERDICT_MODIFY
    end
end

DLOG("z2k-http-strats: 33 HTTP-bypass primitives loaded")
