--!strict
-- lib/ledger.luau : run records, state transitions, reason sentences, retention (EN §7).
-- One JSONL file per job under ledger/<job id>.jsonl (backup-then-write through store). Host only.
local const = require("./const")
local cron = require("./cron")
local ids = require("./ids")
local store = require("./store")
local validate = require("./validate")

local ledger = {}

export type Run = { [string]: any }

-- allowed transitions (EN §7.2/§7.3); terminal states never change
local ALLOWED: { [string]: { [string]: boolean } } = {
	scheduled = {
		scheduled = true,
		launching = true,
		blocked = true,
		skipped = true,
		missed = true,
		cancelled = true,
		failed = true,
	},
	launching = { running = true, failed = true, cancelled = true },
	running = {
		running = true,
		needs_input = true,
		finished = true,
		failed = true,
		timed_out = true,
		cancelled = true,
	},
	needs_input = {
		needs_input = true,
		running = true,
		finished = true,
		failed = true,
		timed_out = true,
		cancelled = true,
	},
}

type Item = { run: Run?, raw: string? }
type File = { items: { Item }, index: { [string]: Run } }

local files: { [string]: File } = {}
-- in-flight runs by run id (includes runs created but not yet saved)
local inflight_index: { [string]: Run } = {}

local function home(): string
	local ok, h = pcall(function()
		return (tern :: any).getenv("HOME")
	end)
	if ok and type(h) == "string" then
		return h
	end
	return ""
end

local function file_path(job_id: string): string
	return "ledger/" .. job_id .. ".jsonl"
end

local function job_of_run(run_id: string): string
	local j = run_id:match("^r_([a-z0-9]+)_")
	if j == nil then
		return "_draft"
	end
	if j == "draft" then
		return "_draft"
	end
	return "j_" .. j
end

-- ---------- load / write ----------

local function parse_text(text: string): File
	local f: File = { items = {}, index = {} }
	local lines: { string } = {}
	for line in text:gmatch("[^\n]+") do
		table.insert(lines, line)
	end
	for i, line in ipairs(lines) do
		local ok, v = pcall(function()
			return (tern :: any).json.decode(line)
		end)
		if ok and type(v) == "table" and type(v.run_id) == "string" then
			table.insert(f.items, { run = v })
			f.index[v.run_id] = v
		elseif i < #lines then
			table.insert(f.items, { raw = line }) -- EN §2.2.7: keep other bad lines verbatim
		end
		-- an unparsable last line is dropped
	end
	return f
end

local function load_file(job_id: string): File
	local cached = files[job_id]
	if cached ~= nil then
		return cached
	end
	local path = file_path(job_id)
	local text = store.read_text(path, const.CAP_LEDGER, true)
	if text == nil then
		text = store.read_text(path .. ".bak", const.CAP_LEDGER)
	end
	local f = parse_text(text or "")
	for id, run in pairs(f.index) do
		if const.INFLIGHT[run.state] == true then
			inflight_index[id] = run
		end
	end
	files[job_id] = f
	return f
end

local function sort_key(run: Run): number
	return tonumber(run.ended) or tonumber(run.started) or tonumber(run.created) or 0
end

local function encode_line(item: Item): string
	if item.raw ~= nil then
		return item.raw
	end
	return (tern :: any).json.encode(item.run)
end

local function remove_run_dir(run: Run)
	local dir = run.run_dir
	if type(dir) == "string" and dir:match("^runs/[^/]+/[^/]+$") then
		store.remove(dir)
	end
end

-- Oldest terminal record index, or nil.
local function oldest_terminal(f: File): number?
	local best: number? = nil
	local best_key = math.huge
	for i, item in ipairs(f.items) do
		local r = item.run
		if r ~= nil and const.TERMINAL[r.state] == true then
			local k = sort_key(r)
			if k < best_key then
				best, best_key = i, k
			end
		end
	end
	return best
end

