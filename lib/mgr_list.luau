--!strict
local timefmt = require("./timefmt")
-- Manager list mode (UX §3): Needs you / Needs fixing / Running / Upcoming / Paused & finished, the empty state with
-- three example jobs, the dock (context line, action badges, key hints) and the list keys.

local ui = tern.ui
local C = require("./mgr_common")
local A = require("./mgr_actions")
local F = require("./mgr_form")
local S = require("./mgr_sheets")
local jobs = require("./jobs")
local Live = require("./mgr_live")
local runner = require("./runner")
local store = require("./store")
local conditions = require("./conditions")
local cond_eval = require("./cond_eval")

local T = require("./mgr_timeline")
local D = require("./mgr_detail")
local H = require("./mgr_history")
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

function L.model(state: State, frame_now: number?): Model
	local now = frame_now or C.now()
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
		local watch_err: any = if type(js.watch) == "table" and type(js.watch.conditions) == "table" then js.watch.conditions.err else nil
		local blocked = js.paused_reason == "blocked"
			or js.paused_reason == "conditions"
			or (
				job.enabled ~= false
				and type(last) == "table"
				and last.state == "blocked"
				and not inflight_jobs[job.id]
				and not (last.reason_code == "cond_error" and watch_err == nil)
			)
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
	return if jobs.settings().manager_layout == "classic" then model else T.model(state, model, now)
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
	local t: number = last.started or last.slot or now
	local glyph = GLYPH[last.state] or "·"
	local tail = if last.quiet == true then "quiet" else OUTCOME[last.state]
	return string.format("%s %s%s", glyph, C.when_text(t, now), if tail ~= nil then " " .. tail else "")
end

