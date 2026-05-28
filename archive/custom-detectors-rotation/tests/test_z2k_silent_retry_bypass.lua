-- tests/test_z2k_silent_retry_bypass.lua
-- Unit tests for D.5a (cross-profile success bypass) в z2k-autocircular.lua.
--
-- Hook'ит module-locals через _G._z2k_autocircular_test, который выставляется
-- autocircular.lua только под Z2K_TEST_MODE=1. В production hook'а нет.
--
-- Покрытие:
--   case1: bypass в окне — maybe_rotate_youtube_silent_retry возвращает nil
--          и чистит stale attempts/last_t.
--   case2: bypass истёк (ts старее окна) — silent_retry работает нормально.
--   case3: marker для несовместимого source_askey игнорируется.
--   case4: outgoing-after-nocheck flow через wrapper circular() не освежает
--          last_seen_success_by_hostn (точка review High 2026-05-16).

local PASS, FAIL = 0, 0
local function check(cond, msg)
  if cond then
    PASS = PASS + 1
    print("[PASS] " .. msg)
  else
    FAIL = FAIL + 1
    print("[FAIL] " .. msg)
  end
end

-- ---------- Test-time globals required by autocircular wrapper ----------
VERDICT_PASS = 0
VERDICT_DROP = 1
VERDICT_MODIFY = 2

function DLOG(...) end
function DLOG_ERR(...) end

-- now_f() в autocircular.lua — module-local function, наш global-определение
-- его НЕ shadow'ит. Здесь now_f() нужен только для test-кода (вычисление
-- offset'ов в case1/2/3); autocircular внутри использует свой реальный
-- now_f(). Diff между os.time() и autocircular's now_f() в одном lua-runtime
-- < миллисекунды, что не влияет на 30s bypass-окно.
local function now_f() return os.time() end

-- orig_circular заглушка (wrap'нется autocircular.lua: `circular` — это
-- global, который autocircular берёт через `if type(circular) == "function"`).
function circular(ctx, desync) return VERDICT_PASS end

-- standard_hostkey глобальная функция — get_hostkey_func() picks её up из _G
-- (line ~949 в autocircular.lua) и через неё реальный get_record_for_desync
-- возвращает корректные askey/hostn без мокинга module-local'ов.
function standard_hostkey(desync)
  return desync and desync.track and desync.track.hostname
end

-- Test mode — autocircular.lua экспортирует internals в _G._z2k_autocircular_test.
-- ENV проверяется через os.getenv в самом autocircular.lua.
dofile("files/lua/z2k-autocircular.lua")

local hook = _G._z2k_autocircular_test
assert(hook, "Z2K_TEST_MODE=1 not set or hook missing in autocircular.lua")
assert(hook.maybe_rotate_youtube_silent_retry, "maybe_rotate_youtube_silent_retry hook missing")
assert(hook.last_seen_success_by_hostn, "last_seen_success_by_hostn hook missing")
assert(hook.youtube_silent_retry, "youtube_silent_retry hook missing")
assert(hook.reset, "reset hook missing")

-- ---------- Helpers ----------

local function make_hrec(nstrategy, ctstrategy)
  return { nstrategy = nstrategy, ctstrategy = ctstrategy }
end

local function make_tch_desync()
  return {
    outgoing = true,
    l7payload = "tls_client_hello",
    track = { hostname = "googlevideo.com", lua_state = {} },
    arg = {},
    plan = {},
    func_instance = "circular",
  }
end

-- ---------- case1: bypass within window clears stale attempts ----------
do
  hook.reset()
  local now = now_f()
  -- Имитируем: 10 сек назад у yt_quic к googlevideo был real-success;
  -- silent_retry уже накопил 1 attempt 10 сек назад на cur=1.
  hook.last_seen_success_by_hostn["googlevideo.com"] = { yt_quic = now - 10 }
  hook.youtube_silent_retry["yt_tcp"] = {
    ["googlevideo.com"] = { attempts = 1, strategy = 1, last_t = now - 10 },
  }
  local hrec = make_hrec(1, 22)
  local cur, next_strategy, attempts =
    hook.maybe_rotate_youtube_silent_retry(make_tch_desync(), "yt_tcp", "googlevideo.com", hrec)
  check(cur == nil and next_strategy == nil and attempts == nil,
    "case1: bypass returns (nil, nil, nil) when compat success within window")
  check(hrec.nstrategy == 1, "case1: hrec.nstrategy unchanged (got " .. tostring(hrec.nstrategy) .. ")")
  local r = hook.youtube_silent_retry["yt_tcp"]["googlevideo.com"]
  check(r and r.attempts == 0,
    "case1: stale attempts cleared on bypass (got " .. tostring(r and r.attempts) .. ")")
  check(r and r.last_t == 0,
    "case1: stale last_t cleared on bypass (got " .. tostring(r and r.last_t) .. ")")
