--!strict
-- Manager layer: role and presets pickers, stop confirm, "Run it now and watch?", key help, the Setup sheet and
-- the Settings sheet. State lives in `state.sheet`; the manager routes keys and events here while a sheet is open.

local ui = tern.ui
local C = require("./mgr_common")
local P = require("./mgr_prefs")
local F = require("./mgr_form")
local textfield = require("./textfield")
local schedule = require("./schedule")
local cron = require("./cron")
local const = require("./const")
local jobs = require("./jobs")
local bins = require("./bins")
local runner = require("./runner")
local platform = require("./platform")
local cond_eval = require("./cond_eval")
local R = require("./mgr_run")

local S = {}

type State = C.State
type Sheet = C.Sheet

-- Setup checks that inform but never mean the scheduler is broken (UX §6.2).
local INFO_ROWS: { [string]: boolean } = { roles = true, keepalive = true, notifications = true }

local FALLBACK_ROLES = { "default", "smol", "task", "plan", "slow" }

type Preset = { id: string, label: string, phrase: string? }

local PRESETS: { Preset } = {
	{ id = "hourly", label = "Hourly", phrase = "hourly" },
	{ id = "daily", label = "Daily", phrase = "daily 09:00" },
	{ id = "weekdays", label = "Weekdays", phrase = "weekdays 09:00" },
	{ id = "weekly", label = "Weekly", phrase = "mon 09:00" },
	{ id = "monthly", label = "Monthly", phrase = "monthly on the 1st 9am" },
	{ id = "once", label = "Once", phrase = "tomorrow 09:00" },
	{ id = "every", label = "Every N minutes/hours…", phrase = "every 2h" },
	{ id = "manual", label = "Manual only", phrase = "manual" },
}

local HELP_KEYS: { { string } } = {
	{ "j k ↑ ↓", "Move the selection (g / G first / last)" },
	{ "enter", "Open the job (a run that needs you: open its terminal)" },
	{ "n", "New job" },
	{ "e", "Edit the job" },
	{ "r", "Run now" },
	{ "i", "Check a job's conditions now" },
	{ "space", "Pause or resume the job" },
	{ "d d", "Delete the job (any other key cancels)" },
	{ "u", "Undo the last delete (10 s)" },
	{ "c", "Duplicate the job" },
	{ "h", "History" },
	{ "o", "Open the job's run terminal" },
	{ "x", "Stop the running run" },
	{ "p", "Edit the prompt file" },
	{ "a", "Jump to a run that needs you" },
	{ "⇧P", "Pause all / resume all (shift+p)" },
	{ ",", "Settings" },
	{ "esc", "Back" },
}

-- Picker helpers ----------------------------------------------------------------------------------------

local function filtered(list: { string }, query: string): { string }
	local q = string.lower(C.trim(query))
	if q == "" then
		return list
	end
	local out: { string } = {}
	for _, name in list do
		if string.find(string.lower(name), q, 1, true) ~= nil then
			table.insert(out, name)
		end
	end
	return out
end

local function role_list(state: State): ({ string }, string?)
	local form = state.form
	if form ~= nil and form.roles ~= nil and #form.roles > 0 then
		return form.roles, nil
	end
	if form ~= nil and form.roles_err ~= nil then
		return FALLBACK_ROLES, "Couldn't read your omp roles. Showing the usual ones."
	end
	if form ~= nil and form.roles_for ~= nil and form.roles == nil then
		return FALLBACK_ROLES, "Reading your omp roles…"
	end
	return FALLBACK_ROLES, nil
end

local function preset_detail(phrase: string?): string
	if phrase == nil then
		return ""
	end
	local now = C.now()
	local rec = schedule.parse(phrase, now)
	if rec == nil then
		return ""
	elseif rec.kind == "manual" then
		return "runs when you press r"
	elseif rec.kind == "once" then
		return "next " .. C.abs(rec.run_at or now)
	elseif rec.kind == "interval" then
		return string.format("every %s", C.span_text(rec.secs or 0))
	end
	local spec = cron.parse(rec.expr)
	local t = if spec ~= nil then cron.next(spec, now, 3000) else nil
	return if t ~= nil then "next " .. C.abs(t) else ""
end

