--!strict
-- lib/conditions.luau : the "Only if" condition language (pure): parse, describe, sig, stored-shape check. Loaded by both halves.
local schedule = require("./schedule")
local ids = require("./ids")

local conditions = {}

export type Cond = { [string]: any }
-- {id="commits", type="commits", ref: string ("HEAD" default), paths: {string}}
-- {id="window",  type="window", days: {number} (0=Sun..6=Sat), from: number, to: number (minutes 0..1440), negate: boolean}
-- {id="budget",  type="budget", per: "day"|"week", max_runs: number?, max_usd: number?}
-- {id="check1"|"check2", type="check", path: string, ack: string?}

local DAY_NAMES = { [0] = "sun", "mon", "tue", "wed", "thu", "fri", "sat" }
local NAME_PATTERN = "^[%w._/@%-]+$"
local MAX_PATHS = 8

local function has_dotdot(s: string): boolean
	for seg in s:gmatch("[^/]+") do
		if seg == ".." then
			return true
		end
	end
	return false
end

local function bad_path_text(p: string): string
	return string.format("“%s” isn't a folder path Agent Scheduler can check (no spaces, .. or leading -).", p)
end

local function ref_ok(r: string): boolean
	return r:match(NAME_PATTERN) ~= nil and r:sub(1, 1) ~= "-" and not r:find("..", 1, true) and not r:find(":", 1, true)
end

local function path_ok(p: string): boolean
	return p:match(NAME_PATTERN) ~= nil and p:sub(1, 1) ~= "-" and p:sub(1, 1) ~= ":" and not has_dotdot(p) and #p <= 200
end

local function not_understood(first: string): string
	return string.format(
		"Not understood: “%s”. Try “new commits on main”, “weekdays 9-18”, “max 3 runs a day” or “./scripts/has-work.sh”.",
		first
	)
end

local BUDGET_TRY = "Try “max 3 runs a day” or “max $2 a day”."

