--!strict
-- Manager list mode (UX §3): Needs you / Needs fixing / Running / Upcoming / Paused & finished, the empty state with
-- three example jobs, the dock (context line, action badges, key hints) and the list keys.

local ui = tern.ui
local C = require("./mgr_common")
local A = require("./mgr_actions")
local F = require("./mgr_form")
local S = require("./mgr_sheets")
local jobs = require("./jobs")
local runner = require("./runner")

local L = {}

type State = C.State
type Row = C.Row

export type Sec = { id: string, title: string, rows: { Row }, collapsed: boolean, count: number }
export type Model = {
	sections: { Sec },
	flat: { Row },
	by_id: { [string]: Row },
	active: number,
	running: number,
	needs: number,
	total: number,
	next_job: any?,
	next_at: number?,
}

-- Setup checks that inform but never mean the scheduler is broken (UX §6.2).
local INFO_ROWS: { [string]: boolean } = { roles = true, keepalive = true, notifications = true }

local SEC_TITLES: { [string]: string } = {
	needs = "NEEDS YOU",
	fix = "NEEDS FIXING",
	running = "RUNNING",
	upcoming = "UPCOMING",
	paused = "PAUSED & FINISHED",
}

local EXAMPLES = {
	{
		name = "TODO sweep",
		when = "weekdays 12:30",
		about = "Find and rank TODO/FIXME comments",
		cost = "~$0.10",
		prompt = "Search this project for TODO and FIXME comments. Group them by file, mark any that look urgent or stale, and list the five that matter most. If there are none, say so in one line. Don't change any files.",
	},
	{
		name = "Docs check",
		when = "fri 13:00",
		about = "Compare README and docs with the code",
		cost = "~$0.10",
		prompt = "Read the README and the docs folder and compare them with the code in this project. List statements that look out of date or wrong, with the file and line. Don't change any files.",
	},
	{
		name = "Dependency audit",
		when = "mon 12:30",
		about = "Report outdated or vulnerable packages",
		cost = "~$0.10",
		prompt = "Run `npm outdated` and `npm audit` in this project. Write a short report: what to update now, what can wait. Don't change any files.",
	},
}

-- Model ---------------------------------------------------------------------------------------------------

local function collapsed(state: State, sec: string): boolean
	local v = state.folds[sec]
	if v ~= nil then
		return v
	end
	return sec == "paused"
end

local function run_job(run: any): any
	local job: any = jobs.get(run.job_id)
	if job ~= nil then
		return job
	end
	return { id = run.job_id, name = run.job_name or "deleted job", role = run.role or "default", cwd = run.cwd or "", created_by = "user" }
end

