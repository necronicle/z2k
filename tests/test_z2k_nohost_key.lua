-- tests/test_z2k_nohost_key.lua
-- Unit tests for z2k_nohost_key — the native arg.hostkey generator that
-- replaces the archived z2k-autocircular allow_nohost behavior. Verifies that
-- hostname-less flows (Discord/STUN UDP carry no SNI) collapse to a single
-- "nohost" rotation bucket instead of fragmenting per dest-IP through the
-- stock standard_hostkey host_ip fallback. See lib/config_official.sh
-- discord_udp (hostkey=z2k_nohost_key) and zapret-auto.lua
-- automate_host_record (arg.hostkey extension point).

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

-- runtime global stubs the module expects when loaded standalone
function DLOG(...) end
function DLOG_ERR(...) end

dofile("files/lua/z2k-modern-core.lua")

check(type(z2k_nohost_key) == "function",
      "z2k_nohost_key defined after loading z2k-modern-core.lua")

local function mk(hostname, is_ip)
  return { track = { hostname = hostname, hostname_is_ip = is_ip } }
end

-- no real hostname → constant shared bucket
check(z2k_nohost_key(mk(nil)) == "nohost",
      "hostname=nil → 'nohost'")
check(z2k_nohost_key(mk("")) == "nohost",
      "hostname='' → 'nohost'")
check(z2k_nohost_key(mk("1.2.3.4", true)) == "nohost",
      "IP-literal + hostname_is_ip=true → 'nohost' (not a real hostname)")

-- real hostname honored unchanged
check(z2k_nohost_key(mk("voice.discord.gg", false)) == "voice.discord.gg",
      "real hostname honored unchanged")

-- anti-fragmentation invariant: two distinct hostname-less flows (different
-- dest IPs in production) resolve to the SAME bucket key
local k1 = z2k_nohost_key(mk(nil))
local k2 = z2k_nohost_key(mk(nil))
check(k1 == k2 and k1 == "nohost",
      "two hostname-less flows share one 'nohost' key (no per-IP fragmentation)")

-- degenerate input must not crash
check(z2k_nohost_key({}) == "nohost",
      "missing desync.track → 'nohost' (no crash)")
check(z2k_nohost_key(nil) == "nohost",
      "nil desync → 'nohost' (no crash)")

print()
print(string.format("Tests passed: %d / %d", PASS, PASS + FAIL))
if FAIL > 0 then
  os.exit(1)
end
