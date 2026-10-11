-- A one-shot job turns itself off as soon as its run is claimed; that run must still launch (regression:
-- it was cancelled as "Stopped by you" by the check for jobs paused while a run waits). A user pause of a
-- recurring job while its run waits still cancels it.
local jobs, runner, ledger = __mods.jobs, __mods.runner, __mods.ledger

fake.dirs["/home/u/proj"] = true
fake.write(fake.omp_bin, "binary")
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))
runner.load()
fake.advance(1000)

local once = assert(jobs.create({ name = "once", prompt = "x", when = "in 2m", cwd = "/home/u/proj" }, "do it", "user", os.time()))
runner.changed()
local run
assert(fake.run_until(function()
	for _, r in ipairs(runner.inflight()) do
		if r.job_id == once.id then
			run = r
		end
	end
	return run ~= nil and run.state == "running"
end, 240000, 1000), "the one-shot run reaches running")
assert(#fake.calls_of("new") == 1, "one launch")
assert(jobs.get(once.id).enabled == false and jobs.state(once.id).done == true, "the one-shot is done")
print("PASS one-shot run launches although the job turned itself off")
runner.stop(run.run_id)
fake.advance(10000)

-- a recurring job paused by the user while its claimed run waits on the cap is cancelled
assert(jobs.set_settings({ max_concurrent = 1 }))
local busy = assert(jobs.create({ name = "busy", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "x", "user", os.time()))
local every = assert(jobs.create({ name = "every", prompt = "x", when = "every 5m", cwd = "/home/u/proj" }, "x", "user", os.time()))
runner.changed()
assert(runner.run_now(busy.id))
assert(fake.run_until(function()
	local r = runner.inflight()[1]
	return r ~= nil and r.state == "running"
end, 30000, 500), "busy run holds the cap")
local waiting
assert(fake.run_until(function()
	for _, r in ipairs(runner.inflight()) do
		if r.job_id == every.id and r.state == "scheduled" then
			waiting = r
		end
	end
	return waiting ~= nil
end, 400000, 1000), "the recurring run waits on the cap")
jobs.pause(every.id, "user")
runner.changed()
fake.advance(5000)
local rec = ledger.get(waiting.run_id)
assert(rec.state == "cancelled" and rec.reason_code == "user_stop", "user pause cancels the waiting run: " .. tostring(rec.state))
print("PASS user pause cancels a waiting recurring run")
