--!strict
-- lib/validate.luau : the one job validator (form + carly_create), EN §1.1 rules, UX §7.5 copy. Pure: no `tern`.
local cron = require("./cron")
local schedule = require("./schedule")
local const = require("./const")

local validate = {}

export type JobInput = {
	name: string?,
	prompt: string?,
	when: string?,
	role: string?,
	cwd: string?,
	approval: string?,
	max_runtime_s: number?,
	enabled: boolean?,
	catch_up: string?,
	catch_up_window_s: number?,
	pause_after_failures: number?,
	allow_home: boolean?,
}

-- ctx: jobs = existing jobs (for uniqueness), self_id = job being edited, now, home,
--      creating = name/prompt/when/cwd are required, defaults = settings.defaults (approval fallback).
export type Ctx = {
	jobs: { any },
	self_id: string?,
	now: number,
	home: string,
	creating: boolean?,
	defaults: { [string]: any }?,
}

local MIN_INTERVAL_COPY = "Agent runs shorter than 5 minutes apart tend to overlap. Use every 5m or more."
local HOME_COPY = "omp may work in a temporary folder instead of your home folder. Pick a project folder for predictable results."
local UNSAFE_COPY = "Folders with quotes, $ or ! in the name aren't supported yet."
local RUNTIME_COPY = "Use a time like 45m or 2h (up to 8h)."

local function trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Lowercase, runs of non-alphanumerics become "-", ≤40 chars. May be "".
function validate.slug(name: string): string
	local s = name:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if #s > const.NAME_MAX then
		s = s:sub(1, const.NAME_MAX):gsub("%-+$", "")
	end
	return s
end

-- LA §2.3: ' " \ $ ` ! and control characters (newline included).
function validate.unsafe_path(p: string): boolean
	return p:find("['\"\\%$`!%c]") ~= nil
end