local function write_file(job_id: string, f: File): boolean
	local limit = math.floor(const.CAP_LEDGER * const.WRITE_CAP_RATIO)
	while true do
		local lines = table.create(#f.items)
		for i, item in ipairs(f.items) do
			lines[i] = encode_line(item)
		end
		local text = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
		if #text <= limit then
			local ok = store.safe_write(file_path(job_id), text, const.CAP_LEDGER)
			return ok
		end
		-- EN §2.2.8: prune oldest terminal records until it fits
		local idx = oldest_terminal(f)
		if idx == nil then
			return false
		end
		local item = table.remove(f.items, idx) :: Item
		if item.run ~= nil then
			f.index[item.run.run_id] = nil
			remove_run_dir(item.run)
		end
	end
end

-- ---------- reason sentences (EN §7.4) ----------

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function day_time(t: number): string
	local w = cron.clock.date("*t", t)
	return string.format("%s %02d:%02d", DAYS[(w.wday or 1)] or "", w.hour, w.min)
end

local function dur(s: number): string
	s = math.max(0, math.floor(s))
	if s >= 172800 then
		return string.format("%dd", s // 86400)
	end
	local h, m = s // 3600, (s % 3600) // 60
	if h > 0 and m > 0 then
		return string.format("%dh %dm", h, m)
	elseif h > 0 then
		return string.format("%dh", h)
	end
	return string.format("%dm", math.max(1, m))
end

local function first_line(s: string?, max: number): string
	if s == nil then
		return ""
	end
	local line = s:match("[^\n]+") or ""
	if #line > max then
		line = line:sub(1, max) .. "…"
	end
	return line
end

local function jobs_phrase(n: number): string
	if n == 1 then
		return "1 other job was"
	end
	return string.format("%d other jobs were", n)
end

function ledger.reason_text(code: string?, run: Run): string
	local c = code or ""
	local detail = run.detail
	local limit = tonumber(run.cap_limit) or const.MAX_CONCURRENT_DEFAULT
	if c == "" or c == "ok" then
		return ""
	elseif c == "ok_unobserved" then
		return "Finished (no window was open to watch it)."
	elseif c == "agent_failed" then
		if type(detail) == "string" and detail ~= "" then
			return string.format("The agent reported it couldn't finish: “%s”.", detail)
		end
		return "The agent reported it couldn't finish."
	elseif c == "agent_error" then
		if type(detail) == "string" and detail ~= "" then
			return string.format("The agent stopped with an error: %s.", detail)
		end
		return "The agent stopped with an error."
	elseif c == "exited_early" then
		return "The agent exited before finishing."
	elseif c == "no_response" then
		return "Couldn't start: the prompt wasn't delivered."
	elseif c == "delivery_error" then
		return "Couldn't start: omp needs updating to receive the prompt."
	elseif c == "launch_error" then
		return "Couldn't start: Tern couldn't open a block."
	elseif c == "launch_timeout" then
		return "Couldn't start: Tern didn't answer in time."
	elseif c == "interrupted" then
		return "Interrupted: Tern was closed while this run was in progress."
	elseif c == "max_runtime" then
		local s = string.format("Stopped at the %s limit.", dur(tonumber(run.max_runtime_s) or const.MAXRUN_DEFAULT_S))
		local last = first_line(run.summary or run.last_message, 80)
		if last ~= "" then
			s ..= string.format(" Last message: “%s”.", last)
		end
		return s
	elseif c == "waiting_for_input" then
		return "Stopped at the limit while waiting for you."
	elseif c == "user_stop" then
		return "Stopped by you."
	elseif c == "closed_by_user" then
		return "Closed by you."
	elseif c == "replaced" then
		return "Replaced by a newer run."
	elseif c == "cwd_missing" then
		return string.format(
			"Blocked: %s doesn't exist or can't be opened.",
			validate.tilde(tostring(run.cwd or "the folder"), home())
		)
	elseif c == "cwd_home" then
		return "Blocked: the folder is your home folder; pick a project folder or allow home in the job."
	elseif c == "cwd_unsafe" then
		return "Blocked: the folder name has characters Agent Scheduler can't pass safely."
	elseif c == "prompt_missing" then
		return "Blocked: the prompt file is missing. Re-save the prompt in the manager."
	elseif c == "prompt_empty" then
		return "Blocked: the prompt is empty."
	elseif c == "prompt_too_large" then
		return "Blocked: the prompt is over 64 KiB."
	elseif c == "role_missing" then
		return string.format(
			"Blocked: role @%s no longer exists in omp. Edit the job and pick another role.",
			tostring(run.role or "default")
		)
	elseif c == "invalid_job" then
		return "Blocked: this job's settings are invalid. Open it in Agent Scheduler to fix it."
	elseif c == "omp_missing" then
		return "Blocked: the omp command wasn't found."
	elseif c == "data_unwritable" then
		return "Blocked: couldn't write run data."
	elseif c == "tern_missing" then
		return "Blocked: the tern command wasn't found."
	elseif c == "overlap" or c == "overlap_replaced" then
		return "Skipped: the previous run was still going."
	elseif c == "cap" then
		return string.format("Skipped: %s already running (limit %d).", jobs_phrase(limit), limit)
	elseif c == "paused_all" then
		return "Skipped: all jobs were paused."
	elseif c == "waiting_cap" then
		return string.format("Waiting: %s running (limit %d).", jobs_phrase(limit):gsub(" was$", " is"):gsub(" were$", " are"), limit)
	elseif c == "late" then
		local slot = tonumber(run.last) or tonumber(run.slot) or 0
		local late = tonumber(run.lateness_s) or 0
		local window = tonumber(run.window_s) or const.CATCHUP_DEFAULT_S
		return string.format("Missed %s: %s late, over the %s limit.", day_time(slot), dur(late), dur(window))
	elseif c == "asleep_or_closed" then
		local count = tonumber(run.count) or 1
		local slot = tonumber(run.last) or tonumber(run.slot) or 0
		if count > 1 then
			return string.format("Missed %d runs, last %s: Tern wasn't running or your Mac was asleep.", count, day_time(slot))
		end
		return string.format("Missed %s: Tern wasn't running or your Mac was asleep.", day_time(slot))
	end
	return ""
end

-- ---------- records ----------

-- New in-memory run (state `scheduled`); persisted on the first save/transition.
-- fields: run_id, trigger, slot, now; optional focus_override, count, first, last, window_s, notes, cap_limit.
function ledger.new(job: any, fields: { [string]: any }): Run
	local now = tonumber(fields.now) or os.time()
	local slot = tonumber(fields.slot) or now
	local run_id = fields.run_id or ids.run_id(job.id, slot)
	local run: Run = {
		run_id = run_id,
		job_id = job.id,
		job_name = job.name,
		trigger = fields.trigger or "schedule",
		slot = slot,
		state = "scheduled",
		state_since = now,
		created = now,
		lateness_s = math.max(0, now - slot),
		run_dir = string.format("runs/%s/%s", job.id, run_id),
		role = job.role,
		cwd = job.cwd,
		allow_home = job.allow_home == true,
		approval = job.approval,
		max_runtime_s = job.max_runtime_s,
		overlay = true,
		busy_seen = false,
		observed = false,
	}
	for _, k in ipairs({ "focus_override", "count", "first", "last", "window_s", "notes", "cap_limit" }) do
		if fields[k] ~= nil then
			run[k] = fields[k]
		end
	end
	inflight_index[run_id] = run
	return run
end

function ledger.save(run: Run): boolean
	local job_id = tostring(run.job_id)
	local f = load_file(job_id)
	local id = tostring(run.run_id)
	if f.index[id] == nil then
		table.insert(f.items, { run = run })
	elseif f.index[id] ~= run then
		for _, item in ipairs(f.items) do
			if item.run ~= nil and item.run.run_id == id then
				item.run = run
			end
		end
	end
	f.index[id] = run
	if const.INFLIGHT[run.state] == true then
		inflight_index[id] = run
	else
		inflight_index[id] = nil
	end
	return write_file(job_id, f)
end

-- Applies a state change (EN §7.2) and persists it. fields are merged into the run first.
function ledger.transition(
	run: Run,
	state: string,
	reason_code: string?,
	fields: { [string]: any }?,
	now: number
): (boolean, string?)
	local from = tostring(run.state)
	local allowed = ALLOWED[from]
	if allowed == nil then
		return false, "terminal"
	end
	if not allowed[state] then
		return false, string.format("illegal transition %s -> %s", from, state)
	end
	if fields ~= nil then
		for k, v in pairs(fields) do
			run[k] = v
		end
	end
	if state ~= from then
		run.state_since = now
	end
	run.state = state
	run.reason_code = reason_code
	run.reason = ledger.reason_text(reason_code, run)
	if state == "running" and run.started == nil then
		run.started = now
	end
	if const.TERMINAL[state] == true and run.ended == nil then
		run.ended = now
	end
	if state == "needs_input" or state == "running" then
		run.ended = nil
	end
	local ok = ledger.save(run)
	if not ok then
		return true, "not_persisted"
	end
	return true, nil
end

function ledger.get(run_id: string): Run?
	local live = inflight_index[run_id]
	if live ~= nil then
		return live
	end
	local f = load_file(job_of_run(run_id))
	return f.index[run_id]
end

-- Newest first. job_id nil = every job (ledger/_drafts included).
function ledger.recent(job_id: string?, n: number): { Run }
	local out: { Run } = {}
	local function collect(id: string)
		local f = load_file(id)
		for _, item in ipairs(f.items) do
			if item.run ~= nil then
				table.insert(out, item.run)
			end
		end
	end
	if job_id ~= nil then
		collect(job_id)
	else
		for _, name in ipairs(store.list("ledger")) do
			local id = name:match("^(.+)%.jsonl$")
			if id ~= nil then
				collect(id)
			end
		end
	end
	table.sort(out, function(a, b)
		local ka, kb = sort_key(a), sort_key(b)
		if ka ~= kb then
			return ka > kb
		end
		return tostring(a.run_id) > tostring(b.run_id)
	end)
	if #out > n then
		for i = #out, n + 1, -1 do
			out[i] = nil
		end
	end
	return out
end

-- Runs for the in-flight ids kept in state.json; registers them as live.
function ledger.load_inflight(run_ids: { string }): { Run }
	local out: { Run } = {}
	for _, id in ipairs(run_ids) do
		local run = ledger.get(id)
		if run ~= nil then
			inflight_index[id] = run
			table.insert(out, run)
		end
	end
	return out
end

-- Retention (EN §7.5): newest `retain_runs` terminal records, none older than `retain_days`. Returns #removed.
function ledger.prune(job_id: string, settings: { [string]: any }, now: number): number
	local f = load_file(job_id)
	local retain_runs = tonumber(settings.retain_runs) or 50
	local retain_days = tonumber(settings.retain_days) or 90
	local terminal: { Run } = {}
	for _, item in ipairs(f.items) do
		if item.run ~= nil and const.TERMINAL[item.run.state] == true then
			table.insert(terminal, item.run)
		end
	end
	table.sort(terminal, function(a, b)
		return sort_key(a) > sort_key(b)
	end)
	local drop: { [Run]: boolean } = {}
	local cutoff = now - retain_days * 86400
	for i, r in ipairs(terminal) do
		if i > retain_runs or sort_key(r) < cutoff then
			drop[r] = true
		end
	end
	if next(drop) == nil then
		return 0
	end
	local kept: { Item } = {}
	local removed = 0
	for _, item in ipairs(f.items) do
		if item.run ~= nil and drop[item.run] then
			f.index[item.run.run_id] = nil
			remove_run_dir(item.run)
			removed += 1
		else
			table.insert(kept, item)
		end
	end
	f.items = kept
	write_file(job_id, f)
	return removed
end

function ledger.remove_job(job_id: string)
	local f = files[job_id]
	if f ~= nil then
		for id in pairs(f.index) do
			inflight_index[id] = nil
		end
	end
	files[job_id] = nil
	for id, run in pairs(inflight_index) do
		if run.job_id == job_id then
			inflight_index[id] = nil
		end
	end
	store.remove(file_path(job_id))
	store.remove(file_path(job_id) .. ".bak")
end

return ledger
