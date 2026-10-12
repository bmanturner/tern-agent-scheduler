--!strict
-- lib/conditions.luau : job conditions (pure): structured build, describe, sig, stored-shape check. Loaded by both halves.
local schedule = require("./schedule")
local ids = require("./ids")

local conditions = {}

export type Cond = { [string]: any }
-- {id="commits", type="commits", ref: string ("HEAD" default), paths: {string}}
-- {id="window",  type="window", days: {number} (0=Sun..6=Sat), from: number, to: number (minutes 0..1440), negate: boolean}
-- {id="budget",  type="budget", per: "day"|"week", max_runs: number?, max_usd: number?}
-- {id="check",   type="check", path: string, ack: string?}

local DAY_NAMES = { [0] = "sun", "mon", "tue", "wed", "thu", "fri", "sat" }
local NAME_PATTERN = "^[%w._/@%-]+$"
local MAX_PATHS = 8
local ORDER: { [string]: number } = { window = 1, budget = 2, commits = 3, check = 4 }

local function has_dotdot(s: string): boolean
	for seg in s:gmatch("[^/]+") do
		if seg == ".." then
			return true
		end
	end
	return false
end

local function bad_path_text(p: string): string
	return string.format("“%s” isn't a folder Agent Scheduler can check (no spaces, .. or leading -).", p)
end

local function ref_ok(r: string): boolean
	return r:match(NAME_PATTERN) ~= nil and r:sub(1, 1) ~= "-" and not r:find("..", 1, true) and not r:find(":", 1, true)
end

local function path_ok(p: string): boolean
	return p:match(NAME_PATTERN) ~= nil and p:sub(1, 1) ~= "-" and p:sub(1, 1) ~= ":" and not has_dotdot(p) and #p <= 200
end