end

-- ---------- case2: bypass expired → silent_retry rotates normally ----------
do
  hook.reset()
  local now = now_f()
  -- Окно 30 сек по дефолту. Ставим success на now-31 (за пределами).
  hook.last_seen_success_by_hostn["googlevideo.com"] = { yt_quic = now - 31 }
  -- Имитируем первый TCH 10 сек назад (attempts=1 на cur=1, last_t = now-10).
  -- Второй TCH сейчас: gap = 10s (>=min_gap=5, <=window=120) → attempts=2 → rotate.
  hook.youtube_silent_retry["yt_tcp"] = {
    ["googlevideo.com"] = { attempts = 1, strategy = 1, last_t = now - 10 },
  }
  local hrec = make_hrec(1, 22)
  local cur, next_strategy, attempts =
    hook.maybe_rotate_youtube_silent_retry(make_tch_desync(), "yt_tcp", "googlevideo.com", hrec)
  check(cur == 1 and next_strategy == 2 and attempts == 2,
    "case2: expired marker → silent_retry rotates 1→2 (got cur=" ..
    tostring(cur) .. " next=" .. tostring(next_strategy) .. " attempts=" .. tostring(attempts) .. ")")
  check(hrec.nstrategy == 2, "case2: hrec.nstrategy bumped to 2")
end

-- ---------- case3: marker от несовместимого source ignored ----------
do
  hook.reset()
  local now = now_f()
  -- http_rkn success не доказательство для yt_tcp по compat_map (только yt_quic).
  hook.last_seen_success_by_hostn["googlevideo.com"] = { http_rkn = now - 1 }
  hook.youtube_silent_retry["yt_tcp"] = {
    ["googlevideo.com"] = { attempts = 1, strategy = 1, last_t = now - 10 },
  }
  local hrec = make_hrec(1, 22)
  local cur, next_strategy, attempts =
    hook.maybe_rotate_youtube_silent_retry(make_tch_desync(), "yt_tcp", "googlevideo.com", hrec)
  check(cur == 1 and next_strategy == 2,
    "case3: incompatible marker ignored, rotation proceeds 1→2 (got " ..
    tostring(cur) .. "→" .. tostring(next_strategy) .. ")")
end

-- ---------- case4: outgoing-after-nocheck не освежает marker ----------
-- Регрессионный тест на review High 2026-05-16. nocheck-flag latched
-- upstream'ом zapret-auto.lua после первого incoming success; без guard
-- `not desync.outgoing` в pipeline-marker-update любой последующий outgoing
-- callback того же flow заходил в successful_state=true и обновлял
-- last_seen_success_by_hostn[hostn][askey], держа bypass-окно вечно
-- свежим. С guard'ом outgoing callback marker не трогает.
--
-- Идём через настоящий circular() wrapper (не direct call к internal
-- helper), чтобы pipeline-блок реально дошёл до D.5a marker-кода.
do
  hook.reset()
  -- Кладём marker отставший далеко за пределами 30s окна. Любое обновление
  -- (regression) будет видимым изменением ts.
  local stale_ts = 1.0  -- произвольное фиксированное значение, не зависит от now_f()
  hook.last_seen_success_by_hostn["googlevideo.com"] = { yt_quic = stale_ts }

  -- desync настраиваем так, чтобы РЕАЛЬНЫЕ module-local helpers вернули
  -- то что нужно: get_record_for_desync → askey="yt_quic", hostn="googlevideo.com",
  -- conn_record_flags → nocheck=true (читает track.lua_state.automate.nocheck),
  -- has_positive_incoming_response → false (desync.outgoing=true).
  --
  -- Совокупность: successful_state=true (nocheck && !failure && !neutral),
  -- response_state=false, desync.outgoing=true. Без guard'а
  -- real_success_incoming=true → marker обновится. С guard'ом — false.
  local d = {
    outgoing = true,
    l7payload = "quic_initial",  -- supported в outgoing_initial check
    arg = { key = "yt_quic" },   -- get_askey возвращает "yt_quic"
    track = {
      hostname = "googlevideo.com",
      lua_state = { automate = { nocheck = true } },  -- conn_record_flags
    },
    plan = {},
    func_instance = "circular",
  }
  circular(nil, d)

  local marker_after = hook.last_seen_success_by_hostn["googlevideo.com"]
    and hook.last_seen_success_by_hostn["googlevideo.com"].yt_quic
  check(marker_after == stale_ts,
    "case4: outgoing callback с nocheck-latched не освежает marker.yt_quic " ..
    "(before=" .. tostring(stale_ts) .. " after=" .. tostring(marker_after) .. ")")
end

-- ---------- summary ----------
print(string.format("--- summary ---\nPASSED: %d\nFAILED: %d", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
