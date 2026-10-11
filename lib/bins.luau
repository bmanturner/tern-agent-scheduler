--!strict
-- lib/bins.luau : LA §1. Absolute `tern` and `omp` paths, each validated with `--version`, cached in
-- cache.json (`bin`). Also owns the in-memory copy of cache.json (shared with roles.luau).
-- No bare-`omp` fallback (R4): no valid candidate => "omp_missing" / "tern_missing".
local const = require("./const")
local store = require("./store")

export type Bins = { tern: string, omp: string, tern_version: string, omp_version: string }

local bins = {}

local cache: { [string]: any }? = nil
local found: { tern: string?, omp: string?, tern_version: string?, omp_version: string? } = {}
local waiting: { (Bins?, string?) -> () } = {}
local resolving = false

local function home(): string
	return ((tern :: any).getenv("HOME") :: string?) or ""
end

-- cache.json, decoded once; damaged or missing => empty (regenerable, never pauses jobs).
function bins.cache(): { [string]: any }
	if cache == nil then
		local data = store.load("cache", const.CAP_CACHE)
		cache = type(data) == "table" and data or { format = 1 }
	end
	return cache :: { [string]: any }
end

function bins.cache_save()
	local c = bins.cache()
	c.format = 1
	store.save("cache", c, const.CAP_CACHE)
end

-- Whatever is known right now (either field may be nil).
function bins.found(): { tern: string?, omp: string?, tern_version: string?, omp_version: string? }
	return found
end

function bins.get(): Bins?
	if found.tern ~= nil and found.omp ~= nil then
		return {
			tern = found.tern,
			omp = found.omp,
			tern_version = found.tern_version or "",
			omp_version = found.omp_version or "",
		}
	end
	return nil
end

-- Forget the resolved paths (a spawn raised, or settings changed).
function bins.invalidate()
	found = {}
	local c = bins.cache()
	if c.bin ~= nil then
		c.bin = nil
		bins.cache_save()
	end
end

local function tern_candidates(settings: any): { string }
	local h = home()
	local out: { string } = {}
	if type(settings.tern_path) == "string" and settings.tern_path ~= "" then
		table.insert(out, settings.tern_path)
	end
	table.insert(out, "/Applications/Tern.app/Contents/MacOS/tern")
	table.insert(out, h .. "/Applications/Tern.app/Contents/MacOS/tern")
	table.insert(out, h .. "/.local/bin/tern")
	table.insert(out, "/opt/homebrew/bin/tern")
	table.insert(out, "/usr/local/bin/tern")
	return out
end

-- Validates candidates in order; cb(path, version) for the first that answers --version.
local function first_valid(cands: { string }, accept: (any) -> string?, cb: (string?, string?) -> ())
	local seen: { [string]: boolean } = {}
	local list: { string } = {}
	for _, c in ipairs(cands) do
		if c ~= "" and c:sub(1, 1) == "/" and not seen[c] then
			seen[c] = true
			table.insert(list, c)
		end
	end
	local function step(i: number)
		local cand = list[i]
		if cand == nil then
			return cb(nil, nil)
		end
		local ok = pcall(function()
			(tern :: any).process.run({ cand, "--version" }, { timeout_ms = 3000 }, function(r: any)
				local version = r.status == 0 and accept(r) or nil
				if version ~= nil then
					return cb(cand, version)
				end
				step(i + 1)
			end)
		end)
		if not ok then
			step(i + 1)
		end
	end
	step(1)
end

local function tern_version(r: any): string?
	local line = tostring(r.stdout):match("^%s*(tern %d[^\r\n]*)")
	return line
end

local function omp_version(r: any): string?
	local line = tostring(r.stdout):match("^%s*([^\r\n]+)")
	return line
end