local function hhmm(m: number): string
	return string.format("%02d:%02d", m // 60, m % 60)
end

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

-- One token "A-B" -> minutes, minutes.
local function parse_range(tok: string): (number?, number?)
	local a, b = tok:lower():match("^([^%-]+)%-([^%-]+)$")
	if a == nil or b == nil then
		return nil, nil
	end
	local ah, am = schedule.time_of_day(a)
	if ah == nil then
		return nil, nil
	end
	local to: number
	if b == "24" or b == "24:00" then
		to = 1440
	else
		local bh, bm = schedule.time_of_day(b)
		if bh == nil then
			return nil, nil
		end
		to = (bh :: number) * 60 + (bm :: number)
	end
	return (ah :: number) * 60 + (am :: number), to
end

local function parse_days(text: string): { number }?
	if text == "weekdays" then
		return { 1, 2, 3, 4, 5 }
	elseif text == "weekends" then
		return { 0, 6 }
	elseif text == "daily" or text == "every day" then
		return all_days()
	end
	local seen: { [number]: boolean } = {}
	local any = false
	for tok in text:gmatch("[^,%s]+") do
		local d = (schedule.DOW :: any)[tok]
		if d == nil then
			return nil
		end
		seen[d] = true
		any = true
	end
	if not any then
		return nil
	end
	local out = {}
	for d = 0, 6 do
		if seen[d] then
			table.insert(out, d)
		end
	end
	return out
end

-- Each clause parser returns (cond?, err?) and a nil cond with nil err means "not this kind".
local function parse_commits(toks: { string }): (Cond?, string?)
	local first, second = (toks[1] :: string):lower(), (toks[2] or ""):lower()
	if first ~= "new" or (second ~= "commits" and second ~= "commit") then
		return nil, nil
	end
	local ref = "HEAD"
	local paths: { string } = {}
	local i = 3
	while i <= #toks do
		local kw = (toks[i] :: string):lower()
		if kw == "on" then
			local r = toks[i + 1]
			if r == nil or r:lower() == "in" then
				return nil, "Say which branch after “on”, e.g. new commits on main."
			end
			if not ref_ok(r) then
				return nil, string.format("“%s” isn't a branch name Agent Scheduler can check.", r)
			end
			ref = r
			i += 2
		elseif kw == "in" then
			paths = {}
			i += 1
			while i <= #toks and (toks[i] :: string):lower() ~= "on" do
				local p = toks[i] :: string
				if not path_ok(p) then
					return nil, bad_path_text(p)
				end
				table.insert(paths, p)
				i += 1
			end
			if #paths == 0 then
				return nil, "Say which folder after “in”, e.g. new commits in src/."
			end
			if #paths > MAX_PATHS then
				return nil, string.format("Use at most %d folders.", MAX_PATHS)
			end
		else
			return nil, not_understood(toks[i] :: string)
		end
	end
	return { id = "commits", type = "commits", ref = ref, paths = paths }, nil
end

local function parse_check(toks: { string }): (Cond?, string?)
	local t = toks[1] :: string
	if not (t:sub(1, 2) == "./" or t:sub(1, 1) == "/" or t:sub(1, 2) == "~/") then
		return nil, nil
	end
	if #toks ~= 1 then
		return nil, "Script paths can't contain spaces."
	end
	if has_dotdot(t) or t:find("['\"\\%$`!%c]") ~= nil or #t > 512 then
		return nil, string.format("“%s” can't be used as a script path.", t)
	end
	return { id = "check", type = "check", path = t }, nil
end

-- A budget clause may omit its period when another clause supplies it ("max 3 runs and max $2 a day").
local function parse_budget(toks: { string }): (Cond?, string?)
	if (toks[1] :: string):lower() ~= "max" then
		return nil, nil
	end
	local c: Cond = { id = "budget", type = "budget" }
	local i = 2
	local amount = (toks[2] or ""):lower()
	if amount:sub(1, 1) == "$" then
		local x = amount:sub(2)
		local n = if x:match("^%d+%.?%d*$") or x:match("^%d*%.%d+$") then tonumber(x) else nil
		if n == nil or n < 0.01 or n > 1000 then
			return nil, BUDGET_TRY
		end
		c.max_usd = n
		i = 3
	else
		local n = if amount:match("^%d+$") then tonumber(amount) else nil
		local unit = (toks[3] or ""):lower()
		if n == nil or n < 1 or n > 100 or (unit ~= "runs" and unit ~= "run") then
			return nil, BUDGET_TRY
		end
		c.max_runs = n
		i = 4
	end
	if i <= #toks then
		local join = (toks[i] or ""):lower()
		local per = (toks[i + 1] or ""):lower()
		if (join ~= "a" and join ~= "per") or (per ~= "day" and per ~= "week") or i + 1 ~= #toks then
			return nil, BUDGET_TRY
		end
		c.per = per
	end
	return c, nil
end

local function parse_window(toks: { string }): (Cond?, string?)
	local list = table.clone(toks)
	local negate = false
	local head = (list[1] :: string):lower()
	if head == "not" or head == "outside" then
		negate = true
		table.remove(list, 1)
	end
	if #list == 0 then
		return nil, nil
	end
	local from, to = 0, 1440
	local have_range = false
	local f, t = parse_range(list[#list] :: string)
	if f ~= nil and t ~= nil then
		from, to = f, t
		have_range = true
		table.remove(list)
	end
	local days: { number }? = nil
	if #list > 0 then
		days = parse_days(table.concat(list, " "):lower())
		if days == nil then
			return nil, nil
		end
	end
	if days == nil and not have_range then
		return nil, nil
	end
	if from == to then
		return nil, "The time range is empty."
	end
	return { id = "window", type = "window", days = days or all_days(), from = from, to = to, negate = negate }, nil
end

local ORDER = { window = 1, budget = 2, commits = 3, check = 4 }

-- Text -> ordered condition list, or nil + a plain sentence.
function conditions.parse(text: string): ({ Cond }?, string?)
	local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" or trimmed:lower() == "always" then
		return {}, nil
	end
	local clauses: { { string } } = { {} }
	for tok in trimmed:gmatch("%S+") do
		if tok:lower() == "and" then
			table.insert(clauses, {})
		else
			table.insert(clauses[#clauses] :: { string }, tok)
		end
	end

	local commits: Cond? = nil
	local window: Cond? = nil
	local budgets: { Cond } = {}
	local checks: { Cond } = {}

	for _, toks in clauses do
		local c = table.clone(toks)
		if c[1] ~= nil and c[1]:lower() == "only" then
			table.remove(c, 1)
			if c[1] ~= nil and c[1]:lower() == "if" then
				table.remove(c, 1)
			end
		elseif c[1] ~= nil and c[1]:lower() == "if" then
			table.remove(c, 1)
		end
		if #c == 0 then
			return nil, not_understood(toks[1] or "and")
		end

		local cond, err = parse_commits(c)
		if cond == nil and err == nil then
			cond, err = parse_check(c)
		end
		if cond == nil and err == nil then
			cond, err = parse_budget(c)
		end
		if cond == nil and err == nil then
			cond, err = parse_window(c)
		end
		if err ~= nil then
			return nil, err
		end
		if cond == nil then
			return nil, not_understood(c[1] :: string)
		end

		if cond.type == "commits" then
			if commits ~= nil then
				return nil, "Only one “new commits” condition."
			end
			commits = cond
		elseif cond.type == "window" then
			if window ~= nil then
				return nil, "Only one time window."
			end
			window = cond
		elseif cond.type == "budget" then
			table.insert(budgets, cond)
		else
			table.insert(checks, cond)
		end
	end

	if #checks > 2 then
		return nil, "Use at most 2 script checks."
	end
	for i, c in checks do
		c.id = "check" .. i
	end

	local budget: Cond? = nil
	if #budgets > 0 then
		local per: string? = nil
		local merged: Cond = { id = "budget", type = "budget" }
		local mixed = false
		for _, b in budgets do
			if b.per ~= nil then
				if per ~= nil and per ~= b.per then
					mixed = true
				end
				per = b.per
			end
			for _, k in { "max_runs", "max_usd" } do
				if b[k] ~= nil then
					if merged[k] ~= nil then
						mixed = true
					end
					merged[k] = b[k]
				end
			end
		end
		if mixed then
			return nil, "Use one period for limits, e.g. max 3 runs and max $2 a day."
		end
		if per == nil then
			return nil, BUDGET_TRY
		end
		merged.per = per
		budget = merged
	end

	local out: { Cond } = {}
	if window ~= nil then
		table.insert(out, window)
	end
	if budget ~= nil then
		table.insert(out, budget)
	end
	if commits ~= nil then
		table.insert(out, commits)
	end
	for _, c in checks do
		table.insert(out, c)
	end
	if #out > 3 then
		return nil, "Use at most 3 conditions."
	end
	table.sort(out, function(a, b)
		return ORDER[a.type] < ORDER[b.type]
	end)
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
		local s = if c.negate == true then "not " else ""
		local dtext = ""
		if days_equal(days, { 1, 2, 3, 4, 5 }) then
			dtext = "weekdays"
		elseif days_equal(days, { 0, 6 }) then
			dtext = "weekends"
		elseif #days < 7 then
			local names = {}
			for _, d in days do
				table.insert(names, DAY_NAMES[d] or "?")
			end
			dtext = table.concat(names, ",")
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
	if type(list) ~= "table" or #list > 6 then
		return BAD
	end
	local n = 0
	for _ in list do
		n += 1
	end
	if n ~= #list then
		return BAD
	end
	for _, c in list do
		if type(c) ~= "table" then
			return BAD
		end
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
			if (id ~= "check1" and id ~= "check2") or type(c.path) ~= "string" then
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
