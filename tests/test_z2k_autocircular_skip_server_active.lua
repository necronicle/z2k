-- tests/test_z2k_autocircular_skip_server_active.lua
-- Unit tests for the server_active_reject skip-rotation gate added in
-- Phase 1 of the Ladon-inspired detection stack.
--
-- Hook'ит module-locals через _G._z2k_autocircular_test, который выставляется
-- autocircular.lua только под Z2K_TEST_MODE=1.
--
-- Покрытие:
--   case1: conn_record_flags возвращает 6 значений (5-е = server_active boolean).
--   case2: record_server_side_marker записывает в bucket с {ts, reason}.
--   case3: Через circular(): crec.z2k_server_active_reject=true И crec.failure=true
--          → server_side_marker_by_hostn записан, failure_event подавлен,
--          last_seen_success_by_hostn НЕ обновлён.
--   case4: Маркер для compatible source (yt_quic→yt_tcp) перезаписан новым ts
--          при повторном server-active event.
--   case5: Без crec.z2k_server_active_reject — bucket пустой, обычное поведение.

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

local function now_f() return os.time() end

function circular(ctx, desync) return VERDICT_PASS end

function standard_hostkey(desync)
  return desync and desync.track and desync.track.hostname
end

dofile("files/lua/z2k-autocircular.lua")

local hook = _G._z2k_autocircular_test
assert(hook, "Z2K_TEST_MODE=1 not set or hook missing in autocircular.lua")
assert(hook.conn_record_flags, "conn_record_flags hook missing")
assert(hook.record_server_side_marker, "record_server_side_marker hook missing")
assert(hook.server_side_marker_by_hostn, "server_side_marker_by_hostn hook missing")
assert(hook.last_seen_success_by_hostn, "last_seen_success_by_hostn hook missing")

-- ---------- case1: conn_record_flags returns 6 values --------------------

do
  hook.reset()
  local desync = {
    track = {
      lua_state = {
        automate = {
          nocheck = false,
          failure = true,
          z2k_neutral_observed = false,
          z2k_server_active_reject = true,
          z2k_reason = "server_active:tcp_refused",
        }
      }
    }
  }
  local nocheck, failure, neutral, server_active, reason, reason_detail =
    hook.conn_record_flags(desync)
  check(nocheck == false, "case1: nocheck=false")
  check(failure == true, "case1: failure=true")
  check(neutral == false, "case1: neutral=false")
  check(server_active == true, "case1: server_active=true (5th return)")
  check(reason == "server_active:tcp_refused", "case1: reason returned (6th)")
end

-- ---------- case2: record_server_side_marker writes bucket ---------------

do
  hook.reset()
  hook.record_server_side_marker("mcpmarket.com", "server_active:waf_header:x-vercel-mitigated:deny")
  local m = hook.server_side_marker_by_hostn["mcpmarket.com"]
  check(m ~= nil, "case2: marker created for mcpmarket.com")
  check(m and type(m.ts) == "number" and m.ts > 0,
    "case2: marker ts set (got " .. tostring(m and m.ts) .. ")")
  check(m and m.reason == "server_active:waf_header:x-vercel-mitigated:deny",
    "case2: marker reason recorded")
end

-- ---------- case3: circular() с server_active stamp records marker, ------
-- ---------- suppresses failure_event, does NOT update success bucket -----

do
  hook.reset()
  -- Pre-existing stale success marker — мы убеждаемся что он не обновится
  -- даже при nocheck-latched flow если параллельно стоит server_active.
  hook.last_seen_success_by_hostn["mcpmarket.com"] = { rkn_tcp = 1.0 }

  -- desync: incoming http_reply классифицированный как server_active_reject
  -- параллельно с crec.failure=true (например, failure_after флаг от
  -- standard_failure_detector раннее), incoming side (outgoing=false).
  local d = {
    outgoing = false,
    l7payload = "http_reply",
    arg = { key = "rkn_tcp" },
    track = {
      hostname = "mcpmarket.com",
      lua_state = {
        automate = {
          nocheck = false,
          failure = true,
          z2k_server_active_reject = true,
          z2k_reason = "server_active:waf_header:x-vercel-mitigated:deny",
        }
      }
    },
    plan = {},
    func_instance = "circular",
  }
  circular(nil, d)

  -- marker должен быть записан
  local m = hook.server_side_marker_by_hostn["mcpmarket.com"]
  check(m ~= nil, "case3: server_side_marker_by_hostn['mcpmarket.com'] recorded")
  check(m and m.reason and m.reason:find("server_active", 1, true),
    "case3: marker reason carries server_active prefix")

  -- last_seen_success_by_hostn[rkn_tcp] остался stale (не обновлён)
  local s = hook.last_seen_success_by_hostn["mcpmarket.com"]
    and hook.last_seen_success_by_hostn["mcpmarket.com"].rkn_tcp
  check(s == 1.0,
    "case3: last_seen_success_by_hostn NOT updated on server-active (got " ..
    tostring(s) .. ")")
