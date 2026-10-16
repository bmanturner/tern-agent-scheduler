--!strict
-- Manager layer: role and presets pickers, stop confirm, "Run it now and watch?", key help and the Settings sheet
-- (one page: setup status, display, where runs start, limits). State lives in `state.sheet`; the manager routes
-- keys and events here while a sheet is open.

local ui = tern.ui
local C = require("./mgr_common")
local P = require("./mgr_prefs")
local F = require("./mgr_form")
local textfield = require("./textfield")
local timefmt = require("./timefmt")
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
	{ "enter", "Open the job; wide panes focus its runs (esc returns to jobs). Needs you: open its terminal" },
	{ "n", "New job" },
	{ "e", "Edit the job" },
	{ "r", "Run now" },
	{ "i", "Check a job's conditions now" },
	{ "space", "Pause or resume the job" },
	{ "dd", "Delete the job (any other key cancels)" },
	{ "u", "Undo the last delete (10 s)" },
	{ "s", "Mark all results seen" },
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
		C.text({ ui.span("When jobs run", "strong") }, "when_head"),
		C.text({ ui.span(C.AVAILABILITY) }, "when_avail"),
		C.text({ ui.span(C.NO_WINDOW) }, "when_window"),
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
			return "Scheduler heartbeat " .. C.span_text(C.now() - hb) .. " ago."
		end
	end
	return "The scheduler hasn't started yet."
end

