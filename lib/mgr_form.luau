--!strict
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
}

local ROW_ORDER = { "name", "prompt", "when", "catch_up", "folder", "role", "approval", "stop", "active" }
local ROW_LABEL: { [string]: string } = {
	name = "Name",
	prompt = "Prompt",
	when = "When",
	catch_up = "If your " .. platform.machine() .. " was asleep",
	folder = "Folder",
	role = "Role",
	approval = "Approval",
	stop = "Stop after",
	active = "Active",
}
local TEXT_ROWS: { [string]: boolean } = { name = true, prompt = true, when = true, folder = true }
local MENU_ROWS: { [string]: boolean } = { catch_up = true, approval = true, stop = true }
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
		local row = if field == "cwd" then "folder" elseif field == "max_runtime_s" then "stop" else field
		out[row] = msg
	end
	for row, msg in form.extra do
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
	return form.touched[row] == true or form.submitted
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
	local tz = os.date("%Z", now)
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

-- Rows -------------------------------------------------------------------------------------------

local function summary_line(text: string): string
	local first = C.trim(string.match(text, "^[^\r\n]*") or "")
	local clipped = if (utf8.len(first) or #first) > 90 then string.sub(first, 1, utf8.offset(first, 90) or 90) .. "…" else first
	if clipped ~= first or string.find(text, "\n", 1, true) ~= nil then
		clipped ..= " …"
	end
	return clipped
end

-- The form's rows. `errs` are the current errors (F.errors); nil builds the structure only (ids, options), which is
-- all the key handlers need, so they skip validation and the schedule preview.
function F.sections(state: State, errs: { [string]: string }?): { P.Section }
	local form = state.form :: Form
	local light = errs == nil
	local errors: { [string]: string } = errs or {}
	local function warn(row: string): string?
		return if shown(form, row) then errors[row] else nil
	end

	local when_hint = if light then "" else F.preview(form)
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
	elseif row == "folder" then
		return form.folder
	end
	return nil
end

local function set_focus(state: State, row: string?)
	local form = state.form :: Form
	form.focus = row
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
	if row == "prompt" then
		-- The editor node exists only after the next render.
		tern.timer(50, function()
			local fm = state.form
			if fm ~= nil and fm.editing ~= nil and fm.editing.row == "prompt" then
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
	if e.row == "prompt" then
		C.focus(state.cx, nil)
	end
	if not revert and f ~= nil and f.text ~= e.initial then
		form.touched[e.row] = true
		form.extra[e.row] = nil
		if e.row == "when" and form.was_done == true then
			-- A new time on a finished one-shot makes it active again (EN §6.6).
			form.enabled = true
		end
		if e.row == "folder" then
			form.folder_ok = nil
			form.extra.role = nil
			F.refresh_roles(state)
			check_folder(state, nil)
		end
	end
end

local function apply_choice(state: State, row: string, value: string)
	local form = state.form :: Form
	if row == "catch_up" then
		form.catch_up = value
	elseif row == "approval" then
		form.approval = value
	elseif row == "stop" then
		form.stop_s = tonumber(value) or form.stop_s
	end
	form.touched[row] = true
	form.extra[row] = nil
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
	elseif row == "active" then
		form.enabled = true
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

local function commit(state: State, form: Form, run_now: boolean)
	local input = F.input(form)
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
				local row = if field == "cwd" then "folder" elseif field == "max_runtime_s" then "stop" else field
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
		local ok, err = runner.run_now(id, { focus_override = "front" })
		if not ok then
			C.notice(state, err or "Couldn't start the run.")
		end
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
		commit(state, fm, run_now)
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
		catch_up = str(s.catch_up),
		approval = str(s.approval),
		stop_s = if type(s.stop_s) == "number" then s.stop_s else nil,
		window_s = if type(s.window_s) == "number" then s.window_s else nil,
	}
	local form = F.new(seed, id, str(s.title) or (if id ~= nil then "Edit job" else "New job"))
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

function F.hints(cols: number, editing: string?): string
	if editing == "prompt" then
		return if cols < 56 then "^⏎ done · esc revert" else "⏎ newline · ^⏎ done · esc revert"
	elseif editing ~= nil then
		return if cols < 56 then "⏎ done · ^⏎ save" else "⏎ done · ^⏎ save · esc revert"
	elseif cols < 56 then
		return "^⏎ save · esc cancel"
	end
	return "↑↓ move · ←→ change · ⏎ edit · ^⏎ save · esc cancel"
end

function F.view(state: State): (Node, Node)
	local form = state.form :: Form
	local cx = state.cx
	local errs = F.errors(state)
	local sections = F.sections(state, errs)

	local editing: any = nil
	local e = form.editing
	if e ~= nil and e.row ~= "prompt" then
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
		lead = if form.id ~= nil then "Change this job. Saved changes apply from its next run." else "Run an omp agent on a schedule.",
		-- One page, so the header reads "01 · Job" rather than an empty label.
		pages = C.arr({ { id = "job", label = "Job", icon = "timer" } }),
		page = "job",
		sections = P.node_sections(sections),
		focus = form.focus,
		editing = editing,
	}
	local children: { Node } = {}
	if e ~= nil and e.row == "prompt" then
		local ed: { Node } = {
			C.text({ ui.span("Prompt", "strong"), ui.span("  Markdown. Sent to the agent as an attached file.", "muted") }, "title"),
			ui.node("editor", {
				key = "text",
				text = form.prompt.text,
				cursor = textfield.utf16(form.prompt),
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
		status = { ui.span(if e ~= nil and e.row == "prompt" then "Discard prompt edits? esc again" else "Discard changes? esc again", "warning") }
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
		C.text({ ui.span(F.hints(cx.cols, if e ~= nil then e.row else nil), "muted") }, "hints"),
	})
	return main, dock
end

-- Keys -------------------------------------------------------------------------------------------------------

local function key_text(state: State, k: Key): boolean
	local form = state.form :: Form
	local e = form.editing :: { row: string, initial: string }
	local f = field_of(form, e.row) :: textfield.Field
	local name = k.name
	local multi = e.row == "prompt"
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
			form.touched.prompt = true
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
	local values = choice_values(state, m.row)
	local name = k.name
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
		local current = if row == "catch_up" then form.catch_up elseif row == "approval" then form.approval else tostring(form.stop_s)
		form.menu = { row = row, option = current }
		return true
	elseif row == "role" then
		state.sheet = { kind = "roles", query = textfield.new(), sel = form.role }
		F.refresh_roles(state)
		return true
	elseif row == "active" then
		form.enabled = not form.enabled
		return true
	end
	return false
end

-- Opens the prompt as a draft file beside (ctrl+o).
local function open_file(state: State)
	local form = state.form :: Form
	local path = form.draft_path
	if path == nil then
		local dir = tern.plugin.data .. "/drafts"
		local made = pcall(tern.fs.mkdir, dir)
		if not made then
			C.notice(state, "Couldn't create the drafts folder.")
			return
		end
		-- The creation time leads the name (tern.fs has no mtime) so housekeeping can age it out.
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
		F.request_cancel(state)
		return true
	end
	form.esc_at = nil

	if name == "o" and k.ctrl then
		open_file(state)
		return true
	elseif name == "p" and k.ctrl then
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
			local cur = if row == "catch_up" then form.catch_up elseif row == "approval" then form.approval else tostring(form.stop_s)
			local at = table.find(values, cur) or 0
			local j = math.clamp(at + (if name == "left" then -1 else 1), 1, math.max(#values, 1))
			if values[j] == nil or values[j] == cur then
				return false
			end
			apply_choice(state, row, values[j])
			return true
		elseif row == "active" then
			local want = name == "right"
			if form.enabled == want then
				return false
			end
			form.enabled = want
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
		elseif item == "active" and type(ev.value) == "boolean" then
			form.enabled = ev.value
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
