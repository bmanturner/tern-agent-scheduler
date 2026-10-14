--!strict
-- Live rows of the manager list: in-flight runs drawn with Tern's `agent` element (pulse, model, tool count, cost,
-- live timer, and a second line for what the agent does now) and upcoming rows with a live countdown.
-- Neither node is a list `item`, so selection is drawn with `mark = "pick"` and kept in state; clicks send the
-- `pick` and `open` actions (value = the row's item id), handled by mgr_list's event function.

local ui = tern.ui
local C = require("./mgr_common")
local jobs = require("./jobs")
local runner = require("./runner")

local M = {}

type Row = C.Row

-- Under this many seconds a next run shows a ticking countdown instead of static "in 38m".
M.COUNTDOWN_S = 3600

local function clip(text: string, max: number): string
	local first = string.match(text, "^[^\r\n]*") or ""
	if (utf8.len(first) or #first) <= max then
		return first
	end
	return string.sub(first, 1, (utf8.offset(first, max) or max + 1) - 1) .. "…"
end

local function ms_since(now: number, t: number): number
	return math.max(0, math.floor((now - t) * 1000))
end

-- True when the row's next run is close enough for a countdown.
function M.counts_down(row: Row, now: number): boolean
	if row.sec ~= "upcoming" or row.js == nil then
		return false
	end
	local nxt: any = (row.js :: any).next_run
	return type(nxt) == "number" and nxt > now and nxt - now < M.COUNTDOWN_S
end

-- One in-flight run (needs you, running, queued or starting) as an `agent` node.
function M.agent_row(row: Row, now: number, tier: number, selected: boolean): Node
	local job: any = row.job
	local run: any = row.run
	local live: any = runner.live(run.run_id)
	local needs = row.sec == "needs"

	local since: number = run.started or run.state_since or run.created or now
	local msg: string? = nil
	local lm: any = if live ~= nil and live.last_message ~= nil then live.last_message else run.last_message
	if type(lm) == "string" and lm ~= "" then
		msg = lm
	end

	local status = "running"
	local task: string? = nil
	if needs then
		status = "idle"
		task = if msg ~= nil then clip(msg, 90) else "Waiting for you."
	elseif run.state == "launching" then
		status = "pending"
		task = "Starting…"
	elseif run.state == "scheduled" then
		status = "pending"
		task = "Queued"
	elseif msg ~= nil then
		-- The agent's latest line says more than the schedule, which the Upcoming row already shows.
		task = clip((msg:gsub("%s+", " ")), 120)
	elseif tier >= 4 and job.cwd ~= nil and job.cwd ~= "" then
		task = C.tilde(job.cwd)
	else
		task = jobs.describe(job)
	end
	if tier < 2 then
		task = nil
	end

	local badges: { { text: string, tone: string? } } = {}
	if needs then
		local waited = if type(run.state_since) == "number" then run.state_since else since
		table.insert(badges, { text = "needs you · " .. C.span_text(now - waited), tone = "warning" })
	end
	if tier >= 3 then
		table.insert(badges, { text = "@" .. tostring(job.role) })
	end
	if job.created_by == "carly" then
		table.insert(badges, { text = if tier >= 3 then "by Carly" else "✦" })
	end

	local stats: { [string]: any } = { age = ms_since(now, since) }
	local model: string? = nil
	if live ~= nil or run.model ~= nil then
		local m: any = if live ~= nil and live.model ~= nil then live.model else run.model
		if type(m) == "string" and m ~= "" then
			model = m
		end
	end
	if tier >= 2 and live ~= nil then
		if type(live.tools) == "number" then
			stats.tools = live.tools
		end
		if tier >= 3 and type(live.requests) == "number" then
			stats.requests = live.requests
		end
	end
	if tier >= 3 then
		local cost: any = if live ~= nil and live.cost ~= nil then live.cost else run.cost
		if type(cost) == "number" then
			stats.cost = cost
		end
	else
		model = nil
	end

	local tool: { [string]: any }? = nil
	if status == "running" and tier >= 2 then
		if live ~= nil and live.tool ~= nil then
			local t: any = live.tool
			local entry: { [string]: any } = { name = t.name, intent = if type(t.detail) == "string" then clip(t.detail, 120) else "" }
			if type(t.since) == "number" then
				entry.age = ms_since(now, t.since)
			end
			tool = entry
		end
	end

	local props: { [string]: any } = {
		key = row.key,
		name = job.name,
		status = status,
		task = task,
		badges = badges,
		model = model,
		stats = stats,
		tool = tool,
		mark = if selected then "pick" else nil,
		actions = { click = "pick=" .. row.id, dblclick = "open=" .. row.id },
		aria = string.format("%s, %s", job.name, if needs then "needs you" else status),
	}
	if needs then
		props.tone = "warning"
	end
	return ui.node("agent", props)
end

-- An upcoming row whose next run is under an hour away: the absolute time stays, the "in …" part ticks.
function M.countdown_row(row: Row, now: number, tier: number, selected: boolean, label: Spans, detail: string?): Node
	local js: any = row.js
	local nxt: number = js.next_run
	local soon = nxt - now < 300
	local tone = if soon then "accent" else "muted"
	local last: any = js.last_run
	local failed = require("./mgr_history").ensure((row.job :: any).id).failed
	-- Same parts as a list `item` (icon, label, detail, value); manager.css gives the row an item's metrics.
	local parts: { Node } = {
		ui.node("icon", { key = "i", name = if failed then "x-circle" else "clock", tone = if failed then "error" else "muted" }),
		C.with(ui.text(label), { key = "l" }),
		C.with(ui.text({ ui.span(detail or "", "muted") }), { key = "d", grow = 1, shrink = 1 }),
	}
	local when = (if tier >= 3 then C.when_text(nxt, now) .. " · " else "") .. C.in_text(nxt, now)
	table.insert(parts, C.with(ui.text({ ui.span(when, tone .. " mono") }), { key = "w" }))
	return ui.node("row", {
		key = row.key,
		role = "tas.soon",
		mark = if selected then "pick" else nil,
		actions = { click = "pick=" .. row.id, dblclick = "open=" .. row.id },
		aria = string.format("%s, next run in %s", (row.job :: any).name, C.span_text(nxt - now)),
	}, parts)
end

return M
