--!strict
-- Manager actions on jobs and runs shared by the list and detail views (keys and badge clicks both call these).

local C = require("./mgr_common")
local F = require("./mgr_form")
local S = require("./mgr_sheets")
local const = require("./const")
local jobs = require("./jobs")
local runner = require("./runner")

local A = {}

type State = C.State

local function job_of(job_id: string): any
	return jobs.get(job_id)
end

-- The in-flight runs of a job, oldest first.
function A.runs_of(job_id: string): { any }
	local out: { any } = {}
	for _, r in runner.inflight() do
		local run: any = r
		if run.job_id == job_id then
			table.insert(out, run)
		end
	end
	return out
end

function A.new_job(state: State)
	F.open_new(state, { cwd = state.cwd_hint })
end

function A.edit(state: State, job_id: string)
	if job_of(job_id) ~= nil then
		F.open_edit(state, job_id)
	end
end

function A.duplicate(state: State, job_id: string)
	local job = job_of(job_id)
	if job == nil then
		return
	end
	local sched: any = job.schedule
	local name: string = job.name .. " copy"
	if (utf8.len(name) or #name) > const.NAME_MAX then
		name = string.sub(name, 1, const.NAME_MAX)
	end
	F.open_new(state, {
		name = name,
		prompt = jobs.prompt(job_id) or "",
		when = if type(sched) == "table" and type(sched.input) == "string" then sched.input else "manual",
		cwd = job.cwd,
		role = job.role,
		enabled = false,
		catch_up = job.catch_up,
		approval = job.approval,
		stop_s = job.max_runtime_s,
		window_s = job.catch_up_window_s,
	})
end

function A.run_now(state: State, job_id: string)
	local job = job_of(job_id)
	if job == nil then
		return
	end
	local ok, err = runner.run_now(job_id)
	if ok then
		C.toast(state, "info", job.name .. " started", "@" .. job.role .. " · " .. C.tilde(job.cwd))
	else
		C.notice(state, err or "Couldn't start the run.")
	end
end

function A.toggle_pause(state: State, job_id: string)
	local job = job_of(job_id)
	if job == nil then
		return
	end
	if job.enabled ~= false then
		jobs.pause(job_id, "user")
		runner.changed()
		C.toast(state, "success", "Paused " .. job.name)
		return
	end
	jobs.resume(job_id, C.now())
	runner.changed()
	local js: any = jobs.state(job_id)
	local nxt = if type(js) == "table" then js.next_run else nil
	C.toast(state, "success", "Resumed " .. job.name, if type(nxt) == "number" then "next " .. C.abs(nxt) else "manual only")
end

-- First call arms, second deletes (stopping its running runs first). True when it deleted.
function A.delete(state: State, job_id: string): boolean
	local job = job_of(job_id)
	if job == nil then
		return false
	end
	if state.armed ~= job_id then
		state.armed = job_id
		return false
	end
	state.armed = nil
	for _, run in A.runs_of(job_id) do
		runner.stop(run.run_id)
	end
	if not jobs.delete(job_id, C.now()) then
		return false
	end
	runner.changed()
	C.toast(state, "success", "Deleted " .. job.name, "press u to undo")
	if state.mode == "detail" then
		state.mode = "list"
		state.detail = nil
	end
	return true
end

function A.undo(state: State): boolean
	local job: any = jobs.undo_delete(C.now())
	if job == nil then
		return false
	end
	runner.changed()
	state.sel = { sec = "upcoming", key = job.id }
	C.toast(state, "success", "Restored " .. job.name)
	return true
end

function A.pause_all(state: State)
	local s = jobs.settings()
	local on = s.paused_all ~= true
	jobs.set_paused_all(on)
	runner.changed()
	C.toast(state, "info", if on then "All jobs paused" else "All jobs resumed", "running jobs keep going")
end

-- Opens a run's terminal: focus when its pane lives, else resume its session in a new tab.
function A.open_run(state: State, run_id: string)
	runner.open_run(run_id, function(ok, err)
		if not ok then
			C.notice(state, err or "Couldn't open the run.")
			C.render(state)
		end
	end)
end

-- The live run of a job, else its last run.
function A.open_job_run(state: State, job_id: string)
	local runs = A.runs_of(job_id)
	local first = runs[1]
	if first ~= nil then
		A.open_run(state, first.run_id)
		return
	end
	local js: any = jobs.state(job_id)
	local last: any = if type(js) == "table" then js.last_run else nil
	if type(last) == "table" and type(last.run_id) == "string" then
		A.open_run(state, last.run_id)
	else
		C.notice(state, "This job hasn't run yet.")
	end
end

-- Confirm overlay for stopping a run.
function A.stop_run(state: State, run_id: string)
	S.confirm_stop(state, run_id)
end

function A.stop_job(state: State, job_id: string)
	local first = A.runs_of(job_id)[1]
	if first == nil then
		C.notice(state, "Nothing is running for this job.")
		return
	end
	S.confirm_stop(state, first.run_id)
end

function A.edit_prompt(state: State, job_id: string)
	if job_of(job_id) == nil then
		return
	end
	local path = tern.plugin.data .. "/prompts/" .. job_id .. ".md"
	local ok = pcall(function()
		state.cx:open(path)
	end)
	if not ok then
		C.notice(state, "Couldn't open the prompt file.")
	end
end

function A.open_detail(state: State, job_id: string)
	if job_of(job_id) == nil then
		return
	end
	state.mode = "detail"
	state.detail = { job_id = job_id, sel = nil, expanded = nil }
	state.armed = nil
end

function A.back(state: State)
	state.mode = "list"
	state.detail = nil
	state.armed = nil
end

return A
