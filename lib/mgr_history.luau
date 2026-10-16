--!strict
-- Host-owned counters survive ledger retention. Older installations can only seed retained history.
local jobs = require("./jobs")
local ledger = require("./ledger")
local H = {}
local TERMINAL = { finished = true, failed = true, timed_out = true, blocked = true, missed = true, cancelled = true, skipped = true }
function H.failed(r: any): boolean
	return r.state == "failed" or r.state == "timed_out" or r.state == "blocked"
end
local function add(c: any, r: any)
	local n = tonumber(r.count) or 1
	c.total += n
	if H.failed(r) then c.failed += n
	elseif r.state == "missed" then c.missed += n
	elseif r.state == "skipped" then c.skipped += n
	elseif r.state == "finished" then c.ok += n end
end
local function empty(): any
	return { total = 0, failed = 0, missed = 0, skipped = 0, ok = 0 }
end
function H.ensure(id: string): any
	local st: any = jobs.state(id)
	if type(st.manager_history) == "table" then return st.manager_history end
	local h = { totals = empty(), pending = empty(), latest = nil, failed = false }
	local runs = ledger.recent(id, 10000)
	for i = #runs, 1, -1 do
		local r = runs[i]
		if TERMINAL[r.state] and r.trigger ~= "test" then
			add(h.totals, r)
			if (r.ended or r.slot or 0) > (jobs.settings().last_looked or 0) then add(h.pending, r) end
			h.latest = r.run_id
			if H.failed(r) then h.failed = true elseif r.state == "finished" then h.failed = false end
		end
	end
	st.manager_history = h
	return h
end
function H.record(run: any)
	if not TERMINAL[run.state] or run.trigger == "test" then return end
	local st: any = jobs.state(run.job_id)
	local existed = type(st.manager_history) == "table"
	local h = H.ensure(run.job_id)
	-- First seed already includes this just-persisted outcome.
	if existed and h.latest ~= run.run_id then
		add(h.totals, run)
		add(h.pending, run)
	end
	h.latest = run.run_id
	if H.failed(run) then h.failed = true elseif run.state == "finished" then h.failed = false end
end
function H.clear(at: number)
	for _, j in jobs.list() do
		local pending = empty()
		for _, r in ledger.recent(j.id, 10000) do
			if TERMINAL[r.state] and r.trigger ~= "test" and (r.ended or r.slot or 0) > at then add(pending, r) end
		end
		H.ensure(j.id).pending = pending
	end
	jobs.set_settings({ last_looked = math.max(at, jobs.settings().last_looked or 0) })
	jobs.save_state()
end
return H
