--!strict
local time_host = require("./time_host")
local timefmt = require("./timefmt")
-- lib/jobs.luau : jobs.json, state.json, settings.json, prompts/, trash/ (EN §1, §2). Host only; the
-- manager and the runner call it in-process (single writer).
local const = require("./const")
local cron = require("./cron")
local ids = require("./ids")
local ledger = require("./ledger")
local policy = require("./policy")
local store = require("./store")
local validate = require("./validate")

local jobs = {}

export type Job = { [string]: any }
export type JobState = { [string]: any }

local FORMAT = 1

local job_list: { Job } = {}
local invalid_list: { { id: string, name: string, error: string, raw: any } } = {}
local state_tbl: { [string]: JobState } = {}
local inflight_ids: { string } = {}
local seq = 0
local settings_tbl: { [string]: any } = {}
local loaded = false
local deleted: { job: Job, state: JobState?, prompt: string, at: number, trash: string }? = nil
local spec_cache: { [string]: any } = {}
-- raw state.json entries of jobs that aren't loaded; written back unchanged (F24)
local kept_state: { [string]: any } = {}
local SAVE_FAILED_COPY = "Agent Scheduler can't save right now. Check Setup."

local function data_blocked(): boolean
	local h = store.health()
	return h == "damaged" or h == "readonly"
end

local function copy_table(t: { [string]: any }): { [string]: any }
	return table.clone(t)
end

-- Puts every key of `from` back into `t` and drops keys added since.
local function restore_table(t: { [string]: any }, from: { [string]: any })
	for k in pairs(t) do
		if from[k] == nil then
			t[k] = nil
		end
	end
	for k, v in pairs(from) do
		t[k] = v
	end
end

local function default_settings(): { [string]: any }
	return {
		format = FORMAT,
		paused_all = false,
		max_concurrent = const.MAX_CONCURRENT_DEFAULT,
		cap_wait_s = const.CAP_WAIT_S_DEFAULT,
		catchup_spacing_s = const.CATCHUP_SPACING_S_DEFAULT,
		catchup_window_s = const.CATCHUP_DEFAULT_S,
		max_finished_panes = const.MAX_FINISHED_PANES,
		manager_layout = "timeline",
		manager_results = "fade",
		time_format = "automatic",
		last_looked = 0,
		retain_runs = 50,
		retain_days = 90,
		defaults = {
			role = "default",
			placement = { where = "session" },
			focus = "keep",
			approval = "yolo",
			max_runtime_s = const.MAXRUN_DEFAULT_S,
			overlap = "skip",
			catch_up = "within",
			notify = "issues",
			system_notification = true,
			after = "keep",
			pause_after_failures = 3,
		},
		bin_dirs = {},
		session_name = const.SESSION_NAME_DEFAULT,
		show_next_in_status = true,
		keep_awake = false,
		watchdog = "notify",
		welcomed = false,
		first_scheduled_toast_done = false,
		max_jobs = const.MAX_JOBS,
	}
end

local function fill_defaults(dst: { [string]: any }, src: { [string]: any })
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = v
		elseif type(v) == "table" and type(dst[k]) == "table" and k == "defaults" then
			fill_defaults(dst[k], v)
		end
	end
end

local function home(): string
	local ok, h = pcall(function()
		return (tern :: any).getenv("HOME")
	end)
	if ok and type(h) == "string" then
		return h
	end
	return ""
end
jobs.home = home

local function array(t: any): any
	return (tern :: any).json.array(t)
end

local function find_index(id: string): number?
	for i, j in ipairs(job_list) do
		if j.id == id then
			return i
		end
	end
	return nil
end

local function id_taken(id: string): boolean
	if find_index(id) ~= nil then
		return true
	end
	for _, bad in ipairs(invalid_list) do
		if bad.id == id then
			return true
		end
	end
	return false
end

local function prompt_rel(id: string): string
	return "prompts/" .. id .. ".md"
end

local function tz_record(): { [string]: any }
	local abbr = ""
	pcall(function()
		abbr = timefmt.date("%Z") :: string
	end)
	return { abbr = abbr }
end

-- ---------- persistence ----------

local function save_jobs(): boolean
	local out: { any } = {}
	for _, j in ipairs(job_list) do
		table.insert(out, j)
	end
	for _, bad in ipairs(invalid_list) do
		table.insert(out, bad.raw)
	end
	local ok = store.save("jobs", { format = FORMAT, seq = seq, jobs = array(out) }, const.CAP_JOBS)
	return ok
