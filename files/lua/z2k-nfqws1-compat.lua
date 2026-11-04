-- z2k-nfqws1-compat.lua
--
-- Три приёма winws/nfqws1, которых в lua-движке zapret2 нет, а в стратегиях
-- winws-конфигов (и перенесённых оттуда плечах) они есть. Без этого слоя плечи
-- выглядели перенесёнными, но работали не так, как у первоисточника.
--
-- Грузится через --lua-init ПОСЛЕ zapret-lib.lua и zapret-antidpi.lua (они
-- дают apply_fooling и hostfakesplit) и ДО z2k-range-rand.lua, который сам
-- оборачивает действия: его обёртка должна лечь поверх нашей, иначе синтаксис
-- диапазонов перестанет работать у hostfakesplit. Порядок держит S99zapret2.new.
--
-- 1. badseq — фулинг nfqws1 (--dpi-desync-fooling=badseq). В nfqws1 это ДВА
--    сдвига разом: seq += badseq_increment (по умолчанию -10000) и
--    ack += badack_increment (по умолчанию -66000); второй — несущий, именно
--    он уводит фейк из окна. В lua есть только tcp_seq=N и tcp_ack=N, а токены
--    badseq/badseq_increment движок молча пропускал: десять наших плеч
--    (rkn 2, 6, 8, 18, 44, 46; yt/gv 4; yt 21; gv 2) до 23.10.2026 слали фейк
--    без заявленного искажения. Здесь badseq раскрывается в tcp_seq/tcp_ack с
--    теми же умолчаниями, что у nfqws1; явные tcp_seq/tcp_ack в том же плече
--    не трогаются.
--
-- 2. tcp_md5_first — раскладка опций TCP фейка как у nfqws1. Тот собирает
--    опции заново: MD5 (md5sig) первой, за ней timestamp, до кратной 4 длины
--    NOP. Штатный tcp_md5 дописывает MD5 в конец, после timestamp. В связке
--    tcp_md5:tcp_nop_del:tcp_ts_up:tcp_md5_first фейк совпадает с nfqws1
--    побайтно (дифференциальный стенд двух движков, 30.10.2026).
--
-- 3. hostfakesplit altorder=1 (--dpi-desync-hostfakesplit-mod=altorder=1).
--    Штатный порядок: оригинал до хоста, фейк хоста, оригинал хоста, фейк
--    хоста, оригинал после хоста. altorder=1: оригинал до хоста, фейк хоста,
--    оригинал ПОСЛЕ хоста, и только потом — оригинал хоста (при midhost —
--    двумя частями). DPI, собирающий сегменты подряд, получает целый запрос с
--    подменённым хостом; настоящий хост догоняет отдельным сегментом вне
--    порядка (разновидность disorder, readme nfqws1 §hostfakesplit). Тело —
--    штатный hostfakesplit из zapret-antidpi.lua с переставленными отправками;
--    без altorder=1 вызов уходит в штатную функцию без изменений.
--
-- luacheck: globals apply_fooling hostfakesplit find_tcp_option TCP_KIND_MD5 TCP_KIND_NOOP TCP_KIND_END

-- ---------------------------------------------------------------------------
-- badseq
-- ---------------------------------------------------------------------------
local z2k_apply_fooling_orig = apply_fooling

