--!strict
-- lib/snapshot.luau : host -> window read model. Writes snapshot.json and bumps kv "hot" (EN §2.4).
local const = require("./const")
local jobs = require("./jobs")
local ledger = require("./ledger")
local store = require("./store")
local validate = require("./validate")
local conditions = require("./conditions")

local snapshot = {}

export type View = {
	inflight: { { [string]: any } },
	managers: { string },
	setup_ok: boolean,
	scheduler: string,
	welcome: boolean,
}

local rev = 0
local rev_seeded = false
local RECENT_MAX = 30
local FAILED_UNSEEN_DAYS = 7

local function array(t: any): any
	return (tern :: any).json.array(t)
end

local function seed_rev()
	if rev_seeded then
		return
	end
	rev_seeded = true
	local ok, hot = pcall(function()
		return (tern :: any).kv.get("hot")
	end)
	if ok and type(hot) == "table" and type(hot.rev) == "number" then
		rev = hot.rev
	end
end

local function last_of(st: { [string]: any }): any?
	local l = st.last_run
	if type(l) ~= "table" then
		return nil
	end
	return {
		run_id = l.run_id,
		state = l.state,
		reason_code = l.reason_code,
		summary = l.summary,
		ended = l.ended,
	}
end

local function job_entries(paused_all: boolean, home: string): ({ any }, { id: string, name: string, at: number }?)
	local out: { any } = {}
	local nxt: { id: string, name: string, at: number }? = nil
	for _, j in ipairs(jobs.list()) do
		local st = jobs.state(j.id)
		local enabled = j.enabled ~= false
		local next_run = enabled and st.next_run or nil
		table.insert(out, {
			id = j.id,
			name = j.name,
			when = jobs.describe(j),
			kind = j.schedule.kind,
			next_run = next_run,
			role = j.role,
			folder = validate.tilde(tostring(j.cwd), home),
			enabled = enabled,
			paused_reason = (not enabled) and st.paused_reason or nil,
			only_when = if type(j.conditions) == "table" and #j.conditions > 0 then conditions.describe(j.conditions) else nil,
			created_by = j.created_by or "user",
			last = last_of(st),
		})
		if not paused_all and next_run ~= nil and (nxt == nil or next_run < nxt.at) then
			nxt = { id = j.id, name = j.name, at = next_run }
		end
	end
	for _, bad in ipairs(jobs.invalid()) do
		table.insert(out, {
			id = bad.id,
			name = bad.name,
			when = "",
			kind = "manual",
			role = "",
			folder = "",
			enabled = false,
			created_by = "user",
			invalid = bad.error,
		})
	end
	return out, nxt
end

local function recent_entries(now: number): ({ any }, number)
	local out: { any } = {}
	local unseen = 0
	local cutoff = now - FAILED_UNSEEN_DAYS * 86400
	for _, r in ipairs(ledger.recent(nil, 80)) do
		if const.TERMINAL[r.state] == true then
			if #out < RECENT_MAX then
				table.insert(out, {
					run_id = r.run_id,
					job_id = r.job_id,
					job_name = r.job_name,
					state = r.state,
					reason_code = r.reason_code,
					reason = r.reason,
					summary = r.summary,
					ended = r.ended,
					trigger = r.trigger,
					incident_repeat = r.incident_repeat,
				})
			end
			if
				(r.state == "failed" or r.state == "timed_out")
				and r.acked ~= true
				and (tonumber(r.ended) or 0) >= cutoff
			then
				unseen += 1
			end
		end
	end
	return out, unseen
end

-- Writes snapshot.json and kv "hot" (bumps rev). Safe to call often; kv failures are swallowed.
function snapshot.publish(view: View, now: number)
	seed_rev()
	rev += 1
	local home = jobs.home()
	local paused_all = jobs.paused_all()
	local job_rows, nxt = job_entries(paused_all, home)
	local recent, failed_unseen = recent_entries(now)

	local inflight: { any } = {}
	local running, needs_input = 0, 0
	for _, r in ipairs(view.inflight) do
		local state = tostring(r.state)
		if state == "needs_input" then
			needs_input += 1
			running += 1
		elseif state == "running" or state == "launching" then
			running += 1
		end
		table.insert(inflight, {
			run_id = r.run_id,
			job_id = r.job_id,
			job_name = r.job_name,
			block = r.block ~= nil and tostring(r.block) or nil,
			state = state,
			started = r.started,
			since = r.state_since or r.started or r.created,
		})
	end

	local health = store.health()
	local settings = jobs.settings()
	local defaults: { [string]: any } = type(settings.defaults) == "table" and settings.defaults or {}
	local placement_where = "session"
	if type(defaults.placement) == "table" and (defaults.placement :: any).where == "tab" then
		placement_where = "tab"
	end
	local snap: { [string]: any } = {
		format = 1,
		rev = rev,
		at = now,
		paused_all = paused_all,
		health = health,
		hb = now,
		setup_ok = view.setup_ok,
		jobs = array(job_rows),
		inflight = array(inflight),
		recent = array(recent),
		managers = array(view.managers),
		session_name = type(settings.session_name) == "string" and settings.session_name or const.SESSION_NAME_DEFAULT,
		placement = placement_where,
	}
	local limit = math.floor(const.CAP_SNAPSHOT * const.WRITE_CAP_RATIO)
	local text = (tern :: any).json.encode(snap)
	-- EN §2.2.8: shrink snapshot.json recent-run entries until it fits
	while #text > limit and #recent > 0 do
		for _ = 1, math.max(1, #recent // 2) do
			table.remove(recent)
		end
		snap.recent = array(recent)
		text = (tern :: any).json.encode(snap)
	end
	store.write_text("snapshot.json", text)

	pcall(function()
		(tern :: any).kv.set("hot", {
			v = 1,
			rev = rev,
			hb = now,
			paused_all = paused_all,
			running = running,
			needs_input = needs_input,
			failed_unseen = failed_unseen,
			setup_ok = view.setup_ok,
			scheduler = view.scheduler,
			health = health,
			next = nxt,
			welcome = view.welcome,
		})
	end)
end

return snapshot
