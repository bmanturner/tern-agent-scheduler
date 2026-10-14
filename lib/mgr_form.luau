--!strict
local timefmt = require("./timefmt")
-- Manager form mode (UX §4.11): the 9-row New job / Edit form as a `prefs` page in `main`, with a multi-line
-- Prompt editor card, a live schedule preview, a role picker (sheets) and Save / Save & run now.

local ui = tern.ui
local C = require("./mgr_common")
local P = require("./mgr_prefs")
local textfield = require("./textfield")
local validate = require("./validate")
local schedule = require("./schedule")
local cron = require("./cron")
local const = require("./const")
local jobs = require("./jobs")
local runner = require("./runner")
local ids = require("./ids")
local platform = require("./platform")
local conditions = require("./conditions")
local cond_eval = require("./cond_eval")
local R = require("./mgr_run")

local F = {}

type State = C.State
type Form = C.Form

export type Seed = {
	name: string?,
	prompt: string?,
	when: string?,
	cwd: string?,
	role: string?,
	enabled: boolean?,
	catch_up: string?,
	approval: string?,
	stop_s: number?,
	window_s: number?,
	only_when: conditions.Input?,
	quiet_ok: boolean?,
}

local ROW_ORDER = {
	"name",
	"prompt",
	"when",
	"only_when",
	"catch_up",
	"folder",
	"role",
	"approval",
	"stop",
	"active",
	"quiet",
	"c_now",
	"c_commits",
	"c_branch",
	"c_paths",
	"c_window",
	"c_days",
	"c_from",
	"c_to",
	"c_outside",
	"c_limits",
	"c_runs",
	"c_usd",
	"c_per",
	"c_check",
	"c_script",
	"c_ask",
	"c_ask_prompt",
	"c_ask_role",
}
local ROW_LABEL: { [string]: string } = {
	name = "Name",
	prompt = "Prompt",
	when = "When",
	only_when = "Only when",
	catch_up = "If your " .. platform.machine() .. " was asleep",
	folder = "Folder",
	role = "Role",
	approval = "Approval",
	stop = "Stop after",
	active = "Active",
	quiet = "Quiet when nothing to report",
	c_now = "Right now",
	c_commits = "Only when there are new commits",
	c_branch = "Branch",
	c_paths = "Only these folders",
	c_window = "Only at certain times",
	c_days = "Days",
	c_from = "From",
	c_to = "Until",
	c_outside = "These hours are",
	c_limits = "At most this many runs or this much spend",
	c_runs = "Runs",
	c_usd = "Spend",
	c_per = "Per",
	c_check = "Ask a script of yours",
	c_script = "Script",
	c_ask = "Ask an AI first",
	c_ask_prompt = "Question",
	c_ask_role = "Model",
}
-- The rows of the Only when page.
local C_ROWS: { [string]: boolean } = {
	c_now = true,
	c_commits = true,
	c_branch = true,
	c_paths = true,
	c_window = true,
	c_days = true,
	c_from = true,
	c_to = true,
	c_outside = true,
	c_limits = true,
	c_runs = true,
	c_usd = true,
	c_per = true,
	c_check = true,
	c_script = true,
	c_ask = true,
	c_ask_prompt = true,
	c_ask_role = true,
	c_commits_now = true,
	c_window_now = true,
	c_limits_now = true,
	c_check_now = true,
	c_ask_now = true,
}
-- The "Right now" rows that follow each switch after Check now.
local NOW_ROWS: { [string]: boolean } = { c_commits_now = true, c_window_now = true, c_limits_now = true, c_check_now = true, c_ask_now = true }
-- Segmented choices (click or ←→ flips them, no menu), number steppers, and rows that open the time picker.
local SEG_ROWS: { [string]: boolean } = { c_outside = true, c_per = true }
local NUM_ROWS: { [string]: boolean } = { c_runs = true, c_usd = true }
local TIME_ROWS: { [string]: boolean } = { c_from = true, c_to = true }
local DAY_ORDER = { 1, 2, 3, 4, 5, 6, 0 }
local DAY_NAMES = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local SWITCH_ROWS: { [string]: boolean } = { active = true, quiet = true, c_commits = true, c_window = true, c_limits = true, c_check = true, c_ask = true }
local TEXT_ROWS: { [string]: boolean } = { name = true, prompt = true, when = true, folder = true, c_paths = true, c_script = true, c_ask_prompt = true }
-- Text rows edited in the multi-line overlay editor (Enter adds a line, ctrl+Enter finishes). The overlay sits at the
-- top of the page, so only rows near the top may use it.
local MULTI_ROWS: { [string]: boolean } = { prompt = true }
local MENU_ROWS: { [string]: boolean } = { catch_up = true, approval = true, stop = true }
-- Validation field -> form row, for the fields that don't share their row's name.
local ERROR_ROW: { [string]: string } = {
	cwd = "folder",
	max_runtime_s = "stop",
	["only_when.branch"] = "c_branch",
	["only_when.folders"] = "c_paths",
	["only_when.days"] = "c_days",
	["only_when.hours"] = "c_to",
	["only_when.limits"] = "c_runs",
	["only_when.script"] = "c_script",
	["only_when.ask"] = "c_ask_prompt",
	["only_when.ask_role"] = "c_ask_role",
}

local function error_row(field: string): string
	return ERROR_ROW[field] or field
end

-- Stands for "this folder's current branch" in the branch picker.
F.CURRENT_BRANCH = "__current__"
local EDITOR_ID = "main.prefs.pe.text"

local function defaults(): { [string]: any }
	local s: any = jobs.settings()
	local d: any = s.defaults
	return if type(d) == "table" then d else {}
end

local function window_s(form: Form): number
	local s: any = jobs.settings()
	return form.catch_up_window_s or (type(s.catchup_window_s) == "number" and s.catchup_window_s) or const.CATCHUP_DEFAULT_S
end

-- Expands a leading ~ and strips trailing slashes.
local function expand(path: string): string
	local p = C.trim(path)
	local home = C.home()
	if p == "~" then
		p = home
	elseif string.sub(p, 1, 2) == "~/" then
		p = home .. string.sub(p, 2)
	end
	return validate.strip_slashes(p)
end

local function sorted_days(days: any): { number }
	local out: { number } = {}
	if type(days) == "table" then
		for _, d in days do
			if type(d) == "number" and table.find(out, d) == nil then
				table.insert(out, d)
			end
		end
	end
	table.sort(out)
	return out
end

local function snapshot_of(form: Form): { [string]: any }
	return {
		name = form.name.text,
		prompt = form.prompt.text,
		when = form.when.text,
		folder = form.folder.text,
		role = form.role,
		catch_up = form.catch_up,
		approval = form.approval,
		stop_s = form.stop_s,
		enabled = form.enabled,
		quiet_ok = form.quiet_ok,
		c_commits = form.c_commits,
		c_branch = form.c_branch,
		c_paths = form.c_paths.text,
		c_window = form.c_window,
		c_days = table.concat(sorted_days(form.c_days), ","),
		c_from = form.c_from,
		c_to = form.c_to,
		c_outside = form.c_outside,
		c_limits = form.c_limits,
		c_runs = form.c_runs or 0,
		c_usd = form.c_usd or 0,
		c_per = form.c_per,
		c_check = form.c_check,
		c_script = form.c_script.text,
		c_ask = form.c_ask,
		c_ask_prompt = form.c_ask_prompt.text,
		c_ask_role = form.c_ask_role,
	}
end

-- The draft file (ctrl+o) is the source of truth only once it was edited there, meaning its text differs from what was
-- written to it. Until then the inline prompt is, so typing after ctrl+o is never overwritten.
local function sync_draft(form: Form)
	local path = form.draft_path
	if path == nil then
		return
	end
	local ok, text = pcall(tern.fs.read, path, const.PROMPT_MAX + 1024)
	if ok and type(text) == "string" and text ~= form.draft_seed then
		textfield.set(form.prompt, text)
		form.draft_seed = text
	end
end

function F.dirty(form: Form): boolean
	sync_draft(form)
	local now = snapshot_of(form)
	for k, v in form.orig do
		if now[k] ~= v then
			return true
		end
	end
	return false
end

