-- tests/test_z2k_hostkey_split.lua
-- Unit tests for z2k_hostkey_split — the arg.hostkey generator that gives a
-- listed hostname its OWN circular rotation bucket instead of folding it into
-- its registrable domain (stock standard_hostkey nld cut). Motivating case:
-- updates.discord.com (rustls updater) must not share discord.com's (Chromium)
-- rotation cell, because a leg that punches one breaks the other. See
-- files/lua/z2k-modern-core.lua and zapret-auto.lua automate_host_record
-- (arg.hostkey extension point).

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

-- Stub of zapret-auto.lua standard_hostkey: registrable-domain cut (nld=2) plus
-- the family_split |4/|6 suffix, with the host_ip fallback collapsed to the
-- sentinel "IP". Mirrors the real contract closely enough to prove that
-- z2k_hostkey_split BYPASSES the cut for listed hosts and DELEGATES otherwise.
function standard_hostkey(desync)
  local t = desync and desync.track
  local h = t and t.hostname
  if not h or #h == 0 or (t and t.hostname_is_ip) then
    return "IP"
  end
  local labels = {}
  for lbl in string.gmatch(h, "[^.]+") do labels[#labels + 1] = lbl end
  local n = #labels
  local key = h
  if n >= 2 then key = labels[n - 1] .. "." .. labels[n] end
  local arg = desync and desync.arg or {}
  if arg.family_split ~= "0" and desync and desync.dis then
    key = key .. (desync.dis.ip6 and "|6" or "|4")
  end
  return key
end

dofile("files/lua/z2k-modern-core.lua")

check(type(z2k_hostkey_split) == "function",
      "z2k_hostkey_split defined after loading z2k-modern-core.lua")

-- opts: is_ip, ip6, family_split
local function mk(hostname, opts)
  opts = opts or {}
  return {
    track = { hostname = hostname, hostname_is_ip = opts.is_ip },
    dis   = { ip6 = opts.ip6 or false },
    arg   = { family_split = opts.family_split },
  }
end

-- 1. Listed host keeps its FULL name (no nld fold), with the ipv4 family suffix.
check(z2k_hostkey_split(mk("updates.discord.com")) == "updates.discord.com|4",
      "listed host -> own bucket 'updates.discord.com|4' (nld cut skipped)")

-- 2. Family suffix tracks the flow's address family.
check(z2k_hostkey_split(mk("updates.discord.com", { ip6 = true })) == "updates.discord.com|6",
      "listed host over ipv6 -> 'updates.discord.com|6'")

-- 3. family_split=0 drops the suffix, same as standard_hostkey.
check(z2k_hostkey_split(mk("updates.discord.com", { family_split = "0" })) == "updates.discord.com",
      "listed host with family_split=0 -> 'updates.discord.com' (no suffix)")

-- 4. THE POINT: the listed host and its registrable domain land in DIFFERENT
--    buckets. Stock behavior folds both to discord.com|4; the split keeps them
--    apart, so updates.discord.com can rotate/freeze onto its own working leg.
local k_updates = z2k_hostkey_split(mk("updates.discord.com"))
local k_discord = z2k_hostkey_split(mk("discord.com"))
check(k_updates ~= k_discord,
      "sibling isolation: updates.discord.com and discord.com get DIFFERENT buckets")
check(standard_hostkey(mk("updates.discord.com")) == k_discord,
      "control: stock standard_hostkey WOULD fold updates.discord.com into discord.com's bucket")

-- 5. Non-listed hosts are delegated to standard_hostkey unchanged.
check(z2k_hostkey_split(mk("discord.com")) == "discord.com|4",
      "non-listed host discord.com -> delegated (nld cut applied) 'discord.com|4'")
check(z2k_hostkey_split(mk("www.google.com")) == "google.com|4",
      "non-listed host www.google.com -> delegated 'google.com|4'")

-- 6. A listed name arriving as an IP literal is NOT split (no real hostname).
check(z2k_hostkey_split(mk("updates.discord.com", { is_ip = true })) == "IP",
      "hostname_is_ip -> not split, delegated to host_ip fallback")

-- 7. Degenerate input must not crash and must delegate.
check(z2k_hostkey_split({}) == "IP",
      "missing desync.track -> delegated, no crash")
check(z2k_hostkey_split(nil) == "IP",
      "nil desync -> delegated, no crash")

print()
print(string.format("Tests passed: %d / %d", PASS, PASS + FAIL))
if FAIL > 0 then
  os.exit(1)
end