local function clip(text: string, max: number): string
	local first = string.match(text, "^[^\r\n]*") or ""
	if (utf8.len(first) or #first) <= max then
		return first
	end
	return string.sub(first, 1, (utf8.offset(first, max) or max + 1) - 1) .. "…"
end

-- `by Carly` is the only marker of a job Carly created, so it stays at every width: the role chip goes first, and
-- below tier 3 the mark shrinks to a glyph.
local function job_label(job: any, tier: number): Spans
	local spans: { Span | string } = { ui.span(job.name, "strong") }
	if tier >= 3 then
		table.insert(spans, ui.span("  @" .. tostring(job.role), "muted"))
	end
	if job.created_by == "carly" then
		table.insert(spans, ui.span(if tier >= 3 then "  by Carly" else "  ✦", "muted"))
	end
	return spans
end

-- "only when <conditions>" for a job row, or nil when the job has none.
local function only_when_part(job: any): string?
	if type(job.conditions) == "table" and #job.conditions > 0 then
		return "only when " .. conditions.describe(job.conditions)
	end
	return nil
end

local function item_node(row: Row, now: number, tier: number): Node
	local job: any = row.job
	local props: { [string]: any } = { key = row.key, role = "tas.job-row" }
	local detail_parts: { string } = {}
	local value: string = ""
	local sec = row.sec
	if sec == "rest" then
		sec = if row.kind == "invalid" or (row.js and (row.js.paused_reason == "blocked" or row.js.paused_reason == "conditions")) then "fix" elseif job.schedule.kind == "manual" and job.enabled ~= false then "manual" else "paused"
	end

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
			local cond = only_when_part(job)
			if cond ~= nil then
				table.insert(detail_parts, cond)
				if tier >= 3 then
					local ok, s = pcall(cond_eval.spend, job.id, "day", now)
					if ok and type(s) == "table" and s.runs > 0 then
						table.insert(detail_parts, string.format("$%.2f today", s.usd))
					end
				end
			end
			table.insert(detail_parts, last_text(js.last_run, now))
		end
		if tier >= 4 then
			table.insert(detail_parts, C.tilde(job.cwd))
		end
		local W: any = if type(js.watch) == "table" then js.watch.conditions else nil
		if type(W) == "table" and type(W.skips) == "table" and (tonumber(W.skips.n) or 0) >= 50 then
			local last_run: any = js.last_run
			local since: number = (type(last_run) == "table" and last_run.ended) or job.created_at or now
			if now - since >= 14 * 86400 then
				detail_parts = {
					string.format("Hasn't run since %s: %s (%d checks)", timefmt.date("%b %d", since), tostring(W.skips.text), W.skips.n),
				}
			end
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
			local failed = H.ensure(job.id).failed
			if failed and not (type(last) == "table" and (last.state == "failed" or last.state == "timed_out")) then table.insert(detail_parts, "✗ Previous failure") end
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
	-- Accent only for a fire under 5 minutes away (UX §8.1); everything else scheduled is muted.
	local tone = "muted"
	local js_next: any = if row.js ~= nil then (row.js :: any).next_run else nil
	if sec == "needs" then
		tone = "warning"
	elseif sec == "running" then
		tone = "num"
	elseif sec == "upcoming" and type(js_next) == "number" and js_next - now < 300 then
		tone = "accent"
	end
	props.value = { ui.span(value, tone .. " mono") }
	props.aria = string.format("%s, %s", job.name, value)
	return ui.node("item", props)
end

-- Dock ------------------------------------------------------------------------------------------------------

-- Key hints for the list, by width: ≥80 full, 56–79 short, <56 minimal (UX §7.2).
function L.hints_text(cols: number): Node
	local hints: { { string } }
	local sep = "  "
	if cols >= 80 then
		hints = { { "n", "new" }, { "e", "edit" }, { "⏎", "open" }, { "r", "run now" }, { "␣", "pause" }, { "dd", "delete" }, { "h", "history" }, { "⇧P", "pause all" }, { "?", "more" } }
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

local DATA_TEXT: { [string]: string } = {
	damaged = "Saved data is damaged, so jobs are paused. Start fresh clears it, or open the data folder to repair it by hand.",
	readonly = "Agent Scheduler can't write its data folder, so jobs are paused. Fix the folder's permissions, then start fresh.",
}

-- "damaged" or "readonly" while the store refuses writes (EN §2.2.4), else nil.
local function data_problem(): string?
	local ok, health = pcall(store.health)
	if ok and (health == "damaged" or health == "readonly") then
		return health
	end
	return nil
end

local function row_badges(state: State, row: Row?): { Node }
	local out: { Node } = {}
	local function add(label, key, act, value, tone)
		table.insert(out, C.action_button(label, key, tone or "neutral", act, act, value))
	end
	if data_problem() ~= nil then
		add("Start fresh", "", "start_fresh", nil, "error")
		add("Open data folder", "", "open_data", nil)
	end
	if row ~= nil and row.kind ~= "invalid" then
		local job: any = row.job
		add("Open", "enter", "details", job.id, "accent")
		add("Run now", "r", "run", job.id)
		add("Edit", "e", "edit", job.id)
		add(if job.enabled == false then "Resume" else "Pause", "space", "pause", job.id)
		if state.cx.cols >= 110 then add("Duplicate", "c", "duplicate", job.id) end
	end
	if row ~= nil then
		add(if state.armed == row.key then "Confirm delete" else "Delete", "dd", "delete", (row.job :: any).id, "error")
	end
	local job_actions = out
	out = {}
	add("New job", "n", "new", nil)
	add("Settings", ",", "settings", nil)
	add("Mark all seen", "s", "seen", nil)
	add(if jobs.paused_all() then "Resume all" else "Pause all", "P", "pause_all", nil, "warning")
	add("Help", "?", "help", nil)
	if state.undo_until ~= nil and tern.now() < state.undo_until then add("Undo", "u", "undo", nil, "accent") end
	return { ui.node("row", { key = "job-actions", role = "tas.dock-job", gap = "sm" }, job_actions), ui.node("row", { key = "global-actions", role = "tas.dock-global", gap = "sm" }, out) }
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

local function setup_line(): Node
	return C.with(
		ui.text({ ui.span("Agent Scheduler needs attention", "warning"), ui.span("  Check setup", "key") }),
		{ key = "ctx", actions = { click = "setup" } }
	)
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
		elseif row ~= nil and row.kind == "invalid" and row.key == armed then
			return C.text({ ui.span(string.format("Press d again to remove %s, or esc to keep it.", (row.job :: any).name), "warning") }, "ctx")
		end
	end
	if state.notice ~= nil and tern.now() - state.notice_at < 6000 then
		return C.text({ ui.span(state.notice, "warning") }, "ctx")
	end
	local problem = data_problem()
	if problem ~= nil then
		return C.text({ ui.span(DATA_TEXT[problem], "warning") }, "ctx")
	end
	if row ~= nil and row.kind == "invalid" then
		return C.text({ ui.span(string.format("This job can't be read: %s. dd removes it, or open the data folder to fix jobs.json.", string.gsub(row.error or "unknown error", "%.$", "")), "warning") }, "ctx")
	end
	if jobs.paused_all() then
		return C.text({ ui.span("All jobs are paused. Press shift+p to resume.", "warning") }, "ctx")
	end
	if setup_failing() then
		return setup_line()
	end
	if row ~= nil then
		return C.text({ ui.span((row.job :: any).name, "strong"), ui.span(if state.split_focus then " · runs selected · esc returns to jobs" else " · selected job", "muted") }, "ctx")
	end
	if model.next_job ~= nil and model.next_at ~= nil then
		local at: number = model.next_at
		return C.text({ ui.span("Next: ", "muted"), ui.span((model.next_job :: any).name, "strong"), ui.span(string.format(" %s (%s)", C.in_text(at, now), C.abs(at)), "muted") }, "ctx")
	end
	return C.text({ ui.span(if model.total > 0 then "Nothing scheduled." else "No jobs yet.", "muted") }, "ctx")
end

-- Header ----------------------------------------------------------------------------------------------------

local function header_node(model: Model, now: number): Node
	local parts: { string } = { string.format("%d active", model.active) }
	if model.running > 0 then
		table.insert(parts, string.format("%d running", model.running))
	end
	if model.needs > 0 then
		table.insert(parts, string.format("%d needs you", model.needs))
	end
	if model.next_at ~= nil then
		table.insert(parts, "next " .. string.gsub(C.in_text(model.next_at, now), "^in ", ""))
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
	local acts: { Node } = {}
	local problem = data_problem()
	if problem ~= nil then
		table.insert(acts, C.badge("Start fresh", "error", "start_fresh", "fresh"))
		table.insert(acts, C.badge("Open data folder", "neutral", "open_data", "data"))
	end
	table.insert(acts, C.badge("+ New", "accent", "new", "new"))
	table.insert(acts, C.badge("Settings", "neutral", "settings", "settings"))
	table.insert(acts, C.badge("?", "neutral", "help", "help"))
	local dock_children: { Node } = {}
	if problem ~= nil then
		table.insert(dock_children, C.text({ ui.span(DATA_TEXT[problem], "warning") }, "ctx"))
	elseif setup_failing() then
		table.insert(dock_children, setup_line())
	end
	table.insert(dock_children, C.with(ui.row(acts), { key = "acts" }))

	local dock = ui.col(dock_children)
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

-- The detail text of an upcoming job row (schedule, last run, folder by width tier).
local function upcoming_detail(row: Row, now: number, tier: number): string
	local parts: { string } = {}
	if tier >= 2 then
		table.insert(parts, jobs.describe(row.job))
		local cond = only_when_part(row.job)
		if cond ~= nil then
			table.insert(parts, cond)
		end
		table.insert(parts, last_text((row.js :: any).last_run, now))
	end
	if tier >= 4 then
		table.insert(parts, C.tilde((row.job :: any).cwd))
	end
	return table.concat(parts, " · ")
end

function L.view(state: State): (Node, Node)
	local now = C.now()
	local model = L.model(state, now)
	if model.total == 0 then
		return example_view(state)
	end
	local row = L.sync(state, model)
	local split = state.cx.cols >= C.SPLIT_COLS
	local tier = C.tier(if split then state.cx.cols / 2 else state.cx.cols)
	local timeline = jobs.settings().manager_layout ~= "classic"
	local children: { Node } = { header_node(model, now) }
	for _, sec in model.sections do
		if timeline and sec.id == "now" then
			table.insert(children, ui.el("div", { key = "h-now", role = "tas.now-rule" }, { ui.el("span", { role = "tas.now-pill", text = sec.title }) }))
		else
			table.insert(children, if timeline then C.with(ui.rule({ ui.span(sec.title, "muted") }), { key = "h-" .. sec.id, role = if sec.id == "results" then "tas.last-looked" else "tas.timeline-heading" }) else section_header(sec))
		end
		if not sec.collapsed then
			local selected: string? = nil
			if sec.id == "needs" or sec.id == "running" then
				-- In-flight runs are `agent` nodes, which a `list` can't select: keep them in a col.
				local nodes: { Node } = {}
				for _, r in sec.rows do
					local node = Live.agent_row(r, now, tier, row ~= nil and r == row)
					local nxt = jobs.state((r.job :: any).id).next_run
					local props: any = node.p
					props.role = "tas.live-row"
					if timeline and type(nxt) == "number" then table.insert(props.badges, { text = "next " .. timefmt.date("%H:%M", nxt) }) end
					table.insert(nodes, node)
				end
				table.insert(children, ui.node("col", { key = sec.id, gap = "xs" }, nodes))
			else
				local items: { Node } = {}
				for _, r in sec.rows do
					if r.kind == "result" then
						table.insert(items, T.result(state, r))
					elseif not timeline and Live.counts_down(r, now) then
						table.insert(items, Live.countdown_row(r, now, tier, row ~= nil and r == row, job_label(r.job, tier), upcoming_detail(r, now, tier)))
					else
						table.insert(items, item_node(r, now, tier))
					end
					if row ~= nil and r == row then
						selected = r.id
						items[#items].p.mark = "pick"
					end
				end
				table.insert(children, ui.node("list", { key = sec.id, selected = selected }, items))
			end
		end
	end
	local dock = ui.col({
		context_line(state, model, row),
		C.with(ui.row(row_badges(state, row)), { key = "acts", role = "tas.dock-actions" }),

	})
	if split and row ~= nil and row.kind ~= "invalid" then
		local id = (row.job :: any).id
		if state.detail == nil or state.detail.job_id ~= id then state.detail = { job_id = id, sel = nil, expanded = nil } end
		if row.kind == "result" and not state.split_focus then state.detail.sel = (row.run :: any).run_id end
		local detail = D.view(state, true, now)
		local left = ui.node("col", { key = "timeline", role = "tas.timeline", gap = "sm" }, children)
		local right = C.with(detail, { key = "detail", role = "tas.detail" })
		-- Native lists require absolute node ids after nesting.
		local function rebase(n: any, prefix: string)
			if n.p and type(n.p.selected) == "string" then n.p.selected = string.gsub(n.p.selected, "^main%.", prefix .. ".") end
			for _, child in n.c or {} do rebase(child, prefix) end
		end
		rebase(left, "main.split.timeline"); rebase(right, "main.split.detail")
		return ui.col({ ui.node("row", { key = "split", role = "tas.split", gap = "lg" }, { left, right }) }), dock
	end
	return ui.col(children), dock
end

-- Keys --------------------------------------------------------------------------------------------------------

local function enter(state: State, row: Row)
	if state.cx.cols >= C.SPLIT_COLS and row.kind ~= "invalid" and row.sec ~= "needs" then
		state.detail = { job_id = (row.job :: any).id, sel = nil, expanded = nil }
		state.split_focus = true
		return
	end
	if row.kind == "run" then
		local run: any = row.run
		if row.sec == "needs" then
			A.open_run(state, run.run_id)
		else
			A.open_detail(state, run.job_id)
		end
	elseif row.kind == "job" or row.kind == "result" then
		A.open_detail(state, (row.job :: any).id)
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
	return (row.job :: any).id
end

-- Starts the form for a new job or opens a settings sheet, etc.; `true` when the state changed.
local function key_inner(state: State, k: Key): boolean?
	local name = k.name
	local model = L.model(state)

	if name == "?" or (name == "/" and k.shift) then
		S.open_help(state)
		return true
	elseif name == "s" then
		T.clear(state)
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

	if row == nil then
		return false
	elseif row.kind == "invalid" then
		if name == "d" then
			A.delete(state, row.key)
			return true
		end
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
	elseif name == "i" then
		local job: any = jobs.get(jid)
		if job ~= nil and type(job.conditions) == "table" and #job.conditions > 0 then
			S.check_conditions(state, jid)
		else
			C.notice(state, "This job has no conditions. Press e and open Only when.")
		end
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

function L.key(state: State, k: Key): boolean?
	-- A key that disarms a pending delete must redraw even when it does nothing else.
	local disarmed = state.armed ~= nil and k.name ~= "d"
	local handled = key_inner(state, k)
	return handled or disarmed
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
		if act == "pick" or act == "open" then
			local row = if type(value) == "string" then select_item(state, value) else nil
			if row ~= nil and act == "open" then
				enter(state, row)
			end
			return
		end
		if act == "fold" and type(value) == "string" then
			state.folds[value] = not collapsed(state, value)
		elseif act == "start_fresh" then
			A.start_fresh(state)
		elseif act == "open_data" then
			S.open_data_folder()
		elseif act == "undo" then
			if not A.undo(state) then
				C.notice(state, "Nothing to undo.")
			end
		elseif act == "pause_all" then
			A.pause_all(state)
		elseif act == "new" then
			A.new_job(state)
		elseif act == "details" then
			local row = L.sync(state, L.model(state))
			if row then
				if state.split_focus then D.key(state, { name = "enter" } :: any) else enter(state, row) end
			end
		elseif act == "seen" then
			T.clear(state)
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
			elseif act == "duplicate" then
				A.duplicate(state, value)
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