function F.new(seed: Seed, id: string?, title: string): Form
	local d = defaults()
	local ow: any = seed.only_when or {}
	local cm: any, wn: any, lm: any, ck: any, ak: any = ow.commits, ow.window, ow.limits, ow.check, ow.ask
	local form: Form = {
		id = id,
		title = title,
		name = textfield.new(seed.name),
		prompt = textfield.new(seed.prompt),
		when = textfield.new(seed.when or "weekdays 09:00"),
		folder = textfield.new(if seed.cwd ~= nil and seed.cwd ~= "" then C.tilde(seed.cwd) else nil),
		role = seed.role or (type(d.role) == "string" and d.role) or "default",
		catch_up = seed.catch_up or (type(d.catch_up) == "string" and d.catch_up) or "within",
		approval = seed.approval or (type(d.approval) == "string" and d.approval) or "yolo",
		stop_s = seed.stop_s or (type(d.max_runtime_s) == "number" and d.max_runtime_s) or const.MAXRUN_DEFAULT_S,
		enabled = seed.enabled ~= false,
		quiet_ok = seed.quiet_ok == true,
		page = "job",
		c_commits = cm ~= nil,
		c_branch = if cm ~= nil and type(cm.branch) == "string" then cm.branch else "",
		c_paths = textfield.new(if cm ~= nil and type(cm.folders) == "table" then table.concat(cm.folders, " ") else nil),
		c_window = wn ~= nil,
		c_days = if wn ~= nil then sorted_days(wn.days) else { 1, 2, 3, 4, 5 },
		c_from = if wn ~= nil and type(wn.from) == "number" then wn.from else 540,
		c_to = if wn ~= nil and type(wn.to) == "number" then wn.to else 1080,
		c_outside = wn ~= nil and wn.outside == true,
		c_limits = lm ~= nil,
		c_runs = if lm ~= nil then lm.runs else 3,
		c_usd = if lm ~= nil then lm.usd else nil,
		c_per = if lm ~= nil and lm.per == "week" then "week" else "day",
		c_check = ck ~= nil,
		c_script = textfield.new(if ck ~= nil and type(ck.path) == "string" then ck.path else nil),
		c_ask = ak ~= nil,
		c_ask_prompt = textfield.new(if ak ~= nil and type(ak.prompt) == "string" then ak.prompt else nil),
		c_ask_role = if ak ~= nil and type(ak.role) == "string" and ak.role ~= "" then ak.role else "smol",
		focus = if seed.name == nil or seed.name == "" then "name" else "prompt",
		editing = nil,
		menu = nil,
		touched = {},
		submitted = false,
		extra = {},
		roles = nil,
		roles_for = nil,
		roles_err = nil,
		folder_ok = nil,
		orig = {},
		esc_at = nil,
		busy = false,
		catch_up_window_s = seed.window_s,
		draft_path = nil,
		draft_seed = nil,
		was_done = false,
		return_to = nil,
	}
	form.orig = snapshot_of(form)
	return form
end

local function default_for(form: Form, row: string): any
	local d = defaults()
	if row == "role" then
		return (type(d.role) == "string" and d.role) or "default"
	elseif row == "catch_up" then
		return (type(d.catch_up) == "string" and d.catch_up) or "within"
	elseif row == "approval" then
		return (type(d.approval) == "string" and d.approval) or "yolo"
	elseif row == "stop" then
		return (type(d.max_runtime_s) == "number" and d.max_runtime_s) or const.MAXRUN_DEFAULT_S
	end
	return true
end

-- Folder checks and roles ----------------------------------------------------------------------

-- Reads the roles of the form's folder (cached by the runner) when the folder changed.
function F.refresh_roles(state: State)
	local form = state.form
	if form == nil then
		return
	end
	local cwd = expand(form.folder.text)
	if cwd == "" or string.sub(cwd, 1, 1) ~= "/" or validate.unsafe_path(cwd) then
		form.roles_for = nil
		form.roles = nil
		form.roles_err = nil
		return
	end
	if form.roles_for == cwd then
		return
	end
	form.roles_for = cwd
	form.roles = nil
	form.roles_err = nil
	runner.roles(cwd, function(list, err)
		if state.form ~= form or form.roles_for ~= cwd then
			return
		end
		if list ~= nil then
			form.roles = list
			form.roles_err = nil
		else
			form.roles = nil
			form.roles_err = err or "Couldn't read your omp roles."
		end
		C.render(state)
	end)
end

-- Reads the branches of the form's folder when the Only when page is shown and the folder changed (or the last read failed).
function F.refresh_branches(state: State)
	local form = state.form
	if form == nil or form.page ~= "only_when" then
		return
	end
	local cwd = expand(form.folder.text)
	if cwd == "" or string.sub(cwd, 1, 1) ~= "/" or validate.unsafe_path(cwd) then
		form.branches_for = nil
		form.branches = nil
		form.branches_err = nil
		return
	end
	if form.branches_for == cwd and form.branches_err == nil then
		return
	end
	form.branches_for = cwd
	form.branches = nil
	form.branches_err = nil
	runner.branches(cwd, function(list, err)
		if state.form ~= form or form.branches_for ~= cwd then
			return
		end
		if list ~= nil then
			form.branches = list
			form.branches_err = nil
		else
			form.branches = nil
			form.branches_err = err or "Couldn't list this folder's branches."
		end
		C.render(state)
	end)
end

-- Checks the folder exists (async, `/bin/test -d`); `cb(ok)` runs unless the form was closed.
local function check_folder(state: State, cb: ((boolean) -> ())?)
	local form = state.form
	if form == nil then
		return
	end
	local path = expand(form.folder.text)
	if path == "" or string.sub(path, 1, 1) ~= "/" or validate.unsafe_path(path) then
		return
	end
	if form.folder_ok ~= nil and form.folder_ok.path == path then
		if cb ~= nil then
			cb(form.folder_ok.ok)
		end
		return
	end
	local started, err = pcall(function()
		tern.process.run({ "/bin/test", "-d", path }, { timeout_ms = 3000 }, function(res)
			if state.form ~= form then
				return
			end
			local ok = res.status == 0
			form.folder_ok = { path = path, ok = ok }
			if cb ~= nil then
				cb(ok)
			end
			C.render(state)
		end)
	end)
	if not started then
		tern.log.warn("tern-agent-scheduler: folder check failed to start", tostring(err))
		form.folder_ok = { path = path, ok = true }
		if cb ~= nil then
			cb(true)
		end
	end
end

-- Validation -------------------------------------------------------------------------------------

