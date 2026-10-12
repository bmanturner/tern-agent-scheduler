-- Review fixes in the runner: policy previous slot (F4) and truncated scans (F8), Pause all vs a run waiting on
-- the cap (F2), the clock moving back (F6), an orphan re-queue never closing the live pane (F5), the finished
-- catch_up=always run surviving a restore (F9), global placement (F34), run_now copy (F77).
local function modules()
	return __mods.jobs, __mods.runner, __mods.ledger
end
local jobs, runner, ledger = modules()
local cron, policy = __mods.cron, __mods.policy

fake.dirs["/home/u/proj"] = true
fake.write(fake.omp_bin, "binary") -- the preflight now checks that the resolved omp still exists (F12)
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))

-- F4: missed.last is the real previous slot, not latest - 1
local function pjob(expr, cursor, extra)
	local j = { sched = { kind = "cron", spec = cron.parse(expr) }, cursor = cursor }
	for k, v in pairs(extra or {}) do
		j[k] = v
	end
	return j
end
local r4 = policy.decide(pjob("0 9 * * 1-5", fake.chicago(2026, 10, 9, 9, 0, 0)), fake.chicago(2026, 10, 14, 10, 0, 0))
assert(r4.fire ~= nil and r4.fire.slot == fake.chicago(2026, 10, 14, 9, 0, 0), "Wednesday 09:00 fires")
assert(r4.missed.count == 2 and r4.missed.last == fake.chicago(2026, 10, 13, 9, 0, 0), "last missed slot is Tue 09:00, got " .. os.date("%a %H:%M", r4.missed.last))
local r4b = policy.decide(pjob("0 9 * * 1-5", fake.chicago(2026, 10, 8, 9, 0, 0)), fake.chicago(2026, 10, 12, 10, 0, 0))
assert(r4b.missed.count == 1 and r4b.missed.last == fake.chicago(2026, 10, 9, 9, 0, 0), "single missed slot is Fri 09:00, got " .. os.date("%a %H:%M", r4b.missed.last))
print("PASS F4 missed.last is a real slot")

-- F8: a frequent cron left over a weekend still catches up to its true latest slot
local now8 = fake.chicago(2026, 10, 12, 10, 3, 0)
local r8 = policy.decide(pjob("*/5 * * * *", now8 - 62 * 3600), now8)
assert(r8.fire ~= nil and r8.fire.slot == fake.chicago(2026, 10, 12, 10, 0, 0), "fires the latest slot, got " .. (r8.fire and os.date("%a %H:%M", r8.fire.slot) or "nil"))
assert(r8.missed ~= nil and r8.missed.approx == true and r8.missed.last < r8.fire.slot, "older slots reported approximately, before the fired slot")
assert(r8.next_run == fake.chicago(2026, 10, 12, 10, 5, 0), "next run follows now")
print("PASS F8 truncated scan finds the true latest slot")

runner.load()
fake.advance(1000)

