-- z2k: поправки к штатному детектору неудач. Все четыре — по замерам на боевом
-- роутере 18.08.2026. Логика bol-van вызывается как есть, мы только сужаем
-- вход, добавляем сигналы и держим политику «живой хост не ротируем».
--
-- 1. РЕТРАНСМИТ СЧИТАЕМ ТОЛЬКО НА ПЕРВОМ ЗАПРОСЕ (ClientHello / HTTP-запрос).
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
-- 6. ПРОВАЛ ЗАСЧИТЫВАЕТСЯ ТОЙ СТРАТЕГИИ, НА КОТОРОЙ СОЕДИНЕНИЕ НАЧАЛОСЬ.
--    Замер 19.08.2026: инстаграм принудительно посажен на заведомо нерабочую
--    седьмую стратегию. Сервер честно ответил `decode_error` на покорёженный
--    ClientHello — 104 фатальных алерта. Ротировать было правильно, но
--    instagram.com по IPv6 за ОДНУ СЕКУНДУ пролистал двенадцать стратегий:
--      failure counter 3/3 -> circular: rotate strategy to 15
--      failure counter 3/3 -> circular: rotate strategy to 16
--      failure counter 3/3 -> circular: rotate strategy to 17
--    Причина в темпе, а не в логике. Страница открывает десятки соединений
--    разом; все они ушли на седьмой и все вернулись с алертом. Каждые три
--    провала — немедленная ротация, а провалы соединений, начатых ещё на
--    седьмой, продолжали капать уже после неё и вешались на стратегии, которые
--    не отправили ни одного пакета. Успехов за это время ноль, гасить счётчик
--    нечем.
--
--    Поэтому соединение помечается номером стратегии при первом же пакете, и
--    провал засчитывается, только если она всё ещё текущая. После ротации
--    счётчик набирается заново — теми соединениями, которые реально пошли на
--    новой стратегии.

-- 5. RST ОТ САМОГО СЕРВЕРА — НЕ ПРОВАЛ.
--    Планка `inseq` у нас поднята до 18-26К намеренно (см. комментарий в
--    lib/config_official.sh): ниже неё не срабатывает штатный success, иначе
--    байтовый гейт ТСПУ на 12-18К объявляется успехом и RST после него
--    становится невидим. Но у bol-van это ОДНА ручка на два смысла, и заодно
--    она объявляет DPI-сбросом ЛЮБОЙ входящий RST до 26 КБ.
--
--    Полевой замер 19.08.2026: apple.com уехал с рабочей первой стратегии на
--    нерабочую вторую. В отладке за 4.5 часа ровно 15 событий детектора, все —
--    incoming RST; 13 из них на s1 подавил гвард живости, а два прошли:
--      standard_failure_detector: incoming RST s7488 in range s26000
--    RST после 7488 доставленных байт — это обычный разрыв со стороны сервера
--    или его балансира, а не DPI: DPI рвёт в начале потока либо на гейте.
--
--    Отличаем по TTL. Инжектированный на пути RST приходит с TTL, который не
--    может принадлежать потоку настоящего сервера: у ТСПУ это два хопа от нас
--    (ttl 126 при данных сервера около полусотни). Запоминаем TTL первого
--    пакета данных и сверяем с ним RST. Совпал — сервер закрылся сам.
--    Не совпал или данных ещё не было — считаем провалом, как раньше, поэтому
--    ни классический сброс на хендшейке, ни гейт на 16К не теряются.

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
-- 4. ВСТАВШИЙ ВХОДЯЩИЙ ПОТОК — ПРОВАЛ. Только пулы видео.
--    LG webOS на заведомо нерабочей 20-й стратегии: соединение к googlevideo
--    поднимается, сервер отдаёт 4482 байта и дальше шлёт один и тот же сегмент
--    15-16 раз, телевизор не подтверждает ни разу. RST нет, FIN нет,
--    исходящих ретрансмитов нет — 676 вызовов детектора и ноль событий, страта
--    стоит вечно, видео не грузится. Штатный детектор смотрит только
--    ИСХОДЯЩИЕ ретрансмиты, входящих не видит вовсе.
--
--    Признак здесь — ИМЕННО ОСТАНОВКА, а не факт повтора. Первая редакция
--    считала любые входящие ретрансмиты в пределах inseq, и 19.08.2026 это
--    увело gv_tcp с первой стратегии на четвёртую без единого реального блока:
--    inseq у gv — 24000, окно перехвата 50 пакетов (~70 КБ), то есть под
--    наблюдением не хендшейк, а первые 24 КБ ВИДЕОПОТОКА. Телевизор, тянущий
--    многомегабитный поток по вайфаю, три потерянных пакета в этом отрезке
--    выдаёт штатно, а gv держит десятки параллельных соединений разом —
--    кворум «три соединения за минуту» набирается на ровном месте.

-- Окно и порог. Окно совпадает с `time=` у circular (60 с по умолчанию):
-- дольше держать нельзя, иначе вчерашние успехи защищают сегодня умерший хост.
-- ── HTTP-классификатор ответов ───────────────────────────────────────────────
--
-- ПЕРЕЕХАЛ СЮДА 26.08.2026 из z2k-detectors.lua, который удалён целиком.
--
-- Тот файл на 1858 строк был мёртв: замер боевого конфига показал, что из него
-- достижима ровно одна функция — эта, и зовёт её z2k_fail_verdict ниже. Все
-- остальные детекторы (z2k_silent_drop_detector, z2k_mid_stream_stall,
-- z2k_tls_stalled и прочие) в конфиг не проводились ни разу; единственное
-- упоминание z2k_mid_stream_stall нашлось В КОММЕНТАРИИ.
--
-- ПОЧЕМУ КЛАССИФИКАТОР НЕ УДАЛЁН ВМЕСТЕ С ФАЙЛОМ. Проба 29 доменов из боевого
-- списка РКН с линии Марка: 19 обычных редиректов, 7 без ответа вовсе, 2 ответа
-- 403 и один 200. Оба 403 прогнаны через эту самую функцию — оба neutral, ни
-- одного hard_fail. Блокировка ТАМ приходит молчанием, а молчание
-- классификатору недоступно: классифицировать нечего.
--
-- Но это ОДНА линия у ОДНОГО провайдера. Там, где провайдер инжектирует
-- страницу-заглушку, эта функция — единственная, кто её видит: штатный детектор
-- смотрит только редирект 302/307. Двести строк не та цена, ради которой стоит
-- терять покрытие, опровергнутое на одном провайдере из всех наших.
-- ---------------------------------------------------------------------------
--
-- Body markers: substrings checked against lowercased response body.
-- These are RU-DPI specific; "blackhole" is included because it appears
-- both as a domain name (blackhole.svyaztelecom.ru) and in some block-page
-- HTML. Generic words like "forbidden"/"warning"/"restrict" are NOT in
-- the body list because they appear on legitimate 4xx pages too.
local Z2K_HTTP_BLOCK_BODY_MARKERS = {
  "rkn", "lawfilter", "zapret", "eais", "blocked-by", "vigruzki", "blackhole",
}