function L.model(state: State): Model
	local now = C.now()
	local secs: { [string]: { Row } } = { needs = {}, fix = {}, running = {}, upcoming = {}, paused = {} }
	local inflight_jobs: { [string]: boolean } = {}

	for _, r in runner.inflight() do
		local run: any = r
		inflight_jobs[run.job_id] = true
		local sec = if run.state == "needs_input" then "needs" else "running"
		table.insert(secs[sec], {
			sec = sec,
			key = run.run_id,
			id = C.item_id(sec, run.run_id),
			kind = "run",
			job = run_job(run),
			run = run,
			js = nil,
		})
	end

	local upcoming: { { row: Row, at: number } } = {}
	local active = 0
	for _, j in jobs.list() do
		local job: any = j
		local js: any = jobs.state(job.id)
		local last: any = js.last_run
		local blocked = js.paused_reason == "blocked"
			or (job.enabled ~= false and type(last) == "table" and last.state == "blocked" and not inflight_jobs[job.id])
		local sec: string
		if blocked then
			sec = "fix"
		elseif job.enabled == false or js.done == true then
			sec = "paused"
		else
			sec = "upcoming"
			active += 1
		end
		local row: Row = { sec = sec, key = job.id, id = C.item_id(sec, job.id), kind = "job", job = job, run = nil, js = js }
		if sec == "upcoming" then
			table.insert(upcoming, { row = row, at = if type(js.next_run) == "number" then js.next_run else math.huge })
		else
			table.insert(secs[sec], row)
		end
	end
	table.sort(upcoming, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return string.lower((a.row.job :: any).name) < string.lower((b.row.job :: any).name)
	end)
	for _, u in upcoming do
		table.insert(secs.upcoming, u.row)
	end
	for _, bad in jobs.invalid() do
		local row: Row = {
			sec = "fix",
			key = bad.id,
			id = C.item_id("fix", bad.id),
			kind = "invalid",
			job = { id = bad.id, name = bad.name },
			run = nil,
			js = nil,
			error = bad.error,
		}
		table.insert(secs.fix, row)
	end

	local model: Model = {
		sections = {},
		flat = {},
		by_id = {},
		active = active,
		running = #secs.running,
		needs = #secs.needs,
		total = #jobs.list() + #jobs.invalid(),
		next_job = nil,
		next_at = nil,
	}
	if #upcoming > 0 and upcoming[1].at ~= math.huge then
		model.next_job = upcoming[1].row.job
		model.next_at = upcoming[1].at
	end
	for _, id in { "needs", "fix", "running", "upcoming", "paused" } do
		local rows = secs[id]
		if #rows > 0 then
			local sec: Sec = { id = id, title = SEC_TITLES[id], rows = rows, collapsed = collapsed(state, id), count = #rows }
			table.insert(model.sections, sec)
			for _, row in rows do
				model.by_id[row.id] = row
				if not sec.collapsed then
					table.insert(model.flat, row)
				end
			end
		end
	end
	return model
end

local function find_selected(state: State, model: Model): Row?
	local sel = state.sel
	if sel == nil then
		return nil
	end
	local row = model.by_id[C.item_id(sel.sec, sel.key)]
	if row ~= nil then
		for _, f in model.flat do
			if f == row then
				return row
			end
		end
	end
	-- The row moved section (paused, resumed, finished): follow the job.
	for _, f in model.flat do
		if f.key == sel.key then
			return f
		end
	end
	return nil
end

-- Makes the selection valid: the same row, else the one now at its index, else the first.
function L.sync(state: State, model: Model): Row?
	local row = find_selected(state, model)
	if row == nil and #model.flat > 0 then
		row = model.flat[math.clamp(state.sel_idx, 1, #model.flat)]
	end
	if row ~= nil then
		state.sel = { sec = row.sec, key = row.key }
		for i, f in model.flat do
			if f == row then
				state.sel_idx = i
			end
		end
	else
		state.sel = nil
	end
	return row
end

local function move_to(state: State, model: Model, idx: number): boolean
	local row = model.flat[idx]
	if row == nil then
		return false
	end
	if state.sel ~= nil and state.sel.sec == row.sec and state.sel.key == row.key then
		return false
	end
	state.sel = { sec = row.sec, key = row.key }
	state.sel_idx = idx
	return true
end

-- Rows ----------------------------------------------------------------------------------------------------

local GLYPH: { [string]: string } = {
	finished = "✓",
	failed = "✗",
	timed_out = "✗",
	cancelled = "■",
	skipped = "↷",
	missed = "◌",
	blocked = "⚠",
}
local OUTCOME: { [string]: string } = {
	failed = "failed",
	timed_out = "timed out",
	cancelled = "stopped",
	skipped = "skipped",
	missed = "missed",
	blocked = "blocked",
}

local function last_text(last: any, now: number): string
	if type(last) ~= "table" then
		return "— never run"
	end
	local t: number = last.ended or last.started or last.slot or now
	local glyph = GLYPH[last.state] or "·"
	local tail = OUTCOME[last.state]
	return string.format("%s %s%s", glyph, C.when_text(t, now), if tail ~= nil then " " .. tail else "")
end

local function clip(text: string, max: number): string
	local first = string.match(text, "^[^\r\n]*") or ""
	if (utf8.len(first) or #first) <= max then
		return first
	end
	return string.sub(first, 1, (utf8.offset(first, max) or max + 1) - 1) .. "…"
end

local function job_label(job: any, tier: number): Spans
	local spans: { Span | string } = { ui.span(job.name, "strong") }
	if tier >= 3 then
		table.insert(spans, ui.span("  @" .. tostring(job.role), "muted"))
		if job.created_by == "carly" then
			table.insert(spans, ui.span("  by Carly", "muted"))
		end
	end
	return spans
end

local function item_node(row: Row, now: number, tier: number): Node
	local job: any = row.job
	local props: { [string]: any } = { key = row.key }
	local detail_parts: { string } = {}
	local value: string = ""
	local sec = row.sec

	if row.kind == "invalid" then
		props.label = { ui.span(job.name, "strong") }
		props.detail = { ui.span(row.error or "Can't be read.", "muted") }
		props.value = { ui.span("needs fixing", "muted") }
		props.icon = "shield-alert"
		props.tone = "warning"
		props.aria = job.name .. ", " .. (row.error or "can't be read")
		return ui.node("item", props)
	end

	if row.kind == "run" then
		local run: any = row.run
		local since: number = run.started or run.created or now
		if sec == "needs" and type(run.state_since) == "number" then
			since = run.state_since
		end
		if sec == "needs" then
			props.icon = "warn"
			props.tone = "warning"
			local msg: any = run.last_message
			table.insert(detail_parts, if type(msg) == "string" and msg ~= "" then clip(msg, 70) else "Waiting for you.")
			value = "waiting " .. C.span_text(now - since)
		else
			props.icon = "activity"
			props.tone = "accent"
			if run.state == "launching" then
				table.insert(detail_parts, "Starting…")
				value = "starting"
			elseif run.state == "scheduled" then
				table.insert(detail_parts, "Queued")
				value = "queued"
			else
				local msg: any = run.last_message
				table.insert(detail_parts, if type(msg) == "string" and msg ~= "" then clip(msg, 70) else jobs.describe(job))
				value = "running " .. C.span_text(now - since)
			end
		end
		if tier >= 4 and job.cwd ~= "" then
			table.insert(detail_parts, C.tilde(job.cwd))
		end
	else
		local js: any = row.js or {}
		if tier >= 2 then
			table.insert(detail_parts, jobs.describe(job))
			table.insert(detail_parts, last_text(js.last_run, now))
		end
		if tier >= 4 then
			table.insert(detail_parts, C.tilde(job.cwd))
		end
		if sec == "fix" then
			props.icon = "shield-alert"
			props.tone = "warning"
			local last: any = js.last_run
			if type(last) == "table" and type(last.reason) == "string" and last.reason ~= "" then
				detail_parts = { clip(last.reason, 90) }
			end
			value = "needs fixing"
		elseif sec == "paused" then
			if js.paused_reason == "failures" then
				props.icon = "x-circle"
				props.tone = "error"
				value = "paused after failures"
			elseif js.done == true then
				props.icon = "check"
				props.tone = "muted"
				value = "finished"
			else
				props.icon = "pause"
				props.tone = "muted"
				value = "paused"
			end
		else
			local last: any = js.last_run
			local failed = type(last) == "table" and (last.state == "failed" or last.state == "timed_out")
			props.icon = if failed then "x-circle" else "clock"
			props.tone = if failed then "error" else "muted"
			local nxt: any = js.next_run
			if type(nxt) == "number" then
				value = if tier >= 3 then C.when_text(nxt, now) .. " · " .. C.in_text(nxt, now) else C.in_text(nxt, now)
			else
				value = "manual"
			end
		end
	end
	props.label = job_label(job, tier)
	if tier >= 2 and #detail_parts > 0 then
		props.detail = { ui.span(table.concat(detail_parts, " · "), "muted") }
	end
	props.value = { ui.span(value, if sec == "needs" then "warning" else "num") }
	props.aria = string.format("%s, %s", job.name, value)
	return ui.node("item", props)
end

-- Dock ------------------------------------------------------------------------------------------------------

-- Key hints for the list, by width: ≥80 full, 56–79 short, <56 minimal (UX §7.2).
function L.hints_text(cols: number): Node
	local hints: { { string } }
	local sep = "  "
	if cols >= 80 then
		hints = { { "n", "new" }, { "e", "edit" }, { "⏎", "open" }, { "r", "run now" }, { "␣", "pause" }, { "dd", "delete" }, { "h", "history" }, { "P", "pause all" }, { "?", "more" } }
	elseif cols >= 56 then
		hints = { { "n", "new" }, { "e", "edit" }, { "⏎", "open" }, { "r", "run" }, { "␣", "pause" }, { "?", "keys" } }
		sep = " · "
	else
		hints = { { "n", "new" }, { "⏎", "open" }, { "?", "keys" } }
		sep = " · "
	end
	local spans: { Span | string } = {}
	for i, pair in hints do
		if i > 1 then
			table.insert(spans, ui.span(sep, "muted"))
		end
		table.insert(spans, ui.span(pair[1], "key"))
		table.insert(spans, ui.span(" " .. pair[2], "muted"))
	end
	return C.text(spans, "hints")
end

local function badge_label(label: string, cols: number): string?
	if cols >= 70 then
		return label
	elseif cols >= 56 then
		return C.short_label(label)
	end
	return nil
end

local function row_badges(state: State, row: Row?): { Node }
	local cols = state.cx.cols
	local out: { Node } = {}
	local function add(label: string, tone: string, act: string, key: string, value: string?)
		local shown = badge_label(label, cols)
		if shown ~= nil then
			table.insert(out, C.badge(shown, tone, act, key, value))
		end
	end
	add("+ New", "accent", "new", "new")
	if row ~= nil and row.kind == "run" then
		local run: any = row.run
		add("Open run", "accent", "open_run", "open", run.run_id)
		add("Stop", "neutral", "stop_run", "stop", run.run_id)
		add("History", "neutral", "history", "history", row.key)
	elseif row ~= nil and row.kind == "job" then
		local job: any = row.job
		local running = #A.runs_of(job.id) > 0
		add("Run now", "accent", "run", "run", job.id)
		add("Edit", "neutral", "edit", "edit", job.id)
		add(if job.enabled == false then "Resume" else "Pause", "neutral", "pause", "pause", job.id)
		if running then
			add("Open run", "neutral", "open_job", "open", job.id)
		end
		add("History", "neutral", "history", "history", job.id)
		local armed = state.armed == job.id
		add(if armed then "Confirm delete" else "Delete", if armed then "error" else "neutral", "delete", "delete", job.id)
	end
	add("Settings", "neutral", "settings", "settings")
	add("?", "neutral", "help", "help")
	return out
end

local function setup_failing(): boolean
	local ok, health = pcall(runner.health)
	if not ok or type(health) ~= "table" then
		return false
	end
	local rows: any = (health :: any).setup
	if type(rows) ~= "table" then
		return false
	end
	for _, r in rows do
		if r.ok == false and not INFO_ROWS[r.id] then
			return true
		end
	end
	return false
end

local function context_line(state: State, model: Model, row: Row?): Node
	local now = C.now()
	local armed = state.armed
	if armed ~= nil then
		local job: any = jobs.get(armed)
		if job ~= nil then
			local running = #A.runs_of(armed) > 0
			local text = if running
				then string.format("%s is running. d again stops it and deletes the job, or esc to keep it.", job.name)
				else string.format("Press d again to delete %s, or esc to keep it.", job.name)
			return C.text({ ui.span(text, "warning") }, "ctx")
		end
	end
	if state.notice ~= nil and tern.now() - state.notice_at < 6000 then
		return C.text({ ui.span(state.notice, "warning") }, "ctx")
	end
	if jobs.paused_all() then
		return C.text({ ui.span("All jobs are paused. Press P to resume.", "warning") }, "ctx")
	end
	if setup_failing() then
		return C.with(
			ui.text({ ui.span("Agent Scheduler needs attention", "warning"), ui.span("  Check setup", "key") }),
			{ key = "ctx", actions = { click = "setup" } }
		)
	end
	if model.next_job ~= nil and model.next_at ~= nil then
		local at: number = model.next_at
		return C.text({ ui.span("Next: ", "muted"), ui.span((model.next_job :: any).name, "strong"), ui.span(string.format(" %s (%s)", C.in_text(at, now), C.abs(at)), "muted") }, "ctx")
	end
	return C.text({ ui.span(if model.total > 0 then "Nothing scheduled." else "No jobs yet.", "muted") }, "ctx")
end

-- Header ----------------------------------------------------------------------------------------------------

local function header_node(model: Model): Node
	local parts: { string } = { string.format("%d active", model.active) }
	if model.running > 0 then
		table.insert(parts, string.format("%d running", model.running))
	end
	if model.needs > 0 then
		table.insert(parts, string.format("%d needs you", model.needs))
	end
	if model.next_at ~= nil then
		table.insert(parts, "next " .. C.span_text(model.next_at - C.now()))
	end
	return C.text({ ui.span("Agent Scheduler", "strong"), ui.span("   " .. table.concat(parts, " · "), "muted") }, "header")
end

local function section_header(sec: Sec): Node
	local arrow = if sec.collapsed then "▸" else "▾"
	return C.with(
		ui.text({ ui.span(string.format("%s %s  %d", arrow, sec.title, sec.count), "dim") }),
		{ key = "h-" .. sec.id, actions = { click = "fold=" .. sec.id } }
	)
end

-- Empty state -----------------------------------------------------------------------------------------------

local function example_view(state: State): (Node, Node)
	local items: { Node } = {}
	for i, ex in EXAMPLES do
		table.insert(
			items,
			ui.node("item", {
				key = tostring(i),
				label = { ui.span(ex.name, "strong") },
				detail = { ui.span(string.format("%s · @smol · %s", ex.when, ex.cost), "muted") },
				value = { ui.span(ex.about, "muted") },
				icon = "timer",
			})
		)
	end
	local selected = C.item_id("examples", tostring(state.example_sel))
	local main = ui.col({
		C.text({ ui.span("Run an omp agent on a schedule.", "strong") }, "title"),
		C.text({ ui.span("Pick a time, write a prompt, point it at a folder. Runs show up here when they need you.", "muted") }, "body"),
		C.text({ ui.span("START FROM AN EXAMPLE", "dim") }, "head"),
		ui.node("list", { key = "examples", selected = selected }, items),
		C.with(
			ui.text({ ui.span(C.AVAILABILITY .. "  ", "muted"), ui.span("Details", "key") }),
			{ key = "avail", actions = { click = "setup" } }
		),
	})
	local acts: { Node } = {
		C.badge("+ New", "accent", "new", "new"),
		C.badge("Settings", "neutral", "settings", "settings"),
		C.badge("?", "neutral", "help", "help"),
	}
	local dock = ui.col({
		C.with(ui.row(acts), { key = "acts" }),
		C.text({ ui.span("⏎", "key"), ui.span(" use example   ", "muted"), ui.span("n", "key"), ui.span(" new job   ", "muted"), ui.span("?", "key"), ui.span(" how it works", "muted") }, "hints"),
	})
	return main, dock
end

local function use_example(state: State, i: number)
	local ex = EXAMPLES[i]
	if ex == nil then
		return
	end
	F.open_new(state, { name = ex.name, prompt = ex.prompt, when = ex.when, cwd = state.cwd_hint, role = "smol" })
end

-- View --------------------------------------------------------------------------------------------------------

function L.view(state: State): (Node, Node)
	local model = L.model(state)
	if model.total == 0 then
		return example_view(state)
	end
	local row = L.sync(state, model)
	local now = C.now()
	local tier = C.tier(state.cx.cols)
	local children: { Node } = { header_node(model) }
	for _, sec in model.sections do
		table.insert(children, section_header(sec))
		if not sec.collapsed then
			local items: { Node } = {}
			local selected: string? = nil
			for _, r in sec.rows do
				table.insert(items, item_node(r, now, tier))
				if row ~= nil and r == row then
					selected = r.id
				end
			end
			table.insert(children, ui.node("list", { key = sec.id, selected = selected }, items))
		end
	end
	local dock = ui.col({
		context_line(state, model, row),
		C.with(ui.row(row_badges(state, row)), { key = "acts" }),
		L.hints_text(state.cx.cols),
	})
	return ui.col(children), dock
end

-- Keys --------------------------------------------------------------------------------------------------------

local function enter(state: State, row: Row)
	if row.kind == "run" then
		local run: any = row.run
		if row.sec == "needs" then
			A.open_run(state, run.run_id)
		else
			A.open_detail(state, run.job_id)
		end
	elseif row.kind == "job" then
		A.open_detail(state, row.key)
	end
end

local function next_needs(state: State, model: Model): boolean
	local needs: { Row } = {}
	for _, r in model.flat do
		if r.sec == "needs" then
			table.insert(needs, r)
		end
	end
	if #needs == 0 then
		return false
	end
	local at = 0
	for i, r in needs do
		if state.sel ~= nil and state.sel.sec == r.sec and state.sel.key == r.key then
			at = i
		end
	end
	local target = needs[at % #needs + 1]
	for i, r in model.flat do
		if r == target then
			return move_to(state, model, i)
		end
	end
	return false
end

-- The job id of a row (a run row's job).
local function job_id_of(row: Row): string
	if row.kind == "run" then
		return (row.run :: any).job_id
	end
	return row.key
end

-- Starts the form for a new job or opens a settings sheet, etc.; `true` when the state changed.
function L.key(state: State, k: Key): boolean?
	local name = k.name
	local model = L.model(state)

	if name == "?" or (name == "/" and k.shift) then
		S.open_help(state)
		return true
	elseif name == "," then
		S.open_settings(state)
		return true
	end

	if model.total == 0 then
		if name == "j" or name == "down" then
			if state.example_sel < #EXAMPLES then
				state.example_sel += 1
				return true
			end
			return false
		elseif name == "k" or name == "up" then
			if state.example_sel > 1 then
				state.example_sel -= 1
				return true
			end
			return false
		elseif name == "enter" then
			use_example(state, state.example_sel)
			return true
		elseif name == "n" then
			A.new_job(state)
			return true
		elseif name == "u" then
			return A.undo(state)
		end
		return false
	end

	local armed = state.armed
	if armed ~= nil and name ~= "d" then
		state.armed = nil
		if name == "escape" then
			return true
		end
	end

	local row = L.sync(state, model)
	if name == "j" or name == "down" then
		return move_to(state, model, state.sel_idx + 1)
	elseif name == "k" or name == "up" then
		return move_to(state, model, state.sel_idx - 1)
	elseif name == "g" and not k.shift then
		return move_to(state, model, 1)
	elseif name == "G" or (name == "g" and k.shift) then
		return move_to(state, model, #model.flat)
	elseif name == "n" then
		A.new_job(state)
		return true
	elseif name == "a" then
		return next_needs(state, model)
	elseif C.is_shift_letter(k, "p") then
		A.pause_all(state)
		return true
	elseif name == "u" then
		return A.undo(state)
	end

	if row == nil or row.kind == "invalid" then
		return false
	end
	local jid = job_id_of(row)
	if name == "enter" then
		enter(state, row)
		return true
	elseif name == "e" then
		A.edit(state, jid)
		return true
	elseif name == "r" then
		A.run_now(state, jid)
		return true
	elseif name == "space" then
		A.toggle_pause(state, jid)
		return true
	elseif name == "d" then
		A.delete(state, jid)
		return true
	elseif name == "h" then
		A.open_detail(state, jid)
		return true
	elseif name == "o" then
		A.open_job_run(state, jid)
		return true
	elseif name == "x" then
		if row.kind == "run" then
			A.stop_run(state, (row.run :: any).run_id)
		else
			A.stop_job(state, jid)
		end
		return true
	elseif name == "p" then
		A.edit_prompt(state, jid)
		return true
	elseif name == "c" then
		A.duplicate(state, jid)
		return true
	end
	return false
end

-- Events ------------------------------------------------------------------------------------------------------

local function select_item(state: State, item: any): Row?
	local sec, key = C.parse_item(item)
	if sec == nil or key == nil then
		return nil
	end
	if sec == "examples" then
		state.example_sel = tonumber(key) or state.example_sel
		return nil
	end
	local model = L.model(state)
	local row = model.by_id[C.item_id(sec, key)]
	if row ~= nil then
		state.sel = { sec = row.sec, key = row.key }
		for i, f in model.flat do
			if f == row then
				state.sel_idx = i
			end
		end
	end
	return row
end

function L.event(state: State, ev: UiEvent)
	local kind = ev.ev
	if kind == "select" then
		select_item(state, ev.item)
	elseif kind == "activate" then
		local sec = C.parse_item(ev.item)
		if sec == "examples" then
			select_item(state, ev.item)
			use_example(state, state.example_sel)
			return
		end
		local row = select_item(state, ev.item)
		if row ~= nil then
			enter(state, row)
		end
	elseif kind == "action" then
		local act = ev.act
		local value: any = ev.value
		if act == "fold" and type(value) == "string" then
			state.folds[value] = not collapsed(state, value)
		elseif act == "new" then
			A.new_job(state)
		elseif act == "settings" then
			S.open_settings(state)
		elseif act == "help" then
			S.open_help(state)
		elseif act == "setup" then
			S.open_setup(state)
		elseif type(value) == "string" then
			if act == "run" then
				A.run_now(state, value)
			elseif act == "edit" then
				A.edit(state, value)
			elseif act == "pause" then
				A.toggle_pause(state, value)
			elseif act == "history" then
				A.open_detail(state, value)
			elseif act == "delete" then
				A.delete(state, value)
			elseif act == "open_run" then
				A.open_run(state, value)
			elseif act == "open_job" then
				A.open_job_run(state, value)
			elseif act == "stop_run" then
				A.stop_run(state, value)
			end
		end
	end
end

return L
