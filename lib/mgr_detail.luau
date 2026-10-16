--!strict
local timefmt = require("./timefmt")
-- Manager detail mode (UX §3.5): one job's settings, its prompt and its last 20 runs from the ledger.

local ui = tern.ui
local C = require("./mgr_common")
local A = require("./mgr_actions")
local S = require("./mgr_sheets")
local runner = require("./runner")
local cron = require("./cron")
local jobs = require("./jobs")
local ledger = require("./ledger")
local conditions = require("./conditions")

local H = require("./mgr_history")
local D = {}

type State = C.State

local GLYPH: { [string]: string } = {
	finished = "✓",
	failed = "✗",
	timed_out = "✗",
	cancelled = "■",
	skipped = "↷",
	missed = "◌",
	needs_input = "⚠",
}

local SAFETY: { [string]: string } = {
	yolo = "Hands-off: runs commands and edits files as you",
	write = "Asks before commands",
	always_ask = "Asks before every edit or command",
}

local function clip(text: string, max: number): string
	if (utf8.len(text) or #text) <= max then
		return text
	end
	return string.sub(text, 1, (utf8.offset(text, max) or max + 1) - 1) .. "…"
end

-- The job being shown, or nil when it no longer exists.
function D.job(state: State): any
	local d = state.detail
	if d == nil then
		return nil
	end
	return jobs.get(d.job_id)
end

local function next_times(job: any, js: any, now: number): string
	if job.enabled == false then
		return "— (paused)"
	end
	local s: any = job.schedule
	local ups: { number } = {}
	if s.kind == "cron" then
		local spec = cron.parse(s.expr)
		if spec ~= nil then
			ups = cron.upcoming(spec, 3, now, 3000)
		end
	elseif s.kind == "interval" then
		local nxt: any = js.next_run
		if type(nxt) == "number" and type(s.secs) == "number" then
			ups = { nxt, nxt + s.secs, nxt + 2 * s.secs }
		end
	elseif s.kind == "once" then
		if type(js.next_run) == "number" then
			ups = { js.next_run }
		end
	end
	if #ups == 0 then
		return "—"
	end
	local parts: { string } = {}
	for _, t in ups do
		table.insert(parts, C.abs(t))
	end
	return table.concat(parts, " · ")
end

local function when_text(job: any): string
	local s: any = job.schedule
	local text = jobs.describe(job)
	if s.kind == "cron" then
		return string.format("%s (local, %s) · %s", text, timefmt.date("%Z", C.now()), s.expr)
	end
	return text
end

local function appears_text(): string
	local settings = jobs.settings()
	local d: any = settings.defaults
	local p: any = if type(d) == "table" then d.placement else nil
	local where = if type(p) == "table" and p.where == "tab"
		then "Background tab in the current session"
		else string.format("%s session, background tab", tostring(settings.session_name or "Scheduled runs"))
	if type(d) == "table" and d.focus == "front" then
		where ..= " · brought to front when it starts"
	end
	return where
end

local function after_text(): string
	return "Notifies you if it needs you, fails or times out"
end

local function safety_text(job: any): string
	local base = SAFETY[job.approval] or tostring(job.approval)
	local secs = tonumber(job.max_runtime_s) or 1800
	return string.format("%s · stops after %s", base, C.span_text(secs))
end

local function kv(label: string, value: string): { Spans }
	return { { ui.span(label, "muted") }, { ui.span(value) } }
end

-- Runs ---------------------------------------------------------------------------------------------------------

local function run_item(run: any, now: number, tier: number): Node
	local props: { [string]: any } = { key = run.run_id, role = "tas.run-row" }
	local t: number = run.started or run.created or run.slot or now
	local suffix = ""
	if run.trigger == "manual" then
		suffix = " (manual)"
	elseif run.trigger == "catchup" then
		suffix = " (caught up)"
	end
	local glyph = GLYPH[run.state]
	if run.state == "blocked" then
		props.icon = "shield-alert"
		props.tone = "warning"
	elseif glyph == nil then
		props.icon = "activity"
		props.tone = "accent"
	elseif run.state == "failed" or run.state == "timed_out" then
		props.tone = "error"
	elseif run.state == "needs_input" then
		props.tone = "warning"
	end
	props.label = { ui.span(string.format("%s%s%s", if glyph ~= nil then glyph .. " " else "", C.when_text(t, now), suffix), "mono") }

	local not_attached = ""
	if type(run.images) == "table" and type(run.images.skipped) == "table" and #run.images.skipped > 0 then
		local k = #run.images.skipped
		not_attached = string.format("%d %s not attached", k, if k == 1 then "image" else "images")
	end
	local detail: string
	if run.state == "finished" then
		local parts: { string } = {}
		local quiet = run.outcome_flag == "quiet"
		if quiet then
			table.insert(parts, "quiet")
			props.tone = "muted"
		end
		if type(run.model) == "string" then
			table.insert(parts, run.model)
		end
		if type(run.summary) == "string" and run.summary ~= "" and not (quiet and run.summary == "nothing to report") then
			table.insert(parts, "“" .. clip(run.summary, 80) .. "”")
		elseif run.reason_code == "ok_unobserved" then
			table.insert(parts, "finished (no window was open to watch it)")
		end
		if not_attached ~= "" then
			table.insert(parts, not_attached)
		end
		detail = table.concat(parts, " · ")
	elseif type(run.summary) == "string" and run.summary ~= "" then
		detail = clip(run.summary, 120)
	elseif type(run.reason) == "string" and run.reason ~= "" then
		detail = clip(run.reason, 120)
		if not_attached ~= "" then
			detail ..= " · " .. not_attached
		end
	else
		detail = run.state
		if not_attached ~= "" then
			detail ..= " · " .. not_attached
		end
	end
	if run.cond_bypass ~= nil then
		detail ..= " · ran without checking conditions"
	end
	if tier >= 2 and detail ~= "" then
		table.insert(props.label, ui.span("  " .. string.gsub(run.state, "_", " ") .. " · " .. detail, "muted"))
	end
	local value = ""
	if type(run.started) == "number" and type(run.ended) == "number" then
		value = C.duration_text(run.ended - run.started)
		if tier >= 3 and (run.state == "finished" or run.state == "failed" or run.state == "timed_out") then
			value ..= " · " .. C.cost_text(run.cost)
		end
	elseif run.state == "needs_input" or run.state == "running" or run.state == "launching" then
		value = run.state
	end
	props.value = { ui.span(value, "num") }
	return ui.node("item", props)
end

local function runs_of_job(state: State): { any }
	local d = state.detail
	if d == nil then
		return {}
	end
	local ok, list = pcall(ledger.recent, d.job_id, 50)
	if ok and type(list) == "table" then
		return list
	end
	return {}
end

local function selected_run(state: State, runs: { any }): any
	local d = state.detail :: { job_id: string, sel: string?, expanded: string? }
	for _, r in runs do
		if r.run_id == d.sel then
			return r
		end
	end
	local first = runs[1]
	if first ~= nil then
		d.sel = first.run_id
	else
		d.sel = nil
	end
	return first
end

-- Demotes Markdown headings to bold lines (outside fenced code) so they don't render as large headings.
local function demote_headings(text: string): string
	local out: { string } = {}
	local fenced = false
	for line in string.gmatch((string.gsub(text, "\r\n?", "\n")) .. "\n", "([^\n]*)\n") do
		if string.match(line, "^%s*```") ~= nil or string.match(line, "^%s*~~~") ~= nil then
			fenced = not fenced
		elseif not fenced then
			local h: string? = nil
			local hashes, rest = string.match(line, "^(#+)%s+(.*)")
			if hashes ~= nil and #hashes <= 6 then
				h = rest
			end
			if h ~= nil then
				line = "**" .. h .. "**"
			end
		end
		table.insert(out, line)
	end
	return table.concat(out, "\n")
end

-- A compact plain-text preview, without Markdown heading punctuation.
function D.prompt_preview(text: string): string
	local lines = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		line = string.gsub(line, "^%s*#+%s*", "")
		line = string.gsub(line, "%s+#+%s*$", "")
		if string.match(line, "%S") then table.insert(lines, line) end
		if #lines >= 2 then break end
	end
	return table.concat(lines, " · ")
end

-- First `max` lines of `text` as Markdown source (an unclosed code fence is closed), and whether lines were dropped.
local function md_head(text: string, max: number): (string, boolean)
	local lines: { string } = {}
	local cut = false
	for line in string.gmatch((string.gsub(text, "\r\n?", "\n")) .. "\n", "([^\n]*)\n") do
		if #lines >= max then
			cut = true
			break
		end
		table.insert(lines, clip(line, 240))
	end
	while #lines > 0 and string.match(lines[#lines] :: string, "^%s*$") ~= nil do
		table.remove(lines)
	end
	local src = table.concat(lines, "\n")
	local _, fences = string.gsub(src, "\n?%s*```", "")
	if fences % 2 == 1 then
		src ..= "\n```"
	end
	return src, cut
end

local function expanded_card(run: any): Node
	local lines: { Node } = {}
	local msg: any = run.last_message
	if type(msg) == "string" and msg ~= "" then
		local src, cut = md_head(msg, 14)
		table.insert(lines, C.with(ui.md(src), { key = "result-md" }))
		if cut then
			table.insert(lines, C.text({ ui.span("…", "muted") }, "result-more"))
		end
	elseif type(run.reason) == "string" and run.reason ~= "" then
		table.insert(lines, ui.text({ ui.span(run.reason) }))
	else
		table.insert(lines, ui.text({ ui.span("No message was recorded for this run.", "muted") }))
	end
	local facts: { string } = {}
	if type(run.model) == "string" then
		table.insert(facts, run.model)
	end
	if type(run.session_id) == "string" then
		table.insert(facts, "session " .. run.session_id)
	end
	table.insert(facts, C.cost_text(run.cost))
	table.insert(lines, ui.text({ ui.span(table.concat(facts, " · "), "muted") }))
	return C.with(ui.card({ ui.span("Last message", "strong") }, lines), { key = "expanded" })
end

-- History is text, not a chart. Counters are independent of ledger retention.

-- View ---------------------------------------------------------------------------------------------------------

function D.hints_text(cols: number): Node
	local hints: { { string } }
	local sep = "  "
	if cols >= 80 then
		hints = { { "⏎", "open run" }, { "r", "run now" }, { "e", "edit" }, { "p", "prompt file" }, { "m", "message" }, { "␣", "pause" }, { "dd", "delete" }, { "esc", "back" }, { "?", "more" } }
	elseif cols >= 56 then
		hints = { { "⏎", "open" }, { "r", "run" }, { "e", "edit" }, { "␣", "pause" }, { "esc", "back" } }
		sep = " · "
	else
		hints = { { "⏎", "open" }, { "esc", "back" } }
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

function D.view(state: State, embedded: boolean?, frame_now: number?): (Node, Node)
	local d = state.detail :: { job_id: string, sel: string?, expanded: string? }
	local job: any = jobs.get(d.job_id)
	local js: any = jobs.state(d.job_id)
	local now = frame_now or C.now()
	local cols = if embedded then state.cx.cols / 2 else state.cx.cols
	local tier = C.tier(cols)
	local runs = runs_of_job(state)
	local sel = selected_run(state, runs)
	local h = H.ensure(job.id)
	local status = if js.done then "✓ Finished" elseif job.enabled == false then "Ⅱ Paused" else "○ Active"
	local live = A.runs_of(job.id)[1]
	if live then status = if live.state == "needs_input" then "! Needs you" else "● Running" end
	if type(js.next_run) == "number" and job.enabled ~= false then status ..= " · next " .. C.when_text(js.next_run, now) end
	local children: { Node } = {
		C.with(C.text({ ui.span(job.name, "strong") }, "title"), { role = "tas.detail-title" }),
		C.with(C.text({ ui.span(status, if live then "accent" else "muted") }, "status"), { role = "tas.detail-status" }),
	}
	local latest = runs[1]
	if latest then
		local bad = H.failed(latest)
		local outcome = string.gsub(latest.state, "_", " ")
		local summary = latest.summary or latest.reason or "No summary recorded."
		if bad then table.insert(children, C.with(ui.badge("Last run failed", "error"), { key = "failed-badge", role = "tas.failure-badge" })) end
		table.insert(children, ui.node("col", { key = "latest", role = if bad then "tas.latest-failed" else "tas.latest", gap = "xs" }, {
			ui.text({ ui.span((GLYPH[latest.state] or "·") .. " Latest result · " .. outcome .. " · " .. C.when_text(latest.started or latest.created or latest.slot or now, now), if bad then "error" else "strong") }),
			ui.text({ ui.span(summary, if bad then "error" else "muted") }),
		}))
	end
	local facts = {
		kv("When", jobs.describe(job)),
		kv("Folder", C.tilde(job.cwd)),
		kv("Agent", "@" .. tostring(job.role) .. " · " .. C.approval_label(job.approval) .. " · stops after " .. C.span_text(job.max_runtime_s or 1800)),
		kv("Only when", if type(job.conditions) == "table" and #job.conditions > 0 then conditions.describe(job.conditions) else "Always runs when due"),
		kv("If asleep", C.catch_up_label(job.catch_up, job.catch_up_window_s or tonumber(jobs.settings().catchup_window_s))),
	}
	table.insert(children, C.with(ui.kv(facts), { key = "facts", role = "tas.detail-settings" }))
	local prompt = jobs.prompt(d.job_id) or ""
	table.insert(children, C.with(ui.kv({ kv("Prompt", clip(D.prompt_preview(prompt), if embedded then 160 else 240)) }), { key = "prompt", role = "tas.detail-prompt" }))
	table.insert(children, C.with(C.action_button("Open prompt file", "p", "neutral", "prompt", "prompt-file", job.id), { role = "tas.prompt-action" }))
	local counts = h.totals
	local label = string.format("%d runs · %d failed · %d missed", counts.total, counts.failed, counts.missed)
	if counts.total > #runs then label ..= string.format(" · latest %d of %d", #runs, counts.total) end
	table.insert(children, C.with(ui.rule({ ui.span(label, "muted") }), { key = "run-heading", role = "tas.run-heading" }))
	local items: { Node } = {}
	for _, r in runs do
		local node = run_item(r, now, tier)
		if sel and r.run_id == sel.run_id then node.p.mark = "pick" end
		table.insert(items, node)
	end
	table.insert(children, ui.node("list", { key = "runs", role = "tas.run-list", selected = if sel then (if embedded then C.item_id("runs", sel.run_id) else "main.detail-card.runs." .. sel.run_id) else nil, empty = { ui.span("Never run. Press r to run it now.", "muted") } }, items))
	if sel ~= nil and d.expanded == sel.run_id then table.insert(children, expanded_card(sel)) end

	-- Dock.
	local ctx: Node
	if state.armed == job.id then
		local running = #A.runs_of(job.id) > 0
		local text = if running
			then string.format("%s is running. d again stops it and deletes the job, or esc to keep it.", job.name)
			else string.format("Press d again to delete %s, or esc to keep it.", job.name)
		ctx = C.text({ ui.span(text, "warning") }, "ctx")
	elseif state.notice ~= nil and tern.now() - state.notice_at < 6000 then
		ctx = C.text({ ui.span(state.notice, "warning") }, "ctx")
	elseif sel ~= nil and sel.block ~= nil and sel.pane_closed_at == nil then
		ctx = C.text({ ui.span("⏎", "key"), ui.span(" jumps to the run's tab.", "muted") }, "ctx")
	elseif sel ~= nil and sel.session_file ~= nil then
		ctx = C.text({ ui.span("⏎", "key"), ui.span(" reopens this run's session in a new tab.", "muted") }, "ctx")
	elseif sel ~= nil and sel.block ~= nil then
		ctx = C.text({ ui.span("This run's pane is closed and its session file is gone; only the summary is kept.", "muted") }, "ctx")
	elseif sel ~= nil then
		ctx = C.text({ ui.span("This run never started a terminal. ", "muted"), ui.span("⏎", "key"), ui.span(" shows why.", "muted") }, "ctx")
	else
		ctx = C.text({ ui.span("No runs yet.", "muted") }, "ctx")
	end
	local acts: { Node } = {}
	local function add(label: string, tone: string, act: string, key: string, value: string?)
		local keys = { open_run = "enter", run = "r", edit = "e", pause = "space", delete = "dd", back = "esc", check_conditions = "i" }
		table.insert(acts, C.action_button(label, keys[act] or "", if act == "delete" then "error" else tone, act, key, value))
	end
	if sel ~= nil then
		local closed = sel.session_file ~= nil and not (sel.block ~= nil and sel.pane_closed_at == nil)
		add(if closed then "Resume run" else "Open run", "accent", "open_run", "open", sel.run_id)
	end
	add("Run now", "neutral", "run", "run", job.id)
	if type(job.conditions) == "table" and #job.conditions > 0 then
		add("Check conditions", "neutral", "check_conditions", "check", job.id)
	end
	add("Edit", "neutral", "edit", "edit", job.id)
	add(if job.enabled == false then "Resume" else "Pause", "neutral", "pause", "pause", job.id)
	local armed = state.armed == job.id
	add(if armed then "Confirm delete" else "Delete", if armed then "error" else "neutral", "delete", "delete", job.id)
	add("Back", "neutral", "back", "back")
	local back = table.remove(acts)
	local dock = ui.col({ ctx, C.with(ui.row({
		ui.node("row", { key = "job-actions", role = "tas.dock-job", gap = "xs" }, acts),
		ui.node("row", { key = "global-actions", role = "tas.dock-global", gap = "xs" }, { back }),
	}), { key = "acts", role = "tas.dock-actions" }) })
	if embedded then return ui.col(children), dock end
	return ui.col({ ui.node("col", { key = "detail-card", role = "tas.detail", gap = "sm" }, children) }), dock
end

-- Keys ----------------------------------------------------------------------------------------------------------

local function move(state: State, delta: number): boolean
	local runs = runs_of_job(state)
	local d = state.detail :: { job_id: string, sel: string?, expanded: string? }
	if #runs == 0 then
		return false
	end
	local at = 1
	for i, r in runs do
		if r.run_id == d.sel then
			at = i
		end
	end
	local j = math.clamp(at + delta, 1, #runs)
	if runs[j].run_id == d.sel then
		return false
	end
	d.sel = runs[j].run_id
	d.expanded = nil
	return true
end

local function open_selected(state: State)
	local d = state.detail :: { job_id: string, sel: string?, expanded: string? }
	local runs = runs_of_job(state)
	local run = selected_run(state, runs)
	if run == nil then
		return
	end
	if run.block ~= nil or run.session_file ~= nil then
		A.open_run(state, run.run_id)
	else
		d.expanded = if d.expanded == run.run_id then nil else run.run_id
	end
end

local function key_inner(state: State, k: Key): boolean?
	local d = state.detail :: { job_id: string, sel: string?, expanded: string? }
	local name = k.name
	local id = d.job_id
	if name == "?" or (name == "/" and k.shift) then
		S.open_help(state)
		return true
	elseif name == "," then
		S.open_settings(state)
		return true
	end
	if state.armed ~= nil and name ~= "d" then
		state.armed = nil
		if name == "escape" then
			return true
		end
	end
	if name == "escape" then
		A.back(state)
		return true
	elseif name == "j" or name == "down" then
		return move(state, 1)
	elseif name == "k" or name == "up" then
		return move(state, -1)
	elseif name == "enter" then
		open_selected(state)
		return true
	elseif name == "m" then
		local run = selected_run(state, runs_of_job(state))
		if run == nil then
			return false
		end
		d.expanded = if d.expanded == run.run_id then nil else run.run_id
		return true
	elseif name == "e" then
		A.edit(state, id)
		return true
	elseif name == "r" then
		A.run_now(state, id)
		return true
	elseif name == "i" then
		local job: any = jobs.get(id)
		if job ~= nil and type(job.conditions) == "table" and #job.conditions > 0 then
			S.check_conditions(state, id)
		else
			C.notice(state, "This job has no conditions. Press e and open Only when.")
		end
		return true
	elseif name == "space" then
		A.toggle_pause(state, id)
		return true
	elseif name == "d" then
		A.delete(state, id)
		return true
	elseif name == "p" then
		A.edit_prompt(state, id)
		return true
	elseif name == "o" then
		A.open_job_run(state, id)
		return true
	elseif name == "x" then
		A.stop_job(state, id)
		return true
	elseif name == "c" then
		A.duplicate(state, id)
		return true
	elseif name == "h" then
		return false
	end
	return false
end

function D.key(state: State, k: Key): boolean?
	-- A key that disarms a pending delete must redraw even when it does nothing else.
	local disarmed = state.armed ~= nil and k.name ~= "d"
	local handled = key_inner(state, k)
	return handled or disarmed
end

function D.event(state: State, ev: UiEvent)
	local d = state.detail
	if d == nil then
		return
	end
	local kind = ev.ev
	if kind == "select" then
		local sec, key = C.parse_item(ev.item)
		if sec == "runs" and key ~= nil then
			d.sel = key
			d.expanded = nil
		end
	elseif kind == "activate" then
		local sec, key = C.parse_item(ev.item)
		if sec == "runs" and key ~= nil then
			d.sel = key
			open_selected(state)
		end
	elseif kind == "action" then
		local act = ev.act
		local value: any = ev.value
		if act == "back" then
			A.back(state)
		elseif type(value) == "string" then
			if act == "prompt" then
				A.edit_prompt(state, value)
			elseif act == "run" then
				A.run_now(state, value)
			elseif act == "check_conditions" then
				S.check_conditions(state, value)
			elseif act == "edit" then
				A.edit(state, value)
			elseif act == "pause" then
				A.toggle_pause(state, value)
			elseif act == "delete" then
				A.delete(state, value)
			elseif act == "open_run" then
				A.open_run(state, value)
			end
		end
	end
end

return D