end

-- ---------- case4: повторный server-active event обновляет ts маркера ----

do
  hook.reset()
  hook.record_server_side_marker("mcpmarket.com", "server_active:tcp_refused")
  local ts1 = hook.server_side_marker_by_hostn["mcpmarket.com"].ts

  -- Принудительный sleep чтобы ts отличался. На macOS os.time() имеет
  -- секундное разрешение; sleep 1s достаточно.
  os.execute("sleep 1")

  hook.record_server_side_marker("mcpmarket.com", "server_active:tls_alert_post_sh:desc=40")
  local ts2 = hook.server_side_marker_by_hostn["mcpmarket.com"].ts
  local r2 = hook.server_side_marker_by_hostn["mcpmarket.com"].reason

  check(ts2 >= ts1,
    "case4: повторная запись обновляет ts (ts1=" .. ts1 .. " ts2=" .. ts2 .. ")")
  check(r2 == "server_active:tls_alert_post_sh:desc=40",
    "case4: reason обновлён на новый (got " .. tostring(r2) .. ")")
end

-- ---------- case5: without server_active stamp → marker stays empty ------

do
  hook.reset()
  local d = {
    outgoing = false,
    l7payload = "http_reply",
    arg = { key = "rkn_tcp" },
    track = {
      hostname = "regular-failing-host.com",
      lua_state = {
        automate = {
          nocheck = false,
          failure = true,   -- regular failure, NOT server_active
          z2k_neutral_observed = false,
        }
      }
    },
    plan = {},
    func_instance = "circular",
  }
  circular(nil, d)
  check(hook.server_side_marker_by_hostn["regular-failing-host.com"] == nil,
    "case5: regular failure_event does not write server_side_marker")
end

-- ---------- case6: server-active wins over latched nocheck ---------------
--
-- Регрессия-страж на review Medium 2026-05-17. Сценарий:
--   * ServerHello прилетел на flow X → upstream zapret-auto.lua latched
--     crec.nocheck = true.
--   * На СЛЕДУЮЩЕМ packet'е того же flow приходит TLS fatal alert ПОСЛЕ SH
--     → z2k_classify_server_active стампит crec.z2k_server_active_reject.
--   * Без приоритета successful_state = (nocheck && !failure && !neutral)
--     = true → success_event = true → server_active_event = false →
--     страта pin'ится через handshake к серверу, который тут же отказал.
--
-- Ожидаемое поведение: server_active_event TRUE, success_event FALSE,
-- marker записан, last_seen_success_by_hostn НЕ обновлён.

do
  hook.reset()
  hook.last_seen_success_by_hostn["mcpmarket.com"] = { rkn_tcp = 1.0 }

  local d = {
    outgoing = false,
    l7payload = "http_reply",
    arg = { key = "rkn_tcp" },
    track = {
      hostname = "mcpmarket.com",
      lua_state = {
        automate = {
          nocheck = true,                       -- latched после ServerHello
          failure = false,
          z2k_neutral_observed = false,
          z2k_server_active_reject = true,      -- post-SH TLS alert в этом callback'е
          z2k_reason = "server_active:tls_alert_post_sh:desc=40",
        }
      }
    },
    plan = {},
    func_instance = "circular",
  }
  circular(nil, d)

  -- server-active marker записан несмотря на latched nocheck
  local m = hook.server_side_marker_by_hostn["mcpmarket.com"]
  check(m ~= nil,
    "case6: marker записан при nocheck=true + z2k_server_active_reject=true")
  check(m and m.reason and m.reason:find("server_active", 1, true),
    "case6: marker reason carries server_active prefix")

  -- last_seen_success_by_hostn НЕ обновлён — pin success не сработал
  local s = hook.last_seen_success_by_hostn["mcpmarket.com"]
    and hook.last_seen_success_by_hostn["mcpmarket.com"].rkn_tcp
  check(s == 1.0,
    "case6: last_seen_success_by_hostn НЕ обновлён (server-active wins over nocheck-latched, got " ..
    tostring(s) .. ")")
end

-- ---------- summary ----------

print(string.format("--- summary ---\nPASSED: %d\nFAILED: %d", PASS, FAIL))
if FAIL > 0 then os.exit(1) end
