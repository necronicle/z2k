-- tests/test_http_classifier.lua
-- Unit tests for z2k_classify_http_reply (z2k-detectors.lua).
--
-- Run: lua tests/test_http_classifier.lua
-- Exit code 0 on green, 1 on any failure.
--
-- Mocks the upstream globals z2k_classify_http_reply depends on
-- (http_dissect_reply, array_field_search, dissect_url, dissect_nld)
-- with minimal-but-real implementations matching the upstream
-- semantics (see zapret-lib.lua:1785 for dissect_url reference).

-- ----- mocks ---------------------------------------------------------------

function http_dissect_reply(payload)
    if type(payload) ~= "string" then return nil end
    local sep = payload:find("\r\n\r\n", 1, true)
    if not sep then return nil end
    local header_block = payload:sub(1, sep - 1)
    local body = payload:sub(sep + 4)
    local code_s = header_block:match("^HTTP/%d%.%d%s+([0-9][0-9][0-9])")
    local headers = {}
    for h in header_block:gmatch("([^\r\n]+)") do
        local name, value = h:match("^([^:]+):%s*(.*)$")
        if name and value then
            table.insert(headers, { header_low = name:lower(), value = value })
        end
    end
    return { code = tonumber(code_s), headers = headers, body = body }
end

function array_field_search(arr, field, value)
    for i, v in ipairs(arr or {}) do
        if v[field] == value then return i end
    end
    return nil
end

function dissect_url(url)
    local p = url:match("^[a-z]+://([^/]+)")
    if p then
        local host = p:gsub(":%d+$", "")
        return { domain = host }
    end
    return nil
end

function dissect_nld(domain, level)
    local parts = {}
    for w in domain:gmatch("[^.]+") do table.insert(parts, w) end
    if #parts < level then return domain end
    local start = #parts - level + 1
    return table.concat(parts, ".", start)
end

-- ----- load classifier under test -----------------------------------------

dofile("files/lua/z2k-detectors.lua")

-- ----- harness ------------------------------------------------------------

local PASS, FAIL = 0, 0

local function mock_desync(payload, hostname)
    return {
        outgoing = false,
        l7payload = "http_reply",
        track = { hostname = hostname or "example.com" },
        dis = { payload = payload },
    }
end

local function check(name, want_class, want_reason_substr, desync)
    local class, reason = z2k_classify_http_reply(desync)
    local ok_class = (class == want_class)
    local ok_reason = (want_reason_substr == nil) or
        (reason ~= nil and reason:find(want_reason_substr, 1, true) ~= nil)
    if ok_class and ok_reason then
        PASS = PASS + 1
        print(string.format("[PASS] %s", name))
    else
        FAIL = FAIL + 1
        print(string.format("[FAIL] %s — got class=%s reason=%s",
            name, tostring(class), tostring(reason)))
    end
end

-- ----- bug 1: Link rel="blocked-by" must NOT trigger hard_fail -----------

print("=== bug 1: Link rel=\"blocked-by\" header must not be marker ===")

check("451 + Link rel=blocked-by header, neutral body",
    "neutral", "no_marker",
    mock_desync(
        "HTTP/1.1 451 Unavailable For Legal Reasons\r\n" ..
        "Link: <https://eais.rkn.gov.ru/>; rel=\"blocked-by\"\r\n" ..
        "Content-Type: text/html\r\n" ..
        "\r\n" ..
        "<html>This content is unavailable in your region.</html>"))

check("451 + Link rel=blocked-by + lawfilter in body, hard_fail",
    "hard_fail", "lawfilter",
    mock_desync(
        "HTTP/1.1 451 Unavailable For Legal Reasons\r\n" ..
        "Link: <https://eais.rkn.gov.ru/>; rel=\"blocked-by\"\r\n" ..
        "\r\n" ..
        "<html>Blocked by lawfilter.ertelecom.ru</html>"))

-- ----- bug 2: scheme-relative //host:port port-strip ----------------------

print("=== bug 2: scheme-relative //host:port must strip port ===")

