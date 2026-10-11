--!strict
-- lib/store.luau : host-side file store under tern.plugin.data (EN §2.2 damage protection 1-9).
-- Structured files (`settings|cache|jobs|state`) go through load/save; other text files through
-- safe_write (backup-then-write) or write_text (plain).
local const = require("./const")

local store = {}

local FORMAT = 1

-- last successfully loaded/written text per absolute path (EN §2.2.3)
local known_good: { [string]: string } = {}
-- absolute path -> latest text that failed to write (EN §2.2.9); retried every tick
local dirty: { [string]: string } = {}
-- absolute paths whose last write was refused for size (EN §2.2.8)
local too_big: { [string]: boolean } = {}
-- structured names never written: "readonly" (newer format) or "damaged" (EN §2.2.2, §2.2.4)
local blocked: { [string]: string } = {}
local made_dirs: { [string]: boolean } = {}

local function warn(...: any)
	local args = table.pack(...)
	pcall(function()
		(tern :: any).log.warn(table.unpack(args, 1, args.n))
	end)
end

function store.root(): string
	return (tern :: any).plugin.data
end

function store.path(rel: string): string
	if rel:sub(1, 1) == "/" then
		return rel
	end
	return store.root() .. "/" .. rel
end

local function dirname(p: string): string
	return (p:match("^(.*)/[^/]*$")) or "."
end

function store.mkdirs(path: string)
	local abs = store.path(path)
	if made_dirs[abs] then
		return
	end
	local ok = pcall(function()
		(tern :: any).fs.mkdir(abs)
	end)
	if ok then
		made_dirs[abs] = true
	end
end

function store.exists(path: string): boolean
	local ok, res = pcall(function()
		return (tern :: any).fs.exists(store.path(path))
	end)
	return ok and res == true
end

