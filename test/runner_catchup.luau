-- Sleep / clock-jump catch-up (EN §5.3, §6.1) with the 3 h default window.
local jobs, runner, ledger = __mods.jobs, __mods.runner, __mods.ledger

fake.dirs["/home/u/proj"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 8, 0, 0)) -- Monday 08:00
runner.load()
fake.advance(1000)

assert(jobs.settings().catchup_window_s == 10800, "catch-up window defaults to 3 h")
local a = jobs.create({ name = "daily-nine", prompt = "x", when = "0 9 * * *", cwd = "/home/u/proj" }, "nine", "user", os.time())
local b = jobs.create({ name = "daily-eleven", prompt = "x", when = "0 11 * * *", cwd = "/home/u/proj" }, "eleven", "user", os.time())
assert(a and b, "jobs created")

-- the Mac sleeps until 13:00: nine is 4 h late (over the limit), eleven is 2 h late
fake.jump_wall(5 * 3600)
fake.advance(2000)
assert(os.date("%H:%M") == "13:00", "clock at 13:00, got " .. os.date("%H:%M"))
fake.advance(30000)

local recs_a = ledger.recent(a.id, 10)
assert(#recs_a == 1, "one record for the 4 h late slot, got " .. #recs_a)
local ra = recs_a[1]
assert(ra.state == "missed" and ra.reason_code == "late", "missed/late: " .. ra.state .. "/" .. tostring(ra.reason_code))
assert(ra.reason == "Missed Mon 09:00: 4h late, over the 3h limit.", "sentence: " .. tostring(ra.reason))
assert(#fake.calls_of("new") == 1, "exactly one launch (the 2 h late job)")
local recs_b = ledger.recent(b.id, 10)
assert(#recs_b == 1 and recs_b[1].trigger == "catchup" and recs_b[1].state == "running", "eleven caught up once: " .. tostring(recs_b[1] and recs_b[1].state))
print("PASS 4 h late => one missed record, no launch; 2 h late => one catch-up launch")

-- no refire for slots already handled
fake.advance(60000)
assert(#ledger.recent(a.id, 10) == 1 and #ledger.recent(b.id, 10) == 1 and #fake.calls_of("new") == 1, "slots are handled once")
assert(jobs.state(a.id).next_run == fake.chicago(2026, 10, 13, 9, 0, 0), "next run is tomorrow 09:00")
print("PASS no double handling")

-- Tuesday: asleep until 10:30, nine is 1.5 h late => exactly one catch-up launch
runner.stop(recs_b[1].run_id)
fake.advance(3000)
fake.set_wall(fake.chicago(2026, 10, 13, 8, 0, 0))
fake.advance(3000)
fake.jump_wall(2.5 * 3600)
fake.advance(2000)
fake.advance(30000)
local recs_a2 = ledger.recent(a.id, 10)
assert(#recs_a2 == 2, "one more record for nine, got " .. #recs_a2)
local launched = recs_a2[1]
assert(launched.trigger == "catchup" and launched.state == "running", "catch-up launch: " .. launched.trigger .. "/" .. launched.state)
assert(launched.slot == fake.chicago(2026, 10, 13, 9, 0, 0), "for the 09:00 slot")
assert(launched.run_id:find(tostring(launched.slot), 1, true), "deterministic run id carries the slot")
local news = fake.calls_of("new")
local ours = 0
for _, argv in ipairs(news) do
	if table.concat(argv, " "):find(launched.run_id, 1, true) then
		ours += 1
	end
end
assert(ours == 1, "launched exactly once")
local pre = fake.read("/d/runs/" .. a.id .. "/" .. launched.run_id .. "/preamble.md")
assert(pre:find("started on schedule (slot Tue 2026-10-13 09:00", 1, true), "preamble names the slot: " .. pre:sub(1, 200))
print("PASS 1.5 h late => exactly one catch-up launch")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
