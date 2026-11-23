-- Интеграционный регресс Anti-Drift (auto_pinned) поверх реального zapret-auto.lua,
-- z2k-alert.lua, z2k-quic-silence.lua и z2k-state-persist.lua.
local H = dofile('tests/lib/detector_harness.lua')
local STATE_DIR = assert(os.getenv('Z2K_STATE_DIR_OVERRIDE'), 'Z2K_STATE_DIR_OVERRIDE required')
local STATE_FILE = STATE_DIR .. '/state.tsv'

-- Догружаем z2k-modern-core.lua и z2k-state-persist.lua поверх реального zapret-auto.lua (как в S99zapret2.new).
dofile('files/lua/z2k-modern-core.lua')
dofile('files/lua/z2k-state-persist.lua')
local P = assert(z2k_state_persist, 'z2k_state_persist missing')
P._set_interval(0)

local real_reset = H.reset
H.reset = function()
    real_reset()
    P._reset()
    os.remove(STATE_FILE)
    os.remove((os.getenv('Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE') or '/tmp') .. '/z2k-autocircular-state.tsv')
end

local function read_tsv_mode(key, host)
    local f = io.open(STATE_FILE, 'r')
    if not f then return nil, nil end
    local s, m
    for line in f:lines() do
        if line:sub(1, 1) ~= '#' then
            local k, h, strat, _, mode = line:match('^([^\t]+)\t([^\t]+)\t([0-9]+)\t?([0-9]*)\t?([a-z_]*)')
            if k == key and h == host then s, m = tonumber(strat), mode end
        end
    end
    f:close()
    return s, m
end

local function tls_rec(kind, len, fill)
    return string.char(kind, 3, 3, math.floor(len / 256), len % 256) .. string.rep(fill or 'a', len)
end

local function succeed_short_tls(host, key)
    local t = H.track(host)
    local d1 = H.tcp(t, true, 1, H.client, 'tls_client_hello'); d1.arg.key = key or 'yt_tcp'
    H.step(d1)
    local burst = H.hello .. tls_rec(20, 1, '\1') .. tls_rec(23, 1200)
    local d2 = H.tcp(t, false, 1, burst, 'tls_server_hello'); d2.arg.key = key or 'yt_tcp'
    return H.step(d2)
end

local function fail_early_alert(host, key)
    local t = H.track(host)
    local d1 = H.tcp(t, true, 1, H.client, 'tls_client_hello'); d1.arg.key = key or 'yt_tcp'
    H.step(d1)
    local d2 = H.tcp(t, false, 1, H.alert); d2.arg.key = key or 'yt_tcp'
    return H.step(d2)
end

H.test('real zapret-auto: sustained short TLS successes arm auto_pinned and block single failure quorum', function()
    local host = 'youtubei.googleapis.com'
    local h
    for _ = 1, 3 do h = succeed_short_tls(host, 'yt_tcp') end
    H.eq(1, h.nstrategy)
    H.eq(1, h.z2k_auto_pinned)
    local strat, mode = read_tsv_mode('yt_tcp', 'googleapis.com|4')
    H.eq(1, strat)
    H.eq('auto', mode)

    -- 8 параллельных старых соединений падают разом — первый кворум гасит дрейф и
    -- переводит generation, поэтому оставшиеся 5 не добивают второй кворум.
    local stale_tracks = {}
    for i = 1, 8 do
        local t = H.track(host)
        local d = H.tcp(t, true, 1, H.client, 'tls_client_hello'); d.arg.key = 'yt_tcp'
        H.step(d)
        stale_tracks[i] = t
    end
    for i = 1, 8 do
        local d = H.tcp(stale_tracks[i], false, 1, H.alert); d.arg.key = 'yt_tcp'
        H.step(d)
    end
    H.eq(1, h.nstrategy)
    H.eq(1, h.z2k_auto_pinned)
    H.eq(1, h.z2k_ap_fail_rounds)

    -- Следом одно здоровое соединение сбрасывает fail_rounds в 0
    succeed_short_tls(host, 'yt_tcp')
    H.eq(0, h.z2k_ap_fail_rounds)
    H.eq(1, h.z2k_auto_pinned)
end)

