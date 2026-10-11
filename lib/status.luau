--!strict
-- Window half: the status-line segment (UX §2.3, §7.4), the scheduler stall watchdog (EN §5.5) and
-- toasts from snapshot transitions (UX §7.3). The formatter only reads an upvalue; a timer
-- refreshes it from the cached snapshot. Nothing here runs at load time.

local const = require("./const")
local wsnap = require("./wsnap")

local status = {}

local REFRESH_MS = 5000
local FORCE_REFRESH_S = 60
local STALL_MIN_S = 120
local NEEDS_CHORD = "ctrl+alt+shift+a"
local CMD_OPEN = "plugin.tern-agent-scheduler.open-manager"
local CMD_NEEDS = "plugin.tern-agent-scheduler.go-to-needs-you"

export type View = {
	seg: StatusSegment?,
	stalled: boolean,
	stall_age: number,
	setup_bad: boolean,
	needs: { any },
	context: string?,
}

export type Toast = { level: ToastLevel, text: string, sub: string? }

local view: View = { seg = nil, stalled = false, stall_age = 0, setup_bad = false, needs = {}, context = nil }

-- Compact age: "<1m", "4m", "14h", "3d".
local function span(secs: number): string
	if secs < 60 then
		return "<1m"
	elseif secs < 3600 then
		return string.format("%dm", secs // 60)
	elseif secs < 172800 then
		return string.format("%dh", secs // 3600)
	end
	return string.format("%dd", secs // 86400)
end
status.span = span

local function num(v: any): number
	if type(v) == "number" then
		return v
	elseif v == true then
		return 1
	end
	return 0
end

local function is_active(job: any): boolean
	return job.enabled == true and job.invalid == nil and job.paused_reason == nil
end

-- The soonest next run among active jobs: {name, at} or nil.
local function soonest(snap: { [string]: any }): (string?, number?)
	local best_name: string? = nil
	local best_at: number? = nil
	local jobs: { any } = if type(snap.jobs) == "table" then snap.jobs else {}
	for _, j in jobs do
		if is_active(j) and type(j.next_run) == "number" then
			if best_at == nil or j.next_run < best_at then
				best_at, best_name = j.next_run, tostring(j.name)
			end
		end
	end
	return best_name, best_at
end

-- Builds the whole view from a snapshot and hot value. Pure: `now` is unix seconds.
function status.compute(snap: { [string]: any }?, hot: { [string]: any }?, now: number): View
	local out: View = { seg = nil, stalled = false, stall_age = 0, setup_bad = false, needs = {}, context = nil }
	if snap == nil then
		return out
	end
	local jobs: { any } = if type(snap.jobs) == "table" then snap.jobs else {}
	local inflight: { any } = if type(snap.inflight) == "table" then snap.inflight else {}
	local recent: { any } = if type(snap.recent) == "table" then snap.recent else {}
	local h: { [string]: any } = hot or {}
	local paused_all = (if hot then h.paused_all else snap.paused_all) == true

	local active, paused = 0, 0
	for _, j in jobs do
		if is_active(j) then
			active += 1
		elseif j.enabled ~= true then
			paused += 1
		end
	end

	local needs: { any } = {}
	local running: { any } = {}
	for _, r in inflight do
		if r.state == "needs_input" then
			table.insert(needs, r)
		else
			table.insert(running, r)
		end
	end
	table.sort(needs, function(a, b)
		return num(a.since) < num(b.since)
	end)
	out.needs = needs

	local nxt_name, nxt_at = soonest(snap)
	if paused_all then
		nxt_name, nxt_at = nil, nil
	end

	-- Context line for Carly.
	if #jobs == 0 then
		out.context = "Agent Scheduler: no jobs yet."
	else
		local line = string.format("Agent Scheduler: %d active, %d paused", active, paused)
		if nxt_name and nxt_at then
			line ..= string.format("; next %s in %s", nxt_name, span(math.max(0, nxt_at - now)))
		end
		line ..= string.format("; %d need you.", #needs)
		out.context = line
	end

	if #jobs == 0 then
		return out -- the segment stays hidden until there is a job
	end

	local hb: any = if hot then h.hb else nil
	if type(hb) ~= "number" then
		hb = snap.hb
	end
	if active > 0 and type(hb) == "number" then
		local limit = math.max(STALL_MIN_S, 3 * const.TICK_S)
		if now - hb > limit then
			out.stalled = true
			out.stall_age = now - hb
		end
	end
	local setup_ok: any = if hot then h.setup_ok else snap.setup_ok
	out.setup_bad = setup_ok == false

	local seg: StatusSegment
	if out.stalled then
		seg = {
			text = "scheduler stalled · last tick " .. span(out.stall_age) .. " ago",
			icon = "warn",
			tone = "error",
			command = CMD_OPEN,
		}
	elseif out.setup_bad then
		seg = { text = "setup needed", icon = "warn", tone = "warn", command = CMD_OPEN }
	elseif #needs > 0 then
		local text: string
		if #running > 0 then
			text = string.format("%d needs you · %d running", #needs, #running)
			if #needs > 1 then
				text = string.format("%d need you · %d running", #needs, #running)
			end
		elseif #needs == 1 then
			text = "1 needs you · " .. tostring(needs[1].job_name)
		else
			text = string.format("%d need you", #needs)
		end
		seg = { text = text, icon = "bell", tone = "warn", command = CMD_NEEDS }
	else
		local failed = math.floor(num(h.failed_unseen))
		if failed > 0 then
			local text: string
			if failed == 1 then
				local name = "a job"
				for _, r in recent do
					if r.state == "failed" or r.state == "timed_out" then
						name = tostring(r.job_name)
						break
					end
				end
				text = name .. " failed"
			else
				text = string.format("%d failed", failed)
			end
			seg = { text = text, icon = "x-circle", tone = "error", command = CMD_OPEN }
		elseif #running == 1 then
			local started = num(running[1].started)
			seg = {
				text = tostring(running[1].job_name) .. " · " .. span(math.max(0, now - started)),
				icon = "activity",
				tone = "accent",
				command = CMD_OPEN,
			}
		elseif #running > 1 then
			seg = { text = string.format("%d running", #running), icon = "activity", tone = "accent", command = CMD_OPEN }
		elseif nxt_name and nxt_at then
			local left = nxt_at - now
			seg = {
				text = "next: " .. nxt_name .. " in " .. span(math.max(0, left)),
				icon = "timer",
				tone = if left < 300 then "accent" else "muted",
				command = CMD_OPEN,
			}
		else
			return out
		end
	end
	out.seg = seg
	return out
end

-- ---- toasts from snapshot transitions --------------------------------------------------------------

type Memo = {
	primed: boolean,
	runs: { [string]: string },
	recent: { [string]: boolean },
	jobs: { [string]: string },
	needs_toasted: { [string]: boolean },
	had_history: boolean,
	setup_ok: boolean,
	suppressed: { [string]: boolean },
}

local memo: Memo = {
	primed = false,
	runs = {},
	recent = {},
	jobs = {},
	needs_toasted = {},
	had_history = false,
	setup_ok = true,
	suppressed = {},
}

-- Carly's export shows its own toast; the diff skips that job id.
function status.suppress_job_toast(job_id: string)
	memo.suppressed[job_id] = true
end

local function clip(s: string, max: number): string
	if #s <= max then
		return s
	end
	local stop = max - 3
	while stop > 0 do
		local b = string.byte(s, stop + 1)
		if b == nil or b < 0x80 or b >= 0xC0 then
			break
		end
		stop -= 1
	end
	return string.sub(s, 1, stop) .. "…"
end

local function next_text(at: any): string
	if type(at) == "number" then
		return os.date("%a %d %b %H:%M", at)
	end
	return "manual only"
end

-- Toasts for what changed since the previous call. The first call only records a baseline.
function status.diff(snap: { [string]: any }, hot: { [string]: any }?, now: number): { Toast }
	local out: { Toast } = {}
	local jobs: { any } = if type(snap.jobs) == "table" then snap.jobs else {}
	local inflight: { any } = if type(snap.inflight) == "table" then snap.inflight else {}
	local recent: { any } = if type(snap.recent) == "table" then snap.recent else {}
	local setup_ok: any = if hot then hot.setup_ok else snap.setup_ok

	local history = #recent > 0
	for _, j in jobs do
		if j.last ~= nil then
			history = true
		end
	end

	if memo.primed then
		for _, r in inflight do
			local id = tostring(r.run_id)
			if r.state == "needs_input" and not memo.needs_toasted[id] then
				memo.needs_toasted[id] = true
				table.insert(out, {
					level = "info",
					text = tostring(r.job_name) .. " needs you",
					sub = "Waiting for you. " .. NEEDS_CHORD .. " to open",
				})
			end
			if memo.runs[id] == nil and not memo.had_history then
				table.insert(out, {
					level = "info",
					text = tostring(r.job_name) .. " started",
					sub = "in the “Scheduled runs” session · later runs start quietly",
				})
			end
		end
		for _, r in recent do
			local id = tostring(r.run_id)
			local fresh = not memo.recent[id] and (type(r.ended) ~= "number" or now - r.ended <= 600)
			if fresh then
				local reason = clip(tostring(r.reason or ""), 120)
				if r.state == "failed" then
					table.insert(out, { level = "error", text = tostring(r.job_name) .. " failed", sub = reason })
				elseif r.state == "timed_out" then
					table.insert(out, { level = "error", text = tostring(r.job_name) .. " timed out", sub = reason })
				elseif r.state == "blocked" then
					table.insert(out, { level = "error", text = tostring(r.job_name) .. " is blocked", sub = reason })
				end
			end
		end
		for _, j in jobs do
			local id = tostring(j.id)
			local before = memo.jobs[id]
			if before == nil then
				if j.created_by == "carly" and not memo.suppressed[id] then
					table.insert(out, {
						level = "success",
						text = "Carly scheduled " .. tostring(j.name),
						sub = tostring(j.when) .. " · next " .. next_text(j.next_run),
					})
				end
			elseif before ~= "failures" and j.paused_reason == "failures" then
				table.insert(out, {
					level = "error",
					text = tostring(j.name) .. " paused after failures",
					sub = "fix the problem, then press space",
				})
			end
		end
		if memo.setup_ok and setup_ok == false then
			table.insert(out, { level = "error", text = "Agent Scheduler needs attention", sub = "Open the manager to check setup" })
		end
	end

	memo.runs = {}
	for _, r in inflight do
		memo.runs[tostring(r.run_id)] = tostring(r.state)
	end
	for _, r in recent do
		memo.recent[tostring(r.run_id)] = true
	end
	memo.jobs = {}
	for _, j in jobs do
		memo.jobs[tostring(j.id)] = if j.paused_reason ~= nil then tostring(j.paused_reason) else ""
	end
	memo.had_history = history
	memo.setup_ok = setup_ok ~= false
	memo.primed = true
	return out
end

-- Test hook: forgets the toast baseline.
function status.reset()
	memo = {
		primed = false,
		runs = {},
		recent = {},
		jobs = {},
		needs_toasted = {},
		had_history = false,
		setup_ok = true,
		suppressed = {},
	}
	view = { seg = nil, stalled = false, stall_age = 0, setup_bad = false, needs = {}, context = nil }
end

-- ---- upvalue accessors -----------------------------------------------------------------------------

function status.view(): View
	return view
end

-- Recomputes only the view (no toasts, no refresh) from the cached snapshot.
function status.recompute(now: number)
	view = status.compute(wsnap.get(), wsnap.hot(), now)
end

-- Runs that need the user, oldest first.
function status.needs(): { any }
	return view.needs
end

-- The Carly request context (≤ 400 characters) or nil.
function status.context(): string?
	local c = view.context
	if c ~= nil and #c > 400 then
		return clip(c, 400)
	end
	return c
end

-- ---- timer + registration --------------------------------------------------------------------------

local registered = false
local ready_shown = false
local stall_toasted = false
local last_key = ""
local last_refresh = 0

local function seg_key(seg: StatusSegment?): string
	if seg == nil then
		return ""
	end
	return table.concat({ seg.text, seg.icon or "", seg.tone or "", seg.command or "" }, "\0")
end

-- Recomputes the view from the cached snapshot, toasts what changed and refreshes the segment when
-- it differs (and at least once a minute). `cx` may be nil when the timer gave none.
function status.update(cx: WindowCx?, now: number)
	local snap = wsnap.get()
	local hot = wsnap.hot()
	local nv = status.compute(snap, hot, now)
	view = nv

	if cx ~= nil then
		if hot ~= nil and hot.welcome == true and not ready_shown then
			ready_shown = true
			cx:toast("info", "Agent Scheduler is ready.", "Press ctrl+alt+shift+s.")
		end
		if snap ~= nil then
			for _, t in status.diff(snap, hot, now) do
				cx:toast(t.level, t.text, t.sub)
			end
		end
		if nv.stalled and not stall_toasted then
			stall_toasted = true
			cx:toast(
				"error",
				"Agent Scheduler stopped ticking",
				"last tick " .. span(nv.stall_age) .. " ago · run “Reload plugins” from the palette"
			)
		elseif not nv.stalled then
			stall_toasted = false
		end
	end

	local key = seg_key(nv.seg)
	if key ~= last_key or now - last_refresh >= FORCE_REFRESH_S then
		last_key = key
		last_refresh = now
		pcall(tern.chrome.refresh)
	end
end

function status.register()
	if registered then
		return
	end
	registered = true
	tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
		local seg = view.seg
		if seg == nil then
			return nil
		end
		return { seg }
	end)
	local function arm()
		tern.timer(REFRESH_MS, function(cx)
			arm()
			pcall(wsnap.poll)
			local ok, err = pcall(status.update, cx, os.time())
			if not ok then
				tern.log.warn("tern-agent-scheduler: status", err)
			end
		end)
	end
	arm()
end

return status
