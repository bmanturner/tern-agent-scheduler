--!strict
-- lib/host_widget.luau : the widget-bar widget, drawn by the host. Its render only reads an upvalue; the pump
-- recomputes it from the last publish (snapshot.last) and refreshes when it changed: at once for a new state, at
-- most every MIN_REFRESH_MS for a clock or countdown. Windows step aside (lib/status.luau sync_widget) unless they
-- have a warning the host can't give. Nothing here runs at require time.
local status = require("./status")
local snapshot = require("./snapshot")

local host_widget = {}

local MIN_REFRESH_MS = 5000

local active = false
local current: WidgetView? = nil
local last_key = ""
local last_ident = ""
local last_refresh = -math.huge

local function warn(...: any)
	local args = table.pack(...)
	pcall(function()
		(tern :: any).log.warn(table.unpack(args, 1, args.n))
	end)
end

-- Offers the widget; true when it is (or already was) registered.
function host_widget.register(): boolean
	if active then
		return true
	end
	local chrome = (tern :: any).chrome
	if type(chrome) ~= "table" or type(chrome.widget) ~= "function" then
		return false
	end
	local ok, err = pcall(
		chrome.widget,
		"status",
		status.widget_spec(function(_pane: StatusPaneInfo?): WidgetView?
			return current
		end)
	)
	if not ok then
		warn("tern-agent-scheduler: host widget not registered", err)
		return false
	end
	active = true
	return true
end

function host_widget.active(): boolean
	return active
end

-- Recomputes the widget from the last publish (wall-clock `now`) and refreshes it when it changed.
function host_widget.update(now: number)
	if not active then
		return
	end
	local snap, hot = snapshot.last()
	-- No stall check: only a window can see the host stall.
	local w = status.widget_view(status.compute(snap, hot, now, true).seg)
	local ident = ""
	local key = ""
	if w ~= nil then
		ident = table.concat({ w.icon or "", w.tone or "", w.command or "" }, "\0")
		key = (w.text or "") .. "\0" .. ident
	end
	if key == last_key then
		return
	end
	local mono = (tern :: any).now()
	if ident == last_ident and mono - last_refresh < MIN_REFRESH_MS then
		return
	end
	current = w
	last_key, last_ident, last_refresh = key, ident, mono
	pcall((tern :: any).chrome.refresh)
end

-- Test hook: forgets everything.
function host_widget.reset()
	active = false
	current = nil
	last_key = ""
	last_ident = ""
	last_refresh = -math.huge
end

return host_widget
