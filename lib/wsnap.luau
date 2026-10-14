--!strict
local timefmt = require("./timefmt")
-- Window half: the host's published snapshot, cached. snapshot.json is re-read only when the kv key
-- `hot` reports a new `rev`. Nothing here runs at load time.

local wsnap = {}

local SNAP_CAP = 131072

local snap: { [string]: any }? = nil
local hot: { [string]: any }? = nil
local loaded_rev: any = nil

local function read(): boolean
	local ok, text = pcall(tern.fs.read, tern.plugin.data .. "/snapshot.json", SNAP_CAP)
	if not ok then
		return false
	end
	local okd, value = pcall(tern.json.decode, text)
	if okd and type(value) == "table" and (value :: any).format == 1 then
		snap = value :: any
		timefmt.set((value :: any).time_format)
		return true
	end
	return false
end

-- Re-checks kv `hot`; reloads the snapshot when its rev changed (or nothing is loaded yet).
-- Returns true when the cached snapshot or hot changed.
function wsnap.poll(): boolean
	local okk, value = pcall(tern.kv.get, "hot")
	local new_hot: { [string]: any }? = nil
	if okk and type(value) == "table" then
		new_hot = value :: any
	end
	local changed = false
	local rev: any = if new_hot then new_hot.rev else nil
	if snap == nil or (rev ~= nil and rev ~= loaded_rev) then
		if read() then
			loaded_rev = rev
			changed = true
		end
	end
	if new_hot ~= nil and (hot == nil or (hot :: any).rev ~= new_hot.rev or (hot :: any).hb ~= new_hot.hb) then
		changed = true
	end
	hot = new_hot
	return changed
end

-- The cached snapshot (nil before the host's first publish).
function wsnap.get(): { [string]: any }?
	return snap
end

-- The cached kv `hot` value.
function wsnap.hot(): { [string]: any }?
	return hot
end

-- The snapshot's jobs, [] when none.
function wsnap.jobs(): { any }
	local s = snap
	if s and type(s.jobs) == "table" then
		return s.jobs :: any
	end
	return {}
end

function wsnap.inflight(): { any }
	local s = snap
	if s and type(s.inflight) == "table" then
		return s.inflight :: any
	end
	return {}
end

-- Test hook: drops the cache.
function wsnap.reset()
	snap, hot, loaded_rev = nil, nil, nil
end

return wsnap