end

function jobs.save_state(): boolean
	local merged: { [string]: any } = {}
	for id, e in pairs(kept_state) do
		merged[id] = e
	end
	for id, e in pairs(state_tbl) do
		merged[id] = e
	end
	local ok = store.save("state", {
		format = FORMAT,
		saved_at = os.time(),
		jobs = merged,
		inflight = array(inflight_ids),
	}, const.CAP_STATE)
	return ok
end

local function save_settings(): (boolean, string?)
	return store.save("settings", settings_tbl, const.CAP_SETTINGS)
end

-- ---------- load ----------

local function materialize(job: Job, d: { [string]: any }, now: number)
	if job.role == nil then job.role = d.role or "default" end
	job.placement = nil -- where runs appear and bring-to-front are global settings (F34)
	job.focus = nil
	if job.approval == nil then job.approval = d.approval or "yolo" end
	if job.max_runtime_s == nil then job.max_runtime_s = d.max_runtime_s or const.MAXRUN_DEFAULT_S end
	if job.overlap == nil then job.overlap = d.overlap or "skip" end
	if job.catch_up == nil then job.catch_up = d.catch_up or "within" end
	if job.notify == nil then job.notify = d.notify or "issues" end
	if job.system_notification == nil then job.system_notification = d.system_notification ~= false end
	if job.after == nil then job.after = d.after or "keep" end
	if job.pause_after_failures == nil then job.pause_after_failures = d.pause_after_failures or 3 end
	if job.unattended_note == nil then job.unattended_note = true end
	if job.enabled == nil then job.enabled = true end
	if job.allow_home == nil then job.allow_home = false end
	if job.created_by ~= "carly" then job.created_by = "user" end
	if job.created_at == nil then job.created_at = now end
	if job.updated_at == nil then job.updated_at = now end
	if job.tz == nil then job.tz = tz_record() end
end

local function fresh_state(now: number): JobState
	return { cursor = now, armed_at = now, failure_streak = 0, runs_total = 0 }
end

-- Loads settings, jobs and state; returns store health ("ok"|"data_unwritable"|"readonly"|"damaged").
function jobs.load(now: number): string
	if deleted ~= nil then
		local d = deleted
		deleted = nil
		ledger.remove_job(d.job.id)
		store.remove("runs/" .. tostring(d.job.id))
	end
	job_list, invalid_list, state_tbl, inflight_ids, seq = {}, {}, {}, {}, 0

	local s = store.load("settings", const.CAP_SETTINGS)
	settings_tbl = default_settings()
	if type(s) == "table" then
		for k, v in pairs(s) do
			settings_tbl[k] = v
		end
		fill_defaults(settings_tbl, default_settings())
	end

	time_host.configure(settings_tbl.time_format)

	local data = store.load("jobs", const.CAP_JOBS)
	if type(data) == "table" then
		seq = tonumber(data.seq) or 0
		local seen: { [string]: boolean } = {}
		local lower_names: { [string]: boolean } = {}
		for _, raw in ipairs(type(data.jobs) == "table" and data.jobs or {}) do
			local err = validate.stored(raw)
			if err == nil and seen[raw.id] then
				err = "Duplicate job id."
			end
			if err == nil and lower_names[raw.name:lower()] then
				err = "Another job already has this name."
			end
			if err ~= nil then
				local name = type(raw) == "table" and tostring(raw.name or raw.id or "?") or "?"
				table.insert(invalid_list, {
					id = type(raw) == "table" and tostring(raw.id or "") or "",
					name = name,
					error = err,
					raw = raw,
				})
			else
				seen[raw.id] = true
				lower_names[raw.name:lower()] = true
				materialize(raw, settings_tbl.defaults, now)
				table.insert(job_list, raw)
			end
		end
	end

	local st = store.load("state", const.CAP_STATE)
	kept_state = {}
	if type(st) == "table" then
		local sj = type(st.jobs) == "table" and st.jobs or {}
		for _, j in ipairs(job_list) do
			local e = sj[j.id]
			if type(e) == "table" then
				state_tbl[j.id] = e
			end
		end
		-- Entries for jobs that aren't loaded (unreadable entries, or jobs.json damaged) are carried
		-- through every state save so repairing the file doesn't lose cursors and history (F24).
		local jobs_blocked = table.find(store.blocked_names(), "jobs") ~= nil
		local invalid_ids: { [string]: boolean } = {}
		for _, bad in ipairs(invalid_list) do
			invalid_ids[bad.id] = true
		end
		for id, e in pairs(sj) do
			if state_tbl[id] == nil and type(e) == "table" and (jobs_blocked or invalid_ids[id] == true) then
				kept_state[id] = e
			end
		end
		for _, id in ipairs(type(st.inflight) == "table" and st.inflight or {}) do
			if type(id) == "string" then
				table.insert(inflight_ids, id)
			end
		end
	end
	-- EN §2.2.6: jobs without a state entry are armed now (never "catch up" on history). Jobs with
	-- state get next_run recomputed from their cursor: the cached value may come from an older
	-- plugin version or another time zone, and the cursor alone decides which slots are still due.
	for _, j in ipairs(job_list) do
		local e = state_tbl[j.id]
		if e == nil then
			e = fresh_state(now)
			state_tbl[j.id] = e
			e.next_run = jobs.next_run(j, now)
		elseif j.enabled ~= false and e.done ~= true and j.schedule.kind ~= "manual" and type(e.cursor) == "number" then
			local view = jobs.policy_view(j)
			e.next_run = policy.next_after(view, e.cursor)
		end
	end
	loaded = true
	return store.health()