local function run_setup_check(state: State, sheet: Sheet)
	if sheet.checking == true then
		return
	end
	sheet.checking = true
	local started = pcall(function()
		runner.check_setup(function()
			sheet.checking = false
			sheet.checked_at = C.now()
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

-- What each settings row resets to. `catchup_window_s` is in hours, as the row shows it; `focus` is the switch.
local DEFAULTS: { [string]: any } = {
	time_format = "automatic",
	manager_layout = "timeline",
	manager_results = "fade",
	placement = "session",
	focus = false,
	session_name = const.SESSION_NAME_DEFAULT,
	omp_path = "",
	max_concurrent = const.MAX_CONCURRENT_DEFAULT,
	max_finished_panes = const.MAX_FINISHED_PANES,
	catchup_window_s = const.CATCHUP_DEFAULT_S // 3600,
}

local CATCHUP_LABELS: { [string]: string } = {
	["1"] = "1 h",
	["2"] = "2 h",
	["3"] = "3 h",
	["6"] = "6 h",
	["12"] = "12 h",
	["24"] = "1 day",
	["48"] = "2 days",
	["72"] = "3 days",
	["168"] = "1 week",
}

-- Marks `row` with whether its value differs from the default, and how that default reads.
local function with_default(row: P.Row, value: any, default_label: string): P.Row
	row.changed = value ~= DEFAULTS[row.id]
	row.defaultLabel = default_label
	return row
end

local function short_path(p: string): string
	local rest = p:match("^~/(.*)$")
	if rest == nil then
		return p
	end
	local segs = string.split(rest, "/")
	if #segs <= 2 then
		return p
	end
	return "~/" .. segs[1] .. "/…/" .. segs[#segs]
end

-- The typed range of each number row; the draft is checked against it before it is saved. `catchup_window_s` is hours.
local NUMBER_LIMITS: { [string]: { number } } = {
	max_concurrent = { 1, 10 },
	max_finished_panes = { const.MAX_FINISHED_PANES_MIN, const.MAX_FINISHED_PANES_MAX },
	catchup_window_s = { 1, 168 },
}

-- A number row's control. While its value is being typed the kit shows the draft in a text field instead.
local function number_control(sheet: Sheet, id: string, value: number, extra: { [string]: any }?): { [string]: any }
	local e = sheet.editing
	if e ~= nil and e.row == id and sheet.field ~= nil then
		return { k = "text", value = tostring(value) }
	end
	local limits = NUMBER_LIMITS[id]
	local c: { [string]: any } = { k = "number", value = value, min = limits[1], max = limits[2] }
	for k, v in extra or {} do
		c[k] = v
	end
	return c
end

-- The next step for a failed setup check whose own text doesn't give one.
local NEXT_STEP: { [string]: string } = {
	data = "Check its permissions: Setup › Data folder › Open.",
}

local function settings_sections(state: State, sheet: Sheet): { P.Section }
	local s = jobs.settings()
	local d: any = s.defaults
	local def: { [string]: any } = if type(d) == "table" then d else {}
	local placement: any = def.placement
	local where = if type(placement) == "table" and placement.where == "tab" then "tab" else "session"
	local warn = sheet.warnings or {}
	local window_s = if type(s.catchup_window_s) == "number" then s.catchup_window_s else const.CATCHUP_DEFAULT_S
	local window_h = math.max(1, window_s // 3600)
	local panes = if type(s.max_finished_panes) == "number" then s.max_finished_panes else const.MAX_FINISHED_PANES
	local session_name = if type(s.session_name) == "string" then s.session_name else const.SESSION_NAME_DEFAULT
	local omp_path = if type(s.omp_path) == "string" then s.omp_path else ""
	local concurrent = tonumber(s.max_concurrent) or const.MAX_CONCURRENT_DEFAULT
	local time_format = s.time_format or "automatic"
	local layout = s.manager_layout or "timeline"
	local results = s.manager_results or "fade"
	local focus_on = def.focus == "front"

	-- Setup checks: a blocking failure means jobs won't run; INFO_ROWS only inform.
	local blocking = false
	local problems: { string } = {}
	local availability = false
	local omp_check: any = nil
	for _, r in setup_rows() do
		if r.id == "omp" then
			omp_check = r
		end
		if r.ok == false then
			local info = INFO_ROWS[r.id] == true
			blocking = blocking or not info
			local line = (if info then "! " else "✗ ") .. tostring(r.label) .. ": " .. tostring(r.text)
			if NEXT_STEP[r.id] ~= nil then
				line ..= " " .. NEXT_STEP[r.id]
			end
			table.insert(problems, line)
			availability = availability or r.id == "heartbeat" or r.id == "keepalive"
		end
	end
	if availability then
		table.insert(problems, C.AVAILABILITY)
	end
	local status_hint = heartbeat_text()
	if sheet.checked_at ~= nil then
		status_hint = "Checked " .. timefmt.date("%H:%M", sheet.checked_at) .. " · " .. status_hint
	end

	local omp_hint = "Agent Scheduler starts each run with omp."
	if omp_check ~= nil and omp_check.ok == true then
		local f = bins.found()
		if f.omp ~= nil and f.omp ~= "" then
			local ver = (f.omp_version or ""):gsub("^omp[/ ]", "")
			local at = C.tilde(f.omp)
			omp_hint ..= if ver ~= "" then " Found " .. ver .. " at " .. at .. "." else " Found at " .. at .. "."
		else
			omp_hint ..= " Found " .. tostring(omp_check.text) .. "."
		end
	end
	omp_hint ..= " Leave empty to find it automatically."
	local omp_warning: string? = warn.omp_path
	if omp_warning == nil and omp_check ~= nil and omp_check.ok == false then
		omp_warning = tostring(omp_check.text)
	end

	local time_hint = if time_format == "12h"
		then "Times show as 2:30 pm."
		elseif time_format == "24h" then "Times show as 14:30."
		else "Follows your system, with a 24-hour fallback."

	return {
		{
			id = "health",
			title = "Status",
			rows = {
				{
					id = "status",
					label = if blocking then "Not ready to run jobs" else "✓ Ready to run jobs",
					hint = status_hint,
					warning = if #problems > 0 then table.concat(problems, "\n") else nil,
					control = { k = "action", act = "check", label = if sheet.checking == true then "Checking…" else "Check again" },
				},
			},
		},
		{
			id = "display",
			title = "Display",
			rows = {
				with_default({
					id = "time_format",
					label = "Time format",
					hint = time_hint,
					control = {
						k = "choice",
						style = "segmented",
						value = time_format,
						options = { { value = "automatic", label = "Automatic" }, { value = "12h", label = "12-hour" }, { value = "24h", label = "24-hour" } },
					},
				}, time_format, "Automatic"),
				with_default({
					id = "manager_layout",
					label = "Layout",
					control = {
						k = "choice",
						style = "segmented",
						value = layout,
						options = { { value = "timeline", label = "Timeline" }, { value = "classic", label = "Classic job list" } },
					},
				}, layout, "Timeline"),
				with_default({
					id = "manager_results",
					label = "New results",
					hint = "Fade after three seconds in the manager, or keep highlights until you mark all seen.",
					control = {
						k = "choice",
						style = "menu",
						value = results,
						options = { { value = "fade", label = "Fade once seen" }, { value = "stay", label = "Stay until marked seen" } },
					},
				}, results, "Fade once seen"),
			},
		},
		{
			id = "runs",
			title = "Where runs start",
			rows = {
				with_default({
					id = "placement",
					label = "Session",
					hint = "Runs open as background tabs, in the first Tern window if several are open.",
					warning = warn.placement,
					control = {
						k = "choice",
						style = "menu",
						value = where,
						options = {
							{ value = "session", label = "Scheduled runs session", detail = "A background tab in a session of its own, named below." },
							{ value = "tab", label = "Current session", detail = "A background tab in the session you're using." },
						},
					},
				}, where, "Scheduled runs session"),
				with_default({
					id = "session_name",
					label = "Session name",
					hint = "The name of the Scheduled runs session.",
					warning = warn.session_name,
					control = { k = "text", value = session_name },
				}, session_name, const.SESSION_NAME_DEFAULT),
				with_default({
					id = "focus",
					label = "Bring to front when it starts",
					hint = if focus_on
						then "On: Tern switches to the run's tab as soon as it starts."
						else "Off: the run starts quietly and you stay where you are.",
					warning = warn.focus,
					control = { k = "switch", on = focus_on },
				}, focus_on, "Off"),
			},
		},
		{
			id = "limits",
			title = "Limits",
			rows = {
				with_default({
					id = "max_concurrent",
					label = "Jobs running at once",
					hint = "A run over the limit waits, then is skipped with a reason.",
					warning = warn.max_concurrent,
					control = number_control(sheet, "max_concurrent", concurrent),
				}, concurrent, tostring(const.MAX_CONCURRENT_DEFAULT)),
				with_default({
					id = "max_finished_panes",
					label = "Finished run tabs to keep",
					hint = "Each finished run keeps an omp process open, roughly 100–500 MB. Tern closes the oldest tabs past this number; Open run reopens any of them.",
					warning = warn.max_finished_panes,
					control = number_control(sheet, "max_finished_panes", panes),
				}, panes, tostring(const.MAX_FINISHED_PANES)),
				with_default({
					id = "catchup_window_s",
					label = "If your " .. platform.machine() .. " was asleep",
					hint = "How late a missed run can be and still start when you're back. Later ones are recorded as missed.",
					warning = warn.catchup_window_s,
					control = number_control(sheet, "catchup_window_s", window_h, { unit = "h", labels = CATCHUP_LABELS }),
				}, window_h, "3 h"),
			},
		},
		{
			id = "setup",
			title = "Setup",
			rows = {
				with_default({
					id = "omp_path",
					label = "omp",
					hint = omp_hint,
					warning = omp_warning,
					control = { k = "text", value = omp_path, placeholder = "Find automatically", mono = true },
				}, omp_path, "Find automatically"),
				{
					id = "data",
					label = "Data folder",
					hint = short_path(C.tilde(tern.plugin.data)),
					control = { k = "action", act = "open_data", label = "Open" },
				},
			},
		},
	}
end

-- The key legend at the bottom of the sheet; it follows what the keys do right now.
local function keys_legend(sheet: Sheet): string
	if sheet.editing == nil then
		return "↑↓ move · ←→ change · ⏎ edit · esc close"
	elseif sheet.field ~= nil then
		return "⏎ save · esc cancel"
	end
	return "↑↓ choose · ⏎ pick · esc cancel"
end

local function settings_node(state: State, sheet: Sheet): Node
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
		role = "tas.settings",
		title = "Agent Scheduler Settings",
		pages = C.arr({ { id = "settings", label = "Agent Scheduler", icon = "timer" } }),
		page = "settings",
		sections = P.node_sections(settings_sections(state, sheet)),
		focus = sheet.focus,
		editing = editing,
	}, {
		C.with(C.text({ ui.span(keys_legend(sheet), "muted") }, "keys"), { key = "keys", role = "tas.settings-keys" }),
	})
end

-- Applies the settings row `id` with `value`; a problem is shown on the row. True when the value was saved.
local function apply_setting(state: State, sheet: Sheet, id: string, value: any): boolean
	local patch: { [string]: any }
	if id == "manager_layout" or id == "manager_results" or id == "time_format" then
		patch = { [id] = value }
	elseif id == "placement" then
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
		return true
	end
	warnings[id] = err or "That value isn't allowed."
	return false
end

local function settings_row(state: State, sheet: Sheet, id: string?): P.Row?
	return P.find(settings_sections(state, sheet), id)
end

local function settings_act(state: State, sheet: Sheet, act: string)
	if act == "check" then
		run_setup_check(state, sheet)
	elseif act == "open_data" then
		open_data_folder()
	end
end

local function settings_activate(state: State, sheet: Sheet, row: P.Row): boolean
	sheet.focus = row.id
	local c = row.control
	if c.k == "switch" then
		apply_setting(state, sheet, row.id, not c.on)
	elseif c.k == "choice" and c.style == "segmented" then
		-- Enter steps to the next option, wrapping.
		local values = P.option_values(c)
		local to = values[((table.find(values, c.value) or 0) % #values) + 1]
		if to ~= nil then
			apply_setting(state, sheet, row.id, to)
		end
	elseif c.k == "choice" then
		sheet.editing = { row = row.id, initial = tostring(c.value), option = c.value }
		sheet.field = nil
	elseif c.k == "text" or c.k == "number" then
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
	local name = k.name
	local e = sheet.editing
	if e ~= nil then
		local row = settings_row(state, sheet, e.row)
		if sheet.field ~= nil then
			if name == "enter" then
				-- A rejected value keeps the editor open on the draft, with the problem on the row.
				local draft = sheet.field.text
				local limits = NUMBER_LIMITS[e.row]
				local value: any = draft
				if limits ~= nil and draft ~= e.initial then
					local n = if string.match(C.trim(draft), "^%d+$") ~= nil then tonumber(C.trim(draft)) else nil
					if n == nil or n < limits[1] or n > limits[2] then
						local warnings = sheet.warnings or {}
						sheet.warnings = warnings
						warnings[e.row] = string.format("Type a whole number from %d to %d.", limits[1], limits[2])
						return true
					end
					value = n
				end
				if draft == e.initial then
					(sheet.warnings or {})[e.row] = nil
					close_editing(sheet)
				elseif apply_setting(state, sheet, e.row, value) then
					close_editing(sheet)
				end
				return true
			elseif name == "escape" then
				(sheet.warnings or {})[e.row] = nil
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
	elseif name == "up" or name == "down" or name == "tab" then
		local back = name == "up" or (name == "tab" and k.shift == true)
		local target = P.move(settings_sections(state, sheet), sheet.focus, if back then -1 else 1)
		if target == nil then
			return false
		end
		sheet.focus = target
		return true
	end
	local row = settings_row(state, sheet, sheet.focus)
	if row == nil then
		return false
	end
	if name == "left" or name == "right" then
		local c = row.control
		local dir = if name == "left" then -1 else 1
		if c.k == "number" then
			local n = P.step_number(c, dir)
			if n == nil then
				return false
			end
			apply_setting(state, sheet, row.id, n)
			return true
		elseif c.k == "choice" and c.style == "segmented" then
			-- No wrap: the ends stay put.
			local values = P.option_values(c)
			local to = values[(table.find(values, c.value) or 0) + dir]
			if to == nil then
				return false
			end
			apply_setting(state, sheet, row.id, to)
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
		if ev.act == "close" then
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
		if row ~= nil then
			-- A null value is Reset: back to the row's default.
			local value = ev.value
			if value == nil or value == tern.json.null then
				value = DEFAULTS[item]
			end
			if value ~= nil then
				apply_setting(state, sheet, item, value)
				sheet.focus = item
			end
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
	state.sheet = { kind = "settings", focus = "status", warnings = {} }
end

function S.open_setup(state: State)
	S.open_settings(state)
	run_setup_check(state, state.sheet :: Sheet)
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
		elseif act == "stop_no" or act == "first_no" or act == "anyway_no" or act == "cond_close" then
			state.sheet = nil
		end
	end
end

return S