-- The branch picker's entries (the folder's current branch first), filtered by the query, and a status note.
local function branch_entries(state: State, query: string): ({ { id: string, label: string } }, string?)
	local form = state.form
	local q = string.lower(C.trim(query))
	local out: { { id: string, label: string } } = {}
	local function add(id: string, label: string)
		if q == "" or string.find(string.lower(label), q, 1, true) ~= nil then
			table.insert(out, { id = id, label = label })
		end
	end
	local note: string? = nil
	add(F.CURRENT_BRANCH, "This folder's current branch")
	if form ~= nil then
		if form.c_branch ~= "" and (form.branches == nil or table.find(form.branches, form.c_branch) == nil) then
			add(form.c_branch, form.c_branch)
		end
		for _, b in form.branches or {} do
			add(b, b)
		end
		if form.branches_err ~= nil then
			note = form.branches_err
		elseif form.branches == nil and form.branches_for ~= nil then
			note = "Reading branches…"
		end
	end
	return out, note
end

-- The From / Until picker's times, filtered by the query.
local function time_entries(state: State, sheet: Sheet): { { id: string, label: string } }
	local form = state.form
	if form == nil then
		return {}
	end
	local q = string.lower(C.trim((sheet.query or textfield.new()).text))
	local out: { { id: string, label: string } } = {}
	for _, e in F.time_entries(form, sheet.row or "c_from") do
		if q == "" or string.find(string.lower(e.label), q, 1, true) ~= nil then
			table.insert(out, e)
		end
	end
	return out
end

local function picker_node(state: State, sheet: Sheet): Node
	local query = (sheet.query or textfield.new()).text
	local items: { any } = {}
	local order: { any } = {}
	local current: { string } = {}
	local message: string? = nil
	if sheet.kind == "roles" then
		local list, note = role_list(state)
		message = note
		for _, name in filtered(list, query) do
			table.insert(items, { id = name, label = "@" .. name, icon = "sparkle" })
			table.insert(order, name)
		end
		local form = state.form
		if form ~= nil then
			current = { if sheet.row == "c_ask_role" then form.c_ask_role else form.role }
		end
	elseif sheet.kind == "branches" then
		local entries, note = branch_entries(state, query)
		message = note
		for _, e in entries do
			table.insert(items, { id = e.id, label = e.label, icon = "tag" })
			table.insert(order, e.id)
		end
		local form = state.form
		if form ~= nil then
			current = { if form.c_branch == "" then F.CURRENT_BRANCH else form.c_branch }
		end
	elseif sheet.kind == "time" then
		for _, e in time_entries(state, sheet) do
			table.insert(items, { id = e.id, label = e.label, icon = "clock" })
			table.insert(order, e.id)
		end
		local form = state.form
		if form ~= nil then
			current = { tostring(if sheet.row == "c_to" then form.c_to else form.c_from) }
		end
	else
		for _, p in PRESETS do
			if query == "" or string.find(string.lower(p.label), string.lower(C.trim(query)), 1, true) ~= nil then
				table.insert(items, {
					id = p.id,
					label = p.label,
					detail = preset_detail(p.phrase),
					icon = "clock",
				})
				table.insert(order, p.id)
			end
		end
	end
	local props: { [string]: any } = {
		key = "picker",
		size = "md",
		title = if sheet.kind == "roles" then (if sheet.row == "c_ask_role" then "Model" else "Role") elseif sheet.kind == "branches" then "Branch" elseif sheet.kind == "time" then (if sheet.row == "c_to" then "Until" else "From") else "When",
		subtitle = if sheet.kind == "roles"
			then message
			elseif sheet.kind == "branches" then (message or "Runs start only when this branch has new commits.")
			elseif sheet.kind == "time" then "Times are your " .. platform.machine() .. "'s local time."
			else "Pick a starting point, then adjust the time.",
		noun = if sheet.kind == "roles" then "roles" elseif sheet.kind == "branches" then "branches" elseif sheet.kind == "time" then "times" else "presets",
		placeholder = if sheet.kind == "roles" then "Search roles…" elseif sheet.kind == "branches" then "Search branches…" elseif sheet.kind == "time" then "Search times…" else "Search presets…",
		query = query,
		cursor = textfield.utf16(sheet.query or textfield.new()),
		items = C.arr(items),
		order = C.arr(order),
		selected = sheet.sel,
		current = C.arr(current),
		actions = C.arr({ { id = "close", label = "Cancel", keys = { "esc" } } }),
	}
	return ui.node("picker", props, {})
end