check("302 //example.com:443/path is same-SLD positive",
    "positive", nil,
    mock_desync(
        "HTTP/1.1 302 Found\r\n" ..
        "Location: //example.com:443/new-path\r\n" ..
        "\r\n",
        "example.com"))

check("302 //www.example.com:8080/x is same-SLD positive",
    "positive", nil,
    mock_desync(
        "HTTP/1.1 302 Found\r\n" ..
        "Location: //www.example.com:8080/new\r\n" ..
        "\r\n",
        "example.com"))

check("302 //warn.beeline.ru:443/x is hard_fail by host-prefix",
    "hard_fail", "prefix:warn.",
    mock_desync(
        "HTTP/1.1 302 Found\r\n" ..
        "Location: //warn.beeline.ru:443/blockpage\r\n" ..
        "\r\n",
        "rutracker.org"))

-- ----- positive regressions ----------------------------------------------

print("=== positive regressions ===")

check("200 OK is positive", "positive", nil,
    mock_desync("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"))

check("304 Not Modified is positive", "positive", nil,
    mock_desync("HTTP/1.1 304 Not Modified\r\n\r\n"))

check("301 same-SLD relative path is positive", "positive", nil,
    mock_desync(
        "HTTP/1.1 301 Moved Permanently\r\n" ..
        "Location: /new-path\r\n" ..
        "\r\n",
        "example.com"))

-- ----- HTTP 403 / 4xx ----------------------------------------------------

print("=== 4xx classification ===")

check("403 plain is neutral", "neutral", "no_marker",
    mock_desync("HTTP/1.1 403 Forbidden\r\n\r\n<html>Access Denied</html>"))

check("403 + rkn in body is hard_fail", "hard_fail", "rkn",
    mock_desync("HTTP/1.1 403 Forbidden\r\n\r\n<html>Blocked by rkn.gov.ru</html>"))

check("404 plain is neutral", "neutral", "no_marker",
    mock_desync("HTTP/1.1 404 Not Found\r\n\r\nNot found"))

check("500 plain is neutral", "neutral", "no_marker",
    mock_desync("HTTP/1.1 500 Internal Server Error\r\n\r\nfailure"))

-- ----- 3xx redirects -----------------------------------------------------

print("=== 3xx redirects ===")

check("302 absolute cross-SLD oauth is neutral", "neutral", "cross_sld_no_marker",
    mock_desync(
        "HTTP/1.1 302 Found\r\n" ..
        "Location: https://login.microsoftonline.com/auth\r\n" ..
        "\r\n",
        "myapp.com"))

check("302 absolute cross-SLD with substring marker is hard_fail",
    "hard_fail", "lawfilter",
    mock_desync(
        "HTTP/1.1 302 Found\r\n" ..
        "Location: https://lawfilter.ertelecom.ru/blocked\r\n" ..
        "\r\n",
        "rutracker.org"))

check("302 absolute cross-SLD with deny. host-prefix is hard_fail",
    "hard_fail", "prefix:deny.",
    mock_desync(
        "HTTP/1.1 302 Found\r\n" ..
        "Location: https://deny.megafon.ru/page\r\n" ..
        "\r\n",
        "rutracker.org"))

check("302 absolute same-SLD HTTP→HTTPS upgrade is positive",
    "positive", nil,
    mock_desync(
        "HTTP/1.1 301 Moved Permanently\r\n" ..
        "Location: https://www.example.com/\r\n" ..
        "\r\n",
        "example.com"))

-- ----- non-applicable cases ----------------------------------------------

print("=== non-applicable ===")

check("not http_reply (tls_server_hello) returns nil",
    nil, nil,
    {
        outgoing = false,
        l7payload = "tls_server_hello",
        track = { hostname = "example.com" },
        dis = { payload = "\x16\x03\x03..." },
    })

check("outgoing direction returns nil", nil, nil,
    {
        outgoing = true,
        l7payload = "http_reply",
        track = { hostname = "example.com" },
        dis = { payload = "GET / HTTP/1.1\r\n\r\n" },
    })

-- ----- summary -----------------------------------------------------------

print(string.format("\n%d passed, %d failed", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
