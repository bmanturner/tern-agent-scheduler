--!strict
-- Window half: Carly exports (list, add, run, pause jobs) and a short request context. Creation is
-- done by the host (`carly_create` intent + reply file); this half only pre-validates and relays.

local commands = require("./commands")
local outbox = require("./outbox")
local schedule = require("./schedule")
local status = require("./status")
local wsnap = require("./wsnap")

local carly = {}

local SPEC_MAX = 1024
local ADD_WAIT_MS = 15000
local REPLY_WAIT_MS = 12000
-- Intents the host hasn't applied by then are dropped, because the caller has been told they failed.
local EXPIRES_S = 20
local MIN_PREFIX = 3

-- Tern rejects an export whose sig or doc exceeds 1024 bytes, which would abort registration.
local function fit(s: string): string
	if #s <= SPEC_MAX then
		return s
	end
	local stop = SPEC_MAX - 3 -- room for "…"
	while stop > 0 do
		local b = string.byte(s, stop + 1)
		if b < 0x80 or b >= 0xC0 then
			break
		end
		stop -= 1
	end
	return string.sub(s, 1, stop) .. "…"
end
carly.fit = fit

local function str(v: any): string?
	if type(v) == "string" then
		local t = string.gsub(v, "^%s+", "")
		t = string.gsub(t, "%s+$", "")
		return t
	end
	return nil
end

-- Exports receive positional args followed by a fresh cx and the call; split them robustly.
local function split_args(...: any): ({ any }, WindowCx, ExportCall)
	local n = select("#", ...)
	local args: { any } = {}
	for i = 1, n - 2 do
		args[i] = (select(i, ...))
	end
	return args, (select(n - 1, ...)) :: any, (select(n, ...)) :: any
end

local function fail(call: ExportCall, message: string): ExportWait
	call:fail(message)
	return call:wait(1000)
end

