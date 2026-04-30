-- tests/test_probe_override.lua
-- Unit tests for z2k-probe live override in z2k-autocircular.lua.

local override_file = "/tmp/z2k-probe-override.tsv"
os.remove(override_file)
os.remove("/tmp/z2k-autocircular-state.tsv")

local now = 1000.0
function clock_getfloattime()
  return now
end

autostate = {
  rkn_tcp = {
    ["cloudflare.com"] = { nstrategy = 4, ctstrategy = 50 },
    ["www.cloudflare.com"] = { nstrategy = 3, ctstrategy = 50 },
  },
}

local observed = {}

function standard_hostkey(desync)
  return desync.track.hostname
end

function circular(ctx, desync)
  local rec = autostate[desync.arg.key][desync.track.hostname]
  table.insert(observed, rec and rec.nstrategy or nil)
  return nil
end

dofile("files/lua/z2k-autocircular.lua")

local PASS, FAIL = 0, 0

local function write_override(strategy, mode, host)
  local f = assert(io.open(override_file, "w"))
  f:write("# key\thost\tstrategy\tts\tmode\n")
  f:write(string.format("rkn_tcp\t%s\t%d\t%d\t%s\n",
    host or "www.cloudflare.com", strategy, os.time(), mode or "probe"))
  f:close()
end

local function write_raw_override(line)
  local f = assert(io.open(override_file, "w"))
  f:write("# key\thost\tstrategy\tts\tmode\n")
  f:write(line)
  f:write("\n")
  f:close()
end

local function clear_override()
  os.remove(override_file)
end

local function mock_desync(host)
  host = host or "cloudflare.com"
  return {
    outgoing = true,
    l7payload = "tls_client_hello",
    arg = { key = "rkn_tcp" },
    track = {
      hostname = host,
      lua_state = { automate = {} },
    },
  }
end

local function check(name, expected, actual)
  if expected == actual then
    PASS = PASS + 1
    print(string.format("[PASS] %s", name))
  else
    FAIL = FAIL + 1
    print(string.format("[FAIL] %s: expected %s, got %s",
      name, tostring(expected), tostring(actual)))
  end
end

write_override(6, "probe", "cloudflare.com")
circular(nil, mock_desync("cloudflare.com"))
check("host match: exact host", 6, observed[#observed])

now = now + 0.2
clear_override()
circular(nil, mock_desync("cloudflare.com"))
check("host match: exact restore", 4, observed[#observed])

write_override(7, "probe")
now = now + 0.2
circular(nil, mock_desync())
check("host match: override subdomain matches SLD flow", 7, observed[#observed])
check("probe override updates in-memory strategy", 7, autostate.rkn_tcp["cloudflare.com"].nstrategy)

now = now + 0.2
write_override(9, "probe")
circular(nil, mock_desync())
check("probe override rotates without restart", 9, observed[#observed])

now = now + 0.2
write_override(8, "probe", "cloudflare.com")
circular(nil, mock_desync("www.cloudflare.com"))
check("host match: SLD override matches subdomain flow", 8, observed[#observed])

now = now + 0.2
write_raw_override(string.format("rkn_tcp\t\t13\t%d\tprobe", os.time()))
circular(nil, mock_desync("www.cloudflare.com"))
check("host match: blank host ignored", 3, observed[#observed])

now = now + 0.2
clear_override()
circular(nil, mock_desync())
check("cleared probe override restores previous strategy", 4, observed[#observed])
check("probe override did not create state fallback", nil, io.open("/tmp/z2k-autocircular-state.tsv", "r"))

now = now + 0.2
write_override(11, "commit")
circular(nil, mock_desync())
check("commit override applies winner live", 11, observed[#observed])

now = now + 0.2
clear_override()
circular(nil, mock_desync())
check("commit override is not restored away", 11, observed[#observed])

os.remove(override_file)

if FAIL > 0 then
  os.exit(1)
end
os.exit(0)