H.test('real zapret-auto: 2 independent healthy failure quorums unlock auto_pinned and rotate', function()
    local host = 'rr1---sn-real.googlevideo.com'
    local h
    for _ = 1, 3 do h = succeed_short_tls(host, 'gv_tcp') end
    H.eq(1, h.z2k_auto_pinned)

    -- Раунд 1 (3 новых провала) -> блокируется, generation обновлён
    for _ = 1, 3 do fail_early_alert(host, 'gv_tcp') end
    H.eq(1, h.nstrategy)
    H.eq(1, h.z2k_ap_fail_rounds)

    -- Нейтральный RST после ServerHello не сбрасывает и не двигает раунды провалов
    local tn = H.track(host)
    local dn = H.tcp(tn, false, 1, H.hello, 'tls_server_hello'); dn.arg.key = 'gv_tcp'
    H.step(dn)
    local dr = H.tcp(tn, false, #H.hello + 1, ''); dr.arg.key = 'gv_tcp'; dr.dis.tcp.th_flags = TH_RST + TH_ACK
    H.step(dr)
    H.eq(1, h.nstrategy)
    H.eq(1, h.z2k_ap_fail_rounds)

    -- Раунд 2 (ещё 3 новых провала в новом generation без успехов) -> снимает auto_pinned и ротирует 1 -> 2
    for _ = 1, 3 do fail_early_alert(host, 'gv_tcp') end
    H.eq(2, h.nstrategy)
    H.eq(nil, h.z2k_auto_pinned)
    local strat, mode = read_tsv_mode('gv_tcp', 'googlevideo.com|4')
    H.eq(2, strat)
    H.eq('auto', mode)
end)

H.test('real zapret-auto: QUIC async timers obey auto_pinned across 2 failure rounds', function()
    local host = 'rr2---sn-quic.googlevideo.com'
    local h
    for _ = 1, 3 do
        local d = H.qstart(H.track(host))
        H.step(d)
        H.step(H.udp(d.track, false, H.quic('initial') .. H.quic('handshake') .. H.quic('short'), nil, 1, 2))
        h = H.step(H.udp(d.track, true, H.quic('short', 'serverid'), nil, 2, 2))
    end
    H.eq(1, h.z2k_auto_pinned)

    -- Раунд 1: 3 QUIC-таймаута -> заблокировано
    for _ = 1, 3 do H.step(H.qstart(H.track(host))) end
    H.advance(6)
    H.eq(1, h.nstrategy)
    H.eq(1, h.z2k_ap_fail_rounds)

    -- Раунд 2: ещё 3 QUIC-таймаута -> разблокировка и ротация 1 -> 2
    for _ = 1, 3 do H.step(H.qstart(H.track(host))) end
    H.advance(6)
    H.eq(2, h.nstrategy)
    H.eq(nil, h.z2k_auto_pinned)
end)

H.test('real zapret-auto: manual frozen pin remains untouched despite failures or successes', function()
    local host = 'frozen.example'
    local f = assert(io.open(STATE_FILE, 'w'))
    f:write('# key\thost\tstrategy\tts\tmode\tsni\n')
    f:write('rkn_tcp\t' .. host .. '|4\t3\t1000\tfrozen\t\n')
    f:close()
    for _ = 1, 10 do fail_early_alert(host, 'rkn_tcp') end
    H.eq(3, autostate['rkn_tcp'][host .. '|4'].nstrategy)
    local strat, mode = read_tsv_mode('rkn_tcp', host .. '|4')
    H.eq(3, strat)
    H.eq('frozen', mode)
end)

H.test('real zapret-auto: >300s gap between failure bursts keeps auto_pinned; panel delete clears it', function()
    local host = 'window.example'
    local h
    for _ = 1, 3 do h = succeed_short_tls(host, 'rkn_tcp') end
    H.eq(1, h.z2k_auto_pinned)

    -- Первый кворум на t=1000
    for _ = 1, 3 do fail_early_alert(host, 'rkn_tcp') end
    H.eq(1, h.nstrategy)
    H.eq(1, h.z2k_ap_fail_rounds)

    -- Спустя >300с одиночный кворум снова считается первым раундом и не ротирует
    H.advance(350)
    for _ = 1, 3 do fail_early_alert(host, 'rkn_tcp') end
    H.eq(1, h.nstrategy)
    H.eq(1, h.z2k_ap_fail_rounds)
    H.eq(1, h.z2k_auto_pinned)

    -- Удаление строки из state.tsv (кнопка × в панели) сбрасывает auto_pinned
    local f = assert(io.open(STATE_FILE, 'w'))
    f:write('# key\thost\tstrategy\tts\tmode\tsni\n')
    f:close()
    H.advance(5)
    fail_early_alert(host, 'rkn_tcp')
    H.eq(nil, h.z2k_auto_pinned)
end)

H.test('real zapret-auto: non-pinned QUIC timeouts reset success streak and nohost stays exempt', function()
    local host = 'rr3---sn-streak.googlevideo.com'
    local h
    for _ = 1, 2 do
        local d = H.qstart(H.track(host))
        H.step(d)
        H.step(H.udp(d.track, false, H.quic('initial') .. H.quic('handshake') .. H.quic('short'), nil, 1, 2))
        h = H.step(H.udp(d.track, true, H.quic('short', 'serverid'), nil, 2, 2))
    end
    H.eq(2, h.z2k_ap_succ)
    H.eq(nil, h.z2k_auto_pinned)

    -- 2 таймерных QUIC-провала до порога обязаны сбросить серию успехов в 0:
    for _ = 1, 2 do H.step(H.qstart(H.track(host))) end
    H.advance(6)
    H.eq(0, h.z2k_ap_succ)
    H.eq(nil, h.z2k_auto_pinned)

    -- Следующий одиночный успех не должен сразу взвести auto_pinned (2 -> 0 -> 1 < 3)
    local d3 = H.qstart(H.track(host))
    H.step(d3)
    H.step(H.udp(d3.track, false, H.quic('initial') .. H.quic('handshake') .. H.quic('short'), nil, 1, 2))
    H.step(H.udp(d3.track, true, H.quic('short', 'serverid'), nil, 2, 2))
    H.eq(1, h.z2k_ap_succ)
    H.eq(nil, h.z2k_auto_pinned)

    -- Пул без имени (hostkey=z2k_nohost_key) исключён даже при успешных сессиях
    for _ = 1, 4 do
        local du = H.udp(H.track(nil), true, 'hello', nil, 1, 0)
        du.track.hostname = nil
        du.arg.key = 'discord_udp'
        du.arg.hostkey = 'z2k_nohost_key'
        H.step(du)
        local ru = H.udp(du.track, false, 'reply', nil, 1, 2)
        ru.arg.key = 'discord_udp'
        ru.arg.hostkey = 'z2k_nohost_key'
        H.step(ru)
    end
    H.eq(true, autostate['discord_udp']['nohost'].z2k_ap_hostless)
    H.eq(nil, autostate['discord_udp']['nohost'].z2k_auto_pinned)
end)

H.finish()
