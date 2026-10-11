--!strict
-- Agent Scheduler window half: palette commands, the status segment, toasts, agent observation and
-- Carly exports. The clock lives in the host half; this half only reads snapshot.json and writes
-- intent files.
--
-- Tern compiles every chunk to native code when it is required, and loading everything at once can
-- exceed the 50 ms window budget. So the entry loads one module per timer callback (each has its own
-- budget, and require caches the result), then registers everything.

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

local function register()
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