end

-- ---------- accessors ----------

function jobs.list(): { Job }
	return job_list
end

function jobs.get(id: string): Job?
	local i = find_index(id)
	return i and job_list[i] or nil
end

function jobs.by_name(name: string): { Job }
	local lower = name:lower()
	local exact: { Job } = {}
	local prefix: { Job } = {}
	for _, j in ipairs(job_list) do
		local jl = (j.name :: string):lower()
		if jl == lower then
			table.insert(exact, j)
		elseif lower ~= "" and jl:sub(1, #lower) == lower then
			table.insert(prefix, j)
		end
	end
	if #exact > 0 then
		return exact
	end
	return prefix
end

function jobs.invalid(): { { id: string, name: string, error: string } }
	local out = {}
	for _, bad in ipairs(invalid_list) do
		table.insert(out, { id = bad.id, name = bad.name, error = bad.error })
	end
	return out
end

-- Mutable per-job runtime state. Callers then call jobs.save_state().
function jobs.state(id: string): JobState
	local s = state_tbl[id]
	if s == nil then
		s = fresh_state(os.time())
		if find_index(id) ~= nil then
			state_tbl[id] = s
		end
	end
	return s
end

-- Mutable list of in-flight run ids (stored in state.json).
function jobs.inflight(): { string }
	return inflight_ids
end

function jobs.settings(): { [string]: any }
	return settings_tbl
end

-- True while the user paused everything or any structured data file is damaged/read-only (EN §2.2.4).
function jobs.paused_all(): boolean
	if settings_tbl.paused_all == true then
		return true
	end
	local h = store.health()
	return h == "damaged" or h == "readonly"
end

function jobs.prompt(id: string): string?
	return store.read_text(prompt_rel(id), const.PROMPT_MAX)
end

-- ---------- settings ----------

local function in_enum(v: any, set: { string }): boolean
	for _, s in ipairs(set) do
		if v == s then
			return true
		end
	end
	return false
end

local function int_in(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function need(ok: boolean, msg: string): string?
	if ok then
		return nil
	end
	return msg
end

local function check_setting(k: string, v: any): string?
	if k == "paused_all" or k == "show_next_in_status" or k == "keep_awake" or k == "welcomed" or k == "first_scheduled_toast_done" then
		return need(type(v) == "boolean", k .. " must be true or false.")
	elseif k == "time_format" then
		return need(in_enum(v, { "automatic", "12h", "24h" }), "Pick Automatic, 12-hour or 24-hour.")
	elseif k == "manager_layout" then
		return need(in_enum(v, { "timeline", "classic" }), "Pick Timeline or Classic job list.")
	elseif k == "manager_results" then
		return need(in_enum(v, { "fade", "stay" }), "Pick Fade once seen or Stay until marked seen.")
	elseif k == "last_looked" then
		return need(type(v) == "number" and v >= 0, "Use a valid time.")
	elseif k == "max_concurrent" then
		return need(int_in(v, 1, 10), "Run at most 1 to 10 jobs at once.")
	elseif k == "cap_wait_s" then
		return need(int_in(v, 30, 86400), "Waiting time must be 30 seconds to 24 hours.")
	elseif k == "catchup_spacing_s" then
		return need(int_in(v, 0, 3600), "Catch-up spacing must be 0 to 3600 seconds.")
	elseif k == "catchup_window_s" then
		return need(int_in(v, const.CATCHUP_MIN_S, const.CATCHUP_MAX_S), "Use 15m or more.")
	elseif k == "max_finished_panes" then
		return need(int_in(v, const.MAX_FINISHED_PANES_MIN, const.MAX_FINISHED_PANES_MAX), "Keep 1 to 20 finished panes.")
	elseif k == "retain_runs" then
		return need(int_in(v, 5, 500), "Keep 5 to 500 runs per job.")
	elseif k == "retain_days" then
		return need(int_in(v, 1, 365), "Keep history for 1 to 365 days.")
	elseif k == "max_jobs" then
		return need(int_in(v, 1, const.MAX_JOBS), "Up to 50 jobs.")
	elseif k == "session_name" then
		if type(v) == "string" and #v >= 1 and #v <= 40 and v:match("^[%w _%.%-]+$") then
			return nil
		end
		return "Session names use letters, numbers, spaces, . _ - (up to 40)."
	elseif k == "watchdog" then
		return need(in_enum(v, { "notify", "reload" }), "Pick notify or reload.")
	elseif k == "omp_path" or k == "tern_path" then
		if v == "" or (type(v) == "string" and v:sub(1, 1) == "/" and not validate.unsafe_path(v)) then
			return nil
		end
		return "Use a full path to the program."
	elseif k == "bin_dirs" then
		if type(v) ~= "table" then
			return "Extra folders must be a list."
		end
		for _, d in ipairs(v) do
			if type(d) ~= "string" or d:sub(1, 1) ~= "/" or validate.unsafe_path(d) then
				return "Use full folder paths."
			end
		end
		return nil
	elseif k == "defaults" then
		if type(v) ~= "table" then
			return "defaults must be a table."
		end
		local d = v :: { [string]: any }
		if d.approval ~= nil and not in_enum(d.approval, { "yolo", "write", "always_ask" }) then
			return "Pick Hands-off, Ask before commands, or Ask for everything."
		end
		if d.placement ~= nil and not (type(d.placement) == "table" and in_enum((d.placement :: any).where, { "session", "tab" })) then
			return "Pick the Scheduled runs session or a background tab."
		end
		if d.focus ~= nil and not in_enum(d.focus, { "keep", "front" }) then
			return "Pick keep or front."
		end
		if d.max_runtime_s ~= nil and not int_in(d.max_runtime_s, const.MAXRUN_MIN_S, const.MAXRUN_MAX_S) then
			return "Use a time like 45m or 2h (up to 8h)."
		end
		if d.role ~= nil and not (type(d.role) == "string" and (d.role :: string):match("^[%w_%-]+$")) then
			return "Role names use letters, numbers, - and _."
		end
		return nil
	end
	return "Unknown setting " .. k .. "."
end

-- Applies a validated top-level patch (`defaults` is merged key-wise). nil value clears omp_path/tern_path.
function jobs.set_settings(patch: { [string]: any }): (boolean, string?)
	for k, v in pairs(patch) do
		local err = check_setting(k, v)
		if err ~= nil then
			return false, err
		end
	end
	for k, v in pairs(patch) do
		if k == "defaults" then
			for dk, dv in pairs(v :: { [string]: any }) do
				(settings_tbl.defaults :: any)[dk] = dv
			end
		elseif (k == "omp_path" or k == "tern_path") and v == "" then
			settings_tbl[k] = nil
		else
			settings_tbl[k] = v
		end
	end
	if patch.time_format ~= nil then time_host.configure(settings_tbl.time_format) end
	local ok, err = save_settings()
	if not ok then
		return false, err
	end
	return true, nil
end

function jobs.set_paused_all(on: boolean)
	jobs.set_settings({ paused_all = on })
end

-- ---------- schedule helpers ----------

-- Parsed cron spec for a stored expr (cached).
local function spec_for(expr: string): any
	local s = spec_cache[expr]
	if s == nil then
		s = cron.parse(expr)
		spec_cache[expr] = s
	end
	return s
end

-- Adapts a stored job (EN §1.1 `schedule` record + state) to the table `policy.decide`/`policy.next_after`
-- expect (policy.luau header): { sched = {kind, spec?, secs?, anchor?, run_at?}, cursor, next_run,
-- catch_up, catch_up_window_s }. The catch-up window falls back to settings.catchup_window_s.
function jobs.policy_view(job: Job): any
	local s = job.schedule
	local st = jobs.state(job.id)
	local sched: { [string]: any } = { kind = s.kind }
	if s.kind == "cron" then
		sched.spec = spec_for(s.expr)
	elseif s.kind == "interval" then
		sched.secs = s.secs
		sched.anchor = s.anchor_at
	elseif s.kind == "once" then
		sched.run_at = s.run_at
	end
	return {
		sched = sched,
		cursor = st.cursor or st.armed_at or 0,
		next_run = st.next_run,
		catch_up = job.catch_up or "within",
		catch_up_window_s = job.catch_up_window_s or tonumber(settings_tbl.catchup_window_s) or const.DEFAULT_WINDOW_S,
	}
end

-- First scheduled instant strictly after `now` (nil for manual, disabled, or a finished one-shot).
function jobs.next_run(job: Job, now: number): number?
	if job.enabled == false then
		return nil
	end
	local s = job.schedule
	if s.kind == "manual" then
		return nil
	end
	local view = {
		sched = {
			kind = s.kind,
			spec = s.kind == "cron" and spec_for(s.expr) or nil,
			secs = s.secs,
			anchor = s.anchor_at,
			run_at = s.run_at,
		},
		cursor = now,
	}
	return policy.next_after(view, now)
end

function jobs.describe(job: Job): string
	local s = job.schedule
	if s.kind == "manual" then
		return "Manual only"
	elseif s.kind == "cron" then
		local spec = spec_for(s.expr)
		return spec and cron.describe(spec) or tostring(s.input)
	elseif s.kind == "interval" then
		local secs = tonumber(s.secs) or 0
		if secs % 3600 == 0 then
			local h = secs // 3600
			return h == 1 and "Every hour" or string.format("Every %d hours", h)
		end
		return string.format("Every %d minutes", secs // 60)
	end
	local w = cron.clock.date("*t", tonumber(s.run_at) or 0)
	local names = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
	local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
	return string.format("Once, %s %d %s %s", names[w.wday] or "", w.day, months[w.month] or "", timefmt.clock(w.hour, w.min))
end

-- Re-arm: cursor = armed_at = now, interval anchor floored to the minute, next_run recomputed.
local function arm(job: Job, now: number)
	local s = job.schedule
	if s.kind == "interval" then
		s.anchor_at = now - now % 60
	end
	local st = jobs.state(job.id)
	st.cursor = now
	st.armed_at = now
	st.pending = nil
	st.done = nil
	st.next_run = jobs.next_run(job, now)
end

-- ---------- create / update / delete ----------

local function validation_ctx(self_id: string?, now: number, creating: boolean): validate.Ctx
	return {
		jobs = job_list,
		self_id = self_id,
		now = now,
		home = home(),
		creating = creating,
		defaults = settings_tbl.defaults,
	}
end

local function save_both(): boolean
	local ok = save_jobs()
	jobs.save_state()
	return ok
end

function jobs.create(input: validate.JobInput, prompt: string, created_by: string, now: number): (Job?, { [string]: string }?)
	if data_blocked() then
		return nil, { name = SAVE_FAILED_COPY }
	end
	if #job_list + #invalid_list >= (tonumber(settings_tbl.max_jobs) or const.MAX_JOBS) then
		return nil, { name = string.format("You can have up to %d jobs. Delete one first.", tonumber(settings_tbl.max_jobs) or const.MAX_JOBS) }
	end
	local fields: { [string]: any } = {}
	for k, v in pairs(input :: any) do
		fields[k] = v
	end
	fields.prompt = prompt
	local ok, errs, norm = validate.job(fields :: any, validation_ctx(nil, now, true))
	if not ok or norm == nil then
		return nil, errs
	end
	local id = ids.job_id(id_taken)
	local job: Job = norm
	job.id = id
	job.created_by = created_by == "carly" and "carly" or "user"
	job.created_at = now
	job.updated_at = now
	materialize(job, settings_tbl.defaults, now)
	local wok = store.write_text(prompt_rel(id), prompt)
	if not wok then
		return nil, { prompt = "Couldn't save the prompt. Check the data folder." }
	end
	local prev_seq = seq
	seq += 1
	table.insert(job_list, job)
	state_tbl[id] = fresh_state(now)
	arm(job, now)
	if not save_both() then
		table.remove(job_list)
		state_tbl[id] = nil
		seq = prev_seq
		store.remove(prompt_rel(id))
		save_jobs() -- replaces the failed text queued for retry
		return nil, { name = SAVE_FAILED_COPY }
	end
	return job, nil
end

-- Applies a patch of the supplied fields. `prompt` nil leaves the prompt file alone.
function jobs.update(id: string, input: validate.JobInput, prompt: string?, now: number): (Job?, { [string]: string }?)
	local job = jobs.get(id)
	if job == nil then
		return nil, { name = "That job no longer exists." }
	end
	if data_blocked() then
		return nil, { name = SAVE_FAILED_COPY }
	end
	local fields: { [string]: any } = {}
	for k, v in pairs(input :: any) do
		fields[k] = v
	end
	if prompt ~= nil then
		fields.prompt = prompt
	end
	local ok, errs, norm = validate.job(fields :: any, validation_ctx(id, now, false))
	if not ok or norm == nil then
		return nil, errs
	end
	if prompt ~= nil then
		local wok = store.write_text(prompt_rel(id), prompt)
		if not wok then
			return nil, { prompt = "Couldn't save the prompt. Check the data folder." }
		end
	end
	local st = jobs.state(id)
	local before_job = copy_table(job)
	local before_state = copy_table(st)
	local before_prompt: string? = if prompt ~= nil then jobs.prompt(id) else nil
	if prompt ~= nil then
		local wok = store.write_text(prompt_rel(id), prompt)
		if not wok then
			return nil, { prompt = "Couldn't save the prompt. Check the data folder." }
		end
	end
	local rearm = false
	if norm.schedule ~= nil then
		local old, new = job.schedule, norm.schedule
		if old.kind ~= new.kind or old.expr ~= new.expr or old.secs ~= new.secs or old.run_at ~= new.run_at or old.input ~= new.input then
			rearm = true
		end
		job.schedule = new
		if rearm and st.done == true then
			job.enabled = true -- editing the schedule of a finished one-shot re-arms it (EN §6.6)
			st.paused_reason = nil
		end
	end
	local was_enabled = job.enabled ~= false
	for k, v in pairs(norm) do
		if k ~= "schedule" then
			job[k] = v
		end
	end
	job.updated_at = now
	local now_enabled = job.enabled ~= false
	if now_enabled ~= was_enabled then
		rearm = true
		if now_enabled then
			st.paused_reason = nil
			st.failure_streak = 0
			st.incident = nil
			if type(st.watch) == "table" and type(st.watch.conditions) == "table" then
				st.watch.conditions.err = nil
			end
		else
			st.paused_reason = "user"
		end
	end
	if rearm then
		arm(job, now)
	end
	if not now_enabled then
		st.next_run = nil
	end
	if not save_both() then
		restore_table(job, before_job)
		restore_table(st, before_state)
		if before_prompt ~= nil then
			store.write_text(prompt_rel(id), before_prompt)
		end
		save_jobs() -- replaces the failed text queued for retry
		return nil, { name = SAVE_FAILED_COPY }
	end
	return job, nil
end

local function purge_deleted_files(d: { job: Job, state: JobState?, prompt: string, at: number, trash: string })
	local id = d.job.id :: string
	ledger.remove_job(id)
	store.remove("runs/" .. id)
end

-- Removes the ledger and run folders of a deleted job once its undo window has passed (F54).
function jobs.purge_deleted(now: number)
	local d = deleted
	if d ~= nil and now - d.at > const.UNDO_DELETE_S then
		deleted = nil
		purge_deleted_files(d)
	end
end

-- EN §2.5: prompt copy to trash/, then remove prompt and state. The ledger and run folders stay until the
-- undo window ends so jobs.undo_delete restores the history too; keeps the job for undo.
function jobs.delete(id: string, now: number): boolean
	local i = find_index(id)
	if i == nil or data_blocked() then
		return false
	end
	local pending = deleted
	if pending ~= nil then
		deleted = nil
		purge_deleted_files(pending) -- only one undo slot: the older delete is final
	end
	local job = job_list[i]
	local prompt = jobs.prompt(id) or ""
	-- The deletion time is in the name (tern.fs has no mtime) so housekeeping can age it out.
	local trash = string.format("trash/%d-%s.md", now, id)
	store.write_text(trash, prompt)
	table.remove(job_list, i)
	if not save_jobs() then
		table.insert(job_list, i, job)
		save_jobs()
		store.remove(trash)
		return false
	end
	deleted = { job = job, state = state_tbl[id], prompt = prompt, at = now, trash = trash }
	state_tbl[id] = nil
	for k = #inflight_ids, 1, -1 do
		if ids.job8(id) == (inflight_ids[k]:match("^r_([a-z0-9]+)_")) then
			table.remove(inflight_ids, k)
		end
	end
	ledger.hide_job(id)
	store.remove(prompt_rel(id))
	jobs.save_state()
	pcall(function()
		(tern :: any).timer((const.UNDO_DELETE_S + 1) * 1000, function()
			jobs.purge_deleted(os.time())
		end)
	end)
	return true
end

-- Restores the job deleted within UNDO_DELETE_S (definition, prompt, run history; re-armed now).
function jobs.undo_delete(now: number): Job?
	local d = deleted
	if d == nil or now - d.at > const.UNDO_DELETE_S then
		if d ~= nil then
			deleted = nil
			purge_deleted_files(d)
		end
		return nil
	end
	if data_blocked() then
		return nil
	end
	local job = d.job
	local lower = (job.name :: string):lower()
	for _, j in ipairs(job_list) do
		if (j.name :: string):lower() == lower then
			return nil
		end
	end
	if find_index(job.id) ~= nil then
		return nil
	end
	store.write_text(prompt_rel(job.id), d.prompt)
	table.insert(job_list, job)
	if not save_jobs() then
		table.remove(job_list)
		save_jobs()
		store.remove(prompt_rel(job.id))
		return nil
	end
	deleted = nil
	store.remove(d.trash)
	state_tbl[job.id] = d.state or fresh_state(now)
	arm(job, now)
	ledger.restore_job(job.id)
	jobs.save_state()
	return job
end

-- Pausing always takes effect in memory (the safe direction); returns whether it reached disk.
function jobs.pause(id: string, reason: string): boolean
	local job = jobs.get(id)
	if job == nil then
		return false
	end
	job.enabled = false
	local st = jobs.state(id)
	st.paused_reason = reason
	st.next_run = nil
	return save_both()
end

function jobs.resume(id: string, now: number): boolean
	local job = jobs.get(id)
	if job == nil or data_blocked() then
		return false
	end
	local st = jobs.state(id)
	local before_state = copy_table(st)
	local before_job = copy_table(job)
	job.enabled = true
	st.paused_reason = nil
	st.failure_streak = 0
	st.incident = nil
	if type(st.watch) == "table" and type(st.watch.conditions) == "table" then
		st.watch.conditions.err = nil
	end
	arm(job, now)
	if not save_both() then
		restore_table(job, before_job)
		restore_table(st, before_state)
		save_jobs()
		return false
	end
	return true
end

-- Removes an unreadable entry (Needs fixing) from jobs.json. Returns true if one was removed.
function jobs.delete_invalid(id: string): boolean
	if data_blocked() then
		return false
	end
	for i, bad in ipairs(invalid_list) do
		if bad.id == id then
			table.remove(invalid_list, i)
			if not save_jobs() then
				table.insert(invalid_list, i, bad)
				save_jobs()
				return false
			end
			kept_state[id] = nil
			-- a valid job may share the id (duplicate entry): never touch its data
			if id ~= "" and find_index(id) == nil and id:match("^j_[a-z0-9]+$") then
				state_tbl[id] = nil
				ledger.remove_job(id)
				store.remove("runs/" .. id)
				store.remove(prompt_rel(id))
				jobs.save_state()
			end
			return true
		end
	end
	return false
end

-- Fresh start after damaged/read-only data (EN §2.2.4): the unusable files are set aside, then reload.
function jobs.start_fresh(now: number): boolean
	for _, name in ipairs(store.blocked_names()) do
		store.start_fresh(name)
	end
	jobs.load(now)
	return true
end

return jobs
