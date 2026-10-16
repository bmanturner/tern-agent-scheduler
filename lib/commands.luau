--!strict
-- Window half: the four palette commands (UX §2.2 #1, #2, #4, #5). They never create or change jobs:
-- they open the manager or send allowlisted intents. Nothing here runs at load time.

local const = require("./const")
local outbox = require("./outbox")
local status = require("./status")
local wsnap = require("./wsnap")
local platform = require("./platform")

local commands = {}

local GROUP = "Agent Scheduler"
-- A run_now intent the host hasn't applied by then is stale and dropped (the user was told it failed).
local RUN_NOW_TTL_S = 20

-- True when the window's current host is a remote machine: blocks open there, and this machine's
-- snapshot, intents and jobs are not that machine's.
local function on_remote_host(cx: WindowCx): boolean
	local ok, host = pcall(function()
		return cx.hosts:current()
	end)
	return ok and type(host) == "table" and (host :: any).kind == "remote"
end

-- The focused pane's working directory on its own host ("" when unknown).
local function pane_cwd(cx: WindowCx): string
	local ok, info = pcall(function()
		local pane = cx.session:focused()
		if pane == nil then
			return nil
		end
		return cx.session:pane(pane)
	end)
	if ok and info ~= nil and type(info.cwd) == "string" then
		return info.cwd
	end
	return ""
end

-- The focused pane's working directory for a job on this machine ("" when unknown), plus a reason
-- when that pane is on another machine.
function commands.focused_cwd(cx: WindowCx): (string, string?)
	if on_remote_host(cx) then
		return "", "That pane is on another machine. Pick a folder on this " .. platform.machine() .. "."
	end
	return pane_cwd(cx), nil
end

local function send(cx: WindowCx, kind: string, payload: { [string]: any }?): boolean
	local name, err = outbox.send(kind, payload)
	if name == nil then
		cx:toast("error", "Agent Scheduler", err)
		return false
	end
	return true
end

-- Opens the manager on the window's current host, starting in the focused pane's folder there. On
-- this machine an open manager is focused instead; a remote host's managers aren't in this
-- machine's snapshot, so there it always opens one.
local function open_manager(cx: WindowCx)
	if not on_remote_host(cx) then
		wsnap.poll()
		local snap = wsnap.get()
		local managers: any = if snap then snap.managers else nil
		if type(managers) == "table" then
			-- The snapshot can list a manager closed seconds ago (the host prunes on its slow tick), so
			-- only ask the host to focus one this window can still see; otherwise open a new one.
			for _, id in managers do
				local ok, pane = pcall(function()
					return cx.session:resolve(tostring(id))
				end)
				if ok and pane ~= nil then
					send(cx, "focus_manager", nil)
					return
				end
			end
		end
	end
	cx:new_block(const.MANAGER_KIND, { "list", pane_cwd(cx) }, "tab")
end

local function new_job(cx: WindowCx)
	cx:new_block(const.MANAGER_KIND, { "new", pane_cwd(cx) }, "tab")
end

local function job_group(job: any): string
	if job.invalid ~= nil or job.paused_reason == "blocked" or job.paused_reason == "failures" then
		return "Needs fixing"
	elseif job.enabled == true then
		return "Active"
	end
	return "Paused"
end

local GROUP_ORDER = { "Needs fixing", "Active", "Paused" }

-- Items for the "Run a job now" picker, grouped Needs fixing / Active / Paused.
function commands.run_items(jobs: { any }, inflight: { any }): { PickItem }
	local running: { [string]: any } = {}
	for _, r in inflight do
		running[tostring(r.job_id)] = r
	end
	local buckets: { [string]: { PickItem } } = { ["Needs fixing"] = {}, Active = {}, Paused = {} }
	for _, j in jobs do
		local run = running[tostring(j.id)]
		local detail = if run ~= nil
			then "Already running"
			elseif j.invalid ~= nil then "Needs fixing in the manager"
			else string.format("%s · %s · @%s", tostring(j.when), tostring(j.folder), tostring(j.role))
		local group = job_group(j)
		table.insert(buckets[group], {
			label = tostring(j.name),
			detail = detail,
			group = group,
			job_id = tostring(j.id),
			invalid = j.invalid ~= nil,
			run_id = if run ~= nil then tostring(run.run_id) else nil,
		})
	end
	local items: { PickItem } = {}
	for _, g in GROUP_ORDER do
		for _, it in buckets[g] do
			table.insert(items, it)
		end
	end
	return items
end

local function run_job_now(cx: WindowCx)
	wsnap.poll()
	local snap = wsnap.get()
	if snap == nil or #wsnap.jobs() == 0 then
		cx:toast("info", "No jobs yet", "Open the manager to add one.")
		return
	end
	if snap.paused_all == true then
		cx:toast("info", "All jobs are paused", "Resume all jobs to run.")
		return
	end
	local items = commands.run_items(wsnap.jobs(), wsnap.inflight())
	cx:pick({ items = items, placeholder = "Run which job now?", icon = "timer", action = "run" }):next(
		function(item, _err, cx2)
			if item == nil or cx2 == nil then
				return
			end
			local run_id: any = item.run_id
			if type(run_id) == "string" then
				send(cx2, "focus_run", { run_id = run_id })
			elseif item.invalid == true then
				cx2:toast("info", tostring(item.label) .. " needs fixing", "Open the manager to fix it.")
			else
				if send(cx2, "run_now", { job_id = item.job_id, expires = os.time() + RUN_NOW_TTL_S }) then
					cx2:toast("info", tostring(item.label) .. " queued")
				end
			end
		end
	)
end

local function go_to_needs_you(cx: WindowCx)
	wsnap.poll()
	status.recompute(os.time())
	local needs = status.needs()
	if #needs == 0 then
		cx:toast("info", "Nothing needs you right now")
		return
	end
	send(cx, "focus_run", { run_id = tostring(needs[1].run_id) })
end

local registered = false

function commands.register()
	if registered then
		return
	end
	registered = true
	tern.command({ id = "settings", title = "Settings", icon = "settings", group = GROUP, run = function(cx: WindowCx)
		cx:new_block(const.MANAGER_KIND, { "settings", pane_cwd(cx) }, "tab")
	end })
	tern.command({
		id = "open-manager",
		title = "Open manager",
		icon = "timer",
		group = GROUP,
		-- m first: Tern's Linux preset already binds ctrl+alt+shift+s, which still works on macOS.
		keys = { "ctrl+alt+shift+m", "ctrl+alt+shift+s" },
		run = open_manager,
	})
	tern.command({
		id = "new-job",
		title = "New job…",
		icon = "plus",
		group = GROUP,
		keys = { "ctrl+alt+shift+j" },
		run = new_job,
	})
	tern.command({
		id = "run-job-now",
		title = "Run a job now…",
		icon = "play",
		group = GROUP,
		keys = { "ctrl+alt+shift+r" },
		run = run_job_now,
	})
	tern.command({
		id = "go-to-needs-you",
		title = "Go to run that needs you",
		icon = "bell",
		group = GROUP,
		keys = { "ctrl+alt+shift+a" },
		available = function(_cx: WindowCx): boolean
			return #status.needs() > 0
		end,
		run = go_to_needs_you,
	})
end

return commands