-- Refuses `..` segments and absolute paths outside the plugin data folder (F60).
local function safe_target(path: string): boolean
	if path:find("%.%.") and (path == ".." or path:find("^%.%./") or path:find("/%.%./") or path:find("/%.%.$")) then
		return false
	end
	if path:sub(1, 1) == "/" then
		local root = store.root()
		return path:sub(1, #root + 1) == root .. "/"
	end
	return true
end

function store.remove(path: string)
	if not safe_target(path) then
		warn("store: refused to remove", path)
		return
	end
	local abs = store.path(path)
	pcall(function()
		(tern :: any).fs.remove(abs)
	end)
	known_good[abs] = nil
	dirty[abs] = nil
	too_big[abs] = nil
	made_dirs[abs] = nil
end

function store.list(path: string): { string }
	local ok, res = pcall(function()
		return (tern :: any).fs.list(store.path(path))
	end)
	if ok and type(res) == "table" then
		return res
	end
	return {}
end

-- Bounded read of a plugin-owned file; nil when missing, oversized or unreadable.
-- `track` remembers the text as the known-good backup source for the next safe_write.
function store.read_text(path: string, cap: number, track: boolean?): string?
	local abs = store.path(path)
	local ok, text = pcall(function()
		return (tern :: any).fs.read(abs, cap)
	end)
	if not ok or type(text) ~= "string" then
		return nil
	end
	if track then
		known_good[abs] = text
	end
	return text
end

-- Plain write (creates the parent directory); no backup.
function store.write_text(path: string, text: string): (boolean, string?)
	local abs = store.path(path)
	store.mkdirs(dirname(abs))
	local ok, err = pcall(function()
		(tern :: any).fs.write(abs, text)
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

local function recompute_health(): string
	for _, why in pairs(blocked) do
		if why == "readonly" then
			return "readonly"
		end
	end
	for _, why in pairs(blocked) do
		if why == "damaged" then
			return "damaged"
		end
	end
	if next(dirty) ~= nil or next(too_big) ~= nil then
		return "data_unwritable"
	end
	return "ok"
end

function store.health(): string
	return recompute_health()
end

-- Backup-then-write (EN §2.2.3, §2.2.8, §2.2.9). `cap` is the READ cap; text over 90 % of it is refused.
function store.safe_write(path: string, text: string, cap: number): (boolean, string?)
	local abs = store.path(path)
	if #text > math.floor(cap * const.WRITE_CAP_RATIO) then
		too_big[abs] = true
		return false, "too_large"
	end
	too_big[abs] = nil
	if known_good[abs] == text and dirty[abs] == nil then
		return true, nil
	end
	store.mkdirs(dirname(abs))
	local prev = known_good[abs]
	local ok, err = pcall(function()
		if prev ~= nil then
			(tern :: any).fs.write(abs .. ".bak", prev)
		end
		(tern :: any).fs.write(abs, text)
	end)
	if not ok then
		dirty[abs] = text
		warn("store: write failed", abs, tostring(err))
		return false, tostring(err)
	end
	dirty[abs] = nil
	known_good[abs] = text
	return true, nil
end

-- Re-attempts every failed write; call each tick.
function store.retry_dirty()
	local pending: { [string]: string } = {}
	for abs, text in pairs(dirty) do
		pending[abs] = text
	end
	for abs, text in pairs(pending) do
		local cap = const.CAP_JOBS
		store.safe_write(abs, text, math.max(cap, #text * 2))
	end
end

local function decode_file(abs: string, cap: number): (any?, string?, string?)
	local okr, text = pcall(function()
		return (tern :: any).fs.read(abs, cap)
	end)
	if not okr or type(text) ~= "string" then
		return nil, nil, "unreadable"
	end
	local okd, value = pcall(function()
		return (tern :: any).json.decode(text)
	end)
	if not okd or type(value) ~= "table" then
		return nil, text, "invalid"
	end
	if type(value.format) ~= "number" then
		return nil, text, "invalid"
	end
	if value.format > FORMAT then
		return nil, text, "newer"
	end
	return value, text, nil
end

-- Files that can be rebuilt from scratch: a bad copy is set aside and never blocks writes or pauses jobs.
local REGENERABLE: { [string]: boolean } = { cache = true }

-- Keep the bytes of an unusable main file as <name>.json.corrupt-<t> (best effort).
local function keep_corrupt(abs: string, cap: number)
	local okc, raw = pcall(function()
		return (tern :: any).fs.read(abs, cap * 4)
	end)
	if okc and type(raw) == "string" then
		pcall(function()
			(tern :: any).fs.write(string.format("%s.corrupt-%d", abs, os.time()), raw)
		end)
	end
end

-- Decoded structured file (`settings|cache|jobs|state`). Returns data, or nil + "missing" | "readonly" | "damaged".
function store.load(name: string, cap: number): (any?, string?)
	local abs = store.path(name .. ".json")
	local bak = abs .. ".bak"
	blocked[name] = nil
	local main_exists = store.exists(abs)
	if not main_exists and not store.exists(bak) then
		return nil, "missing"
	end
	local value, text, why = decode_file(abs, cap)
	if value ~= nil and text ~= nil then
		known_good[abs] = text
		return value, nil
	end
	if why == "newer" and not REGENERABLE[name] then
		blocked[name] = "readonly"
		warn("store: newer format, read-only", name)
		return nil, "readonly"
	end
	if main_exists then
		warn("store: main file unusable, trying backup", name, tostring(why))
	end
	local bval, btext, bwhy = decode_file(bak, cap)
	if bval ~= nil and btext ~= nil then
		-- the newer main bytes would be lost on the next write: keep a copy first (F64)
		if main_exists then
			keep_corrupt(abs, cap)
		end
		known_good[abs] = btext
		return bval, nil
	end
	if bwhy == "newer" and not REGENERABLE[name] then
		blocked[name] = "readonly"
		return nil, "readonly"
	end
	-- both unusable: keep whatever bytes exist
	if main_exists then
		keep_corrupt(abs, cap)
		if REGENERABLE[name] then
			warn("store: regenerable file unusable, starting empty", name)
			return nil, "missing"
		end
		blocked[name] = "damaged"
		warn("store: damaged, not overwriting", name)
		return nil, "damaged"
	end
	return nil, "missing"
end

-- Writes sorted pretty JSON. Refused while the file is read-only or damaged.
function store.save(name: string, tbl: any, cap: number): (boolean, string?)
	local why = blocked[name]
	if why ~= nil then
		return false, why
	end
	local okj, text = pcall(function()
		return (tern :: any).json.encode(tbl, true)
	end)
	if not okj then
		return false, tostring(text)
	end
	return store.safe_write(name .. ".json", text :: string, cap)
end

-- User chose "Start fresh": set the unusable files aside (.corrupt-<t>), delete them and allow writes again.
function store.start_fresh(name: string)
	local abs = store.path(name .. ".json")
	if store.exists(abs) then
		keep_corrupt(abs, const.CAP_JOBS)
	end
	store.remove(abs)
	store.remove(abs .. ".bak")
	blocked[name] = nil
end

-- Structured files currently blocked (damaged or read-only), sorted.
function store.blocked_names(): { string }
	local out: { string } = {}
	for name in pairs(blocked) do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end
return store