-- The conditions the Only when page has switched on, as the structured input (always present, so Save clears the rest).
function F.only_when_input(form: Form): conditions.Input
	local input: any = {}
	if form.c_commits then
		local folders: { string } = {}
		for word in string.gmatch(form.c_paths.text, "%S+") do
			table.insert(folders, word)
		end
		input.commits = { branch = if form.c_branch ~= "" then form.c_branch else nil, folders = if #folders > 0 then folders else nil }
	end
	if form.c_window then
		input.window = { days = sorted_days(form.c_days), from = form.c_from, to = form.c_to, outside = form.c_outside }
	end
	if form.c_limits then
		input.limits = { runs = form.c_runs, usd = form.c_usd, per = form.c_per }
	end
	if form.c_check then
		input.check = { path = C.trim(form.c_script.text) }
	end
	if form.c_ask then
		input.ask = { prompt = form.c_ask_prompt.text, role = form.c_ask_role }
	end
	return input
end

function F.input(form: Form): validate.JobInput
	local home = C.home()
	local cwd = expand(form.folder.text)
	return {
		name = form.name.text,
		prompt = form.prompt.text,
		when = form.when.text,
		role = form.role,
		cwd = form.folder.text,
		approval = form.approval,
		max_runtime_s = form.stop_s,
		enabled = form.enabled,
		only_when = F.only_when_input(form),
		quiet_ok = form.quiet_ok,
		catch_up = form.catch_up,
		catch_up_window_s = form.catch_up_window_s,
		allow_home = home ~= "" and cwd == validate.strip_slashes(home),
	}
end

-- Errors by row id; the row ids are the form's (`folder` for the cwd, `stop` for the time limit).
function F.errors(state: State): { [string]: string }
	local form = state.form :: Form
	local _, errs = validate.job(F.input(form), {
		jobs = jobs.list(),
		self_id = form.id,
		now = C.now(),
		home = C.home(),
		creating = form.id == nil,
	})
	local out: { [string]: string } = {}
	for field, msg in errs do
		local row = error_row(field)
		out[row] = msg
	end
	for field, msg in form.extra do
		local row = error_row(field)
		if out[row] == nil then
			out[row] = msg
		end
	end
	local fok = form.folder_ok
	if out.folder == nil and fok ~= nil and not fok.ok and fok.path == expand(form.folder.text) then
		out.folder = string.format("%s doesn't exist or can't be opened.", C.tilde(fok.path))
	end
	if out.role == nil and form.role ~= "default" and form.roles ~= nil and #form.roles > 0 and table.find(form.roles, form.role) == nil then
		local names: { string } = {}
		for _, r in form.roles do
			table.insert(names, "@" .. r)
		end
		out.role = string.format("No role @%s here. Roles: %s", form.role, table.concat(names, ", "))
	end
	return out
end

local function shown(form: Form, row: string): boolean
	return form.touched[row] == true or form.submitted or (C_ROWS[row] == true and form.touched.cond == true)
end

-- The rows with an error that should be shown, in form order.
local function failing(state: State, errs: { [string]: string }): { string }
	local form = state.form :: Form
	local out: { string } = {}
	for _, row in ROW_ORDER do
		if errs[row] ~= nil and shown(form, row) then
			table.insert(out, row)
		end
	end
	return out
end

-- Schedule preview ---------------------------------------------------------------------------------

local function interval_text(secs: number): string
	if secs % 3600 == 0 then
		return string.format("Every %dh", secs // 3600)
	end
	return string.format("Every %dm", secs // 60)
end

local function next_pair(ups: { number }, now: number): string
	local parts: { string } = {}
	if ups[1] ~= nil then
		table.insert(parts, string.format("next %s (%s)", C.abs(ups[1]), C.in_text(ups[1], now)))
	end
	if ups[2] ~= nil then
		local more: { string } = { C.abs(ups[2]) }
		if ups[3] ~= nil then
			table.insert(more, C.abs(ups[3]))
		end
		table.insert(parts, "then " .. table.concat(more, " · "))
	end
	return table.concat(parts, " · ")
end

-- The hint under the When row: reading, next dates, time zone. Empty when the input doesn't parse.
function F.preview(form: Form): string
	local now = C.now()
	local text = C.trim(form.when.text)
	if text == "" then
		return "For example weekdays 9am, every 2h, in 30m, or a cron like 0 9 * * 1-5."
	end
	local rec = schedule.parse(text, now)
	if rec == nil then
		return ""
	end
	local tz = timefmt.date("%Z", now)
	if rec.kind == "manual" then
		return "Manual only · runs when you press r. Never on a schedule."
	elseif rec.kind == "once" then
		local at: number = rec.run_at or now
		return string.format("Once · %s (%s) · runs one time, then stays here as finished · %s", C.abs(at), C.in_text(at, now), tz)
	elseif rec.kind == "interval" then
		local secs: number = rec.secs or 0
		local anchor = now - now % 60
		local ups: { number } = {}
		local t = now
		for _ = 1, 3 do
			t = cron.next_interval(anchor, secs, t)
			table.insert(ups, t)
		end
		return string.format("%s · %s · %s", interval_text(secs), next_pair(ups, now), tz)
	end
	local spec = cron.parse(rec.expr)
	if spec == nil then
		return ""
	end
	local reading = cron.describe(spec)
	local lead = if string.match(text, "^[%d%*@]") then "Reads as: " .. reading else reading
	local ups = cron.upcoming(spec, 3, now, 3000)
	return string.format("%s · %s · %s", lead, next_pair(ups, now), tz)
end

local function only_when_on(form: Form): boolean
	return form.c_commits or form.c_window or form.c_limits or form.c_check or form.c_ask
end

-- The hint under the Only when row on the Job page: what the switched-on conditions read as.
function F.only_when_summary(form: Form): string
	if not only_when_on(form) then
		return "Always runs when due."
	end
	local list = conditions.build(F.only_when_input(form))
	if list == nil then
		return "Some conditions need fixing."
	end
	local text = conditions.describe(list)
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- Rows -------------------------------------------------------------------------------------------

local function summary_line(text: string): string
	local first = C.trim(string.match(text, "^[^\r\n]*") or "")
	local clipped = if (utf8.len(first) or #first) > 90 then string.sub(first, 1, utf8.offset(first, 90) or 90) .. "…" else first
	if clipped ~= first or string.find(text, "\n", 1, true) ~= nil then
		clipped ..= " …"
	end
	return clipped
end

-- Stepper labels for a number row: 0 reads "No limit"; a seeded value off the list is added.
local function number_control(base: { number }, current: number?, label: (number) -> string): { [string]: any }
	local nums = table.clone(base)
	if current ~= nil and table.find(nums, current) == nil then
		table.insert(nums, current)
		table.sort(nums)
	end
	local labels: { [string]: string } = { ["0"] = "No limit" }
	for _, n in nums do
		labels[tostring(n)] = label(n)
	end
	return { k = "number", value = current or 0, min = 0, max = nums[#nums], labels = labels }
end

local function money_label(n: number): string
	return if n == math.floor(n) then string.format("$%d", n) else string.format("$%.2f", n)
end

function F.time_label(row: string, m: number): string
	return if row == "c_to" and m == 1440 then "Midnight" else conditions.hhmm(m)
end

-- The half-hour picks of the From / Until picker (From 00:00..23:30, Until 00:30..24:00), plus an off-grid value
-- the form already holds (seeded from Carly).
function F.time_entries(form: Form, row: string): { { id: string, label: string } }
	local lo, hi = if row == "c_to" then 30 else 0, if row == "c_to" then 1440 else 1410
	local current = if row == "c_to" then form.c_to else form.c_from
	local mins: { number } = {}
	for m = lo, hi, 30 do
		table.insert(mins, m)
	end
	if table.find(mins, current) == nil then
		table.insert(mins, current)
		table.sort(mins)
	end
	local out: { { id: string, label: string } } = {}
	for _, m in mins do
		table.insert(out, { id = tostring(m), label = F.time_label(row, m) })
	end
	return out
end

-- The "Right now" row under a condition's switch once Check now has answered; nil before that.
local function now_row(form: Form, row_id: string, kind: string): P.Row?
	local v: any = form.verdict
	if v == nil or type(v.results) ~= "table" then
		return nil
	end
	for _, r in v.results do
		if r.type == kind then
			local hint: string? = nil
			local warning: string? = nil
			if r.result == "pass" then
				hint = "✓ " .. tostring(r.text)
			elseif r.result == "fail" then
				hint = "✗ " .. tostring(r.text)
			elseif r.result == "error" then
				warning = "⚠ " .. tostring(r.text)
			else
				hint = "Not checked: an earlier condition said no."
			end
			return { id = row_id, label = "Right now", hint = hint, warning = warning, control = { k = "action", act = "c_now", label = "Check again" } }
		end
	end
	return nil
end

-- The rows of the Only when page: one section per condition, each with its switch first.
local function only_when_sections(state: State, errs: { [string]: string }?): { P.Section }
	local form = state.form :: Form
	local errors: { [string]: string } = errs or {}
	local function warn(row: string): string?
		return if shown(form, row) then errors[row] else nil
	end
	local function off(on: boolean, row: string): string?
		return if on then nil else string.format("Turn on “%s” first.", ROW_LABEL[row])
	end

	local now_hint: string
	local v: any = form.verdict
	if form.checking == true then
		now_hint = "Checking…"
	elseif not only_when_on(form) then
		now_hint = "Nothing to check: this job always runs when due."
	elseif v ~= nil then
		now_hint = if v.ok == true then "A run would start now." else "A run would not start now: " .. tostring(v.text or "a condition said no") .. "."
	else
		now_hint = "Check runs every condition that's on, without starting anything." .. (if form.c_ask then " The AI check costs one model call." else "")
	end

	local branch_hint = "Enter picks one."
	if form.branches_for == nil then
		branch_hint = "Pick the job's folder on the Job page to list its branches."
	elseif form.branches ~= nil then
		branch_hint = string.format("%d %s in this folder.", #form.branches, if #form.branches == 1 then "branch" else "branches")
	elseif form.branches_err == nil then
		branch_hint = "Reading branches…"
	end
	local branch_warning = warn("c_branch")
	if branch_warning == nil and form.c_commits then
		branch_warning = form.branches_err
	end

	local days_values: { string } = {}
	for _, d in sorted_days(form.c_days) do
		table.insert(days_values, tostring(d))
	end
	local days_options: { any } = {}
	for i, d in DAY_ORDER do
		table.insert(days_options, { value = tostring(d), label = DAY_NAMES[i] })
	end
	local function time_control(row: string, m: number): { [string]: any }
		return { k = "choice", style = "menu", value = tostring(m), options = { { value = tostring(m), label = F.time_label(row, m) } } }
	end

	local sections: { P.Section } = {
		{
			id = "now",
			title = nil,
			rows = {
				{
					id = "c_now",
					label = ROW_LABEL.c_now,
					hint = now_hint,
					control = { k = "action", act = "c_now", label = "Check now" },
				},
			},
		},
		{
			id = "commits",
			title = "New commits",
			rows = {
				{
					id = "c_commits",
					label = ROW_LABEL.c_commits,
					hint = "Checks git in the job's folder. The first run notes where the branch is and waits; after that a run starts only if something landed since the last successful run, and the agent gets the list.",
					warning = warn("c_commits"),
					control = { k = "switch", on = form.c_commits },
				},
				{
					id = "c_branch",
					label = ROW_LABEL.c_branch,
					hint = branch_hint,
					warning = branch_warning,
					disabled = off(form.c_commits, "c_commits"),
					control = {
						k = "choice",
						style = "menu",
						value = form.c_branch,
						options = { { value = form.c_branch, label = if form.c_branch == "" then "This folder's current branch" else form.c_branch } },
					},
				},
				{
					id = "c_paths",
					label = ROW_LABEL.c_paths,
					hint = "Space-separated, inside the job's folder, e.g. src docs.",
					warning = warn("c_paths"),
					disabled = off(form.c_commits, "c_commits"),
					control = { k = "text", value = form.c_paths.text, placeholder = "Any folder", mono = true },
				},
			},
		},
		{
			id = "time",
			title = "Time",
			rows = {
				{
					id = "c_window",
					label = ROW_LABEL.c_window,
					hint = "Uses your " .. platform.machine() .. "'s local time.",
					warning = warn("c_window"),
					control = { k = "switch", on = form.c_window },
				},
				{
					id = "c_days",
					label = ROW_LABEL.c_days,
					warning = warn("c_days"),
					disabled = off(form.c_window, "c_window"),
					control = { k = "multi", values = days_values, options = days_options },
				},
				{
					id = "c_from",
					label = ROW_LABEL.c_from,
					warning = warn("c_from"),
					disabled = off(form.c_window, "c_window"),
					control = time_control("c_from", form.c_from),
				},
				{
					id = "c_to",
					label = ROW_LABEL.c_to,
					warning = warn("c_to"),
					disabled = off(form.c_window, "c_window"),
					control = time_control("c_to", form.c_to),
				},
				{
					id = "c_outside",
					label = ROW_LABEL.c_outside,
					warning = warn("c_outside"),
					disabled = off(form.c_window, "c_window"),
					control = {
						k = "choice",
						style = "segmented",
						value = if form.c_outside then "outside" else "inside",
						options = { { value = "inside", label = "When it may run" }, { value = "outside", label = "Quiet hours" } },
					},
				},
			},
		},
		{
			id = "limits",
			title = "Limits",
			rows = {
				{
					id = "c_limits",
					label = ROW_LABEL.c_limits,
					hint = "Counts this job's runs since midnight (or since Monday). Test runs don't count; a run with unknown cost counts as the job's typical cost.",
					warning = warn("c_limits"),
					control = { k = "switch", on = form.c_limits },
				},
				{
					id = "c_runs",
					label = ROW_LABEL.c_runs,
					warning = warn("c_runs"),
					disabled = off(form.c_limits, "c_limits"),
					control = number_control({ 1, 2, 3, 4, 5, 6, 8, 10, 12, 24 }, form.c_runs, function(n: number): string
						return if n == 1 then "1 run" else string.format("%d runs", n)
					end),
				},
				{
					id = "c_usd",
					label = ROW_LABEL.c_usd,
					warning = warn("c_usd"),
					disabled = off(form.c_limits, "c_limits"),
					control = number_control({ 0.5, 1, 2, 3, 5, 10, 20, 50 }, form.c_usd, money_label),
				},
				{
					id = "c_per",
					label = ROW_LABEL.c_per,
					warning = warn("c_per"),
					disabled = off(form.c_limits, "c_limits"),
					control = {
						k = "choice",
						style = "segmented",
						value = form.c_per,
						options = { { value = "day", label = "Day" }, { value = "week", label = "Week" } },
					},
				},
			},
		},
		{
			id = "check",
			title = "Your own check",
			rows = {
				{
					id = "c_check",
					label = ROW_LABEL.c_check,
					hint = "For anything the others can't express. It runs in the job's folder (30 s limit) with a JSON file describing the run as its argument. Exit 0 runs, 1 skips, anything else blocks the run and tells you. It may print REASON: (shown in history), CONTEXT: lines (given to the agent) and CURSOR: (handed back next time). Saving the job approves the script as it is; if it changes, runs are blocked until you save again.",
					warning = warn("c_check"),
					control = { k = "switch", on = form.c_check },
				},
				{
					id = "c_script",
					label = ROW_LABEL.c_script,
					warning = warn("c_script"),
					disabled = off(form.c_check, "c_check"),
					control = { k = "text", value = form.c_script.text, placeholder = "./scripts/has-work.sh", mono = true },
				},
			},
		},
		{
			id = "ask",
			title = "Ask an AI",
			rows = {
				{
					id = "c_ask",
					label = ROW_LABEL.c_ask,
					hint = "For judgement calls. After the other conditions say yes, a model reads your question, can look at the job's folder (read-only), and answers run or skip. It also sees what the other conditions found, like the new commits. Each check is one model call; its cost counts toward Limits.",
					warning = warn("c_ask"),
					control = { k = "switch", on = form.c_ask },
				},
				{
					id = "c_ask_prompt",
					label = ROW_LABEL.c_ask_prompt,
					hint = "Write it as a yes/no question about the current state. It gets the job's name, folder, time and last run.",
					warning = warn("c_ask_prompt"),
					disabled = off(form.c_ask, "c_ask"),
					control = { k = "text", value = summary_line(form.c_ask_prompt.text), placeholder = "Run only if there are open pull requests that need a review." },
				},
				{
					id = "c_ask_role",
					label = ROW_LABEL.c_ask_role,
					hint = "A small, fast model is usually enough.",
					warning = warn("c_ask_role"),
					disabled = off(form.c_ask, "c_ask"),
					changed = form.c_ask_role ~= "smol",
					defaultLabel = "@smol",
					control = { k = "choice", value = form.c_ask_role, options = { { value = form.c_ask_role, label = "@" .. form.c_ask_role } }, style = "menu" },
				},
			},
		},
	}
	-- After a Check now, each switched-on condition gets its own "Right now" row right after its switch.
	local NOW_FOR = { c_commits = { "c_commits_now", "commits" }, c_window = { "c_window_now", "window" }, c_limits = { "c_limits_now", "budget" }, c_check = { "c_check_now", "check" }, c_ask = { "c_ask_now", "ask" } }
	for _, sec in sections do
		for i, r in sec.rows do
			local nf = NOW_FOR[r.id]
			if nf ~= nil and r.control.on == true then
				local nr = now_row(form, nf[1], nf[2])
				if nr ~= nil then
					table.insert(sec.rows, i + 1, nr)
				end
				break
			end
		end
	end
	return sections
end

-- The form's rows. `errs` are the current errors (F.errors); nil builds the structure only (ids, options), which is
-- all the key handlers need, so they skip validation and the schedule preview.
function F.sections(state: State, errs: { [string]: string }?): { P.Section }
	local form = state.form :: Form
	if form.page == "only_when" then
		return only_when_sections(state, errs)
	end
	local light = errs == nil
	local errors: { [string]: string } = errs or {}
	local function warn(row: string): string?
		return if shown(form, row) then errors[row] else nil
	end

	local when_hint = if light then "" else F.preview(form)
	local cond_warning: string? = nil
	for _, row in ROW_ORDER do
		if C_ROWS[row] and warn(row) ~= nil then
			cond_warning = "Fix the conditions on the Only when page."
			break
		end
	end
	local prompt_hint = "Enter edits it · ctrl+o opens it as a file. Say what to do if something is unclear. Nobody is watching a scheduled run."
	if #form.prompt.text > 4000 then
		prompt_hint = string.format("%d characters · long prompts read better as a file (ctrl+o)", #form.prompt.text)
	end

	local folder_path = expand(form.folder.text)
	local folder_warning = warn("folder")
	local folder_hint: string? = "Enter types a path. Runs always start in this folder."
	if folder_warning == nil and folder_path ~= "" and C.home() ~= "" and folder_path == validate.strip_slashes(C.home()) then
		folder_warning = "omp may work in a temporary folder instead of your home folder. Pick a project folder for predictable results."
	end

	local role_hint = "Resolved each time the job runs."
	if form.roles_for ~= nil then
		if form.roles ~= nil then
			role_hint = string.format("%d roles in this folder. Enter picks one. Resolved each time the job runs.", #form.roles)
		elseif form.roles_err ~= nil then
			role_hint = "Couldn't read your omp roles. Jobs still run, but role names aren't checked first."
		else
			role_hint = "Reading your omp roles…"
		end
	end

	local catch_options: { any } = {}
	for _, o in C.CATCH_UPS do
		table.insert(catch_options, { value = o.value, label = if o.value == "within" then C.catch_up_label("within", window_s(form)) else o.label })
	end
	local approval_options: { any } = {}
	for _, o in C.APPROVALS do
		table.insert(approval_options, { value = o.value, label = o.label, detail = o.detail })
	end
	local stop_options: { any } = {}
	local stop_known = false
	for _, o in C.STOPS do
		if o.s == form.stop_s then
			stop_known = true
		end
	end
	if not stop_known then
		table.insert(stop_options, { value = tostring(form.stop_s), label = C.stop_label(form.stop_s) })
	end
	for _, o in C.STOPS do
		table.insert(stop_options, { value = tostring(o.s), label = o.label })
	end
	local role_options: { any } = { { value = form.role, label = "@" .. form.role } }

	local approval_hint: string?
	local approval_warning: string? = warn("approval")
	if form.approval == "yolo" then
		approval_warning = approval_warning or C.HANDS_OFF_WARNING
	elseif form.approval == "write" then
		approval_hint = "If a run stops to ask, it shows up under Needs you. Use Save & run now to see what it asks for."
	else
		approval_hint = "Every edit and command waits for you; those runs show up under Needs you."
	end

	local job_rows: { P.Row } = {
		{
			id = "name",
			label = ROW_LABEL.name,
			warning = warn("name"),
			control = { k = "text", value = form.name.text, placeholder = "e.g. daily-review" },
		},
		{
			id = "prompt",
			label = ROW_LABEL.prompt,
			hint = prompt_hint,
			warning = warn("prompt"),
			control = { k = "text", value = summary_line(form.prompt.text), placeholder = "What should the agent do?" },
		},
		{
			id = "when",
			label = ROW_LABEL.when,
			hint = if when_hint ~= "" then when_hint .. " · ctrl+p presets" else "ctrl+p presets",
			warning = warn("when"),
			control = { k = "text", value = form.when.text, placeholder = "weekdays 9am", mono = true },
		},
		{
			id = "only_when",
			label = ROW_LABEL.only_when,
			hint = (if light then "" else F.only_when_summary(form)) .. " · Enter changes it",
			warning = cond_warning,
			control = { k = "action", act = "only_when", label = "Change…" },
		},
		{
			id = "catch_up",
			label = ROW_LABEL.catch_up,
			hint = "Missed means Tern wasn't running or your " .. platform.machine() .. " was asleep. Several misses count as one.",
			warning = warn("catch_up"),
			changed = form.catch_up ~= default_for(form, "catch_up"),
			defaultLabel = C.catch_up_label(default_for(form, "catch_up") :: string, window_s(form)),
			control = { k = "choice", value = form.catch_up, options = catch_options, style = "menu" },
		},
		{
			id = "folder",
			label = ROW_LABEL.folder,
			hint = folder_hint,
			warning = folder_warning,
			control = { k = "text", value = form.folder.text, placeholder = "Pick a project folder.", mono = true },
		},
		{
			id = "role",
			label = ROW_LABEL.role,
			hint = role_hint,
			warning = warn("role"),
			changed = form.role ~= default_for(form, "role"),
			defaultLabel = "@" .. (default_for(form, "role") :: string),
			control = { k = "choice", value = form.role, options = role_options, style = "menu" },
		},
	}
	local safety_rows: { P.Row } = {
		{
			id = "approval",
			label = ROW_LABEL.approval,
			hint = approval_hint,
			warning = approval_warning,
			changed = form.approval ~= default_for(form, "approval"),
			defaultLabel = C.approval_label(default_for(form, "approval") :: string),
			control = { k = "choice", value = form.approval, options = approval_options, style = "menu" },
		},
		{
			id = "stop",
			label = ROW_LABEL.stop,
			hint = "The run is stopped, not paused, when time is up.",
			warning = warn("stop"),
			changed = form.stop_s ~= default_for(form, "stop"),
			defaultLabel = C.stop_label(default_for(form, "stop") :: number),
			control = { k = "choice", value = tostring(form.stop_s), options = stop_options, style = "menu" },
		},
	}
	local state_rows: { P.Row } = {
		{
			id = "active",
			label = ROW_LABEL.active,
			hint = "Off saves the job paused. Good for a canary: save paused, then press r.",
			changed = not form.enabled,
			defaultLabel = "On",
			control = { k = "switch", on = form.enabled },
		},
		{
			id = "quiet",
			label = ROW_LABEL.quiet,
			hint = "The agent may end with RESULT: [quiet]; those runs show as ✓ quiet with nothing to read.",
			changed = form.quiet_ok,
			defaultLabel = "Off",
			control = { k = "switch", on = form.quiet_ok },
		},
	}
	return {
		{ id = "job", title = "Job", rows = job_rows },
		{ id = "safety", title = "Safety", rows = safety_rows },
		{ id = "state", title = nil, rows = state_rows },
	}
end

-- Editing helpers ------------------------------------------------------------------------------------

local function field_of(form: Form, row: string): textfield.Field?
	if row == "name" then
		return form.name
	elseif row == "prompt" then
		return form.prompt
	elseif row == "when" then
		return form.when
	elseif row == "c_paths" then
		return form.c_paths
	elseif row == "c_script" then
		return form.c_script
	elseif row == "c_ask_prompt" then
		return form.c_ask_prompt
	elseif row == "folder" then
		return form.folder
	end
	return nil
end

local function set_focus(state: State, row: string?)
	local form = state.form :: Form
	form.focus = row
	-- A row on the other page (Save's first failing row) brings its page with it.
	if row ~= nil then
		local page = if C_ROWS[row] then "only_when" else "job"
		if page ~= form.page then
			form.page = page
			F.refresh_branches(state)
		end
	end
end

-- A Check now result stops applying as soon as anything it was based on changes.
local function clear_verdict(form: Form)
	form.verdict = nil
	form.checking = nil
	form.check_token = nil
end

-- A condition value changed: forget the last Check now, show its errors, drop its stale server errors.
local function cond_changed(form: Form)
	clear_verdict(form)
	form.touched.cond = true
	for row in C_ROWS do
		form.extra[row] = nil
	end
	form.extra["only_when.script"] = nil
	form.extra["only_when.ask"] = nil
	form.extra["only_when.ask_role"] = nil
end

local function switch_get(form: Form, row: string): boolean
	if row == "active" then
		return form.enabled
	elseif row == "quiet" then
		return form.quiet_ok
	elseif row == "c_commits" then
		return form.c_commits
	elseif row == "c_window" then
		return form.c_window
	elseif row == "c_limits" then
		return form.c_limits
	end
	if row == "c_ask" then
		return form.c_ask
	end
	return form.c_check
end

local function switch_set(state: State, row: string, on: boolean)
	local form = state.form :: Form
	if row == "active" then
		form.enabled = on
	elseif row == "quiet" then
		form.quiet_ok = on
	else
		if row == "c_commits" then
			form.c_commits = on
		elseif row == "c_window" then
			form.c_window = on
		elseif row == "c_limits" then
			form.c_limits = on
		elseif row == "c_check" then
			form.c_check = on
		elseif row == "c_ask" then
			form.c_ask = on
		end
		cond_changed(form)
	end
end

local function start_edit(state: State, row: string)
	local form = state.form :: Form
	local f = field_of(form, row)
	if f == nil then
		return
	end
	if row == "prompt" then
		-- Adopt the draft file if it was edited there.
		sync_draft(form)
	end
	form.focus = row
	form.menu = nil
	form.editing = { row = row, initial = f.text }
	if MULTI_ROWS[row] then
		-- The editor node exists only after the next render.
		tern.timer(50, function()
			local fm = state.form
			if fm ~= nil and fm.editing ~= nil and MULTI_ROWS[fm.editing.row] then
				C.focus(state.cx, EDITOR_ID)
			end
		end)
	end
end

local function stop_edit(state: State, revert: boolean)
	local form = state.form :: Form
	local e = form.editing
	if e == nil then
		return
	end
	form.esc_at = nil
	local f = field_of(form, e.row)
	if f ~= nil and revert then
		textfield.set(f, e.initial)
	end
	form.editing = nil
	if MULTI_ROWS[e.row] then
		C.focus(state.cx, nil)
	end
	if not revert and f ~= nil and f.text ~= e.initial then
		form.touched[e.row] = true
		form.extra[e.row] = nil
		if C_ROWS[e.row] then
			cond_changed(form)
		end
		if e.row == "when" and form.was_done == true then
			-- A new time on a finished one-shot makes it active again (EN §6.6).
			form.enabled = true
		end
		if e.row == "folder" then
			form.folder_ok = nil
			form.extra.role = nil
			F.refresh_roles(state)
			clear_verdict(form)
			F.refresh_branches(state)
			check_folder(state, nil)
		end
	end
end

-- The value of the option a menu row currently shows (what its menu opens on).
local function menu_current(form: Form, row: string): string
	if row == "catch_up" then
		return form.catch_up
	elseif row == "approval" then
		return form.approval
	end
	return tostring(form.stop_s)
end

-- Shows the other page (Escape on Only when goes back to Job); stops any edit or menu first.
local function switch_page(state: State, page: string)
	local form = state.form :: Form
	if page ~= "job" and page ~= "only_when" then
		return
	end
	if form.editing ~= nil then
		stop_edit(state, false)
	end
	form.menu = nil
	form.esc_at = nil
	if form.page == page then
		return
	end
	form.page = page
	form.focus = if page == "job" then "only_when" else "c_commits"
	F.refresh_branches(state)
end

local function apply_choice(state: State, row: string, value: string)
	local form = state.form :: Form
	if row == "catch_up" then
		form.catch_up = value
	elseif row == "approval" then
		form.approval = value
	elseif row == "stop" then
		form.stop_s = tonumber(value) or form.stop_s
	elseif row == "c_outside" then
		form.c_outside = value == "outside"
	elseif row == "c_runs" then
		local n = tonumber(value)
		form.c_runs = if n ~= nil and n > 0 then n else nil
	elseif row == "c_usd" then
		local n = tonumber(value)
		form.c_usd = if n ~= nil and n > 0 then n else nil
	elseif row == "c_per" then
		form.c_per = if value == "week" then "week" else "day"
	end
	form.touched[row] = true
	form.extra[row] = nil
	if C_ROWS[row] then
		cond_changed(form)
	end
end

local function choice_values(state: State, row: string): { string }
	for _, sec in F.sections(state) do
		for _, r in sec.rows do
			if r.id == row then
				return P.option_values(r.control)
			end
		end
	end
	return {}
end

local function reset_row(state: State, row: string)
	local form = state.form :: Form
	if row == "role" then
		form.role = default_for(form, "role") :: string
		form.touched.role = true
	elseif row == "catch_up" or row == "approval" then
		apply_choice(state, row, default_for(form, row) :: string)
	elseif row == "stop" then
		apply_choice(state, row, tostring(default_for(form, row)))
	elseif row == "c_ask_role" then
		F.set_ask_role(state, "smol")
	elseif row == "active" then
		form.enabled = true
	elseif SWITCH_ROWS[row] then
		switch_set(state, row, false)
	end
end

function F.set_role(state: State, role: string)
	local form = state.form
	if form == nil then
		return
	end
	form.role = role
	form.touched.role = true
	form.extra.role = nil
end

function F.set_ask_role(state: State, role: string)
	local form = state.form
	if form == nil then
		return
	end
	form.c_ask_role = role
	form.touched.c_ask_role = true
	cond_changed(form)
	form.focus = "c_ask_role"
end

function F.set_when(state: State, phrase: string)
	local form = state.form
	if form == nil then
		return
	end
	textfield.set(form.when, phrase)
	form.touched.when = true
	form.extra.when = nil
	if form.was_done == true then
		form.enabled = true
	end
	form.focus = "when"
end

function F.set_branch(state: State, branch: string)
	local form = state.form
	if form == nil then
		return
	end
	form.c_branch = branch
	form.touched.c_branch = true
	cond_changed(form)
	form.focus = "c_branch"
end

function F.set_time(state: State, row: string, minutes: number)
	local form = state.form
	if form == nil then
		return
	end
	if row == "c_to" then
		form.c_to = minutes
	else
		form.c_from = minutes
	end
	form.touched[row] = true
	cond_changed(form)
	form.focus = row
end

-- Applies a new selection of the Days chips; at least one day must stay on.
local function change_days(state: State, days: { number })
	local form = state.form :: Form
	local clean = sorted_days(days)
	if #clean == 0 then
		C.notice(state, "Pick at least one day.")
		return
	end
	form.c_days = clean
	form.touched.c_days = true
	cond_changed(form)
end

-- Flips one weekday (0 = Sunday .. 6 = Saturday) in the Days chips.
local function toggle_day(state: State, day: number)
	local form = state.form :: Form
	local days: { number } = {}
	local found = false
	for _, d in form.c_days do
		if d == day then
			found = true
		else
			table.insert(days, d)
		end
	end
	if not found then
		table.insert(days, day)
	end
	change_days(state, days)
end

-- Save -------------------------------------------------------------------------------------------------

local function close_form(state: State, select_job: string?)
	local form = state.form
	if form ~= nil and form.draft_path ~= nil then
		pcall(tern.fs.remove, form.draft_path)
	end
	state.form = nil
	state.mode = "list"
	state.sheet = nil
	state.armed = nil
	C.focus(state.cx, nil)
	if select_job ~= nil then
		state.sel = { sec = "upcoming", key = select_job }
	end
	-- Opened from a job's Detail: go back to it (the new job after a duplicate was saved).
	local back: string? = if form ~= nil and form.return_to ~= nil then (select_job or form.return_to) else nil
	if back ~= nil and jobs.get(back) ~= nil then
		state.mode = "detail"
		state.detail = { job_id = back, sel = nil, expanded = nil }
	end
end

function F.cancel(state: State)
	close_form(state, nil)
end

-- Esc / Cancel: closes at once when nothing changed, else asks to confirm within 3 s (UX §4.10).
function F.request_cancel(state: State)
	local form = state.form
	if form == nil then
		return
	end
	if not F.dirty(form) or (form.esc_at ~= nil and tern.now() - form.esc_at < 3000) then
		F.cancel(state)
		return
	end
	form.esc_at = tern.now()
	tern.timer(3100, function()
		if state.form == form then
			C.render(state)
		end
	end)
end

local function next_text(job_id: string): string
	local js: any = jobs.state(job_id)
	local nxt = if type(js) == "table" then js.next_run else nil
	if type(nxt) == "number" then
		return "Next " .. C.abs(nxt)
	end
	return "Manual only"
end

-- Dry-runs the conditions that are switched on without starting anything; the result shows on the Only when page.
local function check_now(state: State)
	local form = state.form
	if form == nil or form.checking == true then
		return
	end
	local list = conditions.build(F.only_when_input(form))
	if list == nil then
		form.submitted = true
		local errs = F.errors(state)
		for _, row in ROW_ORDER do
			if C_ROWS[row] and errs[row] ~= nil then
				set_focus(state, row)
				break
			end
		end
		return
	end
	local draft = {
		id = form.id or "_draft",
		name = form.name.text,
		cwd = expand(form.folder.text),
		conditions = list,
	}
	local token = {}
	form.check_token = token
	form.checking = true
	form.verdict = nil
	if NOW_ROWS[form.focus or ""] then
		form.focus = "c_now"
	end
	runner.check_draft(draft, function(v: any)
		if state.form ~= form or form.check_token ~= token then
			return
		end
		form.checking = false
		form.verdict = v
		C.render(state)
	end)
end

-- Reads the script check of the form and pins its hash, so a later edit of the script blocks runs until re-saved.
local function pin_checks(state: State, form: Form, cb: ({ [string]: string }) -> ())
	local acks: { [string]: string } = {}
	if not form.c_check then
		cb(acks)
		return
	end
	local path = C.trim(form.c_script.text)
	cond_eval.read_script(conditions.script_path(path, expand(form.folder.text), C.home()), function(text: string?, err_text: string?)
		if state.form ~= form then
			return
		end
		if text == nil then
			local msg = err_text or "couldn't read your check"
			form.busy = false
			form.submitted = true
			form.extra["only_when.script"] = string.upper(string.sub(msg, 1, 1)) .. string.sub(msg, 2) .. "."
			set_focus(state, "c_script")
			C.render(state)
			return
		end
		acks[path] = "ck1:" .. ids.fnv64(text)
		cb(acks)
	end)
end

local function commit(state: State, form: Form, run_now: boolean, acks: { [string]: string })
	local input = F.input(form)
	input.check_acks = acks
	local prompt = form.prompt.text
	local now = C.now()
	local was_empty = #jobs.list() == 0
	local job: any, errs: any
	if form.id ~= nil then
		job, errs = jobs.update(form.id, input, prompt, now)
	else
		job, errs = jobs.create(input, prompt, "user", now)
	end
	form.busy = false
	if job == nil then
		form.submitted = true
		local failed = false
		if type(errs) == "table" then
			for field, msg in errs do
				local row = error_row(field)
				form.extra[row] = msg
				failed = true
			end
		end
		if not failed then
			form.extra.name = "Couldn't save the job. Check the data folder is writable."
		end
		local errors = F.errors(state)
		set_focus(state, failing(state, errors)[1] or "name")
		C.render(state)
		return
	end
	local id: string = job.id
	local editing = form.id ~= nil
	local was_running = false
	for _, r in runner.inflight() do
		if (r :: any).job_id == id then
			was_running = true
		end
	end
	runner.changed()
	close_form(state, id)
	if job.enabled == false then
		C.toast(state, "success", "Saved " .. job.name .. " (paused)", "Press space to resume it.")
	elseif editing and was_running then
		C.toast(state, "success", "Saved " .. job.name, "Takes effect on the next run.")
	else
		C.toast(state, "success", "Saved " .. job.name, next_text(id))
	end
	if run_now then
		R.run_now(state, id, { override = "front", toast = false })
	elseif was_empty and not editing and job.enabled ~= false then
		state.sheet = { kind = "first_run", job_id = id }
	end
	C.render(state)
end

-- Validates, checks the folder, then saves. `run_now` also starts a run brought to the front.
function F.save(state: State, run_now: boolean)
	local form = state.form
	if form == nil or form.busy then
		return
	end
	if form.editing ~= nil then
		stop_edit(state, false)
	end
	sync_draft(form)
	form.extra["only_when.script"] = nil -- a script-read error from the last Save is re-checked by pin_checks
	local errs = F.errors(state)
	if next(errs) ~= nil then
		form.submitted = true
		set_focus(state, failing(state, errs)[1])
		return
	end
	form.busy = true
	check_folder(state, function(ok)
		local fm = state.form
		if fm ~= form then
			return
		end
		if not ok then
			fm.busy = false
			fm.submitted = true
			set_focus(state, "folder")
			return
		end
		pin_checks(state, fm, function(acks)
			commit(state, fm, run_now, acks)
		end)
	end)
end

-- Opening ------------------------------------------------------------------------------------------------

local function start(state: State, form: Form)
	form.return_to = if state.mode == "detail" and state.detail ~= nil then state.detail.job_id else nil
	state.form = form
	state.mode = "form"
	state.sheet = nil
	state.armed = nil
	F.refresh_roles(state)
	F.refresh_branches(state)
	check_folder(state, nil)
	-- A job without a name opens ready to type it.
	if form.focus == "name" then
		start_edit(state, "name")
	end
end

-- A new job; `seed` pre-fills it (Folder from the focused pane, examples, duplicates).
function F.open_new(state: State, seed: Seed)
	start(state, F.new(seed, nil, "New job"))
end

function F.open_edit(state: State, job_id: string)
	local job: any = jobs.get(job_id)
	if job == nil then
		return
	end
	local sched: any = job.schedule
	local seed: Seed = {
		name = job.name,
		prompt = jobs.prompt(job_id) or "",
		when = if type(sched) == "table" and type(sched.input) == "string" then sched.input else "manual",
		cwd = job.cwd,
		role = job.role,
		enabled = job.enabled ~= false,
		only_when = conditions.to_input(job.conditions),
		quiet_ok = job.quiet_ok == true,
	}
	seed.catch_up = job.catch_up
	seed.approval = job.approval
	seed.stop_s = job.max_runtime_s
	seed.window_s = job.catch_up_window_s
	local form = F.new(seed, job_id, "Edit " .. job.name)
	local js: any = jobs.state(job_id)
	form.was_done = type(js) == "table" and js.done == true
	start(state, form)
end

-- The form's fields for the block `save`, so an open form survives a plugin reload or restart.
function F.snapshot(form: Form): { [string]: any }
	sync_draft(form)
	return {
		id = form.id,
		title = form.title,
		name = form.name.text,
		prompt = form.prompt.text,
		when = form.when.text,
		folder = form.folder.text,
		role = form.role,
		catch_up = form.catch_up,
		approval = form.approval,
		stop_s = form.stop_s,
		enabled = form.enabled,
		page = form.page,
		c_commits = form.c_commits,
		c_branch = form.c_branch,
		c_paths = form.c_paths.text,
		c_window = form.c_window,
		c_days = table.clone(form.c_days),
		c_from = form.c_from,
		c_to = form.c_to,
		c_outside = form.c_outside,
		c_limits = form.c_limits,
		c_runs = form.c_runs or 0,
		c_usd = form.c_usd or 0,
		c_per = form.c_per,
		c_check = form.c_check,
		c_script = form.c_script.text,
		c_ask = form.c_ask,
		c_ask_prompt = form.c_ask_prompt.text,
		c_ask_role = form.c_ask_role,
		quiet_ok = form.quiet_ok,
		window_s = form.catch_up_window_s,
		draft_path = form.draft_path,
		draft_seed = form.draft_seed,
		was_done = form.was_done,
		return_to = form.return_to,
		orig = form.orig,
	}
end

-- Rebuilds a form from F.snapshot output; false when it can't be (the edited job is gone, bad data).
function F.restore(state: State, saved: any): boolean
	if type(saved) ~= "table" then
		return false
	end
	local s: { [string]: any } = saved
	local id: string? = if type(s.id) == "string" then s.id else nil
	if id ~= nil and jobs.get(id) == nil then
		return false
	end
	local function str(v: any): string?
		return if type(v) == "string" then v else nil
	end
	local seed: Seed = {
		name = str(s.name),
		prompt = str(s.prompt),
		when = str(s.when),
		cwd = str(s.folder),
		role = str(s.role),
		enabled = if type(s.enabled) == "boolean" then s.enabled else nil,
		quiet_ok = if type(s.quiet_ok) == "boolean" then s.quiet_ok else nil,
		catch_up = str(s.catch_up),
		approval = str(s.approval),
		stop_s = if type(s.stop_s) == "number" then s.stop_s else nil,
		window_s = if type(s.window_s) == "number" then s.window_s else nil,
	}
	local form = F.new(seed, id, str(s.title) or (if id ~= nil then "Edit job" else "New job"))
	-- The condition values of a saved form override the defaults F.new made (0 stands for "no limit").
	if type(s.c_commits) == "boolean" then
		form.c_commits = s.c_commits
	end
	if type(s.c_branch) == "string" then
		form.c_branch = s.c_branch
	end
	if type(s.c_paths) == "string" then
		textfield.set(form.c_paths, s.c_paths)
	end
	if type(s.c_window) == "boolean" then
		form.c_window = s.c_window
	end
	if type(s.c_days) == "table" then
		local days: { number } = {}
		for _, d in s.c_days do
			if type(d) == "number" then
				table.insert(days, d)
			end
		end
		if #days > 0 then
			form.c_days = days
		end
	end
	if type(s.c_from) == "number" then
		form.c_from = s.c_from
	end
	if type(s.c_to) == "number" then
		form.c_to = s.c_to
	end
	if type(s.c_outside) == "boolean" then
		form.c_outside = s.c_outside
	end
	if type(s.c_limits) == "boolean" then
		form.c_limits = s.c_limits
	end
	if type(s.c_runs) == "number" then
		form.c_runs = if s.c_runs > 0 then s.c_runs else nil
	end
	if type(s.c_usd) == "number" then
		form.c_usd = if s.c_usd > 0 then s.c_usd else nil
	end
	if type(s.c_per) == "string" then
		form.c_per = s.c_per
	end
	if type(s.c_check) == "boolean" then
		form.c_check = s.c_check
	end
	if type(s.c_script) == "string" then
		textfield.set(form.c_script, s.c_script)
	end
	if type(s.c_ask) == "boolean" then
		form.c_ask = s.c_ask
	end
	if type(s.c_ask_prompt) == "string" then
		textfield.set(form.c_ask_prompt, s.c_ask_prompt)
	end
	if type(s.c_ask_role) == "string" and s.c_ask_role ~= "" then
		form.c_ask_role = s.c_ask_role
	end
	if s.page == "only_when" then
		form.page = "only_when"
		form.focus = "c_commits"
	end
	if type(s.orig) == "table" then
		local orig: { [string]: any } = {}
		for k, v in s.orig do
			local t = type(v)
			if type(k) == "string" and (t == "string" or t == "number" or t == "boolean") then
				orig[k] = v
			end
		end
		if next(orig) ~= nil then
			form.orig = orig
		end
	end
	form.draft_path = str(s.draft_path)
	form.draft_seed = str(s.draft_seed)
	form.was_done = s.was_done == true
	start(state, form)
	form.return_to = str(s.return_to)
	return true
end

-- View -------------------------------------------------------------------------------------------------------

local function base_hints(cols: number, editing: string?): string
	if editing == "prompt" then
		return if cols < 56 then "^⏎ done · esc revert" else "⏎ newline · ^⏎ done · esc revert"
	elseif editing ~= nil then
		return if cols < 56 then "⏎ done · ^⏎ save" else "⏎ done · ^⏎ save · esc revert"
	elseif cols < 56 then
		return "^⏎ save · esc cancel"
	end
	return "↑↓ move · ←→ change · ⏎ edit · ^⏎ save · esc cancel"
end

function F.hints(cols: number, editing: string?, page: string?): string
	local text = base_hints(cols, editing)
	if page == "only_when" and editing == nil then
		text = (string.gsub(text, "esc cancel$", "esc back to Job"))
	end
	return text
end

function F.view(state: State): (Node, Node)
	local form = state.form :: Form
	local cx = state.cx
	local errs = F.errors(state)
	local sections = F.sections(state, errs)

	local editing: any = nil
	local e = form.editing
	if e ~= nil and not MULTI_ROWS[e.row] then
		local f = field_of(form, e.row)
		if f ~= nil then
			editing = { row = e.row, draft = f.text, cursor = textfield.utf16(f) }
		end
	elseif form.menu ~= nil then
		editing = { row = form.menu.row, option = form.menu.option }
	end

	local props: { [string]: any } = {
		key = "prefs",
		title = "Agent Scheduler",
		lead = if form.page == "only_when"
			then "A due run starts only if every condition that's on says yes. Otherwise it's skipped and noted in the job's history, and you aren't notified. Run now asks before it ignores them."
			elseif form.id ~= nil then "Change this job. Saved changes apply from its next run."
			else "Run an omp agent on a schedule.",
		pages = C.arr({
			{ id = "job", label = "Job", icon = "timer" },
			{ id = "only_when", label = "Only when", icon = "funnel" },
		}),
		page = form.page,
		sections = P.node_sections(sections),
		focus = form.focus,
		editing = editing,
	}
	local children: { Node } = {}
	local mf: textfield.Field? = if e ~= nil and MULTI_ROWS[e.row] then field_of(form, e.row) else nil
	if e ~= nil and mf ~= nil then
		local ed: { Node } = {
			C.text({
				ui.span("Prompt", "strong"),
				ui.span("  Markdown. Sent to the agent as an attached file.", "muted"),
			}, "title"),
			ui.node("editor", {
				key = "text",
				text = mf.text,
				cursor = textfield.utf16(mf),
				maxLines = 14,
				placeholder = "What should the agent do? Say what to do if something is unclear.",
			}),
			C.text({ ui.span("⏎ newline · ^⏎ done · esc revert", "muted") }, "keys"),
		}
		table.insert(children, C.with(ui.col(ed), { key = "pe", role = "omp.prefs.editor" }))
	end
	local main = ui.col({ ui.node("prefs", props, children) })

	-- Dock: status line, badges, hints.
	local failing_rows = failing(state, errs)
	local status: Spans
	local discard = form.esc_at ~= nil and tern.now() - form.esc_at < 3000
	if state.notice ~= nil and tern.now() - state.notice_at < 6000 then
		status = { ui.span(state.notice, "warning") }
	elseif discard then
		status = { ui.span(if e ~= nil and MULTI_ROWS[e.row] then "Discard prompt edits? esc again" else "Discard changes? esc again", "warning") }
	elseif #failing_rows > 0 then
		local names: { string } = {}
		for _, row in failing_rows do
			table.insert(names, ROW_LABEL[row])
		end
		status = { ui.span("Fix: " .. table.concat(names, ", "), "warning") }
	else
		status = { ui.span("Save & run now runs it once right away, exactly as scheduled. It can change files.", "muted") }
	end
	local blocked = next(errs) ~= nil
	local narrow = cx.cols < 70
	local acts: { Node } = {
		C.badge(if narrow then "Save" else "Save ^⏎", if blocked then "muted" else "accent", "save", "save"),
		C.badge(if narrow then "Run" else "Save & run now ^⇧⏎", "neutral", "save_run", "save_run"),
		C.badge(if narrow then "Cancel" else "Cancel esc", "neutral", "cancel", "cancel"),
	}
	local dock = ui.col({
		C.text(status, "status"),
		C.with(ui.row(acts), { key = "acts" }),
		C.text({ ui.span(F.hints(cx.cols, if e ~= nil then e.row else nil, form.page), "muted") }, "hints"),
	})
	return main, dock
end

-- Keys -------------------------------------------------------------------------------------------------------

local function key_text(state: State, k: Key): boolean
	local form = state.form :: Form
	local e = form.editing :: { row: string, initial: string }
	local f = field_of(form, e.row) :: textfield.Field
	local name = k.name
	local multi = MULTI_ROWS[e.row] == true
	if name == "escape" then
		-- A multi-line prompt can hold minutes of typing: ask before throwing it away.
		if multi and f.text ~= e.initial and not (form.esc_at ~= nil and tern.now() - form.esc_at < 3000) then
			form.esc_at = tern.now()
			tern.timer(3100, function()
				if state.form == form then
					C.render(state)
				end
			end)
			return true
		end
		stop_edit(state, true)
		return true
	end
	local pending = form.esc_at ~= nil
	form.esc_at = nil
	if name == "enter" then
		if multi then
			if k.ctrl or k.meta then
				stop_edit(state, false)
				return true
			end
			form.touched[e.row] = true
			textfield.insert(f, "\n")
			return true
		end
		stop_edit(state, false)
		if k.ctrl or k.meta then
			F.save(state, k.shift)
		end
		return true
	elseif name == "tab" and not multi then
		stop_edit(state, false)
		set_focus(state, P.move(F.sections(state), e.row, if k.shift then -1 else 1) or e.row)
		return true
	elseif name == "p" and k.ctrl and e.row == "when" then
		stop_edit(state, false)
		state.sheet = { kind = "presets", sel = nil }
		return true
	end
	local changed = textfield.key(f, k, multi)
	if changed then
		form.touched[e.row] = true
	end
	return changed or pending
end

local function key_menu(state: State, k: Key): boolean
	local form = state.form :: Form
	local m = form.menu :: { row: string, option: string }
	local name = k.name
	if m.row == "c_days" then
		-- Days chips: ←→ move the highlight, space toggles that day, Enter or Escape closes.
		local at = table.find(DAY_ORDER, tonumber(m.option) or 1) or 1
		if name == "left" or name == "right" then
			local j = math.clamp(at + (if name == "left" then -1 else 1), 1, #DAY_ORDER)
			if j == at then
				return false
			end
			m.option = tostring(DAY_ORDER[j])
			return true
		elseif name == "space" then
			toggle_day(state, DAY_ORDER[at])
			return true
		elseif name == "enter" or name == "escape" then
			form.menu = nil
			return true
		end
		return false
	end
	local values = choice_values(state, m.row)
	if name == "up" or name == "down" then
		local at = table.find(values, m.option) or 0
		local j = math.clamp(at + (if name == "up" then -1 else 1), 1, math.max(#values, 1))
		if values[j] == nil or values[j] == m.option then
			return false
		end
		m.option = values[j]
		return true
	elseif name == "enter" or name == "space" then
		form.menu = nil
		apply_choice(state, m.row, m.option)
		return true
	elseif name == "escape" then
		form.menu = nil
		return true
	end
	return false
end

local function activate(state: State, row: string): boolean
	local form = state.form :: Form
	form.focus = row
	if TEXT_ROWS[row] then
		start_edit(state, row)
		return true
	elseif MENU_ROWS[row] then
		form.menu = { row = row, option = menu_current(form, row) }
		return true
	elseif row == "c_days" then
		local first = 1
		for _, d in DAY_ORDER do
			if table.find(form.c_days, d) ~= nil then
				first = d
				break
			end
		end
		form.menu = { row = row, option = tostring(first) }
		return true
	elseif TIME_ROWS[row] then
		state.sheet = { kind = "time", row = row, query = textfield.new(), sel = tostring(if row == "c_to" then form.c_to else form.c_from) }
		return true
	elseif SEG_ROWS[row] then
		apply_choice(state, row, if row == "c_outside" then (if form.c_outside then "inside" else "outside") else (if form.c_per == "day" then "week" else "day"))
		return true
	elseif NOW_ROWS[row] then
		check_now(state)
		return true
	elseif row == "c_ask_role" then
		state.sheet = { kind = "roles", query = textfield.new(), sel = form.c_ask_role, row = "c_ask_role" }
		F.refresh_roles(state)
		return true
	elseif row == "role" then
		state.sheet = { kind = "roles", query = textfield.new(), sel = form.role }
		F.refresh_roles(state)
		return true
	elseif row == "c_branch" then
		state.sheet = { kind = "branches", query = textfield.new(), sel = if form.c_branch == "" then F.CURRENT_BRANCH else form.c_branch }
		F.refresh_branches(state)
		return true
	elseif SWITCH_ROWS[row] then
		switch_set(state, row, not switch_get(form, row))
		return true
	elseif row == "only_when" then
		switch_page(state, "only_when")
		return true
	elseif row == "c_now" then
		check_now(state)
		return true
	end
	return false
end

-- Opens the prompt as a draft file beside (ctrl+o).
local function open_file(state: State)
	local form = state.form :: Form
	local path = form.draft_path
	if path == nil then
		local dir = tern.plugin.data .. "/prompts"
		local made = pcall(tern.fs.mkdir, dir)
		if not made then
			C.notice(state, "Couldn't create the prompts folder.")
			return
		end
		-- Drafts live beside job prompts so an image Tern saves beside the draft keeps its relative link when
		-- the text is saved as the job's prompt. The time leads the name because tern.fs has no mtime.
		path = string.format("%s/%d-%s.md", dir, os.time(), ids.draft_id())
	else
		-- Keep edits already made in the file before writing the current prompt over it.
		sync_draft(form)
	end
	local ok = pcall(tern.fs.write, path :: string, form.prompt.text)
	if not ok then
		C.notice(state, "Couldn't write the prompt file.")
		return
	end
	form.draft_path = path
	form.draft_seed = form.prompt.text
	state.cx:open(path :: string)
	C.notice(state, "Editing the file replaces the prompt here when you save.")
end

local function key_inner(state: State, k: Key): boolean?
	local form = state.form :: Form
	local name = k.name
	if form.editing ~= nil then
		return key_text(state, k)
	elseif form.menu ~= nil then
		return key_menu(state, k)
	end

	if name == "enter" and (k.ctrl or k.meta) then
		F.save(state, k.shift)
		return true
	elseif name == "escape" then
		if form.page == "only_when" then
			switch_page(state, "job")
		else
			F.request_cancel(state)
		end
		return true
	end
	form.esc_at = nil

	if name == "o" and k.ctrl then
		open_file(state)
		return true
	elseif name == "p" and k.ctrl then
		if form.page ~= "job" then
			return false
		end
		state.sheet = { kind = "presets", sel = nil }
		return true
	elseif name == "up" or name == "down" or name == "tab" then
		local delta = if name == "up" or (name == "tab" and k.shift) then -1 else 1
		local target = P.move(F.sections(state), form.focus, delta)
		if target == nil then
			return false
		end
		form.focus = target
		return true
	elseif k.ctrl or k.meta or k.alt then
		return false
	end

	local row = form.focus
	if row == nil then
		return false
	end
	if name == "left" or name == "right" then
		if MENU_ROWS[row] then
			local values = choice_values(state, row)
			local cur = menu_current(form, row)
			local at = table.find(values, cur) or 0
			local j = math.clamp(at + (if name == "left" then -1 else 1), 1, math.max(#values, 1))
			if values[j] == nil or values[j] == cur then
				return false
			end
			apply_choice(state, row, values[j])
			return true
		elseif SEG_ROWS[row] then
			local want_second = name == "right"
			if row == "c_outside" then
				if form.c_outside == want_second then
					return false
				end
				apply_choice(state, row, if want_second then "outside" else "inside")
			else
				if (form.c_per == "week") == want_second then
					return false
				end
				apply_choice(state, row, if want_second then "week" else "day")
			end
			return true
		elseif NUM_ROWS[row] then
			local r = P.find(F.sections(state), row)
			local n = if r ~= nil then P.step_number(r.control, if name == "left" then -1 else 1) else nil
			if n == nil then
				return false
			end
			apply_choice(state, row, tostring(n))
			return true
		elseif SWITCH_ROWS[row] then
			local want = name == "right"
			if switch_get(form, row) == want then
				return false
			end
			switch_set(state, row, want)
			return true
		end
		return false
	elseif name == "enter" or name == "space" then
		return activate(state, row)
	elseif name == "R" or (name == "r" and k.shift) then
		reset_row(state, row)
		return true
	end
	return false
end

function F.key(state: State, k: Key): boolean?
	local form = state.form :: Form
	local pending = form.esc_at ~= nil
	local handled = key_inner(state, k)
	-- A key that clears the "esc again" prompt must redraw even when it does nothing else.
	return handled or (pending and state.form == form and form.esc_at == nil)
end

-- Events (mouse) ---------------------------------------------------------------------------------------------

function F.event(state: State, ev: UiEvent)
	local form = state.form
	if form == nil then
		return
	end
	local kind = ev.ev
	local item = ev.item
	if kind == "action" then
		local act = ev.act
		if act == "save" then
			F.save(state, false)
		elseif act == "save_run" then
			F.save(state, true)
		elseif act == "cancel" then
			F.request_cancel(state)
		elseif act == "page" and type(ev.value) == "string" then
			switch_page(state, ev.value)
		elseif act == "only_when" then
			switch_page(state, "only_when")
		elseif act == "c_now" then
			check_now(state)
		elseif act == "close" then
			-- Close on an open menu's button (it carries a row) closes the menu; the header's Close leaves the form.
			if form.menu ~= nil and ev.value ~= nil and ev.value ~= tern.json.null then
				form.menu = nil
			else
				F.request_cancel(state)
			end
		end
	elseif kind == "change" and type(item) == "string" then
		if form.editing ~= nil then
			stop_edit(state, false)
		end
		form.menu = nil
		form.focus = item
		if ev.value == nil or ev.value == tern.json.null then
			reset_row(state, item)
		elseif SWITCH_ROWS[item] and type(ev.value) == "boolean" then
			switch_set(state, item, ev.value)
		elseif SEG_ROWS[item] and type(ev.value) == "string" then
			apply_choice(state, item, ev.value)
		elseif NUM_ROWS[item] and type(ev.value) == "number" then
			apply_choice(state, item, tostring(ev.value))
		elseif item == "c_days" and type(ev.value) == "table" then
			local days: { number } = {}
			for _, v in ev.value :: { any } do
				local n = tonumber(v)
				if n ~= nil then
					table.insert(days, n)
				end
			end
			change_days(state, days)
		elseif MENU_ROWS[item] and type(ev.value) == "string" then
			apply_choice(state, item, ev.value)
		end
	elseif kind == "activate" and type(item) == "string" then
		if form.editing ~= nil then
			stop_edit(state, false)
		end
		activate(state, item)
	elseif kind == "select" and type(item) == "string" and string.find(item, "=", 1, true) == nil then
		if form.editing == nil and form.menu == nil then
			form.focus = item
		end
	end
end

return F
