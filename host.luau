--!strict
-- Agent Scheduler host half: the block registry, then the runner (the clock). Each [[blocks]] entry in plugin.toml is implemented by
-- blocks/<id>.luau, which returns its BlockDef; a module that fails to load becomes a stub block
-- showing the error, so the other blocks keep working. Add blocks there, not here.

local manifest = require("./lib/manifest")
local cards = require("./lib/cards")
local ui = tern.ui

-- A local alias: luau-lsp strict mode rejects a computed path passed to the global `require`.
-- The caller is still this file, so "./blocks/<id>" resolves against the package root.
local load_module: (string) -> any = require :: any

local function stub(decl: manifest.BlockDecl, problem: string): BlockDef<{}>
	return {
		init = function(_cx, _args, _saved)
			return {}
		end,
		view = function(_state, _cx)
			return {
				main = ui.col({
					cards.error(
						decl.title .. " failed to load",
						"blocks/" .. decl.id .. ".luau did not load. Fix it and save; Tern reloads the plugin by itself.",
						{ detail = problem }
					),
				}),
			}
		end,
		title = function(_state)
			return decl.title .. " (failed to load)"
		end,
	}
end

-- Defines block `id`; false and the error when Tern rejects the definition.
local function define(id: string, def: BlockDef<any>): (boolean, any)
	return pcall(function()
		tern.block.define(id, def)
	end)
end

local declared: { [string]: boolean } = {}

for _, decl in manifest.blocks() do
	declared[decl.id] = true
	-- A closure, never pcall(require, …): a C caller breaks relative resolution.
	local ok, mod = pcall(function()
		return load_module("./blocks/" .. decl.id)
	end)
	local problem: string? = nil
	if not ok then
		problem = tostring(mod)
	elseif type(mod) ~= "table" or type(mod.init) ~= "function" or type(mod.view) ~= "function" then
		problem = "blocks/" .. decl.id .. ".luau must return a block definition (a table with init and view functions)"
	else
		local defined, err = define(decl.id, mod)
		if not defined then
			problem = tostring(err)
		end
	end
	if problem then
		tern.log.warn("tern-agent-scheduler: block " .. decl.id .. " failed to load; showing a stub", problem)
		local defined, err = define(decl.id, stub(decl, problem))
		if not defined then
			tern.log.error("tern-agent-scheduler: could not define stub for block " .. decl.id, err)
		end
	end
end

-- Modules without a manifest entry are never required: defining an undeclared id raises.
local listed, files = pcall(tern.fs.list, "blocks")
if listed then
	for _, file in files do
		local id = string.match(file, "^(.+)%.luau$")
		if id and not declared[id] then
			tern.log.warn("tern-agent-scheduler: blocks/" .. file .. " has no [[blocks]] entry in plugin.toml; not loaded")
		end
	end
end

-- The clock: store load, reconcile, intents, ticks and launches. Must outlive every manager block.
local runner_ok, runner_err = pcall(function()
	load_module("./lib/runner").load()
end)
if not runner_ok then
	tern.log.error("tern-agent-scheduler: runner failed to start", runner_err)
end
