--!strict
-- Window half: raw agent samples for the host (LA §8.3). While the snapshot lists in-flight runs,
-- every OBS_POLL_S this finds each run's agent in cx.agents:list() and sends an `obs` intent when
-- (state, model, last_message) changed, and again every OBS_HEARTBEAT_S while it persists. The
-- window never interprets the state; the host debounces and decides every transition.

local const = require("./const")
local outbox = require("./outbox")
local wsnap = require("./wsnap")

local observer = {}

local IDLE_POLL_S = 15
local MSG_MAX = 4096
local HEAD = 1024
local ELLIPSIS = "\n…\n"

type Sent = { key: string, at: number }

local sent: { [string]: Sent } = {}
local started = false

local function is_cont(s: string, i: number): boolean
	local b = string.byte(s, i)
	return b ~= nil and b >= 0x80 and b < 0xC0
end

-- At most MSG_MAX bytes: the start (a fallback summary lives there) and the end (RESULT: and cost
-- lines), cut on character boundaries.
function observer.clip(m: string?): string?
	if m == nil or #m <= MSG_MAX then
		return m
	end
	local head_end = HEAD
	while head_end > 0 and is_cont(m, head_end + 1) do
		head_end -= 1
	end
	local tail_len = MSG_MAX - head_end - #ELLIPSIS
	local tail_start = #m - tail_len + 1
	while tail_start <= #m and is_cont(m, tail_start) do
		tail_start += 1
	end
	return string.sub(m, 1, head_end) .. ELLIPSIS .. string.sub(m, tail_start)
end

local function sample_key(state: string, model: string?, msg: string?): string
	return state .. "\0" .. (model or "") .. "\0" .. (msg or "")
end

-- One observation pass. `cx` is the timer's fresh window context.
function observer.sample(cx: WindowCx, now_ms: number)
	local runs = wsnap.inflight()
	local live: { [string]: boolean } = {}
	local entries: { [number]: AgentBlock }? = nil
	for _, run in runs do
		local block = run.block
		if type(block) == "string" and block ~= "" then
			live[block] = true
			if entries == nil then
				local map: { [number]: AgentBlock } = {}
				local okl, list = pcall(function()
					return cx.agents:list()
				end)
				if okl then
					for _, e in list do
						map[e.pane] = e
					end
				end
				entries = map
			end
			local okr, win = pcall(function()
				return cx.session:resolve(block)
			end)
			local entry = if okr and win ~= nil then (entries :: { [number]: AgentBlock })[win] else nil
			if entry then
				local msg = observer.clip(entry.last_message)
				local key = sample_key(entry.state, entry.model, msg)
				local prev = sent[block]
				if prev == nil or prev.key ~= key or now_ms - prev.at >= const.OBS_HEARTBEAT_S * 1000 then
					local name = outbox.send("obs", {
						block = block,
						state = entry.state,
						model = entry.model,
						last_message = msg,
						delivery_error = entry.delivery_error,
						seen_at = os.time(),
					})
					if name then
						sent[block] = { key = key, at = now_ms }
					end
				end
			end
		end
	end
	for block in sent do
		if not live[block] then
			sent[block] = nil
		end
	end
end

-- Starts the polling chain (once per VM). The next timer is armed before the body runs, so an
-- error in a pass doesn't end the chain.
function observer.start()
	if started then
		return
	end
	started = true
	local function arm(ms: number)
		tern.timer(ms, function(cx)
			pcall(wsnap.poll)
			local busy = #wsnap.inflight() > 0
			arm(if busy then const.OBS_POLL_S * 1000 else IDLE_POLL_S * 1000)
			if cx ~= nil and busy then
				local ok, err = pcall(observer.sample, cx, tern.now())
				if not ok then
					tern.log.warn("tern-agent-scheduler: observer", err)
				end
			end
		end)
	end
	arm(1000)
end

return observer