local function picker_ids(state: State, sheet: Sheet): { string }
	local query = (sheet.query or textfield.new()).text
	local out: { string } = {}
	if sheet.kind == "roles" then
		local list = role_list(state)
		for _, name in filtered(list, query) do
			table.insert(out, name)
		end
	elseif sheet.kind == "time" then
		for _, e in time_entries(state, sheet) do
			table.insert(out, e.id)
		end
	elseif sheet.kind == "branches" then
		for _, e in branch_entries(state, query) do
			table.insert(out, e.id)
		end
	else
		for _, p in PRESETS do
			if query == "" or string.find(string.lower(p.label), string.lower(C.trim(query)), 1, true) ~= nil then
				table.insert(out, p.id)
			end
		end
	end
	return out
end

local function choose(state: State, sheet: Sheet, id: string)
	if sheet.kind == "roles" then
		if sheet.row == "c_ask_role" then
			F.set_ask_role(state, id)
		else
			F.set_role(state, id)
		end
	elseif sheet.kind == "branches" then
		F.set_branch(state, if id == F.CURRENT_BRANCH then "" else id)
	elseif sheet.kind == "time" then
		F.set_time(state, sheet.row or "c_from", tonumber(id) or 0)
	else
		for _, p in PRESETS do
			if p.id == id and p.phrase ~= nil then
				F.set_when(state, p.phrase)
			end
		end
	end
	state.sheet = nil
end

