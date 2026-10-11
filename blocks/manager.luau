--!strict
-- The Agent Scheduler manager block (host half): list, detail and form modes plus layer sheets. The views live in
-- lib/mgr_*.luau; this file owns the lifecycle (init/save/title), mode routing and the runner subscription.
-- Args: {"list"} or {"new", <cwd or "">}.

local ui = tern.ui
local C = require("../lib/mgr_common")
local A = require("../lib/mgr_actions")
local L = require("../lib/mgr_list")
local D = require("../lib/mgr_detail")
local F = require("../lib/mgr_form")
local S = require("../lib/mgr_sheets")
local jobs = require("../lib/jobs")
local runner = require("../lib/runner")

type State = C.State

local function pane_id(cx: BlockCx): string
	return string.format("%.0f", cx.pane)
end

local function pane_alive(pane: number): boolean
	for _, info in tern.pane.list() do
		if info.pane == pane then
			return true
		end
	end
	return false
end

-- Called by the runner after any change: re-render, or unsubscribe when the pane is gone.
local function on_change(state: State)
	local ok, live = pcall(pane_alive, state.cx.pane)
	if ok and not live then
		if state.token ~= nil then
			runner.unsubscribe(state.token)
			state.token = nil
		end
		runner.remove_manager(state.pane_id)
		return
	end
	C.render(state)
end

local function saved_folds(v: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(v) == "table" then
		for k, b in v do
			if type(k) == "string" and type(b) == "boolean" then
				out[k] = b
			end
		end
	end
	return out
end

local def: BlockDef<State> = {
	init = function(cx, args, saved)
		local s: any = if type(saved) == "table" then saved else {}
		local state: State = {
			cx = cx,
			pane_id = pane_id(cx),
			token = nil,
			mode = "list",
			sel = nil,
			sel_idx = 1,
			folds = saved_folds(s.folds),
			detail = nil,
			form = nil,
			sheet = nil,
			armed = nil,
			notice = nil,
			notice_at = 0,
			example_sel = 1,
			cwd_hint = nil,
		}
		if type(s.selected_id) == "string" then
			state.sel = { sec = "upcoming", key = s.selected_id }
		end
		local cwd: string? = if args[2] ~= nil and args[2] ~= "" then args[2] else nil
		state.cwd_hint = cwd
		if saved == nil and args[1] == "new" then
			F.open_new(state, { cwd = cwd })
		elseif s.mode == "detail" and type(s.selected_id) == "string" then
			A.open_detail(state, s.selected_id)
		end

		state.token = runner.subscribe(function()
			on_change(state)
		end)
		runner.add_manager(state.pane_id)
		if jobs.settings().welcomed ~= true then
			jobs.set_settings({ welcomed = true })
		end
		return state
	end,

	title = function(state)
		if state.mode == "form" and state.form ~= nil then
			return "Agent Scheduler › " .. state.form.title
		elseif state.mode == "detail" then
			local job = D.job(state)
			if job ~= nil then
				return "Agent Scheduler › " .. job.name
			end
		end
		return "Agent Scheduler"
	end,

	view = function(state, _cx)
		local main: Node
		local dock: Node
		if state.mode == "form" and state.form ~= nil then
			main, dock = F.view(state)
		elseif state.mode == "detail" and D.job(state) ~= nil then
			main, dock = D.view(state)
		else
			if state.mode ~= "list" then
				A.back(state)
			end
			main, dock = L.view(state)
		end
		local layer = S.layer(state)
		if layer ~= nil then
			return { main = main, dock = dock, layer = ui.col({ layer }) }
		end
		return { main = main, dock = dock }
	end,

	key = function(state, k, _cx)
		if state.sheet ~= nil then
			return S.key(state, k)
		end
		if state.mode == "form" and state.form ~= nil then
			return F.key(state, k)
		end
		if k.ctrl or k.meta or k.alt then
			return false
		end
		if state.mode == "detail" and D.job(state) ~= nil then
			return D.key(state, k)
		end
		return L.key(state, k)
	end,

	event = function(state, ev, _cx)
		if state.sheet ~= nil then
			S.event(state, ev)
		elseif state.mode == "form" and state.form ~= nil then
			F.event(state, ev)
		elseif state.mode == "detail" and D.job(state) ~= nil then
			D.event(state, ev)
		else
			L.event(state, ev)
		end
	end,

	save = function(state)
		local selected: string? = nil
		local d = state.detail
		if state.mode == "detail" and d ~= nil then
			selected = d.job_id
		elseif state.sel ~= nil and string.sub(state.sel.key, 1, 2) == "j_" then
			selected = state.sel.key
		end
		return {
			mode = if state.mode == "detail" then "detail" else "list",
			selected_id = selected,
			folds = state.folds,
		}
	end,
}

return def