-- "/Users/me/Dev/app" -> "~/Dev/app" when under home.
function validate.tilde(path: string, home: string): string
	if home ~= "" and home ~= "/" then
		if path == home then
			return "~"
		end
		if path:sub(1, #home + 1) == home .. "/" then
			return "~" .. path:sub(#home + 1)
		end
	end
	return path
end

local function expand_home(p: string, home: string): string
	if p == "~" then
		return home
	end
	if p:sub(1, 2) == "~/" then
		return home .. p:sub(2)
	end
	return p
end

local function strip_trailing_slashes(p: string): string
	local s = p
	while #s > 1 and s:sub(-1) == "/" do
		s = s:sub(1, -2)
	end
	return s
end
validate.strip_slashes = strip_trailing_slashes

local function count_words(s: string): number
	local n = 0
	for _ in s:gmatch("%S+") do
		n += 1
	end
	return n
end

local function when_error(text: string, hint: string): string
	if hint:find("Minimum interval", 1, true) then
		return MIN_INTERVAL_COPY
	end
	if hint:find("Minimum is 1 minute", 1, true) then
		return "Use 1 minute or more, e.g. “in 5m”."
	end
	if hint:find("already passed", 1, true) then
		return "That time has already passed."
	end
	if hint:find("^hour:") then
		return "Hour must be 0–23."
	end
	if hint:find("Maximum interval", 1, true) then
		return "Repeats can be at most every 24h. For longer gaps use “daily 09:00”, “every monday 9am” or a cron."
	end
	if hint:find("That date does not exist", 1, true) then
		return "That date doesn't exist."
	end
	if hint:find("never fires", 1, true) then
		return "That schedule never fires: the day doesn't exist in the chosen months."
	end
	if hint:find("I can't read the time", 1, true) then
		return "Couldn't read that time. Try 9am, 09:30 or noon."
	end
	if text:match("^[%d%*/,%-%s]+$") then
		local n = count_words(text)
		if n ~= 5 then
			return string.format("Cron has %d fields; it needs 5 (minute hour day month weekday).", n)
		end
	end
	if hint:find("^need 5 fields") then
		return string.format("Cron has %d fields; it needs 5 (minute hour day month weekday).", count_words(text))
	end
	local shown = text
	if #shown > 60 then
		shown = shown:sub(1, 60) .. "…"
	end
	return string.format("Couldn't read “%s”. Try “weekdays 9am”, “every 2h”, or a cron like 0 9 * * 1-5.", shown)
end

local function find_job(jobs: { any }, id: string?): any?
	if id == nil then
		return nil
	end
	for _, j in ipairs(jobs) do
		if j.id == id then
			return j
		end
	end
	return nil
end

local function int_in(v: any, lo: number, hi: number): number?
	local n = tonumber(v)
	if n == nil or n ~= math.floor(n) or n < lo or n > hi then
		return nil
	end
	return n
end

-- Returns ok, errors_by_field, normalized partial job (only the supplied fields; `schedule` is the record).
function validate.job(fields: JobInput, ctx: Ctx): (boolean, { [string]: string }, any?)
	local errs: { [string]: string } = {}
	local out: { [string]: any } = {}
	local creating = ctx.creating == true
	local existing = find_job(ctx.jobs, ctx.self_id)

	-- name
	if fields.name ~= nil or creating then
		local name = trim(fields.name or "")
		if name == "" then
			errs.name = "Give the job a name."
		elseif name:find("%c") then
			errs.name = "Names can't contain control characters."
		elseif (utf8.len(name) or #name) > const.NAME_MAX then
			errs.name = "Names can be up to 40 characters."
		else
			local lower, slug = name:lower(), validate.slug(name)
			for _, j in ipairs(ctx.jobs) do
				if j.id ~= ctx.self_id and type(j.name) == "string" then
					local jl = j.name:lower()
					if jl == lower or (slug ~= "" and validate.slug(j.name) == slug) then
						errs.name = string.format("A job named “%s” already exists. Pick another name.", j.name)
						break
					end
				end
			end
			if errs.name == nil then
				out.name = name
			end
		end
	end

	-- prompt
	if fields.prompt ~= nil or creating then
		local p = fields.prompt or ""
		if trim(p) == "" then
			errs.prompt = "Write what the agent should do."
		elseif #p > const.PROMPT_MAX then
			errs.prompt = "That prompt is too long (up to 64 KiB)."
		end
	end

	-- when
	if fields.when ~= nil or creating then
		local text = trim(fields.when or "")
		local old = existing and existing.schedule
		if
			old ~= nil
			and old.input == fields.when
			and (old.kind == "cron" or old.kind == "interval" or old.kind == "manual" or old.kind == "once")
		then
			out.schedule = old
		elseif text == "" then
			errs.when = "Enter a schedule, e.g. “weekdays 9am”."
		else
			local rec, hint = schedule.parse(text, ctx.now)
			if rec == nil then
				errs.when = when_error(text, tostring(hint))
			else
				local bad: string? = nil
				if rec.kind == "cron" then
					local spec = cron.parse(rec.expr)
					if spec == nil then
						bad = when_error(text, "")
					elseif cron.min_gap(spec, ctx.now) < cron.MIN_INTERVAL_S then
						bad = MIN_INTERVAL_COPY
					end
				elseif rec.kind == "interval" then
					if (rec.secs or 0) < cron.MIN_INTERVAL_S then
						bad = MIN_INTERVAL_COPY
					end
					rec.anchor_at = ctx.now - ctx.now % 60
				elseif rec.kind == "once" then
					if (rec.run_at or 0) < ctx.now + 60 then
						bad = "That time has already passed."
					end
				end
				if bad ~= nil then
					errs.when = bad
				else
					rec.input = text:sub(1, 200)
					out.schedule = rec
				end
			end
		end
	end

	-- role
	if fields.role ~= nil then
		local role = trim(fields.role):gsub("^@", "")
		if role == "" then
			role = "default"
		end
		if role:match("^[%w_%-]+$") and #role <= 64 then
			out.role = role
		else
			errs.role = "Role names use letters, numbers, - and _."
		end
	end

	-- cwd
	if fields.cwd ~= nil or creating then
		local raw = trim(fields.cwd or "")
		if raw == "" then
			errs.cwd = "Pick a project folder."
		else
			local home = strip_trailing_slashes(ctx.home)
			local p = strip_trailing_slashes(expand_home(raw, ctx.home))
			if p:sub(1, 1) ~= "/" then
				errs.cwd = "Use a full folder path starting with / or ~."
			elseif #p > 1024 then
				errs.cwd = "That folder path is too long."
			elseif validate.unsafe_path(p) then
				errs.cwd = UNSAFE_COPY
			else
				local allow = fields.allow_home
				if allow == nil and existing ~= nil then
					allow = existing.allow_home == true
				end
				if home ~= "" and p == home and allow ~= true then
					errs.cwd = HOME_COPY
				else
					out.cwd = p
					out.allow_home = (p == home) and allow == true
				end
			end
		end
	end

	-- approval
	if fields.approval ~= nil then
		local a = fields.approval
		if a == "yolo" or a == "write" or a == "always_ask" then
			out.approval = a
		else
			errs.approval = "Pick Hands-off, Ask before commands, or Ask for everything."
		end
	end

	-- max_runtime_s
	if fields.max_runtime_s ~= nil then
		local n = int_in(fields.max_runtime_s, const.MAXRUN_MIN_S, const.MAXRUN_MAX_S)
		if n == nil then
			errs.max_runtime_s = RUNTIME_COPY
		else
			out.max_runtime_s = n
		end
	end

	-- catch up
	if fields.catch_up ~= nil then
		local c = fields.catch_up
		if c == "within" or c == "always" or c == "skip" then
			out.catch_up = c
		else
			errs.catch_up = "Pick whether to catch up missed runs."
		end
	end
	if fields.catch_up_window_s ~= nil then
		local n = int_in(fields.catch_up_window_s, const.CATCHUP_MIN_S, const.CATCHUP_MAX_S)
		if n == nil then
			errs.catch_up = "Use 15m or more."
		else
			out.catch_up_window_s = n
		end
	end

	-- pause_after_failures: 0 or 2–10
	if fields.pause_after_failures ~= nil then
		local n = int_in(fields.pause_after_failures, 0, 10)
		if n == nil or n == 1 then
			errs.pause_after_failures = "Use 0 (never) or a number from 2 to 10."
		else
			out.pause_after_failures = n
		end
	end

	-- enabled (placement and focus are global settings, not per-job fields)
	if fields.enabled ~= nil then
		out.enabled = fields.enabled == true
	end

	if next(errs) ~= nil then
		return false, errs, nil
	end
	return true, errs, out
end

local APPROVALS = { yolo = true, write = true, always_ask = true, read_only = true }
local KINDS = { manual = true, cron = true, interval = true, once = true }

-- Structural check of a stored job (load time). Returns an error sentence or nil. Does NOT re-run the
-- "already passed" or uniqueness rules, so an expired one-shot stays valid.
function validate.stored(job: any): string?
	if type(job) ~= "table" then
		return "Not a job."
	end
	if type(job.id) ~= "string" or not job.id:match("^j_[a-z0-9]+$") or #job.id ~= 10 then
		return "Invalid job id."
	end
	if type(job.name) ~= "string" or trim(job.name) == "" or #job.name > const.NAME_MAX * 4 then
		return "Missing or invalid name."
	end
	local s = job.schedule
	if type(s) ~= "table" or not KINDS[s.kind] then
		return "Missing or invalid schedule."
	end
	if s.kind == "cron" then
		if type(s.expr) ~= "string" or cron.parse(s.expr) == nil then
			return "The cron expression can't be read."
		end
	elseif s.kind == "interval" then
		if type(s.secs) ~= "number" or s.secs < 300 or s.secs > 86400 or type(s.anchor_at) ~= "number" then
			return "The repeat interval is invalid."
		end
	elseif s.kind == "once" then
		if type(s.run_at) ~= "number" then
			return "The one-time schedule is invalid."
		end
	end
	if type(job.role) ~= "string" or not job.role:match("^[%w_%-]+$") then
		return "Missing or invalid role."
	end
	if type(job.cwd) ~= "string" or job.cwd == "" or #job.cwd > 1024 then
		return "Missing or invalid folder."
	end
	if job.approval ~= nil and not APPROVALS[job.approval] then
		return "Invalid approval mode."
	end
	if job.max_runtime_s ~= nil and int_in(job.max_runtime_s, const.MAXRUN_MIN_S, const.MAXRUN_MAX_S) == nil then
		return "Invalid time limit."
	end
	return nil
end

return validate