-- tcp_md5_first: nfqws1 собирает опции фейка заново — MD5 первой, за ней
-- timestamp, до кратной 4 длины NOP в конце; штатный tcp_md5 дописывает MD5 в
-- конец, а сборщик движка добивает длину EOL. Флаг ставит MD5 первой и
-- добивает NOP.
local function z2k_md5_first(desync, dis)
  local d = dis or (desync and desync.dis)
  local opts = d and d.tcp and d.tcp.options
  if not opts then return end
  local i = find_tcp_option(opts, TCP_KIND_MD5)
  if not i then return end
  if i > 1 then
    table.insert(opts, 1, opts[i])
    table.remove(opts, i + 1)
  end
  local len = 0
  for _, o in ipairs(opts) do
    len = len + ((o.kind == TCP_KIND_NOOP or o.kind == TCP_KIND_END) and 1 or 2 + #(o.data or ""))
  end
  while len % 4 ~= 0 do
    opts[#opts + 1] = {kind = TCP_KIND_NOOP}
    len = len + 1
  end
end

function apply_fooling(desync, dis, fooling_options)
  local fo = fooling_options
  if fo == nil and desync then fo = desync.arg end
  if type(fo) == "table" and fo.tcp_md5_first and not fo.badseq then
    local r = z2k_apply_fooling_orig(desync, dis, fooling_options)
    z2k_md5_first(desync, dis)
    return r
  end
  if type(fo) ~= "table" or not fo.badseq then
    return z2k_apply_fooling_orig(desync, dis, fooling_options)
  end
  local t = {}
  for k, v in pairs(fo) do t[k] = v end
  if t.tcp_seq == nil then
    local inc = tonumber(fo.badseq_increment)
    -- badseq=N — короткая запись инкремента; голый badseq — умолчание nfqws1
    if inc == nil and fo.badseq ~= true then inc = tonumber(fo.badseq) end
    t.tcp_seq = inc or -10000
  end
  if t.tcp_ack == nil then
    t.tcp_ack = tonumber(fo.badack_increment) or -66000
  end
  if type(DLOG) == "function" then
    DLOG("z2k_nfqws1_compat: badseq -> tcp_seq=" .. tostring(t.tcp_seq) .. " tcp_ack=" .. tostring(t.tcp_ack))
  end
  local r = z2k_apply_fooling_orig(desync, dis, t)
  if fo.tcp_md5_first then z2k_md5_first(desync, dis) end
  return r
end

-- ---------------------------------------------------------------------------
-- hostfakesplit altorder=1
-- ---------------------------------------------------------------------------
local z2k_hostfakesplit_orig = hostfakesplit

local function z2k_hostfakesplit_altorder1(ctx, desync)
  if not desync.dis.tcp then
    -- do not cutoff on related icmp
    if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
    return
  end
  direction_cutoff_opposite(ctx, desync)
  if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
    DLOG("hostfakesplit(altorder=1): blob '" .. desync.arg.blob .. "' not found. skipped")
    return
  end
  local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
  if #data > 0 and direction_check(desync) and payload_check(desync) then
    if replay_first(desync) then
      local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
      if pos then
        if b_debug then DLOG("hostfakesplit(altorder=1): resolved host range: " .. table.concat(zero_based_pos(pos), " ")) end

        -- как в штатной функции: фулинг — только на фейк, ip_id — на всё
        local part, fakehost
        local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
        local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

        -- 1. оригинал до хоста
        part = string.sub(data, 1, pos[1] - 1)
        if b_debug then DLOG("hostfakesplit(altorder=1): sending before_host part 0-" .. (pos[1] - 2) .. " len=" .. #part) end
        if not rawsend_payload_segmented(desync, part, 0, opts_orig) then return VERDICT_PASS end

        -- 2. фейк хоста (единственный в этом порядке)
        fakehost = genhost(pos[2] - pos[1] + 1, desync.arg.host)
        if not desync.arg.nofake1 then
          if b_debug then DLOG("hostfakesplit(altorder=1): sending fake host part " .. (pos[1] - 1) .. "-" .. (pos[2] - 1) .. " len=" .. #fakehost) end
          if not rawsend_payload_segmented(desync, fakehost, pos[1] - 1, opts_fake) then return VERDICT_PASS end
        end

        -- 3. оригинал после хоста — до настоящего хоста, в этом и есть altorder=1
        part = string.sub(data, pos[2] + 1)
        if b_debug then DLOG("hostfakesplit(altorder=1): sending after_host part " .. pos[2] .. "-" .. (#data - 1) .. " len=" .. #part) end
        if not rawsend_payload_segmented(desync, part, pos[2], opts_orig) then return VERDICT_PASS end

        -- 4. настоящий хост, при midhost — двумя сегментами
        local midhost
        if desync.arg.midhost then
          midhost = resolve_pos(data, desync.l7payload, desync.arg.midhost)
          if midhost then
            if midhost <= pos[1] or midhost > pos[2] then
              DLOG("hostfakesplit(altorder=1): midhost is not inside the host range")
              midhost = nil
            end
          else
            DLOG("hostfakesplit(altorder=1): cannot resolve midhost marker '" .. desync.arg.midhost .. "'")
          end
        end
        if midhost then
          part = string.sub(data, pos[1], midhost - 1)
          if b_debug then DLOG("hostfakesplit(altorder=1): sending real host part 1 len=" .. #part) end
          if not rawsend_payload_segmented(desync, part, pos[1] - 1, opts_orig) then return VERDICT_PASS end
          part = string.sub(data, midhost, pos[2])
          if b_debug then DLOG("hostfakesplit(altorder=1): sending real host part 2 len=" .. #part) end
          if not rawsend_payload_segmented(desync, part, midhost - 1, opts_orig) then return VERDICT_PASS end
        else
          part = string.sub(data, pos[1], pos[2])
          if b_debug then DLOG("hostfakesplit(altorder=1): sending real host part len=" .. #part) end
          if not rawsend_payload_segmented(desync, part, pos[1] - 1, opts_orig) then return VERDICT_PASS end
        end

        replay_drop_set(desync)
        return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
      else
        DLOG("hostfakesplit(altorder=1): host range cannot be resolved")
      end
    else
      DLOG("hostfakesplit(altorder=1): not acting on further replay pieces")
    end
    -- drop replayed packets if reasm was sent successfully in splitted form
    if replay_drop(desync) then
      return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
    end
  end
end

function hostfakesplit(ctx, desync)
  if desync and desync.arg and tostring(desync.arg.altorder) == "1" then
    return z2k_hostfakesplit_altorder1(ctx, desync)
  end
  return z2k_hostfakesplit_orig(ctx, desync)
end
