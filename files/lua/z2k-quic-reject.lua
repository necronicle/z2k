-- z2k-quic-reject.lua — отказ QUIC вместо тихого сброса (тумблеры «YouTube без
-- QUIC» и «Весь QUIC через TCP», Z2K_YT_QUIC_OFF / Z2K_QUIC_OFF).
--
-- Зачем отказ, а не drop. Тихо выкинутый QUIC Initial для клиента неотличим от
-- блокировки QUIC провайдером: клиент ждёт ответа, повторяет Initial и решает
-- сам, когда сдаться. Отказ — ICMP «порт недоступен» от имени сервера — клиент
-- получает сразу: подключённый UDP-сокет отдаёт ECONNREFUSED на чтении, Chromium
-- закрывает QUIC-сессию (QuicChromiumClientSession::OnReadError ->
-- QUIC_PACKET_READ_ERROR), запрос уходит по TCP без ожидания, а QUIC к этому
-- серверу помечается сломанным. Повторов Initial после этого нет, поэтому они
-- не уходят за окно очереди (первые NFQWS2_UDP_PKT_OUT пакетов потока).
--
-- Почему вложенный заголовок верный. Клиент сверяет ICMP со своим сокетом по
-- вложенным адресам и портам. Очередь z2k стоит в mangle POSTROUTING (z2k
-- ставится только на iptables, lib/install.sh), то есть ДО SNAT: адреса в
-- пакете клиентские. Ответ уходит через интерфейс, с которого пакет пришёл
-- (desync.ifin), с адресом источника = адресом сервера. Метку пакета клиента
-- не наследуем: по ней прошивка выбирает политику маршрутизации, а ответ идёт
-- в локальную сеть — только метка движка, чтобы он не попал в очередь.
--
-- Сам пакет клиента выкидывается в любом случае: если отправить отказ не
-- вышло, поведение остаётся прежним (тихий drop).

local ICMP4_UNREACH, ICMP4_PORT_UNREACH = 3, 3
local ICMP6_UNREACH, ICMP6_PORT_UNREACH = 1, 4
-- Сколько исходного пакета вкладывать: RFC 1812 4.3.2.3 (ответ не длиннее 576
-- байт) и RFC 4443 2.4(c) (не длиннее минимального MTU IPv6, 1280).
local IP4_MAX, IP6_MAX = 576, 1280

local function be16(v)
    return string.char(math.floor(v / 256) % 256, v % 256)
end

-- Сумма 16-битных слов в обратном коде (RFC 1071), уже свёрнутая и инвертированная.
local function inet_csum(data)
    local sum = 0
    for i = 1, #data - 1, 2 do
        sum = sum + data:byte(i) * 256 + data:byte(i + 1)
    end
    if #data % 2 == 1 then sum = sum + data:byte(#data) * 256 end
    while sum > 0xFFFF do sum = (sum % 0x10000) + math.floor(sum / 0x10000) end
    return 0xFFFF - sum
end

-- Пакет ICMP-отказа на исходный пакет orig (байты IP-пакета клиента).
-- src/dst — адреса исходного пакета (4 или 16 байт). Возвращает байты IP-пакета.
function z2k_quic_reject_packet(orig, src, dst, ip6)
    if ip6 then
        local body = orig:sub(1, IP6_MAX - 40 - 8)
        local icmp_len = 8 + #body
        local pseudo = dst .. src .. string.char(0, 0) .. be16(icmp_len)
            .. string.char(0, 0, 0, 58)
        local icmp0 = string.char(ICMP6_UNREACH, ICMP6_PORT_UNREACH, 0, 0, 0, 0, 0, 0) .. body
        local icmp = icmp0:sub(1, 2) .. be16(inet_csum(pseudo .. icmp0)) .. icmp0:sub(5)
        return string.char(0x60, 0, 0, 0) .. be16(icmp_len) .. string.char(58, 64)
            .. dst .. src .. icmp
    end
    local body = orig:sub(1, IP4_MAX - 20 - 8)
    local icmp0 = string.char(ICMP4_UNREACH, ICMP4_PORT_UNREACH, 0, 0, 0, 0, 0, 0) .. body
    local icmp = icmp0:sub(1, 2) .. be16(inet_csum(icmp0)) .. icmp0:sub(5)
    local hdr0 = string.char(0x45, 0) .. be16(20 + #icmp) .. string.char(0, 0, 0, 0, 64, 1, 0, 0)
        .. dst .. src
    return hdr0:sub(1, 10) .. be16(inet_csum(hdr0)) .. hdr0:sub(13) .. icmp
end

-- --lua-desync=z2k_quic_reject — только исходящий QUIC Initial.
function z2k_quic_reject(ctx, desync)
    direction_cutoff_opposite(ctx, desync, "out")
    local dis = desync.dis
    if not (desync.outgoing and dis and dis.udp and (dis.ip or dis.ip6)) then return end
    if not payload_check(desync, "quic_initial") then return end
    -- ClientHello, собранный из нескольких пакетов, движок проигрывает по
    -- кускам: выкидываем каждый, отказ шлём один раз.
    if replay_first(desync) then
        local ip = dis.ip6 or dis.ip
        local src = dis.ip6 and ip.ip6_src or ip.ip_src
        local dst = dis.ip6 and ip.ip6_dst or ip.ip_dst
        local ok, orig = pcall(reconstruct_dissect, dis, { keepsum = true })
        if ok and orig and src and dst then
            local pkt = z2k_quic_reject_packet(orig, src, dst, dis.ip6 ~= nil)
            if rawsend(pkt, { ifout = desync.ifin }) then
                DLOG("z2k_quic_reject: port unreachable sent")
            else
                DLOG("z2k_quic_reject: rawsend failed, silent drop")
            end
        else
            DLOG("z2k_quic_reject: cannot rebuild original packet, silent drop")
        end
    end
    return VERDICT_DROP
end