-- F2: Pause all while a run waits on the concurrency cap => skipped, never launched
assert(jobs.set_settings({ max_concurrent = 1 }))
local a = jobs.create({ name = "cap-a", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "first", "user", os.time())
local b = jobs.create({ name = "cap-b", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "second", "user", os.time())
assert(runner.run_now(a.id))
assert(fake.run_until(function()
	local r = runner.inflight()[1]
	return r ~= nil and r.state == "running"
end, 30000, 500), "first run is running")
assert(runner.run_now(b.id))
local waiting
assert(fake.run_until(function()
	for _, r in ipairs(runner.inflight()) do
		if r.job_id == b.id and r.state == "scheduled" and r.reason_code == "waiting_cap" then
			waiting = r
		end
	end
	return waiting ~= nil
end, 30000, 500), "second run waits on the cap")
assert(#fake.calls_of("new") == 1, "one launch so far")
jobs.set_paused_all(true)
runner.changed()
fake.advance(5000)
local rec_b = ledger.get(waiting.run_id)
assert(rec_b.state == "skipped" and rec_b.reason_code == "paused_all", "skipped/paused_all: " .. tostring(rec_b.state) .. "/" .. tostring(rec_b.reason_code))
local ok_now, why = runner.run_now(b.id)
assert(ok_now == false and why == "Resume all jobs to run.", "run_now refused with a full sentence: " .. tostring(why))
jobs.set_paused_all(false)
runner.changed()
-- free the cap and make sure the skipped run never launches afterwards
runner.stop(runner.inflight()[1].run_id)
fake.advance(60000)
assert(#fake.calls_of("new") == 1, "the skipped run never launched, launches: " .. #fake.calls_of("new"))
print("PASS F2 Pause all skips a run waiting on the cap")

-- F77: the in-progress refusal is a sentence too
assert(jobs.set_settings({ max_concurrent = 3 }))
assert(runner.run_now(a.id))
local ok2, why2 = runner.run_now(a.id)
assert(ok2 == false and why2 == "A run is already in progress.", "in-progress copy: " .. tostring(why2))
assert(fake.run_until(function()
	local r = runner.inflight()[1]
	return r ~= nil and r.state == "running"
end, 30000, 500), "running")
runner.stop(runner.inflight()[1].run_id)
fake.advance(20000)
print("PASS F77 run_now copy")

-- F34: where runs appear is the global setting, read at launch
fake.sessions[1].shown = true
assert(jobs.set_settings({ defaults = { placement = { where = "tab" } } }))
local before = #fake.calls_of("new")
assert(runner.run_now(b.id))
assert(fake.run_until(function()
	return #fake.calls_of("new") > before
end, 30000, 500), "launched")
local argv = fake.calls_of("new")[#fake.calls_of("new")]
assert(argv[3] == "tab" and argv[4] == "--json", "background tab in the shown session (no session name): " .. fake.join(argv))
assert(fake.run_until(function()
	return runner.inflight()[1] ~= nil and runner.inflight()[1].state == "running"
end, 30000, 500), "running")
runner.stop(runner.inflight()[1].run_id)
fake.advance(20000)
assert(jobs.set_settings({ defaults = { placement = { where = "session" } } }))
before = #fake.calls_of("new")
assert(runner.run_now(b.id))
assert(fake.run_until(function()
	return #fake.calls_of("new") > before
end, 30000, 500), "launched again")
argv = fake.calls_of("new")[#fake.calls_of("new")]
assert(argv[3] == "tab" and argv[4] == "Scheduled runs", "back to the Scheduled runs session: " .. fake.join(argv))
assert(fake.run_until(function()
	return runner.inflight()[1] ~= nil and runner.inflight()[1].state == "running"
end, 30000, 500), "running")
runner.stop(runner.inflight()[1].run_id)
fake.advance(20000)
print("PASS F34 placement read from settings")

-- F6: the wall clock moves back an hour: the slow tick (heartbeat) keeps running
fake.advance(20000)
local hb0 = runner.health().hb
assert(os.time() - hb0 <= 20, "heartbeat fresh before the jump")
fake.jump_wall(-3600)
fake.advance(40000)
local hb1 = runner.health().hb
assert(hb1 <= os.time() and os.time() - hb1 <= 20, "heartbeat follows the moved-back clock, hb=" .. tostring(hb1) .. " now=" .. os.time())
print("PASS F6 slow tick survives the clock moving back")

-- F9 + F5 need a restart: a launch that never reported, and a claimed always-late slot
local orphan_job = jobs.create({ name = "orphan", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "orphan", "user", os.time())
local late_job = jobs.create({ name = "late-always", prompt = "x", when = "0 9 * * *", cwd = "/home/u/proj", catch_up = "always" }, "late", "user", os.time())
local run_orphan = ledger.new(orphan_job, { run_id = "r_" .. orphan_job.id:sub(3) .. "_1760000000", trigger = "manual", slot = os.time(), now = os.time() })
assert(ledger.transition(run_orphan, "launching", nil, {}, os.time()))
table.insert(jobs.inflight(), run_orphan.run_id)
ledger.save(run_orphan)
local run_late = ledger.new(late_job, { run_id = "r_" .. late_job.id:sub(3) .. "_1760000001", trigger = "schedule", slot = os.time() - 6 * 3600, now = os.time() - 6 * 3600 })
table.insert(jobs.inflight(), run_late.run_id)
ledger.save(run_late)
jobs.save_state()

fake.events = {}
for _, name in ipairs({ "jobs", "ledger", "store", "snapshot", "bins", "roles", "runner", "launcher", "intents", "notify", "tern_state", "session_tail", "validate", "ids", "cond_eval" }) do
	rawset(__mods, name, nil)
end
jobs, runner, ledger = modules()
runner.load()
fake.advance(1000)
local closes0 = #fake.calls_of("close")
fake.latency = 20000 -- every spawn takes 20 s: the preflight outlasts the 15 s liveness pass
local function news_for(run_id)
	local n = 0
	for _, argv in ipairs(fake.calls_of("new")) do
		if table.concat(argv, " "):find(run_id, 1, true) then
			n += 1
		end
	end
	return n
end
fake.advance(600000)
local o = ledger.get(run_orphan.run_id)
assert(o.state == "running" and o.block ~= nil, "orphan relaunched exactly once and running: " .. tostring(o.state))
assert(news_for(run_orphan.run_id) == 1, "one tern new for the orphan, got " .. news_for(run_orphan.run_id))
assert(#fake.calls_of("close") == closes0, "the live pane was not closed by a duplicate attempt")
print("PASS F5 orphan re-queue launches once and keeps its pane")
fake.latency = 0

local l = ledger.get(run_late.run_id)
assert(l.state ~= "missed", "catch_up=always keeps a claimed late slot: " .. tostring(l.state) .. "/" .. tostring(l.reason_code))
print("PASS F9 catch_up=always survives restore")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
