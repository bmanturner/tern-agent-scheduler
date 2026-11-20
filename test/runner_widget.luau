-- The status widget lives in the host half: it renders the scheduler's state without a window, refreshes at
-- most every 5 s for a ticking clock, and a window steps aside unless it has a warning of its own.
local wcalls = {}
local host_spec
local refreshes = 0
tern.chrome = {
	status = function() end,
	widget = function(id, spec)
		table.insert(wcalls, { id = id, on = spec ~= nil, spec = spec })
		if spec ~= nil and host_spec == nil then
			host_spec = spec
		end
	end,
	refresh = function()
		refreshes += 1
	end,
}
local jobs, runner, status = __mods.jobs, __mods.runner, __mods.status

fake.dirs["/home/u/proj"] = true
fake.write(fake.omp_bin, "binary")
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))

runner.load()
fake.advance(1000)
assert(wcalls[1] ~= nil and wcalls[1].id == "status" and wcalls[1].on, "host registers the widget")
assert(host_spec.name == "Agent Scheduler" and host_spec.icon == "timer", "widget spec")

jobs.create({ name = "daily", prompt = "x", when = "daily 09:00", cwd = "/home/u/proj" }, "x", "user", os.time())
runner.changed()
fake.advance(2500)
local w = host_spec.render(nil)
assert(w ~= nil and w.text:sub(1, 6) == "next: ", "host widget shows the next run, got " .. tostring(w and w.text))
assert(fake.kv.hot ~= nil and fake.kv.hot.host_widget == true, "hot says the host has the widget")
print("PASS host widget shows the next run")

local m = jobs.create({ name = "now", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "x", "user", os.time())
assert(runner.run_now(m.id))
assert(fake.run_until(function()
	local r = runner.inflight()[1]
	return r ~= nil and r.state == "running"
end, 30000, 500), "run is running")
fake.advance(2000)
local wr = host_spec.render(nil)
assert(wr ~= nil and wr.icon == "activity", "host widget shows the running run, got " .. tostring(wr and wr.icon))
local before = refreshes
fake.advance(4000)
assert(refreshes - before <= 1, "a ticking clock refreshes at most every 5 s, got " .. (refreshes - before))
print("PASS host widget follows runs, refresh throttled")

-- The hover card: the running run with Open and Stop, the next run with Run now; its buttons act.
local running = runner.inflight()[1]
local function row_with(card, act)
	for _, r in card or {} do
		for _, a in r.actions or {} do
			if a.id == act then
				return r
			end
		end
	end
	return nil
end
local rrow = row_with(wr.card, "stop")
assert(rrow and rrow.id == running.run_id and rrow.text:find("^now · ") and rrow.tone == "accent", "card: running row with Stop")
local nrow = row_with(wr.card, "run")
assert(nrow and nrow.text == "daily · 09:00" and nrow.id:find("^j_"), "card: next row with Run now, got " .. tostring(nrow and nrow.text))
fake.emit("widget_action", { widget = "status", row = "r_../../etc", act = "stop" })
fake.emit("widget_action", { widget = "other", row = running.run_id, act = "stop" })
assert(runner.inflight()[1] ~= nil, "malformed or foreign clicks do nothing")
local closes = #fake.calls_of("close")
fake.emit("widget_action", { widget = "status", row = running.run_id, act = "stop" })
assert(fake.run_until(function()
	return runner.inflight()[1] == nil
end, 30000, 500), "Stop on the card stops the run")
assert(#fake.calls_of("close") > closes, "the run's pane was closed")
print("PASS hover card lists runs and next runs; its Stop stops the run")

-- A window: with the host's widget in place it takes its own away; a paused hook brings it back.
status.register()
fake.advance(5100)
local last = wcalls[#wcalls]
assert(last.id == "status" and not last.on, "window steps aside for the host widget")
status.budget("timer", "paused")
last = wcalls[#wcalls]
assert(last.on and last.spec.render(nil).text == "Agent Scheduler paused · it ran too long", "a paused window shows its own widget")
status.budget("timer", "resumed")
last = wcalls[#wcalls]
assert(not last.on, "window steps aside again once resumed")
print("PASS window widget only for window-side warnings")