-- The job named `name` (case-insensitive exact, then a unique prefix when `name` has at least
-- MIN_PREFIX characters) or nil and an error naming the candidates.
function carly.find_job(name: string): (any?, string?)
	wsnap.poll()
	local jobs = wsnap.jobs()
	if #jobs == 0 then
		return nil, "There are no scheduled jobs yet."
	end
	local want = string.lower(name)
	local exact: { any } = {}
	local prefix: { any } = {}
	local names: { string } = {}
	for _, j in jobs do
		local n = string.lower(tostring(j.name))
		table.insert(names, tostring(j.name))
		if n == want then
			table.insert(exact, j)
		elseif #want >= MIN_PREFIX and string.sub(n, 1, #want) == want then
			table.insert(prefix, j)
		end
	end
	if #exact == 1 then
		return exact[1], nil
	elseif #exact == 0 and #prefix == 1 then
		return prefix[1], nil
	end
	local list: { string } = {}
	for _, j in (if #exact > 1 then exact else if #prefix > 0 then prefix else {}) do
		table.insert(list, tostring(j.name))
	end
	if #list == 0 then
		list = names
	end
	local label = if #list == #names and #exact == 0 and #prefix == 0 then "No job named “%s”. Jobs: %s" else "“%s” is ambiguous. Matches: %s"
	return nil, string.format(label, name, table.concat(list, ", "))
end

local function job_state(j: any): string
	if j.invalid ~= nil or j.paused_reason == "blocked" or j.paused_reason == "failures" then
		return "needs fixing"
	elseif j.enabled == true then
		return "active"
	end
	return "paused"
end

local function next_text(at: any, j: any, paused_all: boolean): string
	if j.enabled ~= true then
		return "paused"
	elseif paused_all then
		return "all jobs paused"
	elseif type(at) == "number" then
		return os.date("%a %d %b %H:%M", at)
	end
	return "manual only"
end

local function last_text(j: any): string
	local last = j.last
	if type(last) ~= "table" then
		return "never run"
	end
	local text = tostring(last.state)
	if type(last.summary) == "string" and last.summary ~= "" then
		text ..= ": " .. last.summary
	end
	return text
end

local ADD_DOC = "Create and start a scheduled omp agent job right away (no review step). `when` accepts: `daily 09:00`, `weekdays 9am`, `mon,thu 18:30`, `every 2h`, `every 15m` (min 5m), `hourly`, `every friday 4pm`, `monthly on the 1st 9am`, `in 30m`, `tomorrow 8am`, `2026-10-14 15:00`, `manual`, or a 5-field cron like `0 9 * * 1-5`. `folder` is an existing local folder (default: the focused pane's). `role` is an omp model role such as `@default` (default) or `@smol`. Jobs use the default approval mode (Hands-off unless changed in settings); Hands-off runs commands as the user. Returns the job's name, schedule and next run."

function carly.job_add(...: any): any
	local a, cx, call = split_args(...)
	local name = str(a[1]) or ""
	local prompt = a[2]
	local when = str(a[3])
	local folder = str(a[4]) or ""
	local role = str(a[5]) or ""

	if type(prompt) ~= "string" or str(prompt) == "" then
		return fail(call, "Write what the agent should do.")
	end
	if #name > 200 then
		return fail(call, "Names can be up to 40 characters.")
	end
	if when == nil or when == "" then
		return fail(call, "When should it run? Try “weekdays 9am”, “every 2h”, or a cron like 0 9 * * 1-5.")
	end
	local spec, hint = schedule.parse(when, os.time())
	if spec == nil then
		return fail(call, tostring(hint or ("Couldn't read “" .. when .. "”.")))
	end
	if folder == "" then
		local cwd, remote = commands.focused_cwd(cx)
		if remote ~= nil then
			return fail(call, remote)
		end
		if cwd == "" then
			return fail(call, "Which folder should it run in?")
		end
		folder = cwd
	end

	local reply_id = outbox.reply_id()
	local payload: { [string]: any } =
		{ reply = reply_id, prompt = prompt, when = when, folder = folder, expires = os.time() + EXPIRES_S }
	if name ~= "" then
		payload.name = name
	end
	if role ~= "" then
		payload.role = role
	end
	-- JSON escaping can double a prompt's size, so measure what will actually be written.
	local encoded = outbox.encode("carly_create", payload)
	if encoded ~= nil and #encoded > outbox.INTENT_MAX_BYTES then
		return fail(call, "That prompt is too long for Carly. Use the manager.")
	end
	local sent, err = outbox.send("carly_create", payload)
	if sent == nil then
		return fail(call, tostring(err))
	end

	outbox.await_reply(reply_id, REPLY_WAIT_MS, function(reply)
		if call.cancelled then
			return
		end
		if reply == nil then
			call:fail("Agent Scheduler didn't answer in 12 s. The job may still have been created; check the manager.")
			return
		end
		if reply.ok ~= true then
			call:fail(tostring(reply.error or "Agent Scheduler couldn't create the job."))
			return
		end
		-- The "Carly scheduled …" toast comes from the snapshot diff in status, once per window.
		reply.format = nil
		call:reply(reply)
	end)
	return call:wait(ADD_WAIT_MS)
end

function carly.register()
	tern.carly.export("jobs_list", {
		sig = "() -> {{name: string, when: string, next: string, role: string, folder: string, state: string, last: string}}",
		doc = fit("Lists the scheduled agent jobs: name, schedule text, next run, role, folder, state (\"active\", \"paused\" or \"needs fixing\") and the last run's outcome. Read-only and instant."),
	}, function(): any
		wsnap.poll()
		local out: { any } = {}
		local snap = wsnap.get()
		local paused_all = snap ~= nil and snap.paused_all == true
		for _, j in wsnap.jobs() do
			table.insert(out, {
				name = tostring(j.name),
				when = tostring(j.when),
				next = next_text(j.next_run, j, paused_all),
				role = "@" .. tostring(j.role),
				folder = tostring(j.folder),
				state = job_state(j),
				last = last_text(j),
			})
		end
		return (tern :: any).json.array(out)
	end)

	tern.carly.export("job_add", {
		sig = "(name: string, prompt: string, when: string, folder: string?, role: string?) -> {name: string, when: string, next: string, folder: string, role: string, approval: string}",
		doc = fit(ADD_DOC),
	}, carly.job_add)

	tern.carly.export("job_run", {
		sig = "(name: string) -> string",
		doc = fit("Runs a scheduled job now, with its saved settings. `name` is matched case-insensitively (a unique prefix of 3+ characters works); an unknown or ambiguous name fails and lists the matches. Fails if the job is already running or needs fixing. Returns \"Queued\"; the run starts within a few seconds."),
	}, function(...: any): any
		local a, _cx, call = split_args(...)
		local name = str(a[1])
		if name == nil or name == "" then
			return fail(call, "Which job? Use jobs_list() for the names.")
		end
		local job, err = carly.find_job(name)
		if job == nil then
			return fail(call, tostring(err))
		end
		local snap = wsnap.get()
		if snap ~= nil and snap.paused_all == true then
			return fail(call, "Resume all jobs to run.")
		end
		if job.invalid ~= nil then
			return fail(call, tostring(job.name) .. " needs fixing in the manager.")
		end
		for _, r in wsnap.inflight() do
			if tostring(r.job_id) == tostring(job.id) then
				return fail(call, tostring(job.name) .. " is already running.")
			end
		end
		local sent, serr = outbox.send("run_now", { job_id = tostring(job.id), expires = os.time() + EXPIRES_S })
		if sent == nil then
			return fail(call, tostring(serr))
		end
		return "Queued"
	end)

	tern.carly.export("job_pause", {
		sig = "(name: string, paused: boolean) -> string",
		doc = fit("Pauses (paused = true) or resumes (paused = false) one scheduled job. `name` is matched case-insensitively (a unique prefix of 3+ characters works). `paused` must be true or false. A run already in progress keeps going. Returns what happened."),
	}, function(...: any): any
		local a, _cx, call = split_args(...)
		local name = str(a[1])
		if name == nil or name == "" then
			return fail(call, "Which job? Use jobs_list() for the names.")
		end
		local job, err = carly.find_job(name)
		if job == nil then
			return fail(call, tostring(err))
		end
		local pause = a[2]
		if type(pause) ~= "boolean" then
			return fail(call, "paused must be true or false.")
		end
		local sent, serr = outbox.send(if pause then "pause" else "resume", { job_id = tostring(job.id) })
		if sent == nil then
			return fail(call, tostring(serr))
		end
		return (if pause then "Paused " else "Resumed ") .. tostring(job.name)
	end)

	tern.carly.export("jobs_pause_all", {
		sig = "(paused: boolean) -> string",
		doc = fit("Pauses (paused = true) or resumes (paused = false) every scheduled job at once. Runs already in progress keep going. Returns what happened."),
	}, function(...: any): any
		local a, _cx, call = split_args(...)
		local pause = a[1]
		if type(pause) ~= "boolean" then
			return fail(call, "paused must be true or false.")
		end
		local sent, serr = outbox.send(if pause then "pause_all" else "resume_all", nil)
		if sent == nil then
			return fail(call, tostring(serr))
		end
		return if pause then "All jobs paused" else "All jobs resumed"
	end)

	tern.carly.context(function(_cx: WindowCx): string?
		return status.context()
	end)
end

return carly