local function hhmm(m: number): string
	return string.format("%02d:%02d", m // 60, m % 60)
end
conditions.hhmm = hhmm

local function all_days(): { number }
	return { 0, 1, 2, 3, 4, 5, 6 }
end

local function days_equal(days: { number }, want: { number }): boolean
	if #days ~= #want then
		return false
	end
	for i, d in days do
		if want[i] ~= d then
			return false
		end
	end
	return true
end

export type Input = {
	commits: { branch: string?, folders: { string }? }?,
	window: { days: { number }, from: number, to: number, outside: boolean? }?,
	limits: { runs: number?, usd: number?, per: string? }?,
	check: { path: string }?,
}

local function is_int(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Sorted, deduplicated copy of a day list (assumes values already validated).
local function sorted_days(days: { number }): { number }
	local seen: { [number]: boolean } = {}
	for _, d in days do
		seen[d] = true
	end
	local out = {}
	for d = 0, 6 do
		if seen[d] then
			table.insert(out, d)
		end
	end
	return out
end

-- Structured input -> ordered condition list (window, budget, commits, check), or nil + errors keyed by field.
function conditions.build(input: Input?): ({ Cond }?, { [string]: string }?)
	local out: { Cond } = {}
	if input == nil then
		return out, nil
	end
	local errs: { [string]: string } = {}

	local w = input.window
	if w ~= nil then
		local days_ok = type(w.days) == "table" and #w.days > 0
		if days_ok then
			for _, d in w.days do
				if not is_int(d, 0, 6) then
					days_ok = false
					break
				end
			end
		end
		if not days_ok then
			errs.days = "Pick at least one day."
		end
		if not is_int(w.from, 0, 1439) or not is_int(w.to, 0, 1440) then
			errs.hours = "Pick a time between 00:00 and 24:00."
		elseif w.from == w.to then
			errs.hours = "Pick two different times."
		end
		if errs.days == nil and errs.hours == nil then
			table.insert(out, {
				id = "window",
				type = "window",
				days = sorted_days(w.days),
				from = w.from,
				to = w.to,
				negate = w.outside == true,
			})
		end
	end

	local l = input.limits
	if l ~= nil then
		local msg: string? = nil
		if l.runs == nil and l.usd == nil then
			msg = "Set a number of runs, an amount, or both."
		elseif l.runs ~= nil and not is_int(l.runs, 1, 100) then
			msg = "Runs must be 1 to 100."
		elseif l.usd ~= nil and not (type(l.usd) == "number" and l.usd >= 0.01 and l.usd <= 1000) then
			msg = "Spend must be $0.01 to $1,000."
		elseif l.per ~= nil and l.per ~= "day" and l.per ~= "week" then
			msg = "Per must be a day or a week."
		end
		if msg ~= nil then
			errs.limits = msg
		else
			table.insert(out, { id = "budget", type = "budget", per = l.per or "day", max_runs = l.runs, max_usd = l.usd })
		end
	end

	local c = input.commits
	if c ~= nil then
		local ok = true
		local ref = "HEAD"
		if c.branch ~= nil and c.branch ~= "" then
			if ref_ok(c.branch) then
				ref = c.branch
			else
				errs.branch = string.format("“%s” isn't a branch name Agent Scheduler can check.", c.branch)
				ok = false
			end
		end
		local paths: { string } = {}
		local folders = c.folders or {}
		if #folders > MAX_PATHS then
			errs.folders = string.format("Pick at most %d folders.", MAX_PATHS)
			ok = false
		else
			for _, f in folders do
				local p = tostring(f):gsub("^%./", ""):gsub("/+$", "")
				if not path_ok(p) then
					errs.folders = bad_path_text(tostring(f))
					ok = false
					break
				end
				table.insert(paths, p)
			end
		end
		if ok then
			table.insert(out, { id = "commits", type = "commits", ref = ref, paths = paths })
		end
	end

	local k = input.check
	if k ~= nil then
		local p = trim(tostring(k.path or ""))
		local msg: string? = nil
		if p == "" then
			msg = "Enter the script's path, e.g. ./scripts/has-work.sh."
		elseif not (p:sub(1, 2) == "./" or p:sub(1, 2) == "~/" or p:sub(1, 1) == "/") then
			msg = "Start the path with ./ (the job's folder), ~/ or /."
		elseif has_dotdot(p) or p:find("['\"\\%$`!%c%s]") ~= nil or #p > 512 then
			msg = string.format("“%s” can't be used as a script path (no spaces, quotes, $ or ..).", p)
		end
		if msg ~= nil then
			errs.script = msg
		else
			table.insert(out, { id = "check", type = "check", path = p })
		end
	end

	if next(errs) ~= nil then
		return nil, errs
	end
	table.sort(out, function(a, b)
		return ORDER[a.type] < ORDER[b.type]
	end)
	return out, nil
end

-- Inverse of build, for seeding forms and echoing to Carly.
function conditions.to_input(list: { Cond }?): Input
	local out: Input = {}
	for _, c in list or {} do
		if c.type == "commits" then
			out.commits = { branch = if c.ref ~= "HEAD" then c.ref else nil, folders = table.clone(c.paths or {}) }
		elseif c.type == "window" then
			out.window = { days = table.clone(c.days), from = c.from, to = c.to, outside = c.negate == true }
		elseif c.type == "budget" then
			out.limits = { runs = c.max_runs, usd = c.max_usd, per = c.per }
		elseif c.type == "check" then
			out.check = { path = c.path }
		end
	end
	return out
end

-- "Every day" | "Weekdays" | "Weekends" | "Mon, Wed" (Monday-first).
function conditions.days_label(days: { number }): string
	local d = sorted_days(days)
	if #d == 7 then
		return "Every day"
	elseif days_equal(d, { 1, 2, 3, 4, 5 }) then
		return "Weekdays"
	elseif days_equal(d, { 0, 6 }) then
		return "Weekends"
	end
	local names = {}
	for _, n in { 1, 2, 3, 4, 5, 6, 0 } do
		if table.find(d, n) ~= nil then
			local s = DAY_NAMES[n] :: string
			table.insert(names, s:sub(1, 1):upper() .. s:sub(2))
		end
	end
	return table.concat(names, ", ")
end

local FIELD_KEYS = {
	"new_commits", "branch", "folders", "days", "from", "to", "quiet_hours", "max_runs", "max_usd", "per",
}

local function parse_clock(s: string): number?
	local l = trim(s):lower()
	if l == "24" or l == "24:00" then
		return 1440
	end
	local h, m = schedule.time_of_day(l)
	if h == nil then
		return nil
	end
	return (h :: number) * 60 + (m :: number)
end

local function parse_day_names(text: string): { number }?
	local l = trim(text):lower()
	if l == "weekdays" then
		return { 1, 2, 3, 4, 5 }
	elseif l == "weekends" then
		return { 0, 6 }
	elseif l == "daily" or l == "every day" then
		return all_days()
	end
	local found: { number } = {}
	for tok in l:gmatch("[^,%s]+") do
		local d = (schedule.DOW :: any)[tok]
		if d == nil then
			return nil
		end
		table.insert(found, d)
	end
	if #found == 0 then
		return nil
	end
	return sorted_days(found)
end

-- Carly's flat table -> Input. Range checks are left to build.
function conditions.from_fields(t: any): (Input?, string?)
	if type(t) ~= "table" then
		return nil, "only_when must be a table of fields."
	end
	local known: { [string]: boolean } = {}
	for _, k in FIELD_KEYS do
		known[k] = true
	end
	local keys = {}
	for k in t do
		table.insert(keys, tostring(k))
	end
	table.sort(keys)
	for _, k in keys do
		if not known[k] then
			return nil, string.format("Unknown field “%s” in only_when.", k)
		end
	end
	local function wrong(k: string): string
		return string.format("%s in only_when has the wrong type.", k)
	end
	for _, k in { "new_commits", "quiet_hours" } do
		if t[k] ~= nil and type(t[k]) ~= "boolean" then
			return nil, wrong(k)
		end
	end
	for _, k in { "branch", "days", "from", "to", "per" } do
		if t[k] ~= nil and type(t[k]) ~= "string" then
			return nil, wrong(k)
		end
	end
	for _, k in { "max_runs", "max_usd" } do
		if t[k] ~= nil and type(t[k]) ~= "number" then
			return nil, wrong(k)
		end
	end

	local out: Input = {}

	local folders: { string }? = nil
	if t.folders ~= nil then
		folders = {}
		if type(t.folders) == "string" then
			for tok in (t.folders :: string):gmatch("[^%s,]+") do
				table.insert(folders :: { string }, tok)
			end
		elseif type(t.folders) == "table" then
			for _, f in t.folders do
				if type(f) ~= "string" then
					return nil, wrong("folders")
				end
				table.insert(folders :: { string }, f)
			end
		else
			return nil, wrong("folders")
		end
	end
	if t.new_commits ~= false and (t.new_commits ~= nil or t.branch ~= nil or folders ~= nil) then
		out.commits = { branch = t.branch, folders = folders }
	end

	if t.days ~= nil or t.from ~= nil or t.to ~= nil or t.quiet_hours == true then
		local days = all_days()
		if t.days ~= nil then
			local d = parse_day_names(t.days)
			if d == nil then
				return nil, "days: use “weekdays”, “weekends”, “every day” or names like “mon,wed”."
			end
			days = d
		end
		local from, to = 0, 1440
		if (t.from == nil) ~= (t.to == nil) then
			return nil, "Give both from and to."
		end
		if t.from ~= nil then
			local f, e = parse_clock(t.from), parse_clock(t.to)
			if f == nil or e == nil then
				return nil, "from/to: use times like 09:00 or 6pm."
			end
			from, to = f, e
		end
		out.window = { days = days, from = from, to = to, outside = t.quiet_hours == true }
	end

	if t.max_runs ~= nil or t.max_usd ~= nil or t.per ~= nil then
		out.limits = { runs = t.max_runs, usd = t.max_usd, per = t.per or "day" }
	end
	return out, nil
end

function conditions.describe_one(c: Cond): string
	local t = c.type
	if t == "commits" then
		local s = "new commits"
		if c.ref ~= nil and c.ref ~= "HEAD" then
			s ..= " on " .. tostring(c.ref)
		end
		if type(c.paths) == "table" and #c.paths > 0 then
			s ..= " in " .. table.concat(c.paths, " ")
		end
		return s
	elseif t == "window" then
		local days = c.days :: { number }
		local s = if c.negate == true then "quiet hours " else ""
		local dtext = ""
		if days_equal(days, { 1, 2, 3, 4, 5 }) then
			dtext = "weekdays"
		elseif days_equal(days, { 0, 6 }) then
			dtext = "weekends"
		elseif #days < 7 then
			dtext = conditions.days_label(days)
		end
		s ..= dtext
		if not (c.from == 0 and c.to == 1440) then
			s ..= (if dtext ~= "" then " " else "") .. hhmm(c.from) .. "–" .. hhmm(c.to)
		end
		return (s:gsub("^%s+", ""):gsub("%s+$", ""))
	elseif t == "budget" then
		local per = tostring(c.per)
		local usd = if c.max_usd ~= nil then string.format("$%.2f", c.max_usd) else nil
		local runs = if c.max_runs == 1 then "1 run" else string.format("%d runs", c.max_runs or 0)
		if c.max_runs ~= nil and usd ~= nil then
			return string.format("max %s and %s a %s", runs, usd, per)
		elseif c.max_runs ~= nil then
			return string.format("max %s a %s", runs, per)
		end
		return string.format("max %s a %s", usd or "$0.00", per)
	elseif t == "check" then
		return tostring(c.path)
	end
	return ""
end

function conditions.describe(list: { Cond }?): string
	if list == nil or #list == 0 then
		return ""
	end
	local parts = {}
	for _, c in list do
		table.insert(parts, conditions.describe_one(c))
	end
	return table.concat(parts, " and ")
end

-- Fingerprint of what a watermark was taken against; "" for conditions without one.
function conditions.sig(c: Cond): string
	if c.type == "commits" then
		return ids.fnv64("commits\0" .. tostring(c.ref) .. "\0" .. table.concat(c.paths or {}, "\0"))
	elseif c.type == "check" then
		return ids.fnv64("check\0" .. tostring(c.path))
	end
	return ""
end

local function numbers_in(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v >= lo and v <= hi
end

-- Structural check of stored conditions (load time). Returns an error sentence or nil.
function conditions.check_stored(list: any): string?
	local BAD = "Its conditions can't be read."
	if type(list) ~= "table" or #list > 4 then
		return BAD
	end
	local n = 0
	for _ in list do
		n += 1
	end
	if n ~= #list then
		return BAD
	end
	local seen: { [string]: boolean } = {}
	for _, c in list do
		if type(c) ~= "table" then
			return BAD
		end
		if type(c.type) ~= "string" or seen[c.type] then
			return BAD
		end
		seen[c.type] = true
		local t, id = c.type, c.id
		if t == "commits" then
			if id ~= "commits" or type(c.ref) ~= "string" or type(c.paths) ~= "table" then
				return BAD
			end
			for _, p in c.paths do
				if type(p) ~= "string" then
					return BAD
				end
			end
		elseif t == "window" then
			if id ~= "window" or type(c.days) ~= "table" or #c.days == 0 then
				return BAD
			end
			for _, d in c.days do
				if not numbers_in(d, 0, 6) then
					return BAD
				end
			end
			if not numbers_in(c.from, 0, 1440) or not numbers_in(c.to, 0, 1440) then
				return BAD
			end
			if c.negate ~= nil and type(c.negate) ~= "boolean" then
				return BAD
			end
		elseif t == "budget" then
			if id ~= "budget" or (c.per ~= "day" and c.per ~= "week") then
				return BAD
			end
			if c.max_runs ~= nil and type(c.max_runs) ~= "number" then
				return BAD
			end
			if c.max_usd ~= nil and type(c.max_usd) ~= "number" then
				return BAD
			end
		elseif t == "check" then
			if id ~= "check" or type(c.path) ~= "string" then
				return BAD
			end
			if c.ack ~= nil and (type(c.ack) ~= "string" or c.ack:match("^ck1:%x+$") == nil) then
				return BAD
			end
		else
			return BAD
		end
	end
	return nil
end

-- "./x" -> cwd/x, "~/x" -> home/x, absolute unchanged.
function conditions.script_path(path: string, cwd: string, home: string): string
	if path:sub(1, 2) == "./" then
		return cwd .. "/" .. path:sub(3)
	elseif path:sub(1, 2) == "~/" then
		return home .. "/" .. path:sub(3)
	end
	return path
end

return conditions
