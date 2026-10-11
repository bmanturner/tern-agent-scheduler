-- Reload / daemon-restart reconcile (EN §5.4, V29): files and panes survive, the host VM state does not.
local function modules()
	return __mods.jobs, __mods.runner, __mods.ledger
end
local jobs, runner, ledger = modules()

fake.dirs["/home/u/proj"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))
runner.load()
fake.advance(1000)

local keeper = jobs.create({ name = "keeper", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "keep going", "user", os.time())
local restarted = jobs.create({ name = "restarted", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "lose pane", "user", os.time())
local lost = jobs.create({ name = "lost-launch", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "orphan", "user", os.time())
local stale = jobs.create({ name = "stale", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "late", "user", os.time())

local function start(job)
	assert(runner.run_now(job.id))
	local run
	assert(fake.run_until(function()
		for _, r in ipairs(runner.inflight()) do
			if r.job_id == job.id and r.state == "running" then
				run = r
			end
		end
		return run ~= nil
	end, 30000, 500), "running: " .. job.name)
	return run
end
local run_keep = start(keeper)
local run_restart = start(restarted)
local block_keep, block_restart = run_keep.block, run_restart.block

-- a launch whose `tern new` was lost: the record says launching with no block, the pane exists with the marker
local run_lost = ledger.new(lost, { run_id = "r_" .. lost.id:sub(3) .. "_1760000000", trigger = "manual", slot = os.time(), now = os.time() })
assert(ledger.transition(run_lost, "launching", nil, {}, os.time()))
table.insert(jobs.inflight(), run_lost.run_id)
ledger.save(run_lost)
jobs.save_state()
local dir_lost = "/d/runs/" .. lost.id .. "/" .. run_lost.run_id
tern.process.run({ fake.tern_bin, "new", "tab", "Scheduled runs", "--json", "--cwd", "/home/u/proj", "--keep-open", "--", fake.omp_bin, "--session-dir", dir_lost .. "/session" }, {}, function() end)
fake.advance(10)

-- a scheduled slot that never launched and is now far past its window
local run_stale = ledger.new(stale, { run_id = "r_" .. stale.id:sub(3) .. "_1760000001", trigger = "schedule", slot = os.time() - 5 * 3600, now = os.time() - 5 * 3600 })
table.insert(jobs.inflight(), run_stale.run_id)
ledger.save(run_stale)
jobs.save_state()
print("PASS phase 1 set up: 2 running, 1 lost launch, 1 stale slot")

-- the daemon restarts after 5 minutes: timers are gone, the restarted pane is a bare login shell
fake.events = {}
fake.jump_wall(300)
local lost_block_id
for id, b in pairs(fake.blocks) do
	if b.command:find(dir_lost, 1, true) then
		lost_block_id = id
	end
end
assert(lost_block_id, "orphan pane exists")
fake.blocks[tonumber(block_restart)].args = { "-l" } -- command still shows the old line, but ownership is by args[3]
for _, name in ipairs({ "jobs", "ledger", "store", "snapshot", "bins", "roles", "runner", "launcher", "intents", "notify", "tern_state", "session_tail", "validate", "ids" }) do
	rawset(__mods, name, nil)
end
jobs, runner, ledger = modules()
runner.load()
fake.advance(60000)

local function get(id)
	return ledger.get(id)
end
local k = get(run_keep.run_id)
assert(k.state == "running" and k.block == block_keep, "live pane with marker keeps being tracked: " .. k.state)
assert(runner.inflight()[1] ~= nil, "tracked in memory")
local r = get(run_restart.run_id)
assert(r.state == "failed" and r.reason_code == "interrupted", "restored login shell counts as gone after a gap: " .. r.state .. "/" .. tostring(r.reason_code))
assert(fake.blocks[tonumber(block_restart)] ~= nil, "the restored shell is never closed by the host")
assert(#fake.calls_of("close") == 0, "no tern close issued")
local l = get(run_lost.run_id)
assert(l.state == "running" and l.block == string.format("%.0f", lost_block_id), "orphan pane adopted: " .. l.state .. " " .. tostring(l.block))
local s = get(run_stale.run_id)
assert(s.state == "missed" and s.reason_code == "late", "stale slot recorded missed: " .. s.state)
assert(s.reason:find("over the 3h limit", 1, true), "missed sentence: " .. tostring(s.reason))
assert(#fake.calls_of("new") == 3, "nothing was launched twice")
print("PASS reconcile: tracked, interrupted, adopted, missed")

-- samples still reach the restored run
fake.intent("1760000000001-testwin01-0001", { format = 1, kind = "obs", block = block_keep, state = "working", seen_at = os.time() })
fake.advance(3000)
assert(runner.inflight()[1].observed == true or get(run_keep.run_id).observed == true, "obs applied after reload")
print("PASS obs after reload")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
