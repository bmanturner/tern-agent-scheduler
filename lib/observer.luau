--!strict
-- Window half: raw agent samples for the host (LA §8.3). While the snapshot lists in-flight runs,
-- every OBS_POLL_S this finds each run's agent in cx.agents:list() and sends an `obs` intent when
-- (state, model, last_message) changed, and again every OBS_HEARTBEAT_S while it persists. The
-- `agent_finished` event also sends one at once, with `finished` = "done" | "failed", when a run's
-- turn ends, and `agent_state` sends a run's state change at once. The window never interprets the
-- state; the host debounces and decides every transition.

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

-- Unknown optional AgentBlock fields arrive as `tern.json.null`, not nil.
local function text_or_nil(v: any): string?
	if type(v) == "string" then
		return v
	end
	return nil
end

-- Sends the `obs` intent for one run's agent entry when it changed or the heartbeat is due, and
-- always when `finished` reports the end of a turn.
function observer.send_sample(block: string, entry: AgentBlock, now_ms: number, finished: string?)
	local e: any = entry
	local model = text_or_nil(e.model)
	local msg = observer.clip(text_or_nil(e.last_message))
	local key = sample_key(tostring(e.state), model, msg)
	local prev = sent[block]
	if finished ~= nil or prev == nil or prev.key ~= key or now_ms - prev.at >= const.OBS_HEARTBEAT_S * 1000 then
		local name = outbox.send("obs", {
			block = block,
			state = e.state,
			model = model,
			last_message = msg,
			delivery_error = text_or_nil(e.delivery_error),
			finished = finished,
			seen_at = os.time(),
		})
		if name then
			sent[block] = { key = key, at = now_ms }
		end
	end
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
				-- one run's bad sample must not stop the others
				local oks, serr = pcall(observer.send_sample, block, entry, now_ms)
				if not oks then
					tern.log.warn("tern-agent-scheduler: observer sample", serr)
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

-- The in-flight run block shown as window pane `pane` and that pane's cx.agents:list() entry (or nil).
local function run_at(cx: WindowCx, pane: number): (string?, any)
	pcall(wsnap.poll)
	for _, run in wsnap.inflight() do
		local block = run.block
		if type(block) == "string" and block ~= "" then
			local okr, win = pcall(function()
				return cx.session:resolve(block)
			end)
			if okr and win == pane then
				local okl, list = pcall(function()
					return cx.agents:list()
				end)
				if okl then
					for _, e in list do
						if e.pane == pane then
							return block, e
						end
					end
				end
				return block, nil
			end
		end
	end
	return nil, nil
end

-- `agent_finished`: a turn ended. Only "done" and "failed" are forwarded; "exited" reaches
-- the host as `pane_exited`, and closing a pane is seen by the host's liveness check.
function observer.on_finished(ev: AgentFinishedEvent, cx: WindowCx)
	if ev.result ~= "done" and ev.result ~= "failed" then
		return
	end
	local block, e = run_at(cx, ev.pane)
	if block == nil then
		return
	end
	observer.send_sample(block, e or { state = "idle" }, tern.now(), ev.result)
end

-- `agent_state`: an agent's state changed. A run's change is sent at once instead of on the next
-- poll; "exited" reaches the host as `pane_exited`.
function observer.on_state(ev: AgentStateEvent, cx: WindowCx)
	if ev.new == "exited" or ev.old == ev.new then
		return
	end
	local block, e = run_at(cx, ev.pane)
	if block == nil then
		return
	end
	local entry: any = {}
	if e ~= nil then
		for k, v in e do
			entry[k] = v
		end
	end
	entry.state = ev.new
	observer.send_sample(block, entry, tern.now())
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
			local t0 = tern.now()
			pcall(wsnap.poll)
			local busy = #wsnap.inflight() > 0
			arm(if busy then const.OBS_POLL_S * 1000 else IDLE_POLL_S * 1000)
			if cx ~= nil and busy then
				local ok, err = pcall(observer.sample, cx, tern.now())
				if not ok then
					tern.log.warn("tern-agent-scheduler: observer", err)
				end
			end
			local took = tern.now() - t0
			if took >= const.WINDOW_SLOW_MS then
				tern.log.warn(string.format("tern-agent-scheduler: observer pass took %.1f ms (%d runs)", took, #wsnap.inflight()))
			end
		end)
	end
	arm(1000)
	-- Polling still covers every state if the event can't be registered.
	local ok = pcall(tern.on, "agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
		local okf, err = pcall(observer.on_finished, ev, cx)
		if not okf then
			tern.log.warn("tern-agent-scheduler: agent_finished", err)
		end
	end)
	if not ok then
		tern.log.debug("tern-agent-scheduler: no agent_finished event; polling only")
	end
	local oks = pcall(tern.on, "agent_state", function(ev: AgentStateEvent, cx: WindowCx)
		local okf, err = pcall(observer.on_state, ev, cx)
		if not okf then
			tern.log.warn("tern-agent-scheduler: agent_state", err)
		end
	end)
	if not oks then
		tern.log.debug("tern-agent-scheduler: no agent_state event; polling only")
	end
end

return observer
