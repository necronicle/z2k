-- z2k persistent strategy selection for circular
if z2k_persist_loaded then return end
z2k_persist_loaded = true

local persist_path = "/opt/zapret2/ipset/z2k-autostrategy.txt"
local persist_loaded = false
local persist_cache = {}

local function sanitize_key(k)
	if not k then return nil end
	k = k:gsub("[%s%z]", " ")
	if #k > 255 then
		k = k:sub(1, 255)
	end
	return k
end

local function load_file()
	if persist_loaded then return end
	persist_loaded = true
	local f = io.open(persist_path, "r")
	if not f then return end
	for line in f:lines() do
		local key, val = line:match("^(.-)\t(%d+)$")
		if key and val then
			persist_cache[key] = tonumber(val)
		end
	end
	f:close()
end

local function save_file()
	local f = io.open(persist_path, "w")
	if not f then return end
	for key, val in pairs(persist_cache) do
		f:write(key, "\t", tostring(val), "\n")
	end
	f:close()
end

local function get_hostkey(desync)
	local hkf = standard_hostkey
	if desync.arg.hostkey then
		if type(_G[desync.arg.hostkey]) == "function" then
			hkf = _G[desync.arg.hostkey]
		else
			return nil
		end
	end
	return hkf(desync)
end

local function get_saved_strategy(hostkey)
	load_file()
	return persist_cache[hostkey]
end

local function set_saved_strategy(hostkey, n)
	load_file()
	if hostkey and n and persist_cache[hostkey] ~= n then
		persist_cache[hostkey] = n
		save_file()
	end
end

local function get_success_detector(desync)
	if desync.arg.success_detector and type(_G[desync.arg.success_detector]) == "function" then
		return _G[desync.arg.success_detector]
	end
	return standard_success_detector
end

local orig_circular = circular
function circular(ctx, desync)
	local hostkey = get_hostkey(desync)
	if hostkey then
		hostkey = sanitize_key(hostkey)
	end
	local hrec = hostkey and automate_host_record(desync) or nil
	if hrec and hostkey then
		local saved = get_saved_strategy(hostkey)
		if saved and type(saved) == "number" then
			hrec.nstrategy = saved
		end
	end

	local verdict = orig_circular(ctx, desync)

	if hrec and hostkey then
		local crec = automate_conn_record(desync)
		local sdet = get_success_detector(desync)
		if crec and sdet and sdet(desync, crec) then
			if hrec.nstrategy then
				set_saved_strategy(hostkey, hrec.nstrategy)
			end
		end
	end

	return verdict
end
