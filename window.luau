--!strict
-- Agent Scheduler window half: palette commands, the status segment, toasts, agent observation and
-- Carly exports. The clock lives in the host half; this half only reads snapshot.json and writes
-- intent files.
--
-- Tern compiles each module when it is required; loading one module per timer callback keeps each
-- step small (require caches the result), then the entry registers everything.

-- iOS has no tern.process, and the scheduler is desktop-only.
if tern.runtime.os == "ios" then
	return
end

-- Dependencies first, so each step compiles one module.
local MODULES = {
	"./lib/const",
	"./lib/cron",
	"./lib/schedule",
	"./lib/fmt",
	"./lib/ids",
	"./lib/outbox",
	"./lib/wsnap",
	"./lib/platform",
	"./lib/observer",
	"./lib/status",
	"./lib/commands",
	"./lib/carly",
}

-- A local alias: luau-lsp strict mode rejects a computed path passed to the global `require`. The
-- caller is still this file, so the paths resolve against the package root.
local load_module: (string) -> any = require :: any

local loading = MODULES[1]
local registered = false

-- Tern pauses a hook that runs over its time budget (5 s, doubling on repeats, at most 5 min) and
-- resumes it on its own. Log it, and let the status line say so while anything is paused.
local okb = pcall(tern.on, "budget", function(ev: BudgetEvent, _cx: WindowCx)
	if ev.state == "paused" then
		tern.log.warn(
			string.format(
				"tern-agent-scheduler: %s paused for %d ms after running over its %d ms budget",
				tostring(ev.hook),
				ev.paused_ms or 0,
				ev.ms or 0
			)
		)
	else
		tern.log.info(string.format("tern-agent-scheduler: %s resumed", tostring(ev.hook)))
	end
	if registered then
		pcall(function()
			load_module("./lib/status").budget(ev.hook, ev.state)
		end)
	end
end)
if not okb then
	tern.log.debug("tern-agent-scheduler: no budget event")
end

local function register()
	registered = true
	load_module("./lib/commands").register()
	load_module("./lib/status").register()
	load_module("./lib/observer").start()
	if tern.carly then
		-- Carly exports are optional; a failure here must not keep the rest from starting.
		local ok, err = pcall(function()
			load_module("./lib/carly").register()
		end)
		if not ok then
			tern.log.warn("tern-agent-scheduler: Carly exports not registered", err)
		end
	end
end

local function step(i: number)
	tern.timer(0, function()
		if i > #MODULES then
			register()
			return
		end
		loading = MODULES[i]
		local t0 = tern.now()
		load_module(MODULES[i])
		local ms = tern.now() - t0
		if ms >= 15 then
			tern.log.warn(string.format("tern-agent-scheduler: loading %s took %.1f ms", loading, ms))
		else
			tern.log.debug(string.format("tern-agent-scheduler: loaded %s in %.1f ms", loading, ms))
		end
		step(i + 1)
	end)
end

step(1)
