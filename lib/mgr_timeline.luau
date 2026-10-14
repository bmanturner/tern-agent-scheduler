--!strict
local timefmt = require("./timefmt")
-- Timeline projection shares the classic list's selection and action routing.
local C = require("./mgr_common")
local jobs = require("./jobs")
local ledger = require("./ledger")
local H = require("./mgr_history")
local ui = tern.ui
local T = {}
local TERMINAL = { finished = true, failed = true, timed_out = true, blocked = true, skipped = true, missed = true, cancelled = true }
local GLYPH = { finished = "✓", failed = "✗", timed_out = "✗", blocked = "✗", skipped = "↷", missed = "◌", cancelled = "■" }
function T.clear(state: any)
	H.clear(C.now())
	state.looked_at = C.now()
	state.history_baseline = nil
	state.seen_results = {}
	C.notice(state, "All results marked seen.")
end
function T.model(state: any, model: any, frame_now: number?): any
	local results, nexts, bottom, live = {}, {}, {}, {}
	local since = state.looked_at or jobs.settings().last_looked or 0
	local busy = {}
	for _, sec in model.sections do
		for _, row in sec.rows do
			if row.kind == "run" then busy[row.job.id] = true; table.insert(live, row) end
		end
	end
	for _, sec in model.sections do
		for _, row in sec.rows do
			if row.kind ~= "run" and not busy[row.job.id] then
				if row.kind == "job" and sec.id == "upcoming" and row.job.schedule.kind ~= "manual" then table.insert(nexts, row)
				else table.insert(bottom, row) end
			end
		end
	end
	state.history_baseline = state.history_baseline or {}
	local counts, total = {}, 0
	for _, j in jobs.list() do
		local h = H.ensure(j.id)
		local base = state.history_baseline[j.id]
		if base == nil then
			base = {}
			for k, n in h.totals do base[k] = n - (h.pending[k] or 0) end
			state.history_baseline[j.id] = base
		end
		local c = {}
		for k, n in h.totals do c[k] = math.max(0, n - (base[k] or 0)) end
		counts[j.id] = c
		total += c.total
		for _, r in ledger.recent(j.id, 500) do
			if TERMINAL[r.state] and r.trigger ~= "test" and (r.ended or r.slot or 0) > since then
				table.insert(results, { sec = "results", key = r.run_id, id = C.item_id("results", r.run_id), kind = "result", job = j, run = r, js = jobs.state(j.id) })
			end
		end
	end
	table.sort(results, function(a, b)
		local x, y = a.run.ended or a.run.slot or 0, b.run.ended or b.run.slot or 0
		return if x == y then a.key < b.key else x < y
	end)
	if total > 8 then
		-- Failures keep their own rows (pinned above). Each other job folds into one summary row whose
		-- "latest" names its newest result that isn't pinned, so a failure is never shown twice.
		local folded, latest, singles = {}, {}, {}
		for _, row in results do
			if H.failed(row.run) then
				table.insert(folded, row)
			else
				latest[row.job.id] = row
			end
		end
		for _, j in jobs.list() do
			local c = counts[j.id]
			local r = latest[j.id]
			if c.total == 1 and r ~= nil then
				-- One new run: show it as itself; a summary of one reads oddly.
				table.insert(singles, r)
			elseif c.total > 1 then
				local parts = {}
				local function add(n: number?, word: string)
					if (n or 0) > 0 then table.insert(parts, string.format("%d %s", n, word)) end
				end
				add(c.ok, "finished")
				add(c.skipped, "skipped")
				add(c.missed, "missed")
				add(c.failed, "failed, shown above")
				local text = string.format("%d %s since %s: %s", c.total, if c.total == 1 then "run" else "runs", if since > 0 then timefmt.date("%a", since) else "your first visit", table.concat(parts, ", "))
				if r then text ..= " · latest “" .. tostring(r.run.summary or r.run.reason or r.run.state) .. "”" end
				table.insert(folded, { sec = "results", key = j.id, id = C.item_id("results", j.id), kind = "result", job = j, run = if r then r.run else {}, js = jobs.state(j.id), error = text })
			end
		end
		for _, r in singles do table.insert(folded, r) end
		results = folded
	end
	model.sections, model.flat, model.by_id = {}, {}, {}
	local function section(id, title, rows)
		local sec = { id = id, title = title, rows = rows, collapsed = false, count = #rows }
		table.insert(model.sections, sec)
		for _, row in rows do
			row.sec = id; row.id = C.item_id(id, row.key)
			table.insert(model.flat, row); model.by_id[row.id] = row
		end
	end
	section("results", "You last looked " .. (if since > 0 then C.abs(since) else "— first visit"), results)
	-- Keep needs/running section identities for their existing key semantics.
	section("now", "now · " .. timefmt.date("%H:%M", frame_now or C.now()), {})
	local needs, running = {}, {}
	for _, r in live do table.insert(if r.sec == "needs" then needs else running, r) end
	if #needs > 0 then section("needs", "Needs you", needs) end
	if #running > 0 then section("running", "Running", running) end
	section("upcoming", "Next runs", nexts)
	if #bottom > 0 then section("rest", "Paused & needs fixing", bottom) end
	return model
end
function T.result(state: any, row: any): Node
	local r = row.run
	local seen = state.seen_results or {}
	state.seen_results = seen
	local stamp = row.key .. ":" .. tostring(r.ended or r.slot or 0)
	local fresh = not seen[stamp]
	local bad = H.failed(r)
	local text = row.error or tostring(r.summary or r.reason or r.state or "No result recorded")
	text = string.match(text, "^[^\r\n]*") or text
	local status = if r.outcome_flag == "quiet" then "quiet" else string.gsub(r.state or "finished", "_", " ")
	local time = if row.error then "" else timefmt.date("%a %H:%M", r.started or r.created or r.slot or C.now()) .. "  "
	local node = ui.node("item", { key = row.key, role = if fresh then (if bad then "tas.new-failed" else "tas.new") else "tas.seen",
		label = { ui.span(time, "mono"), ui.span((GLYPH[r.state] or "·") .. " " .. row.job.name, "strong"), ui.span(" · " .. status, if bad then "error" else "muted") },
		detail = { ui.span(text, if bad then "error" else "muted") },
		value = if not row.error and r.started and r.ended then { ui.span(C.duration_text(r.ended - r.started) .. " · " .. C.cost_text(r.cost), "mono") } else nil })
	-- Tern has no block visibility/closed event. A host timer is the documented fallback.
	-- Never clear while a form/sheet covers the list; fresh outcomes get their own timer.
	state.seen_pending = state.seen_pending or {}
	if fresh and not state.seen_pending[stamp] and state.sheet == nil and jobs.settings().manager_results ~= "stay" then
		state.seen_pending[stamp] = true
		local checkpoint = C.now()
		tern.timer(3000, function()
			state.seen_pending[stamp] = nil
			if state.mode ~= "list" or state.sheet ~= nil or jobs.settings().manager_results == "stay" then return end
			local alive = false
			for _, p in tern.pane.list() do if p.pane == state.cx.pane then alive = true end end
			if not alive then return end
			seen[stamp] = true
			-- Keep this visit's rows in place; the next visit starts from this checkpoint.
			H.clear(checkpoint)
			C.render(state)
		end)
	end
	return node
end
return T
