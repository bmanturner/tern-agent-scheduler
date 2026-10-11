--!strict
-- lib/roles.luau : LA §6. omp model roles per job folder (`omp config get modelRoles --json` run IN that
-- folder so project overlays apply), cached per cwd in cache.json (`roles[cwd] = {at, list, map}`).
local const = require("./const")
local bins = require("./bins")

local roles = {}

-- Not chat models; hidden from the picker (LA §6).
local HIDDEN: { [string]: boolean } = { image = true, web = true, speech = true, dictation = true, judge = true }
local ORDER = { "default", "smol", "task", "plan", "slow", "commit", "advisor", "tiny", "memory", "vision" }

local function sorted(map: { [string]: any }): { string }
	local rank: { [string]: number } = {}
	for i, r in ipairs(ORDER) do
		rank[r] = i
	end
	local out: { string } = {}
	for role, _ in pairs(map) do
		if type(role) == "string" and role:match("^[%w_%-]+$") and not HIDDEN[role] then
			table.insert(out, role)
		end
	end
	table.sort(out, function(a, b)
		local ra, rb = rank[a], rank[b]
		if ra and rb then
			return ra < rb
		elseif ra then
			return true
		elseif rb then
			return false
		end
		return a < b
	end)
	return out
end

local function store_entry(cwd: string, list: { string }, map: { [string]: string })
	local c = bins.cache()
	local all = c.roles
	if type(all) ~= "table" then
		all = {}
		c.roles = all
	end
	all[cwd] = { at = os.time(), list = (tern :: any).json.array(list), map = map }
	bins.cache_save()
end

-- Fresh cached list for `cwd` (default max age ROLE_CACHE_S), else nil.
function roles.cached(cwd: string, max_age: number?): { string }?
	local all = bins.cache().roles
	if type(all) ~= "table" then
		return nil
	end
	local e = all[cwd]
	if type(e) ~= "table" or type(e.at) ~= "number" or type(e.list) ~= "table" then
		return nil
	end
	if os.time() - e.at > (max_age or const.ROLE_CACHE_S) then
		return nil
	end
	return e.list
end

-- Cached selector ("anthropic/claude-opus-5-5:medium") for a role, when known.
function roles.selector(cwd: string, role: string): string?
	local all = bins.cache().roles
	local e = type(all) == "table" and all[cwd] or nil
	if type(e) == "table" and type(e.map) == "table" then
		return e.map[role]
	end
	return nil
end

-- Drops the cached list for a cwd (a role_missing block, a manual refresh).
function roles.invalidate(cwd: string)
	local all = bins.cache().roles
	if type(all) == "table" and all[cwd] ~= nil then
		all[cwd] = nil
		bins.cache_save()
	end
end

local function parse(r: any): ({ string }?, { [string]: string }?, string?)
	if r.status ~= 0 then
		return nil, nil, "omp exited with status " .. tostring(r.status)
	end
	local ok, j = pcall(function()
		return (tern :: any).json.decode(r.stdout)
	end)
	if not ok or type(j) ~= "table" or type(j.value) ~= "table" then
		return nil, nil, "omp printed no roles"
	end
	local map: { [string]: string } = {}
	-- omp resolves every built-in chat role even when the config never sets it, so they are always listed
	local names: { [string]: boolean } = {}
	for _, role in ipairs(ORDER) do
		names[role] = true
	end
	for role, sel in pairs(j.value :: any) do
		if type(role) == "string" and type(sel) == "string" then
			map[role] = sel
			names[role] = true
		end
	end
	return sorted(names), map, nil
end

-- Reads the roles for `cwd` through omp. cb(list) or cb(nil, why). `process.run` takes a `cwd`
-- option; if it raises on it, the same command runs through a login shell that cds first.
function roles.list(omp: string, cwd: string, cb: ({ string }?, string?) -> ())
	local function done(r: any)
		if r.timed_out then
			return cb(nil, "omp took too long")
		end
		if r.status == 127 then
			bins.invalidate() -- omp moved or removed: re-resolve on the next use
		end
		local list, map, err = parse(r)
		if list == nil or map == nil then
			return cb(nil, err)
		end
		store_entry(cwd, list, map)
		cb(list, nil)
	end
	local ok = pcall(function()
		(tern :: any).process.run({ omp, "config", "get", "modelRoles", "--json" }, { cwd = cwd, timeout_ms = 8000 }, done)
	end)
	if ok then
		return
	end
	local okf, err = pcall(function()
		(tern :: any).process.run({
			"/bin/zsh",
			"-l",
			"-c",
			'cd "$1" && exec "$2" config get modelRoles --json',
			"_",
			cwd,
			omp,
		}, { timeout_ms = 8000 }, done)
	end)
	if not okf then
		bins.invalidate()
		cb(nil, tostring(err))
	end
end

return roles