local function key_picker(state: State, sheet: Sheet, k: Key): boolean?
	local name = k.name
	local ids_ = picker_ids(state, sheet)
	if name == "escape" then
		state.sheet = nil
		return true
	elseif name == "up" or name == "down" then
		local at = table.find(ids_, sheet.sel :: any) or 0
		local j = math.clamp(at + (if name == "up" then -1 else 1), 1, math.max(#ids_, 1))
		if ids_[j] == nil or ids_[j] == sheet.sel then
			return false
		end
		sheet.sel = ids_[j]
		return true
	elseif name == "enter" then
		local id = sheet.sel
		if id == nil or table.find(ids_, id) == nil then
			id = ids_[1]
		end
		if id ~= nil then
			choose(state, sheet, id)
		end
		return true
	end
	local q = sheet.query or textfield.new()
	sheet.query = q
	if textfield.key(q, k, false) then
		local list = picker_ids(state, sheet)
		sheet.sel = list[1]
		return true
	end
	return false
end

-- Small dialogs ------------------------------------------------------------------------------------------

local function dialog(head: string, size: string, body: { Node }): Node
	return ui.node("overlay", { key = "dialog", head = head, size = size, modal = true }, body)
end

local function job_name(job_id: string?): string
	local job: any = if job_id ~= nil then jobs.get(job_id) else nil
	return if job ~= nil then job.name else "this job"
end

local function run_name(run_id: string?): string
	for _, r in runner.inflight() do
		local run: any = r
		if run.run_id == run_id then
			return run.job_name or "this run"
		end
	end
	return "this run"
end

local function confirm_stop_node(state: State, sheet: Sheet): Node
	return dialog("Stop " .. run_name(sheet.run_id) .. "?", "sm", {
		C.text({ ui.span("This closes the run's terminal. Its record stays, and Open run can resume the session.", "muted") }, "body"),
		C.with(ui.row({
			C.badge("Stop run  y", "error", "stop_yes", "yes"),
			C.badge("Keep  esc", "neutral", "stop_no", "no"),
		}), { key = "acts" }),
	})
end

local function first_run_node(_state: State, _sheet: Sheet): Node
	return dialog("Run it now and watch?", "md", {
		C.text({
			ui.span(
				"The first run shows you any permission prompts, so later runs go smoothly. It opens the run's terminal (an omp session) and takes you there; if it stops to ask, answer in that terminal.",
				"muted"
			),
		}, "body"),
		C.with(ui.row({
			C.badge("Run now  ⏎", "accent", "first_yes", "yes"),
			C.badge("Not now  esc", "neutral", "first_no", "no"),
		}), { key = "acts" }),
	})
end

local function run_anyway_node(_state: State, sheet: Sheet): Node
	return dialog("Run anyway?", "md", {
		C.text({ ui.span("Not running: " .. tostring(sheet.text or "a condition said no") .. ".") }, "body"),
		C.text({ ui.span("Run anyway runs it once now without checking its conditions.", "muted") }, "note"),
		C.with(ui.row({
			C.badge("Run anyway  ⏎", "accent", "anyway_yes", "yes"),
			C.badge("Cancel  esc", "neutral", "anyway_no", "no"),
		}), { key = "acts" }),
	})
end

local RESULT_GLYPH: { [string]: { string } } = {
	pass = { "✓", "success" },
	fail = { "✗", "error" },
	error = { "⚠", "warning" },
	skip = { "·", "muted" },
}

local function conditions_job(sheet: Sheet): any
	return if sheet.job_id ~= nil then jobs.get(sheet.job_id) else nil
end

local function conditions_node(_state: State, sheet: Sheet): Node
	local job: any = conditions_job(sheet)
	local name = if job ~= nil then job.name else "this job"
	local body: { Node } = {}
	local v: any = sheet.verdict
	if sheet.checking == true or v == nil then
		table.insert(body, C.text({ ui.span("Checking…", "muted") }, "wait"))
	else
		for i, r in v.results do
			local g = RESULT_GLYPH[r.result] or RESULT_GLYPH.skip
			table.insert(body, C.text({ ui.span(g[1] .. " ", g[2]), ui.span(tostring(r.label), "strong"), ui.span(" — " .. tostring(r.text), "muted") }, "res" .. i))
			if type(r.context) == "string" and r.context ~= "" then
				local n = 0
				for line in string.gmatch(r.context, "[^\r\n]+") do
					n += 1
					if n > 6 then
						break
					end
					table.insert(body, C.text({ ui.span("    " .. line, "muted") }, string.format("ctx%d_%d", i, n)))
				end
			end
		end
		table.insert(body, C.text({ ui.span(if v.ok == true then "A run would start now." else "A run would not start now.", "strong") }, "summary"))
	end
	local seen: { string } = if job ~= nil then cond_eval.seen_lines(job) else {}
	for i, line in seen do
		table.insert(body, C.text({ ui.span(line, "muted") }, "seen" .. i))
	end
	local acts: { Node } = {}
	if sheet.job_id ~= nil and #seen > 0 then
		table.insert(acts, C.badge("Forget what it has seen  f", "neutral", "cond_forget", "forget"))
	end
	table.insert(acts, C.badge("Close  esc", "neutral", "cond_close", "close"))
	table.insert(body, C.with(ui.row(acts), { key = "acts" }))
	return dialog("Conditions · " .. name, "md", body)
end

local function help_node(_state: State, _sheet: Sheet): Node
	local rows: { { Spans } } = {}
	for _, r in HELP_KEYS do
		table.insert(rows, { { ui.span(r[1], "key") }, { ui.span(r[2]) } })
	end
	return dialog("Keys", "md", {
		ui.kv(rows),
		C.text({ ui.span("Most actions also have a button under the list. esc closes this.", "muted") }, "foot"),
	})
end

-- Setup ----------------------------------------------------------------------------------------------------

local function setup_rows(): { any }
	local ok, health = pcall(runner.health)
	if not ok or type(health) ~= "table" then
		return {}
	end
	local rows: any = (health :: any).setup
	return if type(rows) == "table" then rows else {}
end

local function heartbeat_text(): string
	local ok, health = pcall(runner.health)
	if ok and type(health) == "table" then
		local hb: any = (health :: any).hb
		if type(hb) == "number" and hb > 0 then
			return "Last scheduler tick " .. C.span_text(C.now() - hb) .. " ago."
		end
	end
	return "The scheduler hasn't ticked yet."
end

local function setup_node(_state: State, sheet: Sheet): Node
	local body: { Node } = {}
	for i, row in setup_rows() do
		local glyph, tone
		if row.ok == true then
			glyph, tone = "✓ ", "muted"
		elseif row.ok == false and INFO_ROWS[row.id] then
			glyph, tone = "! ", "warning"
		elseif row.ok == false then
			glyph, tone = "✗ ", "error"
		else
			glyph, tone = "· ", "muted"
		end
		table.insert(body, C.text({ ui.span(glyph, tone), ui.span(tostring(row.label), "strong"), ui.span("  " .. tostring(row.text), "muted") }, "row" .. i))
	end
	if #body == 0 then
		table.insert(body, C.text({ ui.span("No results yet. Press c to check.", "muted") }, "none"))
	end
	table.insert(body, C.text({ ui.span(heartbeat_text(), "muted") }, "hb"))
	table.insert(body, C.text({ ui.span(C.AVAILABILITY, "muted") }, "avail"))
	table.insert(body, C.text({ ui.span(C.NO_WINDOW, "muted") }, "nowin"))
	table.insert(body, C.text({ ui.span(C.WINDOWS, "muted") }, "wins"))
	table.insert(
		body,
		C.with(ui.row({
			C.badge(if sheet.checking == true then "Checking…" else "Check again  c", "accent", "setup_check", "check"),
			C.badge("Open data folder", "neutral", "open_data", "data"),
			C.badge("Close  esc", "neutral", "close_sheet", "close"),
		}), { key = "acts" })
	)
	return ui.node("overlay", { key = "dialog", head = "Check setup", size = "md", modal = true }, body)
end

local function run_setup_check(state: State, sheet: Sheet)
	if sheet.checking == true then
		return
	end
	sheet.checking = true
	local started = pcall(function()
		runner.check_setup(function()
			sheet.checking = false
			C.render(state)
		end)
	end)
	if not started then
		sheet.checking = false
	end
end

local function open_data_folder()
	local argv = platform.open_argv(tern.plugin.data)
	if argv == nil then
		return
	end
	pcall(function()
		tern.process.run(argv :: { string }, { timeout_ms = 5000 }, function() end)
	end)
end

function S.open_data_folder()
	open_data_folder()
end

-- Settings ---------------------------------------------------------------------------------------------------

local function settings_sections(state: State, sheet: Sheet): { P.Section }
	local s = jobs.settings()
	local d: any = s.defaults
	local def: { [string]: any } = if type(d) == "table" then d else {}
	local placement: any = def.placement
	local where = if type(placement) == "table" and placement.where == "tab" then "tab" else "session"
	local warn = sheet.warnings or {}
	local window_s = if type(s.catchup_window_s) == "number" then s.catchup_window_s else const.CATCHUP_DEFAULT_S
	local panes = if type(s.max_finished_panes) == "number" then s.max_finished_panes else const.MAX_FINISHED_PANES
	local session_name = if type(s.session_name) == "string" then s.session_name else const.SESSION_NAME_DEFAULT
	if sheet.page == "setup" then
		return {
			{
				id = "setup",
				title = "Setup",
				rows = {
					{
						id = "check",
						label = "Check setup",
						hint = heartbeat_text(),
						control = { k = "action", act = "check", label = "Check…" },
					},
					{
						id = "avail",
						label = "Availability",
						hint = C.AVAILABILITY,
						control = { k = "action", act = "details", label = "Details" },
					},
					{
						id = "omp_path",
						label = "omp path",
						hint = "Where Agent Scheduler finds omp. Leave it empty to find omp automatically.",
						warning = warn.omp_path,
						control = { k = "text", value = if type(s.omp_path) == "string" then s.omp_path else "", placeholder = "Automatic", mono = true },
					},
					{
						id = "data",
						label = "Data folder",
						hint = tern.plugin.data,
						control = { k = "action", act = "open_data", label = "Open data folder" },
					},
				},
			},
		}
	end
	return {
		{
			id = "runs",
			title = "Runs",
			rows = {
				{
					id = "placement",
					label = "Where runs appear",
					hint = C.WINDOWS,
					warning = warn.placement,
					control = {
						k = "choice",
						value = where,
						style = "menu",
						options = {
							{ value = "session", label = "Scheduled runs session, background tab" },
							{ value = "tab", label = "Background tab in the current session" },
						},
					},
				},
				{
					id = "focus",
					label = "Bring to front when it starts",
					hint = "Off: the run starts quietly and you stay where you are.",
					warning = warn.focus,
					control = { k = "switch", on = def.focus == "front" },
				},
				{
					id = "session_name",
					label = "Run session name",
					hint = "The session scheduled runs open in.",
					warning = warn.session_name,
					control = { k = "text", value = session_name },
				},
				{
					id = "max_finished_panes",
					label = "Finished run panes to keep",
					hint = string.format(
						"Each finished run keeps an omp process open, roughly 100–500 MB. Tern closes the oldest beyond %d; Open run reopens any of them.",
						panes
					),
					warning = warn.max_finished_panes,
					control = { k = "number", value = panes, min = const.MAX_FINISHED_PANES_MIN, max = const.MAX_FINISHED_PANES_MAX },
				},
				{
					id = "max_concurrent",
					label = "Jobs running at once",
					hint = "A run over the limit waits, then is skipped with a reason.",
					warning = warn.max_concurrent,
					control = { k = "number", value = tonumber(s.max_concurrent) or const.MAX_CONCURRENT_DEFAULT, min = 1, max = 10 },
				},
				{
					id = "catchup_window_s",
					label = "Late limit for missed runs",
					hint = "If your " .. platform.machine() .. " was asleep: a run later than this is recorded as missed.",
					warning = warn.catchup_window_s,
					control = { k = "number", value = math.max(1, window_s // 3600), min = 1, max = 168, unit = "h" },
				},
			},
		},
	}
end

local function settings_pages(): { any }
	return C.arr({
		{ id = "runs", label = "Runs", icon = "timer" },
		{ id = "setup", label = "Setup", icon = "shield-alert" },
	})
end

local function settings_node(state: State, sheet: Sheet): Node
	sheet.page = sheet.page or "runs"
	local sections = settings_sections(state, sheet)
	local editing: any = nil
	local e = sheet.editing
	if e ~= nil then
		local f = sheet.field
		if f ~= nil then
			editing = { row = e.row, draft = f.text, cursor = textfield.utf16(f) }
		else
			editing = { row = e.row, option = e.option }
		end
	end
	return ui.node("prefs", {
		key = "prefs",
		title = "Settings",
		pages = settings_pages(),
		page = sheet.page,
		lead = if sheet.page == "setup" then "Is Agent Scheduler able to run jobs?" else "How scheduled runs start and what Tern keeps.",
		sections = P.node_sections(sections),
		focus = sheet.focus,
		editing = editing,
	}, {})
end

-- Applies the settings row `id` with `value`; a problem is shown on the row.
local function apply_setting(state: State, sheet: Sheet, id: string, value: any)
	local patch: { [string]: any }
	if id == "placement" then
		patch = { defaults = { placement = { where = value } } }
	elseif id == "focus" then
		patch = { defaults = { focus = if value == true then "front" else "keep" } }
	elseif id == "catchup_window_s" then
		patch = { catchup_window_s = math.floor(tonumber(value) or 3) * 3600 }
	elseif id == "session_name" then
		patch = { session_name = C.trim(tostring(value)) }
	elseif id == "omp_path" then
		patch = { omp_path = C.trim(tostring(value)) }
	else
		patch = { [id] = math.floor(tonumber(value) or 0) }
	end
	local ok, err = jobs.set_settings(patch)
	local warnings = sheet.warnings or {}
	sheet.warnings = warnings
	if ok then
		warnings[id] = nil
		runner.changed()
		if id == "omp_path" then
			bins.invalidate()
			run_setup_check(state, sheet)
		end
	else
		warnings[id] = err or "That value isn't allowed."
	end
end

local function settings_row(state: State, sheet: Sheet, id: string?): P.Row?
	return P.find(settings_sections(state, sheet), id)
end

local function settings_act(state: State, sheet: Sheet, act: string)
	if act == "check" or act == "details" then
		state.sheet = { kind = "setup" }
		run_setup_check(state, state.sheet)
	elseif act == "open_data" then
		open_data_folder()
	end
end

local function settings_activate(state: State, sheet: Sheet, row: P.Row): boolean
	sheet.focus = row.id
	local c = row.control
	if c.k == "switch" then
		apply_setting(state, sheet, row.id, not c.on)
	elseif c.k == "choice" then
		sheet.editing = { row = row.id, initial = tostring(c.value), option = c.value }
		sheet.field = nil
	elseif c.k == "text" then
		sheet.editing = { row = row.id, initial = tostring(c.value or "") }
		sheet.field = textfield.new(tostring(c.value or ""))
	elseif c.k == "action" then
		settings_act(state, sheet, c.act)
	else
		return false
	end
	return true
end

local function close_editing(sheet: Sheet)
	sheet.editing = nil
	sheet.field = nil
end

local function key_settings(state: State, sheet: Sheet, k: Key): boolean?
	sheet.page = sheet.page or "runs"
	local name = k.name
	local e = sheet.editing
	if e ~= nil then
		local row = settings_row(state, sheet, e.row)
		if sheet.field ~= nil then
			if name == "enter" then
				if sheet.field.text ~= e.initial then
					apply_setting(state, sheet, e.row, sheet.field.text)
				end
				close_editing(sheet)
				return true
			elseif name == "escape" then
				close_editing(sheet)
				return true
			end
			return textfield.key(sheet.field, k, false)
		end
		if row == nil then
			close_editing(sheet)
			return true
		end
		local values = P.option_values(row.control)
		if name == "up" or name == "down" then
			local at = table.find(values, e.option :: any) or 0
			local j = math.clamp(at + (if name == "up" then -1 else 1), 1, math.max(#values, 1))
			if values[j] == nil or values[j] == e.option then
				return false
			end
			e.option = values[j]
			return true
		elseif name == "enter" or name == "space" then
			local v = e.option
			close_editing(sheet)
			if v ~= nil and v ~= row.control.value then
				apply_setting(state, sheet, row.id, v)
			end
			return true
		elseif name == "escape" then
			close_editing(sheet)
			return true
		end
		return false
	end

	if name == "escape" then
		state.sheet = nil
		return true
	elseif name == "up" or name == "down" then
		local target = P.move(settings_sections(state, sheet), sheet.focus, if name == "up" then -1 else 1)
		if target == nil then
			return false
		end
		sheet.focus = target
		return true
	elseif name == "tab" then
		sheet.page = if sheet.page == "runs" then "setup" else "runs"
		sheet.focus = nil
		return true
	end
	local row = settings_row(state, sheet, sheet.focus)
	if row == nil then
		return false
	end
	if name == "left" or name == "right" then
		local c = row.control
		local dir = if name == "left" then -1 else 1
		if c.k == "choice" then
			local values = P.option_values(c)
			local at = table.find(values, c.value) or 0
			local j = math.clamp(at + dir, 1, math.max(#values, 1))
			if values[j] == nil or values[j] == c.value then
				return false
			end
			apply_setting(state, sheet, row.id, values[j])
			return true
		elseif c.k == "number" then
			local n = P.step_number(c, dir)
			if n == nil then
				return false
			end
			apply_setting(state, sheet, row.id, n)
			return true
		end
		return false
	elseif name == "enter" or name == "space" then
		return settings_activate(state, sheet, row)
	end
	return false
end

local function event_settings(state: State, sheet: Sheet, ev: UiEvent)
	local kind = ev.ev
	local item = ev.item
	if kind == "action" then
		if ev.act == "page" and type(ev.value) == "string" then
			sheet.page = ev.value
			sheet.focus = nil
			close_editing(sheet)
		elseif ev.act == "close" then
			if ev.value == nil or ev.value == tern.json.null then
				state.sheet = nil
			else
				close_editing(sheet)
			end
		elseif type(ev.act) == "string" then
			settings_act(state, sheet, ev.act)
		end
	elseif kind == "change" and type(item) == "string" then
		local row = settings_row(state, sheet, item)
		if row ~= nil and ev.value ~= nil and ev.value ~= tern.json.null then
			apply_setting(state, sheet, item, ev.value)
			sheet.focus = item
		end
		close_editing(sheet)
	elseif kind == "activate" and type(item) == "string" then
		local row = settings_row(state, sheet, item)
		if row ~= nil then
			settings_activate(state, sheet, row)
		end
	elseif kind == "select" and type(item) == "string" and string.find(item, "=", 1, true) == nil then
		sheet.focus = item
	end
end

-- Entry points -----------------------------------------------------------------------------------------------

function S.open_settings(state: State)
	state.sheet = { kind = "settings", page = "runs", warnings = {} }
end

function S.open_setup(state: State)
	state.sheet = { kind = "setup" }
	run_setup_check(state, state.sheet)
end

function S.open_help(state: State)
	state.sheet = { kind = "help" }
end

function S.confirm_stop(state: State, run_id: string)
	state.sheet = { kind = "confirm_stop", run_id = run_id }
end

-- Opens the Conditions sheet for a saved job and runs a dry check.
function S.check_conditions(state: State, job_id: string)
	local sheet: Sheet = { kind = "conditions", job_id = job_id, checking = true }
	state.sheet = sheet
	runner.check_conditions(job_id, function(v: any)
		if state.sheet ~= sheet then
			return
		end
		sheet.verdict = v
		sheet.checking = false
		C.render(state)
	end)
end

-- The layer content for the open sheet, or nil.
function S.layer(state: State): Node?
	local sheet = state.sheet
	if sheet == nil then
		return nil
	end
	local kind = sheet.kind
	if kind == "roles" or kind == "presets" or kind == "branches" or kind == "time" then
		return picker_node(state, sheet)
	elseif kind == "confirm_stop" then
		return confirm_stop_node(state, sheet)
	elseif kind == "first_run" then
		return first_run_node(state, sheet)
	elseif kind == "run_anyway" then
		return run_anyway_node(state, sheet)
	elseif kind == "conditions" then
		return conditions_node(state, sheet)
	elseif kind == "help" then
		return help_node(state, sheet)
	elseif kind == "setup" then
		return setup_node(state, sheet)
	elseif kind == "settings" then
		return settings_node(state, sheet)
	end
	return nil
end

local function do_stop(state: State, sheet: Sheet)
	local run_id = sheet.run_id
	local name = run_name(run_id)
	state.sheet = nil
	if run_id ~= nil and runner.stop(run_id) then
		C.toast(state, "success", "Stopped " .. name)
	else
		C.toast(state, "error", "Couldn't stop " .. name, "It may have just finished.")
	end
	runner.changed()
end

local function do_first_run(state: State, sheet: Sheet)
	local job_id = sheet.job_id
	state.sheet = nil
	if job_id ~= nil then
		R.run_now(state, job_id, { override = "front", toast = false })
	end
end

local function do_run_anyway(state: State, sheet: Sheet)
	local job_id = sheet.job_id
	state.sheet = nil
	if job_id == nil then
		return
	end
	local ok, err = runner.run_now(job_id, { focus_override = sheet.override, bypass = sheet.code or "cond" })
	if ok then
		C.toast(state, "info", job_name(job_id) .. " started", "Ran without checking its conditions.")
	else
		C.notice(state, err or "Couldn't start the run.")
	end
end

local function do_forget(state: State, sheet: Sheet)
	local id = sheet.job_id
	if id == nil then
		return
	end
	runner.forget_conditions(id)
	state.sheet = nil
	C.toast(state, "success", "Forgot what " .. job_name(id) .. " has seen", "The next run notes where things are and waits for something new.")
end

-- Keys while a sheet is open. `true` / `nil` re-render; `false` means nothing changed.
function S.key(state: State, k: Key): boolean?
	local sheet = state.sheet :: Sheet
	local kind = sheet.kind
	local name = k.name
	if kind == "roles" or kind == "presets" or kind == "branches" or kind == "time" then
		return key_picker(state, sheet, k)
	elseif kind == "settings" then
		return key_settings(state, sheet, k)
	elseif kind == "confirm_stop" then
		if name == "y" or name == "enter" then
			do_stop(state, sheet)
			return true
		elseif name == "escape" or name == "n" then
			state.sheet = nil
			return true
		end
		return false
	elseif kind == "first_run" then
		if name == "y" or name == "enter" then
			do_first_run(state, sheet)
			return true
		elseif name == "escape" or name == "n" then
			state.sheet = nil
			return true
		end
		return false
	elseif kind == "run_anyway" then
		if name == "y" or name == "enter" then
			do_run_anyway(state, sheet)
			return true
		elseif name == "escape" or name == "n" then
			state.sheet = nil
			return true
		end
		return false
	elseif kind == "conditions" then
		if name == "escape" or name == "enter" or name == "q" then
			state.sheet = nil
			return true
		elseif name == "f" and sheet.job_id ~= nil then
			do_forget(state, sheet)
			return true
		end
		return false
	elseif kind == "setup" then
		if name == "escape" then
			state.sheet = nil
			return true
		elseif name == "c" or name == "enter" then
			run_setup_check(state, sheet)
			return true
		end
		return false
	elseif kind == "help" then
		if name == "escape" or name == "?" or name == "q" or name == "enter" then
			state.sheet = nil
			return true
		end
		return false
	end
	return false
end

-- Mouse events while a sheet is open.
function S.event(state: State, ev: UiEvent)
	local sheet = state.sheet
	if sheet == nil then
		return
	end
	local kind = sheet.kind
	if kind == "settings" then
		event_settings(state, sheet, ev)
		return
	end
	local act = ev.act
	if kind == "roles" or kind == "presets" or kind == "branches" or kind == "time" then
		if ev.ev == "select" and type(ev.item) == "string" then
			sheet.sel = ev.item
		elseif ev.ev == "activate" and type(ev.item) == "string" then
			choose(state, sheet, ev.item)
		elseif ev.ev == "action" and (act == "close" or act == "cancel") then
			state.sheet = nil
		end
	elseif ev.ev == "action" then
		if act == "stop_yes" then
			do_stop(state, sheet)
		elseif act == "first_yes" then
			do_first_run(state, sheet)
		elseif act == "anyway_yes" then
			do_run_anyway(state, sheet)
		elseif act == "cond_forget" then
			do_forget(state, sheet)
		elseif act == "stop_no" or act == "first_no" or act == "anyway_no" or act == "cond_close" or act == "close_sheet" then
			state.sheet = nil
		elseif act == "setup_check" then
			run_setup_check(state, sheet)
		elseif act == "open_data" then
			open_data_folder()
		end
	end
end

return S
