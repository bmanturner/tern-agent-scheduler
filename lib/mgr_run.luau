--!strict
-- Manager "run now": checks a job's conditions first and offers Run anyway when one says no.
local C = require("./mgr_common")
local jobs = require("./jobs")
local runner = require("./runner")

type State = C.State

local R = {}

local function start(state: State, job_id: string, opts: { override: string?, toast: boolean })
	local ok, err = runner.run_now(job_id, { focus_override = opts.override })
	if ok then
		if opts.toast then
			local job: any = jobs.get(job_id)
			if job ~= nil then
				C.toast(state, "info", job.name .. " started", "@" .. job.role .. " · " .. C.tilde(job.cwd))
			end
		end
	else
		C.notice(state, err or "Couldn't start the run.")
	end
end

function R.run_now(state: State, job_id: string, opts: { override: string?, toast: boolean })
	local job: any = jobs.get(job_id)
	if job == nil then
		return
	end
	if type(job.conditions) ~= "table" or #job.conditions == 0 then
		start(state, job_id, opts)
		return
	end
	C.notice(state, "Checking conditions…")
	runner.check_conditions(job_id, function(v: any)
		if v.ok then
			state.notice = nil
			start(state, job_id, opts)
			C.render(state)
			return
		end
		state.notice = nil
		state.sheet = { kind = "run_anyway", job_id = job_id, text = v.text, code = v.code, override = opts.override }
		C.render(state)
	end)
end

return R
