-- Two Tern windows: sessions are per window and the host has none, so every tern call must name the window
-- holding the pane, runs open in the window they were started from, and liveness reads every window.
local jobs, runner, ledger = __mods.jobs, __mods.runner, __mods.ledger

fake.dirs["/home/u/proj"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))
fake.windows = { "", "2" }
table.insert(fake.sessions, { id = 1, name = "Default", shown = true, tabs = {}, window = "2" }) -- the session window 2 shows

runner.load()
fake.advance(1000)
local job = jobs.create({ name = "job-w", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "Do it", "user", os.time())
assert(job, "job created")

local function run_of()
	for _, r in ipairs(runner.inflight()) do
		if r.job_id == job.id then
			return r
		end
	end
end
local function started()
	local r = run_of()
	return r ~= nil and r.state == "running"
end
local function last(key)
	for i = #fake.calls, 1, -1 do
		if fake.calls[i].key == key then
			return fake.calls[i]
		end
	end
end
local function finish(run)
	fake.exit_block(tonumber(run.block), 0)
	fake.emit("pane_exited", { pane = tonumber(run.block), status = 0 })
	assert(fake.run_until(function() return run_of() == nil end, 60000, 1000), "run finished")
end

-- 1. Nobody said which window: the run opens in the first window, as before.
assert(runner.run_now(job.id, nil), "run_now")
assert(fake.run_until(started, 30000, 500), "first run started")
local r1 = run_of()
assert(last("new").window == nil, "no --window without a known window")
assert(fake.window_of(tonumber(r1.block)) == "", "pane in the first window")
print("PASS no window known: first window")

-- 2. Open run from window 2 finds the pane in the first window, focuses it there and says so.
local got_ok, got_err, got_else
runner.open_run(r1.run_id, function(ok, err, elsewhere)
	got_ok, got_err, got_else = ok, err, elsewhere
end, { window = "2" })
fake.advance(500)
assert(got_ok == true and got_else == true, "shown in the other window: " .. tostring(got_err))
assert(last("focus").window == "", "focus names the pane's window")
runner.open_run(r1.run_id, function(ok, _err, elsewhere)
	got_ok, got_else = ok, elsewhere
end, { window = "" })
fake.advance(500)
assert(got_ok == true and got_else == false, "same window: not elsewhere")
print("PASS open run focuses the pane in its own window")
finish(r1)

-- 3. Started from window 2: launched, renamed and tracked there; liveness reads every window.
assert(runner.run_now(job.id, { origin = { window = "2" } }), "run_now from window 2")
assert(fake.run_until(started, 30000, 500), "second run started")
local r2 = run_of()
assert(last("new").window == "2" and last("rename").window == "2", "new and rename name window 2")
assert(fake.window_of(tonumber(r2.block)) == "2" and r2.window == "2", "pane and record in window 2")
fake.advance(40000) -- slow ticks: a first-window-only read would call this pane closed by the user
assert(run_of() ~= nil and run_of().state == "running", "still running after liveness passes")
print("PASS run started from window 2 lives there")

-- 4. A run with no pane resumes in the requesting window.
finish(r2)
local rec = ledger.get(r2.run_id)
rec.session_file = "/d/runs/" .. job.id .. "/" .. r2.run_id .. "/session/s.jsonl"
fake.remove_block(tonumber(r2.block))
runner.open_run(r2.run_id, function(ok, err)
	got_ok, got_err = ok, err
end, { window = "2" })
fake.advance(500)
assert(got_ok == true, "resumed: " .. tostring(got_err))
local resume = last("new")
assert(resume.window == "2" and fake.join(resume.argv):find("--resume", 1, true), "resume opens in window 2")
print("PASS resume opens in the requesting window")

-- 5. Runs nobody started from a window follow the last window used; a closed window falls back to the first.
assert(runner.run_now(job.id, nil), "run_now without origin")
assert(fake.run_until(started, 30000, 500), "third run started")
assert(last("new").window == "2" and fake.window_of(tonumber(run_of().block)) == "2", "last used window")
finish(run_of())
fake.windows = { "" }
assert(runner.run_now(job.id, nil), "run_now after window 2 closed")
assert(fake.run_until(started, 30000, 500), "fourth run started")
assert(fake.window_of(tonumber(run_of().block)) == "", "fell back to the first window")
assert(run_of().window == nil, "record says first window")
print("PASS closed window falls back to the first")
assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