-- Candidates tried before the login-shell lookup, and those tried after it.
local function omp_candidates(settings: any): ({ string }, { string })
	local h = home()
	local before: { string } = {}
	if type(settings.omp_path) == "string" and settings.omp_path ~= "" then
		table.insert(before, settings.omp_path)
	end
	-- the link Tern's own omp manager records (a small file at a fixed path)
	local okr, text = pcall(function()
		return (tern :: any).fs.read(h .. "/Library/Application Support/Tern/omp/state.json", 65536)
	end)
	if okr and type(text) == "string" then
		local okd, j = pcall(function()
			return (tern :: any).json.decode(text)
		end)
		if okd and type(j) == "table" and type(j.link) == "string" then
			table.insert(before, j.link)
		end
	end
	table.insert(before, h .. "/Library/Application Support/Tern/omp/bin/omp")
	table.insert(before, "/opt/homebrew/bin/omp")
	local after: { string } = {
		h .. "/.local/bin/omp",
		h .. "/.bun/bin/omp",
		"/usr/local/bin/omp",
	}
	return before, after
end

-- Interactive login shell argv for `command -v omp`: the user's own zsh/bash so rc files that extend PATH
-- (bun, nvm, mise) are read; /bin/zsh otherwise.
local function lookup_argv(): { string }
	local sh = (tern :: any).getenv("SHELL") :: string?
	if type(sh) == "string" and sh:sub(1, 1) == "/" then
		local base = sh:match("([^/]+)$")
		if base == "zsh" or base == "bash" then
			return { sh, "-l", "-i", "-c", "command -v omp" }
		end
	end
	return { "/bin/zsh", "-l", "-i", "-c", "command -v omp" }
end

-- rc files may print banners; the answer is the last line that is an absolute path.
local function last_path_line(stdout: string): string?
	local found_line: string? = nil
	for line in stdout:gmatch("[^\r\n]+") do
		local t = line:match("^%s*(/.-)%s*$")
		if t ~= nil and t ~= "" then
			found_line = t
		end
	end
	return found_line
end

local function finish(b: Bins?, err: string?)
	resolving = false
	local list = waiting
	waiting = {}
	for _, cb in ipairs(list) do
		cb(b, err)
	end
end

local function resolve_fresh(settings: any)
	first_valid(tern_candidates(settings), tern_version, function(tpath, tver)
		local function with_omp(omp_path: string?, over: string?)
			-- the known paths are replaced only now, so they stay usable while the probes run
			found = { tern = tpath, tern_version = tver, omp = omp_path, omp_version = over }
			local c = bins.cache()
			if found.tern ~= nil or found.omp ~= nil then
				c.bin = {
					tern = found.tern,
					omp = found.omp,
					tern_version = found.tern_version,
					omp_version = found.omp_version,
					at = os.time(),
					tern_path_setting = settings.tern_path,
					omp_path_setting = settings.omp_path,
				}
				bins.cache_save()
			end
			if tpath == nil then
				return finish(nil, "tern_missing")
			end
			if omp_path == nil then
				return finish(nil, "omp_missing")
			end
			finish(bins.get(), nil)
		end
		local before, after = omp_candidates(settings)
		first_valid(before, omp_version, function(p1, v1)
			if p1 ~= nil then
				return with_omp(p1, v1)
			end
			local okl = pcall(function()
				(tern :: any).process.run(lookup_argv(), { timeout_ms = 5000 }, function(r: any)
					local rest: { string } = {}
					local looked = r.status == 0 and last_path_line(tostring(r.stdout)) or nil
					if looked ~= nil then
						table.insert(rest, looked)
					end
					for _, p in ipairs(after) do
						table.insert(rest, p)
					end
					first_valid(rest, omp_version, with_omp)
				end)
			end)
			if not okl then
				first_valid(after, omp_version, with_omp)
			end
		end)
	end)
end

-- cb(Bins) or cb(nil, "tern_missing" | "omp_missing"). A cached result is used without re-validation
-- unless `force`, or the explicit tern_path/omp_path settings changed since it was stored.
function bins.resolve(settings: any, cb: (Bins?, string?) -> (), force: boolean?)
	if not force then
		local current = bins.get()
		if current ~= nil then
			return cb(current, nil)
		end
		local c = bins.cache().bin
		if type(c) == "table" and type(c.tern) == "string" and type(c.omp) == "string"
			and c.tern_path_setting == settings.tern_path and c.omp_path_setting == settings.omp_path then
			found = { tern = c.tern, omp = c.omp, tern_version = c.tern_version, omp_version = c.omp_version }
			return cb(bins.get(), nil)
		end
	end
	table.insert(waiting, cb)
	if resolving then
		return
	end
	resolving = true
	resolve_fresh(settings)
end

return bins