-- Host-prefix markers for cross-SLD redirect detection. Operator block
-- pages commonly live on subdomains like warn.beeline.ru, deny.megafon.ru.
-- These prefixes (with trailing dot — host-anchored) catch operator
-- redirect targets without firing on legitimate URLs containing the
-- bare word in path/query.
-- Leading-label-anchored (sub(1,#p)==p, every entry ends in "."). Inflected
-- forms added 2026-05-30 (review w7kkh0yb7): "warn." alone MISSED the single
-- most common RU stub warning.rt.ru (Ростелеком) — "warning" is one label with
-- no dot after "warn"; same for restricted./blocking./blockpage. A host that
-- STARTS with these is a block portal (legit sites don't), so leading-anchored
-- prefixes are low-FP. (Bare generic words stay OUT of the body list — they
-- appear on legit 4xx pages.)
local Z2K_HTTP_BLOCK_HOST_PREFIXES = {
  "warn.", "warning.", "deny.", "restrict.", "restricted.", "block.",
  "blocked.", "blocking.", "blockpage.", "blackhole.", "forbidden.",
}

-- Server-side WAF response headers — signal that the SERVER (not DPI on
-- path) actively rejected the request. Each entry is {lowered_header,
-- lowered_value_substring}. Match fires when the header is present AND
-- its lowered value contains the substring.
--
-- Initial conservative list — only signals confirmed in the wild as
-- pure server-side enforcement, NOT mixable with DPI imitation:
--   x-vercel-mitigated: deny     (Vercel WAF hard block)
--
-- Additional headers gated behind Z2K_WAF_MARKERS_AGGRESSIVE=1 env
-- because they can fire on legitimate per-request CF challenges or
-- Sucuri rate-limit pages that the user is supposed to retry through;
-- counting those as server-active would skip bypass attempts that
-- ARE worth trying.
local Z2K_HTTP_WAF_HEADERS_CORE = {
  { "x-vercel-mitigated", "deny" },
}
local Z2K_HTTP_WAF_HEADERS_AGGRESSIVE = {
  { "x-vercel-mitigated", "deny" },
  { "cf-mitigated", "challenge" },
  { "cf-mitigated", "block" },
  { "x-sucuri-block", "" },
}
local Z2K_HTTP_WAF_HEADERS =
  (os.getenv("Z2K_WAF_MARKERS_AGGRESSIVE") == "1")
    and Z2K_HTTP_WAF_HEADERS_AGGRESSIVE
    or  Z2K_HTTP_WAF_HEADERS_CORE

-- Sanitize a reason_detail string for safe inclusion in debug.log lines.
-- Keep ASCII alphanumeric + dot/dash/equals/colon/underscore; replace
-- everything else (CRLF, spaces, tabs, non-ASCII, raw URL chars) with
-- underscore. Cap length at 64 chars to avoid log bloat. This prevents
-- log injection from attacker-controlled Location URLs / response bodies.
local function z2k_sanitize_reason(s)
  if type(s) ~= "string" then return "" end
  if #s > 64 then s = s:sub(1, 64) end
  return (s:gsub("[^A-Za-z0-9._:=-]", "_"))
end

local function z2k_find_body_marker(payload_lower)
  for _, m in ipairs(Z2K_HTTP_BLOCK_BODY_MARKERS) do
    if payload_lower:find(m, 1, true) then return m end
  end
  return nil
end

local function z2k_find_host_marker(host_lower)
  -- Match a block marker as a COMPLETE dot-delimited domain label, NOT a bare
  -- substring. Operator/RKN block pages carry the marker as a real label
  -- (lawfilter.ertelecom.ru, eais.rkn.gov.ru, blackhole.svyaztelecom.ru), so
  -- label-anchoring keeps real coverage while killing the false-positive a bare
  -- substring scan produced: short markers matched INSIDE legitimate hostnames
  -- ("rkn" inside spa-rkn-otes.com, "eais" inside id-eais.com), which then
  -- counted a legit cross-SLD redirect as a DPI block and rotated the strategy
  -- needlessly. (Stage 1 review w4h4x4bif flagged this; Этап 4 fix.)
  local padded = "." .. host_lower .. "."
  for _, m in ipairs(Z2K_HTTP_BLOCK_BODY_MARKERS) do
    if padded:find("." .. m .. ".", 1, true) then return m end
  end
  -- Host-prefix markers (warn.beeline.ru, deny.megafon.ru, etc).
  for _, p in ipairs(Z2K_HTTP_BLOCK_HOST_PREFIXES) do
    if host_lower:sub(1, #p) == p then return "prefix:" .. p end
  end
  -- CGNAT captive-portal redirect target (review w7kkh0yb7): an operator
  -- DNS-poison / 302 to a literal 100.64.0.0/10 (carrier-grade NAT) address is
  -- a block portal, never a real cross-SLD destination. Match the /10 range
  -- exactly (2nd octet 64-127) — NOT a raw "100." prefix, which would
  -- false-positive on public 100.x addresses.
  local o2 = host_lower:match("^100%.(%d+)%.")
  if o2 then
    local n = tonumber(o2)
    if n and n >= 64 and n <= 127 then return "cgnat:100.64/10" end
  end
  return nil
end

-- Scan dissected HTTP reply headers for server-side WAF rejection
-- markers. `headers` is the array returned by http_dissect_reply with
-- {header, header_low, value} items. Returns "header:value-substring"
-- on match (used as reason suffix), nil otherwise.
local function z2k_find_waf_header(headers)
  if type(headers) ~= "table" then return nil end
  for _, want in ipairs(Z2K_HTTP_WAF_HEADERS) do
    local want_header, want_value = want[1], want[2]
    for _, h in ipairs(headers) do
      if type(h) == "table" and h.header_low == want_header then
        local v = type(h.value) == "string" and h.value:lower() or ""
        if want_value == "" or v:find(want_value, 1, true) then
          return want_header .. ":" .. (want_value ~= "" and want_value or v:sub(1, 24))
        end
      end
    end
  end
  return nil
end

-- Extract host from Location header value, lowercased. Handles three
-- forms:
--   1. absolute URL    "https://example.com/path"  → use dissect_url
--   2. scheme-relative "//example.com/path"        → manual parse
--                       (dissect_url misses these — its regex is
--                       `[a-z]+://` which doesn't match `//host`)
--   3. path-only       "/some/path"                → returns nil
--                       (no host change, same-origin redirect)
-- Strip `:port` suffix from a hostname (mirrors dissect_url's domain
-- extraction at zapret-lib.lua:1816-1821). Apply before SLD comparison
-- so example.com:443 == example.com.
local function z2k_strip_port(host)
  if type(host) ~= "string" then return host end
  return (host:gsub(":%d+$", ""))
end

local function z2k_extract_loc_host(location)
  if type(location) ~= "string" or location == "" then return nil end
  if location:sub(1, 2) == "//" then
    local host = location:match("^//([^/?#]+)")
    if not host then return nil end
    return z2k_strip_port(host):lower()
  end
  if type(dissect_url) == "function" then
    local ds = dissect_url(location)
    if ds and ds.domain then return ds.domain:lower() end
  end
  return nil
end

-- z2k_classify_http_reply(desync) — shared HTTP-reply classifier.
--
-- Returns:
--   "positive", nil                  — real-success response (2xx, 304,
--                                       same-SLD 3xx upgrade)
--   "neutral",  reason_string        — suspicious/ambiguous response
--                                       (4xx/5xx no marker, cross-SLD 3xx
--                                       no marker, unparseable redirect)
--   "hard_fail", reason_string       — confirmed block (4xx/5xx with body
--                                       marker; cross-SLD 3xx with host
--                                       marker or block-prefix)
--   "server_active_reject", reason   — server itself rejected (bare 451
--                                       без RKN markers = RFC 7725 origin
--                                       compliance; 4xx с WAF response
--                                       header = server WAF, не DPI).
--                                       Не fail (bypass не поможет) и не
--                                       success (бэкап-роутинг бессмыслен) —
--                                       autocircular skip-rotation gate.
--   nil, nil                         — not applicable (not http_reply,
--                                       no payload, no parseable code)
function z2k_classify_http_reply(desync)
  if not desync or desync.outgoing then return nil, nil end
  if desync.l7payload ~= "http_reply" then return nil, nil end
  local payload = desync.dis and desync.dis.payload
  if type(payload) ~= "string" then return nil, nil end

  local code_s = payload:match("^HTTP/%d%.%d%s+([0-9][0-9][0-9])")
  local code = tonumber(code_s)
  if not code then return nil, nil end

  -- 2xx and 304 = real positive
  if code >= 200 and code < 300 then return "positive", nil end
  if code == 304 then return "positive", nil end

  -- 4xx / 5xx — dissect once for body + headers (WAF marker scan и
  -- body marker scan делят один parse).
  --
  -- IMPORTANT: body marker scan читает только BODY, не headers. Per RFC
  -- 7725 a legitimate 451 from origin/CDN may carry `Link: <authority>;
  -- rel="blocked-by"` header — substring "blocked-by" в нашем
  -- body-marker списке. WAF header scan — отдельный list (X-Vercel-*,
  -- cf-mitigated, X-Sucuri-Block), не пересекается с body markers.
  if code >= 400 and code < 600 then
    local body = ""
    local hdis = nil
    if type(http_dissect_reply) == "function" then
      hdis = http_dissect_reply(payload)
      if hdis and hdis.body then body = hdis.body end
    end
    -- Fallback: separate body manually at first blank-line if dissector
    -- is unavailable / returned no body field.
    if body == "" then
      local sep = payload:find("\r\n\r\n", 1, true)
      if sep then body = payload:sub(sep + 4) end
    end

    local low = body ~= "" and body:lower() or ""
    local rkn_marker = low ~= "" and z2k_find_body_marker(low) or nil

    -- 451 split: RKN body marker → hard_fail (наш RKN). Bare 451 (no
    -- marker) was previously classified as server_active_reject, but
    -- we treat this as Hot — origin geo-compliance MAY be
    -- bypassable by changing egress fingerprint (different SNI / fake
    -- TLS hello), so autocircular keeps rotating.
    if code == 451 then
      if rkn_marker then
        return "hard_fail", "http_4xx_marker:" .. z2k_sanitize_reason(rkn_marker)
      end
      return "neutral", "http_451_no_marker"
    end

    -- WAF response headers (Vercel/CF/Sucuri) used to be classified as
    -- server_active_reject. Same rationale as bare 451:
    -- packet-level fingerprint masking can sometimes evade WAF
    -- signature matching, so let autocircular rotate before giving up.
    if hdis and hdis.headers then
      local waf = z2k_find_waf_header(hdis.headers)
      if waf then
        return "neutral", "waf_header:" .. z2k_sanitize_reason(waf)
      end
    end

    if body == "" then
      return "neutral", "http_4xx_no_body:code=" .. tostring(code)
    end
    if rkn_marker then
      return "hard_fail", "http_4xx_marker:" .. z2k_sanitize_reason(rkn_marker)
    end
    return "neutral", "http_4xx_no_marker:code=" .. tostring(code)
  end

  -- 3xx — Location parse + cross-SLD check
  if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
    if type(http_dissect_reply) ~= "function" or
       type(array_field_search) ~= "function" then
      return "neutral", "http_redirect_no_dissector"
    end
    local hdis = http_dissect_reply(payload)
    if not hdis then return "neutral", "http_redirect_unparseable" end
    local idx = array_field_search(hdis.headers, "header_low", "location")
    if not idx then return "neutral", "http_redirect_no_location" end
    local loc_host = z2k_extract_loc_host(hdis.headers[idx].value)
    if not loc_host then
      -- Path-only or unparseable Location — same-origin redirect, treat
      -- as positive (the request handshake succeeded; redirect is just
      -- application-level navigation).
      return "positive", nil
    end
    local req_host = desync.track and desync.track.hostname
    if not req_host then return "neutral", "http_redirect_no_req_host" end
    -- Defensive port-strip: HTTP Host header may carry port even though
    -- nfqws2 dissector usually normalises it. Cheap to apply, prevents
    -- a same-origin redirect to host:port being misclassified cross-SLD.
    local req_lower = z2k_strip_port(req_host:lower())
    local req_sld = type(dissect_nld) == "function" and dissect_nld(req_lower, 2) or req_lower
    local loc_sld = type(dissect_nld) == "function" and dissect_nld(loc_host, 2) or loc_host
    if req_sld and loc_sld and req_sld == loc_sld then
      -- Same-SLD redirect = legit (HTTP→HTTPS upgrade, vanity URL,
      -- internal app routing). Strategy did its job — handshake worked.
      return "positive", nil
    end
    -- Cross-SLD — check if loc_host carries a block marker
    local marker = z2k_find_host_marker(loc_host)
    if marker then
      return "hard_fail", "http_redirect_marker:" .. z2k_sanitize_reason(marker)
    end
    return "neutral", "http_redirect_cross_sld_no_marker"
  end

  -- 1xx informational, 3xx other (300/305/306/...), unknown — neutral.
  return "neutral", "http_other_code:code=" .. tostring(code)
end

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
--
-- Окно отсчитывается от ПЕРВОГО успеха в серии, а не от последнего. Сброс по
-- давности последнего пакета окном не является: на хосте с непрерывным
-- трафиком каждый пакет отодвигает срок, счётчик не обнуляется никогда, и
-- получается «три успеха когда-либо плюс один пакет за минуту». Тогда хост,
-- который час назад работал, а сейчас режется, держит гвард взведённым вечно —
-- ровно то, что в шапке названо недопустимым.
-- Форвард-декларация: strategy_current определён ниже, рядом с note_strategy,
-- но нужен уже здесь. Без неё имя ушло бы в ГЛОБАЛЬНУЮ таблицу и вернуло nil —
-- ошибка была бы рантаймовой, то есть невидимой и для luac, и для тестов,
-- которые зовут только host_alive.
local strategy_current

local function note_alive(desync, crec, is_fatal_alert)
	if is_fatal_alert then return end
	local p = desync.dis and desync.dis.payload
	if not p or #p == 0 then return end
	-- ОДНО СОЕДИНЕНИЕ = ОДНО ДОКАЗАТЕЛЬСТВО.
	--
	-- Считался каждый входящий пакет, поэтому три сегмента ОДНОГО ответа
	-- взводили гвард, а он дальше глушил провалы параллельных соединений:
	-- ретрансмит ClientHello, ранний RST и фатальный алерт. Порог выше
	-- обоснован как «три живых ОТВЕТА», а не «три пакета» — приводим
	-- реализацию к тому, что в нём написано. Без crec (движок не дал запись
	-- соединения) считаем как раньше: ослепить детектор хуже, чем пересчитать.
	if crec then
		if crec.z2k_alive_seen then return end
	end
	-- Успех соединения, начатого на ПРЕЖНЕЙ стратегии, ничего не говорит о
	-- нынешней. Проверка стояла только на провалах (strategy_current ниже),
	-- и из-за этой асимметрии запоздалый ответ старого flow защищал страту,
	-- через которую он не проходил.
	if not strategy_current(desync, crec) then return end
	local hrec = host_record(desync)
	if not hrec then return end
	local now = os.time()
	-- Счётчик привязан к НОМЕРУ стратегии. Раньше привязки не было вовсе:
	-- после ротации доказательства, набранные на старой страте, продолжали
	-- гасить провалы новой все 60 секунд окна.
	if hrec.z2k_ok_nstrat ~= hrec.nstrategy then
		hrec.z2k_ok_n = 0
		hrec.z2k_ok_start = now
		hrec.z2k_ok_nstrat = hrec.nstrategy
	end
	if not hrec.z2k_ok_start or (now - hrec.z2k_ok_start) > Z2K_OK_WINDOW then
		hrec.z2k_ok_n = 0
		hrec.z2k_ok_start = now
	end
	hrec.z2k_ok_n = hrec.z2k_ok_n + 1
	hrec.z2k_ok_last = now
	if crec then crec.z2k_alive_seen = true end
end

-- true, если хост прямо сейчас доказал, что работает.
local function host_alive(desync)
	local hrec = host_record(desync)
	if not hrec or not hrec.z2k_ok_start then return false end
	-- Доказательства другой стратегии не в счёт — см. note_alive.
	if hrec.z2k_ok_nstrat ~= hrec.nstrategy then
		hrec.z2k_ok_n = 0
		return false
	end
	if (os.time() - hrec.z2k_ok_start) > Z2K_OK_WINDOW then
		hrec.z2k_ok_n = 0
		return false
	end
	return (hrec.z2k_ok_n or 0) >= Z2K_OK_MIN
end

-- Пулы, где вставший входящий поток считается провалом.
--
-- РКН включён 19.08.2026. До этого он был исключён намеренно, и причина в
-- комментарии стояла такая: на одном хосте живут и API-ответы в пару
-- килобайт, и страницы, и рвать рабочую страту из-за одного залипшего
-- соединения нельзя. Но это была претензия к ПЕРВОЙ редакции правила, которая
-- считала провалом любой входящий ретрансмит — то есть любую потерю пакета.
-- Ровно она в тот же день увела gv_tcp с первой стратегии на четвёртую.
-- Нынешняя редакция требует шесть повторов ОДНОГО сегмента без единого
-- продвижения вперёд, даёт одно событие на соединение, и на ротацию нужно три
-- соединения. Потеря пакета такого не набирает.
--
-- Зачем это РКН. `inseq` там поднят до 26000 ради байтового гейта ТСПУ, но
-- сам гейт он не ЛОВИТ — только не даёт объявить успех раньше него. Если гейт
-- рвёт поток тихо, без RST и FIN, у профиля не остаётся ни одного события, и
-- заблокированный сайт стоит на нерабочей стратегии вечно. Это правило —
-- единственный сигнал на такой случай.
local Z2K_RETRANS_POOLS = { yt_tcp = true, gv_tcp = true, rkn_tcp = true }
-- Сколько раз подряд сервер должен повторить ОДИН И ТОТ ЖЕ сегмент, ни разу
-- не продвинув поток вперёд, чтобы считать поток вставшим. Полевой замер
-- 18.08.2026, LG webOS на заведомо нерабочей 20-й стратегии: на КАЖДОМ
-- соединении к googlevideo сервер слал один и тот же seq 15-16 раз, телевизор
-- не подтверждал ни разу, RST и FIN не приходили вовсе. Шесть — с запасом ниже
-- замеренных пятнадцати и заведомо выше здорового потока: там потеря головного
-- сегмента лечится одним-двумя повторами, после чего идут НОВЫЕ данные, и
-- счётчик обнуляется.
local Z2K_RETRANS_MIN = 6

-- Провал по вставшему входящему потоку. Считаем по СОЕДИНЕНИЮ (crec), а не по
-- хосту: залипает именно поток, и пятнадцать повторов в нём — законченное
-- событие.
--
-- Гвард по живости сюда намеренно не применяется. Такое соединение как раз и
-- отдаёт первые килобайты данных, то есть по меркам гварда хост «живой» —
-- и настоящий провал был бы подавлен своим же ответом. Для пулов видео живость
-- определяется не байтами, а тем, едет ли поток дальше.
local function incoming_retrans_failure(desync, crec)
	if not crec then return false end
	if not Z2K_RETRANS_POOLS[desync.arg.key] then return false end

	-- Клиент закрылся раньше — считать нечего. Замер 30.08.2026, ловушка на
	-- facebook.com|6: при НАСТОЯЩЕЙ блокировке клиент молчит и ждёт, а FIN шлёт
	-- лишь через четырнадцать секунд ПОСЛЕ того, как вердикт уже вынесен. То
	-- есть боевые срабатывания этот гвард не глушит, а брошенное соединение —
	-- где FIN идёт ПЕРВЫМ, и уже потом сервер долбит закрытый сокет — перестаёт
	-- набивать ротатору провалы и уводить рабочую стратегию.
	if crec.z2k_cli_closed then return false end

	local p = desync.dis.payload
	-- Чистые ACK данных не несут, повторами их считать нечего.
	if not p or #p == 0 then return false end

	-- Тот же признак, которым движок ловит ИСХОДЯЩИЕ ретрансмиты: позиция
	-- пакета не выше уже виденного максимума. Своего счёта позиций не заводим,
	-- иначе разойдёмся с движком на переупорядоченных и частично перекрытых
	-- сегментах.
	--
	-- ПОТОК ПОЕХАЛ — залипания нет, счёт начинаем заново. Это и есть развилка
	-- между «сервер долбит мёртвый сегмент» и «по дороге потерялся пакет»:
	-- во втором случае за повтором приходят новые данные.
	if not is_retransmission(desync) then
		crec.z2k_stall_pos = nil
		crec.z2k_in_retrans = 0
		return false
	end

	-- Поток, пробивший планку успеха, ротировать не за что: страта своё дело
	-- сделала, а повторы там — обычная потеря пакетов по дороге.
	local s = pos_get(desync, 's') or 0
	local bar = tonumber(desync.arg.inseq) or 0
	if bar > 0 and s >= bar then return false end

	-- Повтор ДРУГОГО сегмента: сервер отъехал назад по окну, а не долбит одно
	-- место. Считаем это новой попыткой, а не продолжением прежней серии.
	if crec.z2k_stall_pos ~= s then
		crec.z2k_stall_pos = s
		crec.z2k_in_retrans = 1
		return false
	end

	-- Одно соединение — одно событие. Дальше порога не считаем: сервер долбит
	-- мёртвый поток по пятнадцать раз, и без этого стопа он в одиночку набирает
	-- ротатору всю норму провалов, уводя страту, которая для остальных
	-- соединений работает. Тот же стоп стоит у bol-van в штатном детекторе
	-- (`(crec.retrans or 0) < arg.retrans`, lua/zapret-auto.lua).
	if (crec.z2k_in_retrans or 0) >= Z2K_RETRANS_MIN then return false end

	crec.z2k_in_retrans = crec.z2k_in_retrans + 1
	if crec.z2k_in_retrans < Z2K_RETRANS_MIN then return false end

	DLOG("z2k_fail_tls_alert: входящий поток встал на s" .. s .. ", повтор " ..
	     crec.z2k_in_retrans .. "/" .. Z2K_RETRANS_MIN .. " без продвижения -> failure")
	return true
end

-- TTL пакета: подпись пути, по которому он пришёл.
local function packet_ttl(desync)
	local d = desync.dis
	if not d then return nil end
	if d.ip and d.ip.ip_ttl then return d.ip.ip_ttl end
	if d.ip6 and d.ip6.ip6_hlim then return d.ip6.ip6_hlim end
	return nil
end

-- Разброс TTL внутри одного потока. Ноль ставить нельзя: у крупных CDN ответы
-- приходят с разных машин балансира, путь отличается на хоп-другой.
local Z2K_TTL_TOLERANCE = 2

-- Эталон берём с ПЕРВОГО пакета данных: он заведомо от настоящего сервера,
-- инжектировать данные DPI не станет — он рвёт.
local function note_server_ttl(desync, crec)
	if not crec or crec.z2k_srv_ttl then return end
	local p = desync.dis and desync.dis.payload
	if not p or #p == 0 then return end
	crec.z2k_srv_ttl = packet_ttl(desync)
end

-- Вердикт по входящему провалу, который нашёл штатный детектор:
--   "server" — RST пришёл тем же путём, что и данные: сервер закрылся сам;
--   "block"  — либо RST с чужим TTL (инжект), либо вовсе не RST (DPI-редирект);
--   nil      — судить не по чему, решает гвард живости.
--
-- Почему "block" обязан идти МИМО гварда живости. Гвард считает живым любой
-- непустой ответ, а оба этих класса блокировки как раз и приходят ПОСЛЕ
-- нормальных данных:
--   * байтовый гейт ТСПУ — ради него планка inseq и поднята до 26К — рвёт
--     соединение на 12-18 КБ, то есть после десятков «живых» пакетов. С
--     гвардом впереди он не даёт события никогда, и планка стоит впустую;
--   * страница-заглушка в HTTP-пуле — тоже непустой ответ, и три соединения
--     подряд успевают взвести гвард раньше, чем наберётся порог провалов.
-- Инжект и редирект — доказательства блокировки сами по себе, живость хоста
-- их не отменяет.
local function incoming_reset_verdict(desync, crec)
	local tcp = desync.dis and desync.dis.tcp
	if not tcp or not tcp.th_flags or not TH_RST then return nil end
	-- Не RST — значит DPI-редирект. Мимо гварда его пускать НЕЛЬЗЯ:
	-- is_dpi_redirect (zapret-auto.lua:108) считает редиректом ЛЮБОЙ ответ,
	-- где SLD цели не совпал с SLD запроса, без всякой проверки на страницу-
	-- заглушку. На восьмидесятом порту такие редиректы законны сплошь и рядом
	-- — сокращатели ссылок, передача на CDN другого домена, OAuth. Ложное
	-- срабатывание тут стоит рабочей стратегии, а самоподавление настоящего
	-- редиректа закрыто иначе: провальный пакет больше не считается «живым»
	-- ответом (см. порядок вызовов в z2k_fail_tls_alert).
	if bitand(tcp.th_flags, TH_RST) == 0 then return nil end

	-- Эталона нет: данных сервер ещё не присылал. Это классический DPI-сброс
	-- на хендшейке, но ровно так же выглядит и поддельный RST на живом хосте,
	-- поэтому оставляем решение гварду живости.
	if not crec or not crec.z2k_srv_ttl then return nil end

	local t = packet_ttl(desync)
	if not t then return nil end
	local d = t - crec.z2k_srv_ttl
	if d < 0 then d = -d end
	if d > Z2K_TTL_TOLERANCE then
		DLOG("z2k_fail_tls_alert: RST с TTL " .. t .. " при данных сервера TTL " ..
		     crec.z2k_srv_ttl .. " — инжект, провал независимо от живости хоста")
		return "block"
	end
	DLOG("z2k_fail_tls_alert: RST с TTL " .. t .. " при данных сервера TTL " ..
	     crec.z2k_srv_ttl .. " — разрыв со стороны сервера, не провал")
	return "server"
end

-- Номер стратегии, под которым соединение началось. Ставится на первом же
-- пакете, до любых проверок: если пометить позже, соединение, чей провал
-- доехал уже после ротации, унаследует НОВЫЙ номер и отфильтровано не будет.
local function note_strategy(desync, crec)
	if not crec or crec.z2k_nstrat then return end
	local hrec = host_record(desync)
	if hrec and hrec.nstrategy then crec.z2k_nstrat = hrec.nstrategy end
end

-- false, если стратегия под соединением уже сменилась. Без пометки или без
-- host-записи не судим: лучше засчитать лишний провал, чем ослепить детектор.
strategy_current = function(desync, crec)
	if not crec or not crec.z2k_nstrat then return true end
	local hrec = host_record(desync)
	if not hrec or not hrec.nstrategy then return true end
	return crec.z2k_nstrat == hrec.nstrategy
end

local function suppressed(desync, why)
	if host_alive(desync) then
		DLOG("z2k_fail_tls_alert: " .. why .. " подавлен — хост отвечает живьём в текущем окне")
		return true
	end
	return false
end

-- Первый запрос клиента в соединении: до ответа сервера его ретрансмит
-- действительно означает, что запрос не дошёл. Пул HTTP работает с http_req,
-- пулы TLS — с tls_client_hello; всё остальное это уже живая сессия.
local Z2K_FIRST_REQUEST = { tls_client_hello = true, http_req = true }

-- ОБРЫВ ПОТОКА ПОСРЕДИ TLS-ЗАПИСИ.
--
-- Класс блокировки: рукопожатие проходит, ответ идёт, и на 12-24 КБ гейт
-- глушит поток. Ни одно наше правило его не видит: FIN и RST в этом классе
-- НЕ ПРИХОДЯТ ВОВСЕ (полевой замер на LG webOS: сервер слал один seq 15-16
-- раз, RST и FIN не приходили), а входящих повторов может не быть — сервер
-- иногда просто замолкает. Поймать можно только по молчанию, то есть таймером.
--
-- ПОЧЕМУ ОДНОГО ТАЙМЕРА МАЛО. Молчание после ответа в 20 КБ — это ещё и
-- обычный keep-alive завершённого ответа. По таймеру они неотличимы, и мы
-- ловили бы ложняк на ровном месте.
--
-- РАЗДЕЛИТЕЛЬ — КАДРИРОВАНИЕ TLS, ПОДТВЕРЖДЁН ЗАМЕРОМ. Дамп зависшего
-- hetzner.com (30.08, 19 сегментов, 22286 байт): последняя запись объявила
-- 16401 байт, доехало 2309, не хватило 14092. Завершённый ответ ВСЕГДА
-- кончается на границе записи, усечённый — нет. Отсюда и «16 КБ»: сервер
-- шлёт записи по 16401 байт, гейт режет внутри такой записи.
--
-- ТРЕТЬЕ УСЛОВИЕ, БЕЗ КОТОРОГО ВСЁ ЛОЖНО. До нас доезжает только первые
-- ~26.8 КБ ответа — потолок ставит iptables connbytes reply 1:50. У здоровой
-- большой загрузки пакеты после него просто перестают приходить, трекер
-- остаётся посреди записи, и таймер выдал бы обрыв на КАЖДОМ большом файле.
-- Поэтому взводимся только пока uppos ниже Z2K_STALL_MAX, а выше — снимаем.
--
-- Мерим по pos.server.tcp.uppos (высшая отметка реальных данных), а НЕ по
-- pbcounter: тот считает и повторы, на вставшем потоке набежит 20+ КБ при
-- реальных 16.
local Z2K_STALL_MIN = tonumber(os.getenv("Z2K_STALL_MIN")) or 12288
local Z2K_STALL_MAX = tonumber(os.getenv("Z2K_STALL_MAX")) or 24000
local Z2K_STALL_MS  = tonumber(os.getenv("Z2K_STALL_MS"))  or 4000
-- Отдельное окно на рукопожатие: длиннее тишины в потоке, сюда входит вся
-- дорога до сервера и обратно.
local Z2K_STALL_HS_MS = tonumber(os.getenv("Z2K_STALL_HS_MS")) or 7000
-- Потолок перебора на хост. Каждый кандидат стоит одной неудачной попытки
-- открыть сайт, поэтому список из 188 имён целиком не гоняем: на линии
-- владельца первое рабочее имя было пятым, у автора dpi-detector три рабочих
-- имени находились в пределах первых десятков.
local Z2K_SNI_TRIES = tonumber(os.getenv("Z2K_SNI_TRIES")) or 24
-- Сколько провалов подряд терпит УЖЕ ДОКАЗАВШЕЕ себя имя, прежде чем мы
-- признаем его негодным и вернёмся к перебору.
local Z2K_SNI_PROVEN_FAILS = tonumber(os.getenv("Z2K_SNI_PROVEN_FAILS")) or 3
-- Сколько неудачных рукопожатий подряд нужно, чтобы ВООБЩЕ начать подбор.
-- Одного мало: сразу после перезапуска ни один хост ещё не отмечен живым, и
-- любая случайная неудача первого коннекта запускала перебор рабочему сайту.
local Z2K_SNI_START_FAILS = tonumber(os.getenv("Z2K_SNI_START_FAILS")) or 2
-- Насколько дальше последнего разобранного байта должен оказаться закрывающий
-- пакет, чтобы считать, что поток ехал за нашим горизонтом. Одна TLS-запись
-- бывает до 16 КБ, поэтому планка выше неё: меньший отрыв объясняется и
-- обычным дописыванием хвоста.
local Z2K_STALL_JUMP = tonumber(os.getenv("Z2K_STALL_JUMP")) or 20000
-- Сколько хост считается живым после последней реальной доставки данных.
-- Совпадает с окном контент-гейта в движке: та же величина, тот же смысл.
local Z2K_ALIVE_WINDOW = tonumber(os.getenv("Z2K_ALIVE_WINDOW")) or 300
local Z2K_STALL_POOLS = { rkn_tcp = true, yt_tcp = true, gv_tcp = true }

-- Машинка кадрирования. Запись делится между пакетами, в пакете бывает
-- несколько записей, пятибайтовый заголовок тоже делится — поэтому состояние,
-- а не разбор одного пакета.
function z2k_tls_frame_feed(st, p)
	local i, n = 1, #p
	while i <= n do
		if (st.need or 0) > 0 then
			local take = st.need
			if take > n - i + 1 then take = n - i + 1 end
			st.need = st.need - take
			i = i + take
		else
			local have = st.hdr and #st.hdr or 0
			local take = 5 - have
			if take > n - i + 1 then take = n - i + 1 end
			st.hdr = (st.hdr or "") .. p:sub(i, i + take - 1)
			i = i + take
			if #st.hdr == 5 then
				st.need = st.hdr:byte(4) * 256 + st.hdr:byte(5)
				st.hdr = nil
			end
		end
	end
end

-- Обработчик таймера. Контекста у него НЕТ: ни desync, ни ctx (движок зовёт
-- его из главного цикла с двумя аргументами). Всё нужное лежит в data живыми
-- ссылками: st — таблица в lua_state потока, hrec — запись хоста в autostate.
-- Хост ответил: он жив, а имя, с которым это вышло, себя доказало.
--
-- Разделение «доказанное имя» и «имя-кандидат» нужно из-за перезапуска. Раньше
-- в файл уезжало ЛЮБОЕ имя, включая неудачных кандидатов, а после рестарта
-- памяти нет: одна неудачная попытка — и найденное имя выбрасывалось, перебор
-- начинался с первого кандидата. Замер 30.08.2026: hetzner с уже найденным
-- 300.ya.ru после рестарта ушёл на hcaptcha.com и снова прошёл весь путь.
function z2k_sni_proven(hrec)
	if not hrec then return end
	hrec.z2k_alive_at = os.time()
	hrec.z2k_hs_fails = 0
	if hrec.z2k_sni then
		hrec.z2k_sni_ok = true
		hrec.z2k_sni_fails = 0
	end
end

-- Сдвиг на следующего кандидата. Доказанное имя за один провал не отдаём:
-- у любого рабочего сайта случается неудачный коннект, а цена ошибки —
-- полный перебор заново, до двух десятков неудачных загрузок у человека.
local function z2k_sni_advance(hrec)
	if hrec.z2k_sni_ok then
		local f = (hrec.z2k_sni_fails or 0) + 1
		hrec.z2k_sni_fails = f
		if f < Z2K_SNI_PROVEN_FAILS then return hrec.z2k_sni end
		hrec.z2k_sni_ok = false
	end
	return z2k_sni_next(hrec)
end

function z2k_stall_timer(name, data)
	local st = data and data.st
	local hrec = data and data.hrec
	if not st or not hrec then return end
	if st.judged then return end

	-- ПОТОК УШЁЛ ЗА ГОРИЗОНТ — и это ДОКАЗАТЕЛЬСТВО, а не помеха.
	--
	-- Горизонт меряется в ПАКЕТАХ (`--connbytes 1:N ... dir reply`), не в
	-- байтах, поэтому в байтах он плавающий: instagram отдал 404 КБ, из них
	-- видно 17 КБ на пятидесяти пакетах. Раньше отсюда следовал только запрет
	-- судить. Но у сторожа расширен диапазон (`--in-range=a-`), и он видит
	-- закрывающий пакет потока даже далеко за горизонтом кадрирования. Если тот
	-- пришёл с позицией много дальше последнего разобранного байта — поток
	-- ЕХАЛ, пока мы не смотрели. Это разом отвечает на оба вопроса: хост жив, и
	-- имя, с которым это вышло, себя оправдало.
	--
	-- Обратное тоже важно: потолок САМ ПО СЕБЕ имя не оправдывает. Замер
	-- 30.08.2026 — hcaptcha.com попал в файл как «доказанное» только потому,
	-- что поток успел набрать килобайты и упереться в потолок, хотя сайт не
	-- открывался вовсе.
	if (st.hi_seen or 0) >= (st.high or 0) + Z2K_STALL_JUMP then
		st.judged = true
		z2k_sni_proven(hrec)
		return
	end

	-- Упёрлись в потолок, а доказательства продолжения нет: судить не по чему.
	-- Живость отмечаем — байты были, — но имя не оправдываем.
	-- Запас в шесть пакетов — на ответные пакеты, которые до нашего инстанса не
	-- доходят (отсеяны фильтром профиля), но потолок расходуют.
	if (st.cap or 0) > 0 and (st.rx or 0) >= (st.cap - 6) then
		if (st.high or 0) >= 1024 then hrec.z2k_alive_at = os.time() end
		return
	end

	-- ИСХОД ПЕРВЫЙ: рукопожатие не состоялось. Раньше мы ждали именно обрыва
	-- объёма, и из-за этого механизм не запускался вовсе там, где хост валится
	-- ещё на hello — а это ровно случай hetzner на первом плече. Полагаться на
	-- то, что ротация сперва уведёт хост на плечо, где обрыв виден, нельзя:
	-- имя из белого списка снимает инспекцию ЦЕЛИКОМ и чинит оба случая, так
	-- что ждать чужой помощи механизму незачем.
	--
	-- Здесь же ловится и обратное: неподходящее имя делает ХУЖЕ, чем его
	-- отсутствие. Замер на роутере: без имени 15994 байта, с чужим hcaptcha.com
	-- ноль. Без этого исхода перебор вставал намертво — данных нет, значит нет
	-- и обрыва, значит следующее имя не берётся никогда.
	if (st.high or 0) < 1024 then
		st.judged = true
		if (hrec.z2k_sni_idx or 0) >= Z2K_SNI_TRIES then return end
		-- Хост, недавно отдававший данные, живой: одно неудачное рукопожатие у
		-- него ничего не доказывает, а подбор имени способен его сломать.
		-- Подбор начинаем только у того, кто молчит целиком.
		-- ГВАРД ЖИВОСТИ СТЕРЕЖЁТ СТАРТ ПОДБОРА, А НЕ ЕГО ХОД.
		--
		-- Пока имя не найдено, хост отвечает — на нём же и стоит наш неудачный
		-- кандидат, ломающий соединения. Отметка живости от соседнего
		-- соединения гасила сдвиг на следующее имя, и подбор двигался не чаще
		-- раза в Z2K_ALIVE_WINDOW. Замер 30.08.2026: браузер за пять минут
		-- открыл 79 соединений, имя подставилось в 58, а сдвиг случился ОДИН.
		-- При позиции рабочего имени K=5 это полчаса неработающего сайта.
		if not (hrec.z2k_sni and not hrec.z2k_sni_ok) then
			local alive = hrec.z2k_alive_at
			if alive and os.time() <= (alive + Z2K_ALIVE_WINDOW) then return end
		end
		-- Пока имени нет — стартуем не с первой неудачи. Замер 30.08.2026:
		-- chatgpt.com получил чужое имя с одного неудачного коннекта сразу
		-- после перезапуска, когда отметки живости ещё нет ни у кого.
		if not hrec.z2k_sni then
			local f = (hrec.z2k_hs_fails or 0) + 1
			hrec.z2k_hs_fails = f
			if f < Z2K_SNI_START_FAILS then return end
		end
		local nm = z2k_sni_advance(hrec)
		DLOG("z2k_stall: рукопожатие не состоялось (" .. tostring(st.high or 0) ..
		     " Б); имя: " .. tostring(nm))
		return
	end

	-- ИСХОД ВТОРОЙ: кончились ровно на границе записи — завершённый ответ.
	-- Вот он и есть доказательство живости хоста, а НЕ сам факт пришедших байтов:
	-- зарезанный поток тоже приносит данные (hetzner на втором плече отдаёт 15994
	-- байта и встаёт), и по «пришли байты» мы заглушили бы подбор ровно там, где
	-- он нужен. Завершённость записи различает эти два случая, и это единственное,
	-- что их различает.
	if not st.mid then
		if (st.high or 0) >= 1024 then
			-- ЗАВЕРШЁННЫЙ ОТВЕТ ПРИ НЕОПРАВДАННОМ КАНДИДАТЕ = ПОДБОР БЫЛ ЛИШНИМ.
			--
			-- Хост ответил целиком и в пределах нашей видимости — значит по
			-- объёму его не режут, и имя ему не нужно вовсе. Снимаем кандидата
			-- совсем, а не просто не записываем: иначе чужое имя продолжало бы
			-- уходить в каждом хелло рабочего сайта. Замеры 30.08.2026:
			-- chatgpt.com (403 от Cloudflare, 8484 Б) и instagram получали имя
			-- на ровном месте.
			--
			-- Потолок сюда не попадает намеренно: там ответ НЕ завершён, там мы
			-- просто ослепли, и снимать кандидата было бы отменой настоящего
			-- подбора у заблокированного хоста.
			if hrec.z2k_sni and not hrec.z2k_sni_ok then
				DLOG("z2k_stall: ответ завершён на " .. tostring(st.high) ..
				     " Б — имя не нужно, подбор снят (был " ..
				     tostring(hrec.z2k_sni) .. ")")
				hrec.z2k_sni = nil
				hrec.z2k_sni_idx = 0
				hrec.z2k_hs_fails = 0
			end
			z2k_sni_proven(hrec)
		end
		return
	end
	if (st.high or 0) >= Z2K_STALL_MAX then return end
	if (st.high or 0) < Z2K_STALL_MIN then return end
	if (hrec.z2k_sni_idx or 0) >= Z2K_SNI_TRIES then return end
	st.judged = true
	hrec.z2k_stall_at = os.time()
	hrec.z2k_stall_high = st.high
	-- Имя сдвигаем ПРЯМО ЗДЕСЬ, а не в детекторе ротатора: тот после
	-- защёлки успеха не зовётся вовсе, и сдвиг никогда бы не случился.
	-- Проверено на живом обрыве: наблюдатель отработал, детектор — нет.
	local nm = z2k_sni_advance(hrec)
	DLOG("z2k_stall: поток встал на " .. tostring(st.high) ..
	     " Б посреди TLS-записи, тишина " .. Z2K_STALL_MS ..
	     " мс; следующее имя: " .. tostring(nm))
end

-- СПИСОК ИМЁН-КАНДИДАТОВ И ПЕРЕБОР ПО НЕМУ.
--
-- Перебор идёт на трафике самого пользователя: каждый зафиксированный обрыв
-- сдвигает хост на следующее имя, и следующая попытка открыть сайт проверяет
-- уже его. Отдельных проб не заводим — они потребовали бы своей машинерии и
-- своего состояния, а повторная попытка у человека и так происходит.
--
-- Порядок файла = приоритет, поэтому идём строго сверху вниз. Список кончился
-- — возвращаем nil: значит на этой линии белый список другой, и врать про
-- «подобрали» нельзя.
local Z2K_SNI_LIST_PATH = os.getenv("Z2K_SNI_LIST") or
                          "/opt/zapret2/lists/sni_wl_candidates.txt"
local sni_list, sni_loaded = nil, false

-- ЗАКРЕПЛЁННОЕ ИМЯ ЛИНИИ.
--
-- Один файл, одно имя. Его выбирает проба (z2k-sni-select.sh) на курируемой
-- мишени, а не догадка по чужому трафику, поэтому здесь только чтение и
-- проверка формы. Файл перечитывается по mtime: смена имени не требует
-- перезапуска, как и у списков движка.
-- Читаем не чаще раза в Z2K_PIN_RECHECK секунд: это путь КАЖДОГО исходящего
-- хелло, и открывать файл на каждый пакет незачем.
local z2k_pin_name, z2k_pin_at = nil, 0
local Z2K_PIN_RECHECK = tonumber(os.getenv("Z2K_PIN_RECHECK")) or 10
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

function z2k_sni_candidates()
	if sni_loaded then return sni_list end
	sni_loaded = true
	local f = io.open(Z2K_SNI_LIST_PATH, "r")
	if not f then return nil end
	local t = {}
	for raw in f:lines() do
		local line = raw:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
		-- Имя уезжает в фейковый ClientHello. Пропускаем только то, что является
		-- именем хоста: мусор оттуда уже не выковырять, а падать будет молча.
		if #line > 0 and #line <= 253 and not line:find("[^%w%.%-]") then
			t[#t + 1] = line
		end
	end
	f:close()
	if #t == 0 then t = nil end
	sni_list = t
	return t
end

-- Следующее имя для хоста. nil — кандидаты кончились.
function z2k_sni_next(hrec)
	local t = z2k_sni_candidates()
	if not t then return nil end
	local i = (hrec.z2k_sni_idx or 0) + 1
	if i > #t then return nil end
	hrec.z2k_sni_idx = i
	hrec.z2k_sni = t[i]
	return t[i]
end

-- ПОДСТАНОВКА ПОДОБРАННОГО ИМЕНИ В ФЕЙКОВЫЙ ClientHello.
--
-- Сам не отправляет: готовит блоб и кладёт его в поле desync, а шлёт штатный
-- fake с флагом optional. Так мы не повторяем своими руками ttl, badsum,
-- tcp_ts и repeats — всё это остаётся в ведении движка, — а optional даёт
-- тихий пропуск, когда имя ещё не подобрано. У того, кто на этот класс
-- блокировки не наткнулся, не происходит ровно ничего.
--
-- Ставится ДО circular и БЕЗ strategy=N: инстанс без этого аргумента circular
-- не вызывает вовсе, его исполняет линейный оркестратор. Значит имя
-- подставляется на ЛЮБОМ плече, а разрез продолжает ротироваться штатно —
-- имя и разрез это разные оси, и смешивать их в одно плечо неверно.
--
-- key и nld обязаны совпадать с теми, что у circular: иначе запись хоста
-- возьмётся под другим ключом, и селектор будет читать не то состояние,
-- которое пишет детектор обрыва.
function z2k_sni_pick(ctx, desync)
	direction_cutoff_opposite(ctx, desync)
	if not desync.dis or not desync.dis.tcp then return end
	if not (direction_check(desync) and payload_check(desync)) then return end
	if not replay_first(desync) then return end

	local ok_h, hrec = pcall(automate_host_record, desync)
	if not ok_h or not hrec then return end

	-- ЗАКРЕПЛЁННОЕ ИМЯ НА ВСЮ ЛИНИЮ — если оно выбрано, перебирать нечего.
	--
	-- Замер 30.08.2026 на линии владельца: проба по курируемым мишеням нашла
	-- блок по объёму в 34 AS из 43 — включая Cloudflare. Это свойство ЛИНИИ, а
	-- не отдельного хоста, и одно проходящее имя годится для всех: с ним
	-- hetzner отдал 163 654 Б вместо 15 994, а youtube, rutracker и chatgpt не
	-- изменились вовсе.
	--
	-- Поэтому, когда имя выбрано заранее (файл заполняет z2k-sni-select.sh),
	-- мы не ведём ни поиска, ни записи о хосте: подставили и вышли. Перебор по
	-- живому трафику остаётся запасным путём — для линий, где закрепить нечего.
	local pin = z2k_sni_pinned()
	if pin then
		local base_pin = blob(desync, desync.arg.src or "fake_default_tls")
		if not base_pin then return end
		local out_pin = tls_mod(base_pin,
			(desync.arg.mods or "rnd,dupsid") .. ",sni=" .. pin, desync.reasm_data)
		if out_pin then desync[desync.arg.blob or "z2k_ch"] = out_pin end
		return
	end

	-- ПОДТЯНУТЬ НАЙДЕННОЕ ИМЯ С ДИСКА ПРЯМО ЗДЕСЬ.
	--
	-- Селектор стоит В ПРОФИЛЕ ПЕРЕД circular, а запись хоста засевается с диска
	-- внутри circular — то есть на первом же hello после перезапуска имени в
	-- памяти ещё нет, и человек получает одну гарантированно неудачную загрузку.
	-- Замер 30.08.2026: после рестарта первая попытка ноль байт, вторая 163654.
	if not hrec.z2k_sni and type(z2k_state_persist) == "table"
	   and type(z2k_state_persist.get_record) == "function" then
		pcall(z2k_state_persist.get_record, desync, true)
	end

	-- СТОРОЖ ВЗВОДИТСЯ ВСЕГДА, ещё до того как имя выбрано.
	--
	-- Иначе механизм не запускается там, где хост валится на самом рукопожатии:
	-- имени нет, значит нечего подставлять, значит таймер никто не взводит,
	-- значит имя не выберется никогда. Замкнутый круг, проверенный на живом
	-- hetzner: шесть заходов подряд по нулю байт и ни одной записи в логе.
	--
	-- Взвод стоит здесь, на исходящем hello, потому что это единственный пакет,
	-- который на таком потоке гарантированно есть.
	local crec = desync.track and desync.track.lua_state
	if crec then
		local st = crec.z2k_tls
		if not st then st = {}; crec.z2k_tls = st end
		st.named = (hrec.z2k_sni ~= nil)
		timer_set("z2k_stall_" .. dis_timer_name(desync.dis),
		          "z2k_stall_timer", Z2K_STALL_HS_MS, true, { st = st, hrec = hrec })
	end

	if not hrec.z2k_sni then return end

	local base = blob(desync, desync.arg.src or "fake_default_tls")
	if not base then return end

	-- rnd и dupsid — то же, чем штатные плечи готовят свой фейк: случайные
	-- random/session id и копия session id с настоящего hello.
	local mods = (desync.arg.mods or "rnd,dupsid") .. ",sni=" .. hrec.z2k_sni
	local ok_m, ch = pcall(tls_mod, base, mods, desync.reasm_data)
	if not ok_m or not ch then return end

	desync[desync.arg.blob or "z2k_ch"] = ch
	if b_debug then
		DLOG("z2k_sni_pick: подставлено имя " .. hrec.z2k_sni)
	end
end

-- Взвод и перевзвод на каждом входящем пакете с данными.
--
-- ОТДЕЛЬНЫЙ ИНСТАНС, А НЕ ЧАСТЬ ДЕТЕКТОРА, И ЭТО ВАЖНО. Детектор ротатора
-- зовётся только пока соединение не признано успешным: automate_failure_check
-- выходит по crec.nocheck. На нашем классе рукопожатие проходит и успех
-- защёлкивается сразу, поэтому наблюдение внутри детектора не увидело бы
-- НИ ОДНОГО пакета из тех 16 КБ, ради которых всё и затевалось. Проверено на
-- живом обрыве: circular отработал 48 раз, детектор не позвался ни разу.
--
-- Поэтому наблюдение живёт своим инстансом с dir=in, до circular и без
-- strategy=N. key и nld обязаны совпадать с circular — иначе запись хоста
-- возьмётся под другим ключом.
function z2k_stall_watch(ctx, desync)
	if not desync.dis or not desync.dis.tcp then return end
	if not direction_check(desync) then return end
	-- Страховка на случай, если инстанс припишут не к тому профилю:
	-- наблюдение осмысленно только там, где есть ротация и наш детектор.
	if not Z2K_STALL_POOLS[desync.arg.key] then return end
	local ok_h, hrec = pcall(automate_host_record, desync)
	if not ok_h or not hrec then return end
	local crec = desync.track and desync.track.lua_state
	if not crec then return end
	if not desync.track or not desync.track.pos then return end
	local srv = desync.track.pos.server
	if not srv or not srv.tcp then return end
	local st = crec.z2k_tls
	if not st then st = {}; crec.z2k_tls = st end
	-- Пакеты считаем ДО проверки на данные: потолок очереди
	-- (`--connbytes 1:N ... dir reply`) считает пакеты, а не байты, и пустые
	-- ACK расходуют его наравне с данными.
	st.rx = (st.rx or 0) + 1
	st.cap = tonumber(desync.arg.cap) or st.cap

	-- САМАЯ ДАЛЬНЯЯ УВИДЕННАЯ ПОЗИЦИЯ — отдельно от разобранной.
	--
	-- Кадрирование идёт только по пакетам в пределах диапазона профиля, а вот
	-- закрывающий пакет большого ответа приходит далеко за ним: замер
	-- 30.08.2026, здоровая загрузка 163 КБ — FIN с позицией s168082 при
	-- диапазоне разбора a0-s27500. Раньше инстанс на таких пакетах не
	-- запускался вовсе, и «поток ехал за горизонтом» было нечем доказать.
	-- Инстансу расширен диапазон, и здесь мы этот след запоминаем.
	local pos_here = pos_get(desync, "s")
	if pos_here and pos_here > (st.hi_seen or 0) then st.hi_seen = pos_here end

	local p = desync.dis and desync.dis.payload
	if not p or #p == 0 then return end
	z2k_tls_frame_feed(st, p)
	st.mid  = ((st.need or 0) > 0) or (st.hdr ~= nil and #st.hdr > 0)
	st.high = srv.tcp.uppos or 0

	local name = "z2k_stall_" .. dis_timer_name(desync.dis)
	if st.high >= Z2K_STALL_MAX then
		-- Поток ушёл за наш горизонт видимости: молчание там ничего не значит.
		timer_del(name)
		return
	end
	if st.high < Z2K_STALL_MIN then
		-- Данных ещё мало. Таймер НЕ снимаем: он поставлен на исходящем hello и
		-- сторожит как раз случай «рукопожатие не состоялось». Просто ждём.
		return
	end
	-- Одноимённый таймер движок замещает с обнулением отсчёта — это и есть
	-- перевзвод: каждый новый пакет с данными отодвигает срок.
	timer_set(name, "z2k_stall_timer", Z2K_STALL_MS, true, { st = st, hrec = hrec })
end

local function z2k_fail_verdict(desync, crec)
	-- Исходящее: в штатный детектор пускаем только первый запрос. Ретрансмиты
	-- живой сессии — не признак негодной стратегии.
	if desync.outgoing then
		-- КЛИЕНТ УШЁЛ ПЕРВЫМ. Отмечаем момент, когда клиент закрыл свою сторону:
		-- всё, что сервер повторяет после этого, он повторяет в закрытый сокет,
		-- и к качеству стратегии отношения не имеет.
		local fl = desync.dis and desync.dis.tcp and desync.dis.tcp.th_flags
		if fl and TH_FIN and TH_RST and crec and not crec.z2k_cli_closed
		   and (bitand(fl, TH_FIN) ~= 0 or bitand(fl, TH_RST) ~= 0) then
			crec.z2k_cli_closed = os.time()
		end
		if not Z2K_FIRST_REQUEST[desync.l7payload] then return false end
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

	note_server_ttl(desync, crec)

	-- Входящее: штатный детектор (входящий RST, DPI-редирект), окно 16К-гейта
	-- по inseq — его же.
	--
	-- ПОРЯДОК ВАЖЕН. Учёт живости идёт ПОСЛЕ вердикта и только если провала
	-- нет: иначе пакет, который сам является блокировкой, засчитывается в
	-- доказательство того, что хост живой, и глушит собственный провал.
	-- Страница-заглушка DPI — непустой ответ, и трёх соединений хватает, чтобы
	-- взвести гвард раньше, чем наберётся порог провалов; блокировка тогда не
	-- ротируется никогда.
	-- HTTP-ОТВЕТ РАЗБИРАЕМ СВОИМ КЛАССИФИКАТОРОМ, ДО ШТАТНОГО ДЕТЕКТОРА.
	--
	-- Разборов кодов в профилях нет: их инжекции и проход, который их же
	-- вырезал, сняты 2026-08-26 — в конфиг они не попадали ни разу. Их работу
	-- делает эта обёртка. Штатный детектор кодов не смотрит вовсе, поэтому
	-- 403/451/5xx с нашими маркерами блокировки и
	-- редирект на страницу блокировки проходили как обычный ответ — и, хуже
	-- того, засчитывались в живость хоста ниже: заглушка DPI это непустой
	-- пейлоад без фатального алерта. Трёх таких хватало, чтобы взвести гвард
	-- раньше, чем наберётся кворум провалов, и блокировка не ротировалась.
	--
	-- Классификатор с 26.08.2026 живёт в ЭТОМ же файле (см. шапку). Проверку
	-- типа держим не ради отсутствующего файла, а ради частично обновлённой
	-- установки: обновление раскладывает файлы по одному, и обёртка обязана
	-- пережить окно, в котором рядом лежит ещё старая пара.
	local http_class
	if type(z2k_classify_http_reply) == "function" then
		local ok_c, cls = pcall(z2k_classify_http_reply, desync)
		if ok_c then http_class = cls end
	end
	if http_class == "hard_fail" then
		DLOG("z2k_fail_tls_alert: HTTP-ответ с маркером блокировки -> failure")
		return true
	end

	local failed = standard_failure_detector(desync, crec)
	-- В живость идёт только то, что доказывает работу: разбор либо не про
	-- HTTP (nil), либо признал ответ настоящим (positive). "neutral" — это
	-- голый 451, WAF-заголовок, 4xx без тела: провалом не считаем, но и
	-- доказательством жизни оно не является.
	if not failed and (http_class == nil or http_class == "positive") then
		note_alive(desync, crec, fatal_alert)
	end

	if failed then
		local verdict = incoming_reset_verdict(desync, crec)
		if verdict == "server" then return false end
		if verdict == "block" then return true end
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

function z2k_fail_tls_alert(desync, crec)
	note_strategy(desync, crec)

	local failed = z2k_fail_verdict(desync, crec)
	if not failed then return false end

	if not strategy_current(desync, crec) then
		DLOG("z2k_fail_tls_alert: провал соединения со стратегии " ..
		     tostring(crec.z2k_nstrat) .. " не засчитан — сейчас уже другая")
		return false
	end
	-- Время последнего ЗАСЧИТАННОГО провала. Читает z2k-state-persist.lua:
	-- откат sticky-успехом разрешён только если успех НОВЕЕ этой отметки.
	-- Иначе успех, случившийся ДО провалов, отменяет ротацию, которую эти
	-- провалы только что оплатили, и кворум приходится набирать заново.
	local hrec = host_record(desync)
	if hrec then
		-- Тот же источник времени, что у z2k-state-persist.lua (now_f): их
		-- значения сравниваются напрямую, и расхождение в базе часов дало бы
		-- сравнение целых секунд с дробными и промах на секунду в обе стороны.
		local t
		if type(clock_getfloattime) == "function" then
			local ok_t, v = pcall(clock_getfloattime)
			if ok_t and tonumber(v) then t = tonumber(v) end
		end
		hrec.z2k_last_fail_ts = t or os.time()
	end
	return true
end
