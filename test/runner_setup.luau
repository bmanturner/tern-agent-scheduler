-- Setup health as the manager draws it: no "needs attention" from the heartbeat right after a load or a sleep, a
-- stalled tick still fails, and a manager that drew a setup problem redraws once it clears (without redrawing on
-- every tick when nothing changed).
local runner = __mods.runner

fake.dirs["/home/u/proj"] = true
fake.write(fake.omp_bin, "binary")
fake.set_wall(fake.chicago(2026, 10, 13, 9, 0, 0))

local INFO = { roles = true, keepalive = true, notifications = true }
local function failing(): string
	local bad = {}
	for _, r in ipairs(runner.health().setup) do
		if r.ok == false and not INFO[r.id] then
			table.insert(bad, r.id)
		end
	end
	return table.concat(bad, ",")
end
local function heartbeat(): any
	for _, r in ipairs(runner.health().setup) do
		if r.id == "heartbeat" then
			return r
		end
	end
	return nil
end

runner.load()
local redraws = 0
runner.subscribe(function()
	redraws += 1
end)

-- 1. before the first tick the scheduler is starting, not stalled (the harness has no cached binaries, so a
--    manager drawn now does show a real problem: tern and omp aren't resolved yet)
local hb = heartbeat()
assert(hb.ok ~= false and hb.text == "The scheduler is starting.", "heartbeat right after load: " .. tostring(hb.ok) .. " " .. hb.text)
assert(failing() == "tern,omp", "drawn right after load: " .. failing())
print("PASS no heartbeat alarm before the first tick")

-- 2. the binaries resolve and the first tick runs: the manager that drew the problem redraws by itself
fake.advance(3000)
assert(failing() == "", "healthy after the first tick: " .. failing())
assert(redraws >= 1, "the manager that drew a problem redraws when it clears")
print("PASS a manager that drew a setup problem redraws when it clears")

-- 3. nothing changed: ticks don't redraw the manager
redraws = 0
fake.advance(60000)
assert(redraws == 0, "redraws with nothing changed: " .. redraws)
print("PASS no redraws while the setup rows stay the same")

-- 4. a 10 minute sleep: the wall clock jumps, the monotonic clock doesn't; drawn before the first tick after wake,
--    the heartbeat still isn't an alarm
fake.jump_wall(600)
assert(heartbeat().ok ~= false, "heartbeat right after wake")
fake.advance(2100)
assert(failing() == "", "healthy after the first tick after wake: " .. failing())
print("PASS no heartbeat alarm right after a sleep")

-- 5. the tick really stops while the machine is awake (every timer dropped): after 2 minutes it fails
fake.events = {}
fake.advance(130000)
local dead = heartbeat()
assert(dead.ok == false and dead.text:find("has stopped", 1, true), "stalled tick: " .. tostring(dead.ok))
print("PASS a tick stalled while awake still fails")
