-- z2k-white-presets.lua
-- Pre-mutated TLS ClientHello payloads с whitelist-SNI для обхода 16KB cap.
--
-- ТСПУ classified соединение по SNI первого ClientHello. Если SNI в whitelist
-- (российские телекомы / госуслуги / dot-ru популярные домены), DPI помечает
-- flow как разрешённый и не применяет 16KB cap.
--
-- Идея: создаём множество **white-variant** payloads на основе fake_default_tls
-- через tls_mod() + sni= override + rnd для уникальности random-field. Каждый
-- variant — глобальная переменная, на которую ссылаются стратегии через
-- :blob=z2k_white_<name> в z2k_flood_white / z2k_white_sandwich / z2k_ttl_ladder.
--
-- Архитектура повторяет init_vars.lua у ALFiX01/GoodbyeZapret —
-- разнообразие масок не даёт ЦСУ заблочить все варианты одной волной.
--
-- Загружается через --lua-init ПОСЛЕ zapret-antidpi.lua (где определена
-- tls_mod()) и ДО strats где blob=z2k_white_* используется. Подключение
-- через S99zapret2.new в LUAOPT chain.

if not tls_mod or not fake_default_tls then
    -- Standalone load / тестовый режим — не падать, просто не создавать
    -- presets. Реальный nfqws2 предоставляет оба символа из zapret-antidpi.lua.
    return
end

-- Каждый preset = `rnd,dupsid,sni=DOMAIN`. `rnd` рандомизирует 32-байтовое
-- random-поле TLS handshake (per-instance уникальность), `dupsid` копирует
-- session ID из реального ClientHello клиента (выглядит как продолжение его
-- сессии), `sni=` подменяет SNI на whitelist-значение.

-- ============== Российский whitelist (приоритет) ==============
z2k_white_max     = tls_mod(fake_default_tls, "rnd,dupsid,sni=web.max.ru")
z2k_white_yandex  = tls_mod(fake_default_tls, "rnd,dupsid,sni=yandex.ru")
z2k_white_mail    = tls_mod(fake_default_tls, "rnd,dupsid,sni=mail.ru")
z2k_white_sber    = tls_mod(fake_default_tls, "rnd,dupsid,sni=sberbank.ru")
z2k_white_vk      = tls_mod(fake_default_tls, "rnd,dupsid,sni=vk.com")
z2k_white_rzd     = tls_mod(fake_default_tls, "rnd,dupsid,sni=rzd.ru")
z2k_white_gosus   = tls_mod(fake_default_tls, "rnd,dupsid,sni=gosuslugi.ru")

-- ============== Зарубежные «вне-санкций» ==============
z2k_white_msn     = tls_mod(fake_default_tls, "rnd,dupsid,sni=msn.com")
z2k_white_google  = tls_mod(fake_default_tls, "rnd,dupsid,sni=www.google.com")
z2k_white_youtube = tls_mod(fake_default_tls, "rnd,dupsid,sni=youtube.com")

DLOG("z2k-white-presets: 10 white-SNI variants loaded")
