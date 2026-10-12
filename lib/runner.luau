--!strict
-- lib/runner.luau : the clock (EN §5-§7, LA §8-§10). Host only; outlives every manager block.
--   pump (PUMP_MS, armed first): intents -> events -> [slow tick: due scan, liveness, housekeeping,
--   heartbeat] -> advance runs (admission, timeouts, debounce) -> flush dirty state.
-- Every transition goes through ledger.transition (EN §7.2); facts (tail: summary, cost, session file) are
-- read BEFORE a run turns terminal. Window samples are raw; this module owns every interpretation (R9).
local const = require("./const")
local ids = require("./ids")
local jobs = require("./jobs")
local ledger = require("./ledger")
local store = require("./store")
local validate = require("./validate")
local policy = require("./policy")
local snapshot = require("./snapshot")
local bins = require("./bins")
local roles = require("./roles")
local tern_state = require("./tern_state")
local launcher = require("./launcher")
local images = require("./images")
local session_tail = require("./session_tail")
local notify = require("./notify")
local platform = require("./platform")
local intents = require("./intents")

type Run = { [string]: any }
type RT = {
	stage: string?, -- nil -> "checking" -> "ready" -> "queued"
	bins: any?,
	prompt: string?,
	obs: { state: string, since: number, seen_at: number }?,
	last_message: string?,
	finishing: boolean?,
	exiting: boolean?,
	deadline: boolean?,
	tail_busy: boolean?,
	tail_sig: string?,
	tail_since: number?,
	exit_status: number?,
	reported_failed: boolean?, -- agent_finished said "failed"
	cap_marked: boolean?,
	live_tail: { cost: number?, tools: number, requests: number, last_message: string? }?,
	live_tool: { id: string?, name: string, detail: string?, since: number }?,
	live_at: number?,
	live_sig: string?,
	live_updated: number?,
}

local runner = {}

local CONFIG_BLOCKS: { [string]: boolean } = {
	cwd_missing = true,
	cwd_home = true,
	cwd_unsafe = true,
	prompt_missing = true,
	prompt_empty = true,
	prompt_too_large = true,
	role_missing = true,
	invalid_job = true,
	omp_missing = true,
}
local CLOSE_DELAY_S = 5
local ROLE_FIRE_CACHE_S = 60 -- LA §6: at fire time a role list older than this is re-read
local WELCOME_HOLD_MS = 60000
local HOUSEKEEPING_S = 3600

local S = {
	loaded = false,
	ready = false,
	runs = {} :: { [string]: Run },
	rt = {} :: { [string]: RT },
	by_block = {} :: { [string]: string },
	subs = {} :: { [number]: () -> () },
	next_token = 1,
	managers = {} :: { string },
	events = {} :: { any }, -- queued pane_exited payloads
	gaps = {} :: { { from: number, to: number } },
	last_wall = 0,
	last_mono = 0,
	last_slow = 0,
	last_house = 0,
	first_pump = true,
	last_hb = 0,
	ls_busy = false,
	ls_waiters = {} :: { (any?) -> () },
	tstate = nil :: tern_state.State?,
	cap_check_due = false,
	cap_over = false,
	pub_dirty = true,
	sub_dirty = false,
	dirty_runs = {} :: { [string]: boolean },
	last_catchup_launch = 0,
	welcome_until = nil :: number?,
	welcome_done = false,
	keepalive = nil :: { ok: boolean, text: string }?,
	data_probe = nil :: boolean?,
	roles_probe = nil :: boolean?,
}

-- ---------- small helpers ----------

local function T(): any
	return tern
end

local function wall(): number
	return os.time()
end

local function log_warn(...: any)
	local args = table.pack(...)
	pcall(function()
		T().log.warn(table.unpack(args, 1, args.n))
	end)
end

local function log_error(...: any)
	local args = table.pack(...)
	pcall(function()
		T().log.error(table.unpack(args, 1, args.n))
	end)
end

local function clip(s: string, n: number): string
	return session_tail.clip(s, n)
end

local function home(): string
	return (T().getenv("HOME") :: string?) or ""
end

local function sorted_runs(): { Run }
	local list: { Run } = {}
	for _, r in pairs(S.runs) do
		table.insert(list, r)
	end
	table.sort(list, function(a, b)
		local sa, sb = tonumber(a.slot) or 0, tonumber(b.slot) or 0
		if sa ~= sb then
			return sa < sb
		end
		return tostring(a.run_id) < tostring(b.run_id)
	end)
	return list
end

local function mark(run: Run?)
	S.pub_dirty = true
	S.sub_dirty = true
	if run ~= nil then
		S.dirty_runs[tostring(run.run_id)] = true
	end
end

local function rt_of(run: Run): RT
	local id = tostring(run.run_id)
	local r = S.rt[id]
	if r == nil then
		r = {}
		S.rt[id] = r
	end
	return r
end

local function append_event(ev: { [string]: any })
	pcall(function()
		local text = store.read_text("events.jsonl", 262144) or ""
		local lines: { string } = {}
		for line in text:gmatch("[^\n]+") do
			table.insert(lines, line)
		end
		table.insert(lines, T().json.encode(ev))
		while #lines > 200 do
			table.remove(lines, 1)
		end
		store.write_text("events.jsonl", table.concat(lines, "\n") .. "\n")
	end)
end

local function proc(argv: { string }, opts: { [string]: any }, cb: (any) -> ())
	local ok, err = pcall(function()
		T().process.run(argv, opts, cb)
	end)
	if not ok then
		cb({ status = -1, stdout = "", stderr = tostring(err), timed_out = false, raised = true })
	end
end

local function tern_bin(): string?
	return bins.found().tern
end

-- ---------- outcome bookkeeping ----------

local function alert(run: Run, key: string, text: string)
	notify.send(run, key, "Agent Scheduler · " .. tostring(run.job_name), text)
end

-- Updates last_run / streak / incident / auto-pause for a terminal run (EN §6.5) and sends the
-- failure notification (once per incident). Success never notifies.
local function record_outcome(run: Run)
	local state = tostring(run.state)
	local code = tostring(run.reason_code or "")
	local job = jobs.get(tostring(run.job_id))
	if job == nil then
		return
	end
	local st = jobs.state(job.id)
	local test = run.trigger == "test"
	local launched_like = state == "finished" or state == "failed" or state == "timed_out" or state == "cancelled" or state == "blocked"
	if launched_like and not test then
		st.last_run = {
			run_id = run.run_id,
			slot = run.slot,
			started = run.started,
			ended = run.ended,
			state = state,
			reason_code = run.reason_code,
			summary = run.summary,
		}
		if run.started ~= nil then
			st.runs_total = (tonumber(st.runs_total) or 0) + 1
		end
	end
	if test then
		return
	end
	local counted = (state == "failed" and code ~= "interrupted" and code ~= "data_unwritable")
		or state == "timed_out"
		or (state == "blocked" and CONFIG_BLOCKS[code] == true)
	if state == "finished" then
		st.failure_streak = 0
		st.incident = nil
	elseif counted then
		st.failure_streak = (tonumber(st.failure_streak) or 0) + 1
		if st.incident == nil then
			st.incident = { since = run.ended or wall(), run_id = run.run_id, notified = true }
			alert(run, state, clip(tostring(run.reason ~= "" and run.reason or state), 120))
		end
		local limit = tonumber(job.pause_after_failures) or 3
		if limit ~= 0 and (tonumber(st.failure_streak) or 0) >= limit and job.enabled ~= false then
			jobs.pause(job.id, state == "blocked" and "blocked" or "failures")
			alert(run, "paused", string.format("%s paused after %d failures.", tostring(job.name), limit))
		end
	elseif state == "failed" or (state == "blocked" and not CONFIG_BLOCKS[code]) then
		-- not counted (interrupted, data_unwritable, tern_missing): still host-visible
		alert(run, state, clip(tostring(run.reason ~= "" and run.reason or state), 120))
	end
	jobs.save_state()
end

local close_block: (Run, (() -> ())?) -> ()

local function maybe_close_after(run: Run)
	local job = jobs.get(tostring(run.job_id))
	if job == nil or run.block == nil or run.trigger == "test" then
		return
	end
	local after = job.after
	local state = tostring(run.state)
	local do_close = false
	if after == "close" and run.reason_code ~= "no_response" then
		do_close = true
	elseif after == "close_ok" and state == "finished" then
		do_close = true
	end
	if not do_close then
		return
	end
	pcall(function()
		T().timer(CLOSE_DELAY_S * 1000, function()
			local b = tern_bin()
			if b == nil then
				return
			end
			tern_state.snapshot(b, function(st)
				if st == nil then
					return
				end
				local blk = st.blocks[tostring(run.block)]
				if blk ~= nil and blk.focused ~= true and st.by_run[tostring(run.job_id) .. "/" .. tostring(run.run_id)] == blk then
					close_block(run)
				end
			end)
		end)
	end)
end

local function on_terminal(run: Run)
	local id = tostring(run.run_id)
	S.runs[id] = nil
	S.rt[id] = nil
	if run.block ~= nil then
		S.by_block[tostring(run.block)] = nil
	end
	local list = jobs.inflight()
	for i = #list, 1, -1 do
		if list[i] == id then
			table.remove(list, i)
		end
	end
	pcall(record_outcome, run)
	jobs.save_state()
	if run.block ~= nil then
		S.cap_check_due = true
		maybe_close_after(run)
	end
	mark(nil)
end

local function transition(run: Run, state: string, code: string?, fields: { [string]: any }?): boolean
	local ok, err = ledger.transition(run, state, code, fields, wall())
	if not ok then
		log_warn("runner: transition refused", tostring(run.run_id), tostring(run.state), state, tostring(err))
		return false
	end
	if err == "not_persisted" then
		log_warn("runner: run record not persisted", tostring(run.run_id))
	end
	mark(run)
	if const.TERMINAL[state] == true then
		on_terminal(run)
	end
	return true
end

-- ---------- facts ----------

local function read_facts(run: Run, cb: (session_tail.Facts?) -> ())
	session_tail.read(store.path(tostring(run.run_dir)), function(facts)
		cb(facts)
	end)
end

local function apply_facts(run: Run, facts: session_tail.Facts?)
	if facts == nil then
		return
	end
	run.session_file = facts.session_file
	run.session_id = facts.session_id
	if facts.cost ~= nil then
		run.cost = facts.cost
		run.cost_approx = facts.cost_approx
	end
	if facts.last_message ~= nil then
		run.last_message = facts.last_message
	end
	if facts.summary ~= nil and facts.summary ~= "" then
		run.summary = facts.summary
	end
	if facts.failed_reason ~= nil then
		run.detail = facts.failed_reason
	end
end

-- Summary from a window sample when no session file could be read.
local function apply_sample_message(run: Run, rt: RT)
	local lm = rt.last_message
	if lm == nil or lm == "" then
		return
	end
	if run.last_message == nil then
		run.last_message = clip(lm, const.LAST_MESSAGE_MAX)
	end
	local cost_line = nil
	for line in lm:gmatch("[^\n]+") do
		if line:find("·", 1, true) and line:find("tok", 1, true) then
			cost_line = line
		end
	end
	if cost_line ~= nil then
		run.cost_line = cost_line
	end
	if run.summary == nil or run.summary == "" then
		local summary, failed = session_tail.summarize(lm)
		if summary ~= "" then
			run.summary = summary
		end
		if failed ~= nil and run.detail == nil then
			run.detail = failed
		end
	end
end

-- Lines omp prints around its own exit that say nothing about why it failed.
local TAIL_CHROME = { "^Closing session", "^Update Available", "^New version .+ is available", "Run: omp update" }

-- `--surfaces` because plain capture is empty for omp panes even after omp exits; with it omp's text comes
-- through and ordinary grid text is still included.
local function capture_tail(run: Run, cb: (string?) -> ())
	local b, block = tern_bin(), run.block
	if b == nil or block == nil then
		return cb(nil)
	end
	proc({ b, "capture", tostring(block), "--surfaces" }, { timeout_ms = 5000 }, function(r)
		if r.status ~= 0 then
			return cb(nil)
		end
		local text = tostring(r.stdout):gsub("\27%[[%d;?]*[%a]", ""):gsub("%c", "\n")
		local last: string? = nil
		local last_error: string? = nil
		for line in text:gmatch("[^\n]+") do
			local t = line:gsub("^%s+", ""):gsub("%s+$", "")
			local chrome = t == ""
			for _, pat in TAIL_CHROME do
				chrome = chrome or t:find(pat) ~= nil
			end
			if not chrome then
				last = t
				if t:find("^Error") or t:find("error:", 1, true) or t:find("Error:", 1, true) then
					last_error = t
				end
			end
		end
		local pick = last_error or last
		cb(pick ~= nil and clip(pick, 120) or nil)
	end)
end

-- ---------- finishing a run ----------

local function finish_with(run: Run, facts: session_tail.Facts?, unobserved: boolean)
	if const.TERMINAL[tostring(run.state)] == true then
		return
	end
	local rt = rt_of(run)
	apply_facts(run, facts)
	apply_sample_message(run, rt)
	if run.detail ~= nil or rt.reported_failed == true then
		transition(run, "failed", "agent_failed", {})
		return
	end
	if unobserved then
		run.observed = false
	end
	transition(run, "finished", (run.observed == true and not unobserved) and "ok" or "ok_unobserved", {})
end

local function begin_finish(run: Run, unobserved: boolean)
	local rt = rt_of(run)
	if rt.finishing then
		return
	end
	rt.finishing = true
	read_facts(run, function(facts)
		local cur = S.runs[tostring(run.run_id)]
		if cur == nil then
			return
		end
		rt.finishing = false
		finish_with(run, facts, unobserved)
	end)
end

local function timed_out_code(run: Run): string
	return run.state == "needs_input" and "waiting_for_input" or "max_runtime"
end

local function force_deadline(run: Run)
	local rt = rt_of(run)
	if rt.deadline then
		return
	end
	rt.deadline = true
	read_facts(run, function(facts)
		if S.runs[tostring(run.run_id)] == nil then
			return
		end
		run.close_requested = true
		apply_facts(run, facts)
		if facts ~= nil and facts.completed_turn then
			run.observed = false
			transition(run, "finished", "ok_unobserved", {})
		else
			transition(run, "timed_out", timed_out_code(run), {})
		end
		close_block(run)
	end)
end

local function handle_exit(run: Run, status: number)
	local rt = rt_of(run)
	if rt.exiting or const.TERMINAL[tostring(run.state)] == true then
		return
	end
	rt.exiting = true
	local now = wall()
	local elapsed = now - (tonumber(run.started) or tonumber(run.created) or now)
	local limit = tonumber(run.max_runtime_s) or const.MAXRUN_DEFAULT_S
	read_facts(run, function(facts)
		if S.runs[tostring(run.run_id)] == nil then
			return
		end
		apply_facts(run, facts)
		apply_sample_message(run, rt)
		if elapsed >= limit - const.EXIT_NEAR_LIMIT_S then
			if facts ~= nil and facts.completed_turn and facts.failed_reason == nil then
				run.observed = run.observed == true
				transition(run, "finished", run.observed == true and "ok" or "ok_unobserved", {})
			else
				transition(run, "timed_out", timed_out_code(run), {})
			end
		elseif status ~= 0 then
			capture_tail(run, function(line)
				transition(run, "failed", "agent_error", { detail = line or string.format("omp exited with status %d", status) })
			end)
		elseif facts ~= nil and facts.failed_reason ~= nil then
			transition(run, "failed", "agent_failed", {})
		elseif run.busy_seen == true or (facts ~= nil and facts.completed_turn) then
			transition(run, "finished", run.observed == true and "ok" or "ok_unobserved", {})
		else
			capture_tail(run, function(line)
				transition(run, "failed", "exited_early", { detail = line })
			end)
		end
	end)
end

-- ---------- closing panes ----------

function close_block(run: Run, cb: (() -> ())?)
	local b, block = tern_bin(), run.block
	if b == nil or block == nil then
		if cb then
			cb()
		end
		return
	end
	run.close_requested = true
	pcall(ledger.save, run)
	proc({ b, "close", tostring(block) }, { timeout_ms = 8000 }, function()
		run.pane_closed_at = wall()
		pcall(ledger.save, run)
		if cb then
			cb()
		end
	end)
end

-- EN §6.9: at most settings.max_finished_panes finished run panes stay open, oldest unfocused first.
local function enforce_cap(st: tern_state.State)
	local limit = tonumber(jobs.settings().max_finished_panes) or const.MAX_FINISHED_PANES
	local finished: { { block: any, run: Run? } } = {}
	for key, blk in pairs(st.by_run) do
		local run_id = key:match("/(r_[%w_]+)$")
		if run_id ~= nil and S.runs[run_id] == nil then
			table.insert(finished, { block = blk, run = ledger.get(run_id) })
		end
	end
	local over = #finished - limit
	if over <= 0 then
		S.cap_over = false
		return
	end
	local cands: { { block: any, run: Run, key: number } } = {}
	for _, f in ipairs(finished) do
		local run = f.run
		if f.block.focused ~= true and run ~= nil and const.TERMINAL[tostring(run.state)] == true and run.pane_closed_at == nil then
			table.insert(cands, { block = f.block, run = run, key = tonumber(run.ended) or tonumber(run.created) or 0 })
		end
	end
	table.sort(cands, function(a, b)
		return a.key < b.key
	end)
	local n = 0
	for _, c in ipairs(cands) do
		if n >= over then
			break
		end
		n += 1
		close_block(c.run)
	end
	S.cap_over = n < over
end

-- ---------- tern state: liveness and reconcile (EN §5.4, LA §8.2) ----------

local start_launch: (Run, RT) -> ()

local function gap_precedes(run: Run): boolean
	local since = tonumber(run.created) or 0
	for _, g in ipairs(S.gaps) do
		if g.to >= since then
			return true
		end
	end
	return false
end

local function process_liveness(st: tern_state.State, asked_at: number)
	local now = wall()
	for _, run in ipairs(sorted_runs()) do
		local state = tostring(run.state)
		local key = tostring(run.job_id) .. "/" .. tostring(run.run_id)
		local rt = rt_of(run)
		if state == "scheduled" then
			continue
		end
		if run.block == nil then
			-- a launch that never reported: adopt the orphan pane, or re-queue after ORPHAN_WAIT_S
			if state == "launching" and rt.stage ~= "queued" then
				local b = st.by_run[key]
				if b ~= nil then
					run.block = b.id
					S.by_block[b.id] = tostring(run.run_id)
					transition(run, "running", nil, { block = b.id, tab = b.tab, started = now })
				elseif rt.stage == nil and now - (tonumber(run.state_since) or now) >= const.ORPHAN_WAIT_S then
					rt.stage = "relaunch" -- only from a settled stage: a preflight in flight ("checking") must not be duplicated
				end
			end
			continue
		end
		if (tonumber(run.started) or 0) >= asked_at and state == "running" then
			continue -- launched after this `tern ls` was requested
		end
		local b = st.blocks[tostring(run.block)]
		local ours = b ~= nil and st.by_run[key] ~= nil and st.by_run[key].id == b.id
		if not ours then
			if run.close_requested ~= true and run.cancel_requested ~= true then
				-- EN §7.3: a daemon/heartbeat gap before the pane vanished => interrupted, else the user closed it
				if gap_precedes(run) then
					transition(run, "failed", "interrupted", {})
				else
					run.cancel_requested = true
					transition(run, "cancelled", "closed_by_user", {})
				end
			end
		else
			local ex: number? = b.exited
			if ex == nil and rt.exit_status ~= nil then
				ex = rt.exit_status
			end
			if ex ~= nil then
				handle_exit(run, ex)
			end
		end
	end
end

-- Re-reads `tern ls --json`, then runs liveness and the pane cap. Single flight; cb(State?) afterwards.
local function refresh_state(cb: ((tern_state.State?) -> ())?)
	local b = tern_bin()
	if b == nil then
		if cb then
			cb(nil)
		end
		return
	end
	if S.ls_busy then
		if cb then
			table.insert(S.ls_waiters, cb)
		end
		return
	end
	S.ls_busy = true
	local asked = wall()
	tern_state.snapshot(b, function(st)
		S.ls_busy = false
		if st ~= nil then
			S.tstate = st
			local ok, err = pcall(function()
				process_liveness(st, asked)
				enforce_cap(st)
			end)
			if not ok then
				log_error("runner: liveness", tostring(err))
			end
			S.cap_check_due = false
		end
		if cb then
			cb(st)
		end
		local waiters = S.ls_waiters
		S.ls_waiters = {}
		for _, w in ipairs(waiters) do
			w(st)
		end
	end)
end

-- ---------- preflight and admission (EN §5.6, §6.4) ----------

type PreResult = { bins: any, prompt: string, role_unverified: boolean }

local function preflight(run: Run, job: { [string]: any }, done: (string?, PreResult?) -> ())
	local settings = jobs.settings()
	if jobs.get(job.id) == nil or job.approval == "read_only" then
		return done("invalid_job", nil)
	end
	local function with_bins(b: any)
		local cwd = tostring(job.cwd)
		if cwd:find("%c") ~= nil then
			return done("cwd_unsafe", nil) -- cwd is only an argv element; only control characters are refused
		end
		local h = home():gsub("/+$", "")
		if h ~= "" and cwd:gsub("/+$", "") == h and job.allow_home ~= true then
			return done("cwd_home", nil)
		end
		proc({ "/bin/test", "-d", cwd }, { timeout_ms = 3000 }, function(r)
			if r.status ~= 0 then
				return done("cwd_missing", nil)
			end
			local prompt = jobs.prompt(job.id)
			if prompt == nil then
				return done("prompt_missing", nil)
			end
			if prompt:gsub("%s", "") == "" then
				return done("prompt_empty", nil)
			end
			if #prompt > const.PROMPT_MAX then
				return done("prompt_too_large", nil)
			end
			local role = tostring(job.role or "default")
			local function with_list(list: { string }?)
				local unverified = list == nil
				if list ~= nil then
					local present = false
					for _, r2 in ipairs(list) do
						if r2 == role then
							present = true
						end
					end
					if not present then
						roles.invalidate(cwd)
						return done("role_missing", nil)
					end
				end
				done(nil, { bins = b, prompt = prompt, role_unverified = unverified })
			end
			local cached = roles.cached(cwd, ROLE_FIRE_CACHE_S)
			if cached ~= nil then
				return with_list(cached)
			end
			roles.list(b.omp, cwd, function(list)
				with_list(list)
			end)
		end)
	end
	bins.resolve(settings, function(b, berr)
		if b == nil then
			return done(berr or "omp_missing", nil)
		end
		if not T().fs.exists(b.omp) then
			-- the cached path went stale (omp moved or removed): re-resolve once
			bins.invalidate()
			return bins.resolve(settings, function(b2, e2)
				if b2 == nil or not T().fs.exists(b2.omp) then
					return done(e2 or "omp_missing", nil)
				end
				with_bins(b2)
			end, true)
		end
		with_bins(b)
	end)
end

local function others_active(run: Run): boolean
	for id, r in pairs(S.runs) do
		if r ~= run and r.job_id == run.job_id then
			local s = tostring(r.state)
			if s == "launching" or s == "running" or s == "needs_input" then
				return true
			end
		end
	end
	return false
end

local function active_count(): number
	local n = 0
	for _, r in pairs(S.runs) do
		local s = tostring(r.state)
		if s == "launching" or s == "running" or s == "needs_input" then
			n += 1
		end
	end
	return n
end

local function slot_local(slot: number): string?
	local ok, s = pcall(function()
		return os.date("%a %Y-%m-%d %H:%M", slot)
	end)
	return ok and s :: string or nil
end

function start_launch(run: Run, rt: RT)
	local job = jobs.get(tostring(run.job_id))
	local b = rt.bins
	if job == nil or b == nil or rt.prompt == nil then
		return
	end
	local settings = jobs.settings()
	local defaults = type(settings.defaults) == "table" and settings.defaults or {}
	local where = (type(defaults.placement) == "table" and defaults.placement.where) or "session"
	local req: launcher.LaunchRequest = {
		run = run,
		job = job,
		prompt = rt.prompt,
		bins = b,
		session_name = tostring(settings.session_name or const.SESSION_NAME_DEFAULT),
		where = tostring(where),
		focus = tostring(run.focus_override or defaults.focus or "keep"),
		trigger = tostring(run.trigger),
		slot_local = slot_local(tonumber(run.slot) or wall()),
	}
	rt.stage = "queued"
	launcher.enqueue(req, function(res, err)
		if S.runs[tostring(run.run_id)] == nil then
			-- cancelled or dropped while waiting: do not leave a stray pane behind
			if res ~= nil then
				local tb = tern_bin()
				if tb ~= nil then
					proc({ tb, "close", res.block }, { timeout_ms = 8000 }, function() end)
				end
			end
			return
		end
		if res ~= nil then
			if run.state ~= "launching" then
				-- never close the run's own pane (a duplicate attempt may have adopted the same block)
				if res.block ~= tostring(run.block) then
					local tb = tern_bin()
					if tb ~= nil then
						proc({ tb, "close", res.block }, { timeout_ms = 8000 }, function() end)
					end
				end
				return
			end
			run.block = res.block
			S.by_block[res.block] = tostring(run.run_id)
			transition(run, "running", nil, {
				block = res.block,
				tab = res.tab,
				session = res.session,
				placement_used = res.placement_used,
				started = wall(),
			})
			return
		end
		local code = err and err.code or "launch_error"
		local text = err and err.text or ""
		if code == "data_unwritable" then
			transition(run, "failed", "data_unwritable", { detail = text })
		elseif code == "launch_timeout" then
			transition(run, "failed", "launch_timeout", { detail = text })
		else
			transition(run, "failed", "launch_error", { detail = text })
		end
	end)
end

local function blocked(run: Run, code: string)
	transition(run, "blocked", code, {})
end

local function run_admission(run: Run, rt: RT, now: number)
	local settings = jobs.settings()
	local job = jobs.get(tostring(run.job_id))
	if job == nil then
		return
	end
	-- overlap (EN §6.2)
	local mode = tostring(job.overlap or "skip")
	if mode ~= "parallel" and others_active(run) then
		if mode == "queue" then
			return -- wait for the previous run (latest waiting slot wins, below)
		end
		transition(run, "skipped", "overlap", {})
		return
	end
	-- cap (EN §6.3)
	local limit = tonumber(settings.max_concurrent) or const.MAX_CONCURRENT_DEFAULT
	if active_count() >= limit then
		if not rt.cap_marked then
			rt.cap_marked = true
			ledger.transition(run, "scheduled", "waiting_cap", { cap_limit = limit }, now)
			mark(run)
		end
		if now - (tonumber(run.created) or now) >= (tonumber(settings.cap_wait_s) or const.CAP_WAIT_S_DEFAULT) then
			transition(run, "skipped", "cap", { cap_limit = limit })
		end
		return
	end
	-- catch-up spacing (EN §5.6 step 7)
	if run.trigger == "catchup" then
		local spacing = tonumber(settings.catchup_spacing_s) or const.CATCHUP_SPACING_S_DEFAULT
		if now - S.last_catchup_launch < spacing then
			return
		end
		S.last_catchup_launch = now
	end
	-- the launch
	local b = rt.bins
	local fields: { [string]: any } = {
		omp_path = b.omp,
		omp_version = b.omp_version,
		prompt_head = clip(rt.prompt or "", 200),
		overlay = true,
	}
	if run.reason_code == "waiting_cap" then
		run.reason_code = nil
	end
	if transition(run, "launching", nil, fields) then
		start_launch(run, rt)
	end
end

local function advance_scheduled(now: number)
	local list = sorted_runs()
	-- overlap=queue: only the newest waiting slot of a job survives
	local newest: { [string]: Run } = {}
	for _, run in ipairs(list) do
		if run.state == "scheduled" then
			local job = jobs.get(tostring(run.job_id))
			if job ~= nil and job.overlap == "queue" and rt_of(run).stage == "ready" then
				local prev = newest[tostring(run.job_id)]
				if prev ~= nil then
					transition(prev, "skipped", "overlap_replaced", {})
				end
				newest[tostring(run.job_id)] = run
			end
		end
	end
	for _, run in ipairs(list) do
		if run.state == "scheduled" and S.runs[tostring(run.run_id)] ~= nil then
			local rt = rt_of(run)
			local job = jobs.get(tostring(run.job_id))
			if job == nil then
				-- handled by drop_deleted
			elseif jobs.settings().paused_all == true then
				-- EN §6.7: Pause all is an absolute kill switch, including for runs already claimed
				transition(run, "skipped", "paused_all", {})
			elseif job.enabled == false and run.trigger ~= "manual" and jobs.state(job.id).done ~= true then
				-- Paused by the user (or for failures) while this run waited. A one-shot also turns
				-- itself off (`done`) as soon as its run is claimed; that run must still go ahead.
				transition(run, "cancelled", "user_stop", {})
			elseif rt.stage == nil then
				rt.stage = "checking"
				preflight(run, job, function(code, pre)
					if S.runs[tostring(run.run_id)] == nil or run.state ~= "scheduled" then
						return
					end
					if code ~= nil then
						return blocked(run, code)
					end
					local p = pre :: PreResult
					rt.bins, rt.prompt = p.bins, p.prompt
					if p.role_unverified then
						local notes = type(run.notes) == "table" and run.notes or {}
						table.insert(notes, "role_unverified")
						run.notes = notes
					end
					rt.stage = "ready"
					mark(run)
				end)
			elseif rt.stage == "ready" then
				run_admission(run, rt, now)
			end
		end
	end
end

-- A launch that never reported (restored at load, or its `tern new` was lost) and left no pane: run the
-- preflight again to rebuild the request, then queue the launch (EN §5.4: safe, the pane provably doesn't exist).
local function relaunch_orphans()
	for _, run in ipairs(sorted_runs()) do
		local rt = rt_of(run)
		if run.state == "launching" and run.block == nil and rt.stage == "relaunch" then
			rt.stage = "checking"
			local job = jobs.get(tostring(run.job_id))
			if job == nil then
				continue
			end
			preflight(run, job, function(code, pre)
				if S.runs[tostring(run.run_id)] == nil or run.state ~= "launching" then
					return
				end
				if code ~= nil then
					transition(run, "failed", "launch_error", { detail = "Blocked: " .. code })
					return
				end
				local p = pre :: PreResult
				rt.bins, rt.prompt = p.bins, p.prompt
				start_launch(run, rt)
			end)
		end
	end
end

-- ---------- claims and the due scan (EN §5.6, §6.1) ----------

local function remove_inflight(id: string)
	local list = jobs.inflight()
	for i = #list, 1, -1 do
		if list[i] == id then
			table.remove(list, i)
		end
	end
end

-- Persist a new run before anything acts on it (claim-then-act). nil when the claim could not be written.
local function claim(job: { [string]: any }, run_id: string, trigger: string, slot: number, now: number, focus_override: string?): Run?
	local run = ledger.new(job, { run_id = run_id, trigger = trigger, slot = slot, now = now, focus_override = focus_override })
	table.insert(jobs.inflight(), run_id)
	S.runs[run_id] = run
	S.rt[run_id] = {}
	local ok_ledger = ledger.save(run)
	local ok_state = jobs.save_state()
	if not (ok_ledger and ok_state) then
		S.runs[run_id] = nil
		S.rt[run_id] = nil
		remove_inflight(run_id)
		-- never persisted: drop it from the ledger cache so the retried slot (same deterministic run id) isn't mistaken for handled
		ledger.forget(run)
		log_warn("runner: claim not persisted", run_id)
		return nil
	end
	mark(run)
	return run
end

-- A run record that never launches (skipped / missed): created and terminal at once.
local function record_only(job: { [string]: any }, run_id: string, trigger: string, slot: number, now: number, state: string, code: string, fields: { [string]: any })
	if ledger.get(run_id) ~= nil then
		return
	end
	local f: { [string]: any } = { run_id = run_id, trigger = trigger, slot = slot, now = now }
	for k, v in pairs(fields) do
		f[k] = v
	end
	local run = ledger.new(job, f)
	ledger.transition(run, state, code, nil, now)
	mark(run)
end

local function finish_once(job: { [string]: any })
	jobs.pause(job.id, nil :: any)
	local st = jobs.state(job.id)
	st.done = true
	jobs.save_state()
end

local function due_scan(now: number)
	local settings = jobs.settings()
	local paused_all = settings.paused_all == true
	local health_ok = store.health() == "ok"
	local touched = false
	local list: { { [string]: any } } = {}
	for _, j in ipairs(jobs.list()) do
		table.insert(list, j)
	end
	for _, job in ipairs(list) do
		if job.enabled == false or job.schedule.kind == "manual" then
			continue
		end
		local st = jobs.state(job.id)
		local view = jobs.policy_view(job)
		local ok, res = pcall(policy.decide, view, now)
		if not ok then
			log_error("runner: policy.decide", tostring(job.id), tostring(res))
			continue
		end
		if res.fire == nil and res.missed == nil then
			if st.next_run ~= res.next_run then
				st.next_run = res.next_run
				touched = true
			end
			if res.done then
				finish_once(job)
				touched = true
			end
			continue
		end
		if not paused_all and not health_ok then
			continue -- EN §5.6 step 2: do not claim; the slot stays due
		end
		local latest = res.fire ~= nil and res.fire.slot or res.missed.last
		local first_slot = res.missed ~= nil and res.missed.first or res.fire.slot
		local total = (res.fire ~= nil and 1 or 0) + (res.missed ~= nil and res.missed.count or 0)
		local old_cursor, old_next = st.cursor, st.next_run
		st.cursor = latest
		st.next_run = res.next_run
		touched = true
		if paused_all then
			record_only(job, ids.run_id(job.id, first_slot), "schedule", latest, now, "skipped", "paused_all", {
				count = total,
				first = first_slot,
				last = latest,
			})
		else
			if res.missed ~= nil then
				local over_window = res.fire == nil and job.catch_up ~= "skip"
				record_only(job, ids.run_id(job.id, res.missed.first), "schedule", res.missed.last, now, "missed", over_window and "late" or "asleep_or_closed", {
					count = res.missed.count,
					first = res.missed.first,
					last = res.missed.last,
					window_s = view.catch_up_window_s,
				})
			end
			if res.fire ~= nil then
				local run_id = ids.run_id(job.id, res.fire.slot)
				if S.runs[run_id] == nil and ledger.get(run_id) == nil then
					local run = claim(job, run_id, res.fire.catchup and "catchup" or "schedule", res.fire.slot, now, nil)
					if run == nil then
						st.cursor, st.next_run = old_cursor, old_next
					end
				end
			end
		end
		if res.done then
			finish_once(job)
		end
	end
	if touched then
		jobs.save_state()
		S.pub_dirty = true
	end
end

-- ---------- live view (manager rows / detail) ----------

local LIVE_MESSAGE_MAX = 500

local function live_sig(live: { [string]: any }): string
	local tool = live.tool
	return table.concat({
		tostring(live.obs),
		tostring(live.model),
		tostring(live.last_message),
		tostring(live.cost),
		tostring(live.tools),
		tostring(live.requests),
		if tool ~= nil then tostring(tool.name) .. "|" .. tostring(tool.detail) .. "|" .. tostring(tool.since) else "-",
	}, "\31")
end

local function build_live(run_id: string): { [string]: any }?
	local run = S.runs[run_id]
	local rt = S.rt[run_id]
	if run == nil or rt == nil or (run.state ~= "running" and run.state ~= "needs_input") then
		return nil
	end
	local lt = rt.live_tail
	local lm: string? = nil
	local raw = rt.last_message
	if raw ~= nil and raw ~= "" then
		lm = raw
	elseif lt ~= nil and lt.last_message ~= nil then
		lm = lt.last_message
	elseif type(run.last_message) == "string" then
		lm = run.last_message :: string
	end
	if lm ~= nil then
		lm = clip(session_tail.body(lm), LIVE_MESSAGE_MAX)
		if lm == "" then
			lm = nil
		end
	end
	local tool = rt.live_tool
	return {
		obs = if rt.obs ~= nil then rt.obs.state else nil,
		model = run.model,
		last_message = lm,
		cost = if lt ~= nil then lt.cost else nil,
		tools = if lt ~= nil then lt.tools else nil,
		requests = if lt ~= nil then lt.requests else nil,
		tool = if tool ~= nil then { name = tool.name, detail = tool.detail, since = tool.since } else nil,
		updated = rt.live_updated or wall(),
	}
end

-- Marks subscribers dirty only when what the manager would draw changed.
local function check_live(run: Run)
	local id = tostring(run.run_id)
	local rt = S.rt[id]
	local live = build_live(id)
	if rt == nil or live == nil then
		return
	end
	local sig = live_sig(live)
	if rt.live_sig ~= sig then
		rt.live_sig = sig
		S.sub_dirty = true
	end
end

local function apply_live_facts(rt: RT, facts: session_tail.Facts)
	rt.live_tail = { cost = facts.cost, tools = facts.tools, requests = facts.requests, last_message = facts.last_message }
	local t = facts.tool
	if t == nil then
		rt.live_tool = nil
	else
		local cur = rt.live_tool
		local same = cur ~= nil and cur.name == t.name and cur.detail == t.detail and cur.id == t.id
		if not same then
			rt.live_tool = { id = t.id, name = t.name, detail = t.detail, since = wall() }
		end
	end
	rt.live_updated = wall()
end

-- One tail per run at a time; no session file yet => read_facts reports nil and nothing is spawned.
local function refresh_live_one(run: Run, now: number)
	local rt = rt_of(run)
	if rt.tail_busy or rt.finishing then
		return
	end
	rt.live_at = now
	rt.tail_busy = true
	read_facts(run, function(facts)
		rt.tail_busy = false
		if S.runs[tostring(run.run_id)] == nil or (run.state ~= "running" and run.state ~= "needs_input") then
			return
		end
		if facts ~= nil then
			apply_live_facts(rt, facts)
		end
		check_live(run)
	end)
end

local function refresh_live(now: number)
	for _, run in ipairs(sorted_runs()) do
		if run.state == "running" or run.state == "needs_input" then
			local rt = rt_of(run)
			if now - (rt.live_at or 0) >= const.LIVE_TAIL_S then
				refresh_live_one(run, now)
			end
		end
	end
end

-- ---------- window samples (R9: raw in, host decides) ----------

local function on_obs(p: { [string]: any })
	local run_id = S.by_block[tostring(p.block)]
	local run = run_id and S.runs[run_id]
	if run == nil then
		return
	end
	local rt = rt_of(run)
	local now = wall()
	local prev = rt.obs
	if prev == nil or prev.state ~= p.state then
		rt.obs = { state = tostring(p.state), since = now, seen_at = now }
		if prev ~= nil then
			refresh_live_one(run, now) -- state change: refresh the tail now
		end
	else
		prev.seen_at = now
	end
	if run.observed ~= true then
		run.observed = true
		mark(run)
	end
	if type(p.model) == "string" and p.model ~= "" and run.model ~= p.model then
		run.model = p.model
		mark(run)
	end
	if type(p.last_message) == "string" then
		rt.last_message = p.last_message
		if p.last_message ~= "" and run.busy_seen ~= true then
			run.busy_seen = true
			mark(run)
		end
	end
	if p.delivery_error ~= nil and run.state ~= "launching" then
		run.detail = p.delivery_error
		transition(run, "failed", "delivery_error", {})
		return
	end
	if p.state == "working" then
		if run.busy_seen ~= true then
			run.busy_seen = true
			run.first_work_at = now
			mark(run)
		end
		if run.state == "needs_input" then
			transition(run, "running", nil, {})
		end
	end
	if S.runs[tostring(run.run_id)] ~= nil then
		check_live(run)
	end
	-- agent_finished: omp itself reported the end of its turn, so no idle hold is needed
	local finished = p.finished
	if
		(finished == "done" or finished == "failed")
		and S.runs[tostring(run.run_id)] ~= nil
		and (run.state == "running" or run.state == "needs_input")
	then
		if run.busy_seen ~= true then
			run.busy_seen = true
			mark(run)
		end
		if finished == "failed" then
			rt.reported_failed = true
		end
		begin_finish(run, false)
	end
end

-- ---------- advancing runs ----------

local function advance_runs(now: number)
	for _, run in ipairs(sorted_runs()) do
		local state = tostring(run.state)
		if state ~= "running" and state ~= "needs_input" then
			continue
		end
		local rt = rt_of(run)
		local obs = rt.obs
		local fresh = obs ~= nil and now - obs.seen_at <= const.OBS_STALE_S
		local started = tonumber(run.started) or now
		local limit = tonumber(run.max_runtime_s) or const.MAXRUN_DEFAULT_S
		if now >= started + limit + const.MAXRUN_GRACE_S then
			force_deadline(run)
		elseif fresh and obs ~= nil then
			if state == "running" and obs.state == "waiting_input" and now - obs.since >= const.NEEDS_INPUT_S then
				if transition(run, "needs_input", nil, {}) then
					alert(run, "needs_input", "Waiting for you.")
				end
			elseif state == "needs_input" and obs.state == "waiting_input" then
				if now - (tonumber(run.state_since) or now) >= const.NEEDS_INPUT_REMIND_S then
					alert(run, "needs_input_reminder", "Still waiting for you.")
				end
			elseif obs.state == "idle" and run.busy_seen == true and now - obs.since >= const.FINISH_CONFIRM_S and not rt.finishing then
				begin_finish(run, false)
			end
		end
		if
			S.runs[tostring(run.run_id)] ~= nil
			and run.state == "running"
			and run.observed == true
			and run.busy_seen ~= true
			and fresh -- stale samples prove nothing: leave unobserved runs to the tail and deadline tiers
			and (rt.last_message == nil or rt.last_message == "")
			and now - started >= const.NO_RESPONSE_S
		then
			transition(run, "failed", "no_response", {})
		end
	end
end

-- No window watching: the session tail shows a completed assistant turn that has not grown for 15 s (EN §7.3 T2).
local function poll_unobserved(now: number)
	for _, run in ipairs(sorted_runs()) do
		if run.state == "running" or run.state == "needs_input" then
			local rt = rt_of(run)
			local obs = rt.obs
			local fresh = obs ~= nil and now - obs.seen_at <= const.OBS_STALE_S
			if not fresh and not rt.tail_busy and not rt.finishing and now - (tonumber(run.started) or now) >= 20 then
				rt.tail_busy = true
				read_facts(run, function(facts)
					rt.tail_busy = false
					if S.runs[tostring(run.run_id)] == nil then
						return
					end
					if facts ~= nil and facts.completed_turn then
						local sig = string.format("%s|%s|%d", tostring(facts.cost), tostring(facts.session_id), #(facts.last_message or ""))
						if rt.tail_sig ~= sig then
							rt.tail_sig, rt.tail_since = sig, wall()
						elseif wall() - (rt.tail_since or wall()) >= 15 then
							finish_with(run, facts, true)
						end
					else
						rt.tail_sig = nil
					end
				end)
			end
		end
	end
end

-- A run whose job was deleted: stop tracking and close its pane, write nothing (the ledger is gone).
local function drop_deleted()
	for _, run in ipairs(sorted_runs()) do
		if jobs.get(tostring(run.job_id)) == nil then
			local id = tostring(run.run_id)
			S.runs[id] = nil
			S.rt[id] = nil
			if run.block ~= nil then
				S.by_block[tostring(run.block)] = nil
				local b = tern_bin()
				if b ~= nil then
					proc({ b, "close", tostring(run.block) }, { timeout_ms = 8000 }, function() end)
				end
			end
			remove_inflight(id)
			mark(nil)
		end
	end
end

-- ---------- publishing ----------

local function setup_ok(): boolean
	local f = bins.found()
	return f.tern ~= nil and f.omp ~= nil and store.health() == "ok"
end

local function publish(now: number)
	local welcome = false
	local settings = jobs.settings()
	if settings.welcomed ~= true and not S.welcome_done then
		local mono = T().now()
		if S.welcome_until == nil then
			S.welcome_until = mono + WELCOME_HOLD_MS
		end
		if mono < (S.welcome_until :: number) then
			welcome = true
		else
			S.welcome_done = true
			jobs.set_settings({ welcomed = true })
		end
	end
	local inflight: { Run } = {}
	for _, r in ipairs(sorted_runs()) do
		table.insert(inflight, r)
	end
	local ok, err = pcall(snapshot.publish, {
		inflight = inflight,
		managers = S.managers,
		setup_ok = setup_ok(),
		scheduler = "ok",
		welcome = welcome,
	}, now)
	if not ok then
		log_error("runner: publish", tostring(err))
	end
	S.pub_dirty = false
end

local function notify_subs()
	S.sub_dirty = false
	for _, fn in pairs(S.subs) do
		pcall(fn)
	end
end

-- ---------- housekeeping (EN §2.5) ----------

local DRAFT_AGE_S = 7 * 86400
local sweep_running = false

-- Removes image files in prompts/ (pasted by Tern beside a prompt) that are over 7 days old and that no
-- prompt or trashed prompt links to. Never touches Markdown files or anything outside prompts/.
local function sweep_images()
	if sweep_running then
		return
	end
	local dir = store.path("prompts")
	sweep_running = true
	proc({ "/usr/bin/find", dir, "-type", "f", "!", "-name", "*.md", "-mtime", "+7" }, { timeout_ms = 10000 }, function(r)
		sweep_running = false
		if r.status ~= 0 or tostring(r.stdout) == "" then
			return
		end
		-- Trashed texts were prompts in prompts/, so their relative links resolve against the same folder.
		local referenced: { [string]: boolean } = {}
		local t0 = T().now()
		local h = home()
		for _, sub in { "prompts", "trash" } do
			for _, name in store.list(sub) do
				if name:match("%.md$") then
					local text = store.read_text(sub .. "/" .. name, const.PROMPT_MAX)
					-- A text that can't be read might link the image: delete nothing this time.
					if text == nil or T().now() - t0 > 300 then
						return
					end
					for _, ref in images.refs(text) do
						local path = images.resolve(ref.dest, dir, h)
						if path ~= nil then
							referenced[path] = true
						end
					end
				end
			end
		end
		local prefix = dir .. "/"
		for line in tostring(r.stdout):gmatch("[^\n]+") do
			if line:sub(1, #prefix) == prefix and not referenced[line] then
				pcall(function()
					T().fs.remove(line)
				end)
			end
		end
	end)
end

local function housekeeping(now: number)
	local settings = jobs.settings()
	local t0 = T().now()
	for _, job in ipairs(jobs.list()) do
		if T().now() - t0 > 200 then
			break
		end
		pcall(ledger.prune, job.id, settings, now)
	end
	pcall(intents.prune, now)
	-- trash/ after 30 days (EN §2.5); names start with their creation time.
	for _, name in store.list("trash") do
		local at = tonumber(name:match("^(%d+)%-"))
		if at ~= nil and now - at > 30 * 86400 then
			store.remove("trash/" .. name)
		end
	end
	-- ctrl+o drafts live in prompts/ as <unix time>-<id>.md and age out after 7 days. A draft still open in a
	-- manager form is rewritten on save, so aging out an old one loses nothing saved. Job prompts are j_….md.
	for _, name in store.list("prompts") do
		local at = tonumber(name:match("^(%d+)%-.+%.md$"))
		if at ~= nil and now - at > DRAFT_AGE_S then
			store.remove("prompts/" .. name)
		end
	end
	-- Older versions kept drafts in drafts/. Age them the same way; once none is left, drop the folder (and
	-- any image Tern saved there).
	local kept = false
	for _, name in store.list("drafts") do
		local at = tonumber(name:match("^(%d+)%-"))
		if at ~= nil then
			if now - at > DRAFT_AGE_S then
				store.remove("drafts/" .. name)
			else
				kept = true
			end
		end
	end
	if not kept and store.exists("drafts") then
		store.remove("drafts")
	end
	sweep_images()
end

-- ---------- gaps and the pump ----------

-- First look after load (EN §5.3): the persisted heartbeat tells how long the host was down. Runs at load,
-- BEFORE the first liveness pass, so a pane lost to a daemon restart is classified as interrupted.
local function note_start_gap(now: number)
	local okh, hot = pcall(function()
		return T().kv.get("hot")
	end)
	if okh and type(hot) == "table" and type(hot.hb) == "number" and now - hot.hb > 30 then
		table.insert(S.gaps, { from = hot.hb, to = now })
		append_event({ ev = "down", from = hot.hb, to = now })
	end
end

-- EN §5.3. Returns true when a due scan must run now.
local function detect_gap(now: number, mono: number): boolean
	local gap = false
	if S.first_pump then
		S.first_pump = false
		return true
	end
	local dw = now - S.last_wall
	local dm = (mono - S.last_mono) / 1000
	if dw > 30 then
		gap = true
		table.insert(S.gaps, { from = S.last_wall, to = now })
		append_event({ ev = "gap", from = S.last_wall, to = now })
	elseif dw < -5 then
		-- the wall clock moved back: the slow-tick spacing is measured on it, so re-base or the tick stalls until it catches up
		S.last_slow = now - const.TICK_S
		S.last_house = now
		append_event({ ev = "clock_back", from = S.last_wall, to = now })
		for _, job in ipairs(jobs.list()) do
			jobs.state(job.id).next_run = nil
		end
	elseif math.abs(dw - dm) > 20 then
		append_event({ ev = "clock_step", from = S.last_wall, to = now })
		for _, job in ipairs(jobs.list()) do
			jobs.state(job.id).next_run = nil
		end
	end
	return gap
end

-- Drop manager blocks whose pane is gone (otherwise the list only shrinks through the manager's own on_change).
local function prune_managers()
	if #S.managers == 0 then
		return
	end
	local okl, list = pcall(function()
		return T().pane.list()
	end)
	if not okl or type(list) ~= "table" then
		return
	end
	local live: { [string]: boolean } = {}
	for _, info in list do
		live[string.format("%.0f", info.pane)] = true
	end
	local removed = false
	for i = #S.managers, 1, -1 do
		if live[S.managers[i]] ~= true then
			table.remove(S.managers, i)
			removed = true
		end
	end
	if removed then
		S.pub_dirty = true
	end
end

local handlers: intents.Handlers

local function slow_tick(now: number, gap: boolean)
	S.last_hb = now
	prune_managers()
	pcall(store.retry_dirty)
	if S.ready then
		due_scan(now)
	end
	if next(S.runs) ~= nil or S.cap_check_due or S.cap_over then
		refresh_state(nil)
	end
	if now - S.last_house >= HOUSEKEEPING_S then
		S.last_house = now
		housekeeping(now)
	end
	poll_unobserved(now)
	S.pub_dirty = true -- heartbeat
end

local pump: () -> ()

function pump()
	pcall(function()
		T().timer(const.PUMP_MS, pump)
	end)
	local t0 = T().now()
	local now, mono = wall(), T().now()
	local ok, err = pcall(function()
		local gap = detect_gap(now, mono)
		S.last_wall, S.last_mono = now, mono
		intents.drain(t0 + 300, handlers)
		-- queued pane_exited events
		local events = S.events
		S.events = {}
		local exited_any = false
		for _, ev in ipairs(events) do
			local id = S.by_block[string.format("%.0f", ev.pane)]
			local run = id and S.runs[id]
			if run ~= nil then
				rt_of(run).exit_status = tonumber(ev.status) or 0
				exited_any = true
			end
		end
		if gap or now - S.last_slow >= const.TICK_S then
			S.last_slow = now
			slow_tick(now, gap)
		elseif exited_any then
			refresh_state(nil)
		elseif S.cap_check_due then
			refresh_state(nil)
		end
		drop_deleted()
		if S.ready then
			advance_scheduled(now)
			relaunch_orphans()
		end
		advance_runs(now)
		refresh_live(now)
		for id in pairs(S.dirty_runs) do
			local run = S.runs[id]
			if run ~= nil then
				pcall(ledger.save, run)
			end
			S.dirty_runs[id] = nil
		end
		if S.pub_dirty then
			publish(now)
		end
		if S.sub_dirty then
			notify_subs()
		end
	end)
	if not ok then
		log_error("pump", tostring(err))
	end
	local dt = T().now() - t0
	if dt > 500 then
		log_warn("slow pump ms", dt)
	end
end

-- ---------- public API (manager, window intents) ----------

function runner.subscribe(fn: () -> ()): number
	local token = S.next_token
	S.next_token += 1
	S.subs[token] = fn
	return token
end

function runner.unsubscribe(token: number)
	S.subs[token] = nil
end

function runner.add_manager(block: string)
	for _, b in ipairs(S.managers) do
		if b == block then
			return
		end
	end
	table.insert(S.managers, block)
	S.pub_dirty = true
end

function runner.remove_manager(block: string)
	for i = #S.managers, 1, -1 do
		if S.managers[i] == block then
			table.remove(S.managers, i)
			S.pub_dirty = true
		end
	end
end

function runner.managers(): { string }
	return S.managers
end

function runner.inflight(): { Run }
	return sorted_runs()
end

-- Live detail of an in-flight (running / needs_input) run for the manager; nil otherwise. See build_live.
function runner.live(run_id: string): { [string]: any }?
	return build_live(run_id)
end

-- After any job/settings mutation by the manager: re-arm missing next runs, publish, notify subscribers.
function runner.changed()
	local now = wall()
	S.cap_check_due = true -- settings (max_finished_panes) may have changed
	for _, job in ipairs(jobs.list()) do
		local st = jobs.state(job.id)
		if job.enabled ~= false and st.next_run == nil and job.schedule.kind ~= "manual" and st.done ~= true then
			st.next_run = jobs.next_run(job, now)
		end
	end
	if S.loaded then
		publish(now)
	end
	notify_subs()
end

function runner.run_now(job_id: string, opts: { focus_override: string? }?): (boolean, string?)
	local settings = jobs.settings()
	if settings.paused_all == true then
		return false, "Resume all jobs to run."
	end
	if store.health() ~= "ok" then
		return false, "Agent Scheduler can't use its data right now. Check Setup."
	end
	local job = jobs.get(job_id)
	if job == nil then
		return false, "That job no longer exists."
	end
	if job.overlap ~= "parallel" then
		for _, r in pairs(S.runs) do
			if r.job_id == job.id then
				return false, "A run is already in progress."
			end
		end
	end
	local now = wall()
	local override = opts ~= nil and opts.focus_override or nil
	local run = claim(job, ids.manual_run_id(job.id, now), "manual", now, now, override)
	if run == nil then
		return false, "Agent Scheduler can't write its data right now."
	end
	return true, nil
end

function runner.stop(run_id: string): boolean
	local run = S.runs[run_id]
	if run == nil then
		return false
	end
	run.cancel_requested = true
	run.close_requested = true
	local had_block = run.block ~= nil
	if not transition(run, "cancelled", "user_stop", {}) then
		return false
	end
	if had_block then
		close_block(run)
		-- facts for "Open run" (session file, cost), filled in after the pane is closed
		read_facts(run, function(facts)
			apply_facts(run, facts)
			pcall(ledger.save, run)
		end)
	end
	return true
end

function runner.focus_run(run_id: string)
	local run = S.runs[run_id] or ledger.get(run_id)
	local b = tern_bin()
	if run == nil or run.block == nil or b == nil then
		return
	end
	proc({ b, "focus", tostring(run.block) }, { timeout_ms = 8000 }, function() end)
end

-- LA §10: focus the live pane, else resume the session in a new tab. cb(ok, err) is optional.
function runner.open_run(run_id: string, cb: ((boolean, string?) -> ())?)
	local run = S.runs[run_id] or ledger.get(run_id)
	local found = bins.get()
	local done = cb or function(_ok: boolean, _err: string?) end
	if run == nil then
		return done(false, "That run no longer exists.")
	end
	if found == nil then
		return done(false, "Agent Scheduler can't find tern or omp. Check Setup.")
	end
	tern_state.snapshot(found.tern, function(st)
		local key = tostring(run.job_id) .. "/" .. tostring(run.run_id)
		local blk = st ~= nil and st.by_run[key] or nil
		if blk ~= nil then
			proc({ found.tern, "focus", blk.id }, { timeout_ms = 8000 }, function()
				done(true, nil)
			end)
		else
			launcher.resume(run, found, done)
		end
	end)
end

function runner.ack_failed(run_id: string)
	local run = ledger.get(run_id)
	if run ~= nil and run.acked ~= true then
		run.acked = true
		ledger.save(run)
		S.pub_dirty = true
	end
end

-- cb(list) or cb(nil, why). Cache first, then omp.
function runner.roles(cwd: string, cb: ({ string }?, string?) -> ())
	local cached = roles.cached(cwd)
	if cached ~= nil then
		return cb(cached, nil)
	end
	local omp = bins.found().omp
	if omp == nil then
		return cb(nil, "omp_missing")
	end
	roles.list(omp, cwd, cb)
end

function runner.focus_manager()
	prune_managers()
	local b = tern_bin()
	local block = S.managers[#S.managers]
	if b == nil or block == nil then
		return
	end
	proc({ b, "focus", block }, { timeout_ms = 8000 }, function() end)
end

-- ---------- setup rows (UX §6.2) ----------

export type SetupRow = { id: string, label: string, ok: boolean?, text: string }

local function version_at_least(v: string, major: number, minor: number, patch: number): boolean
	local a, b, c = v:match("(%d+)%.(%d+)%.(%d+)")
	if a == nil then
		return false
	end
	local n = tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
	return n >= major * 1000000 + minor * 1000 + patch
end

local function setup_rows(): { SetupRow }
	local f = bins.found()
	local rows: { SetupRow } = {}
	local tern_ok = f.tern ~= nil and version_at_least(f.tern_version or "", 0, 8, 3)
	table.insert(rows, {
		id = "tern",
		label = "Tern version",
		ok = tern_ok,
		text = tern_ok and (f.tern_version or "") or "Agent Scheduler is built and tested on Tern 0.8.3. Update Tern.",
	})
	table.insert(rows, {
		id = "omp",
		label = "omp",
		ok = f.omp ~= nil,
		text = f.omp ~= nil and string.format("%s (%s)", f.omp_version or "", f.omp) or "omp wasn't found. Scheduled runs can't start. Install omp, then check setup again.",
	})
	local roles_ok: boolean? = S.roles_probe
	table.insert(rows, {
		id = "roles",
		label = "Roles readable",
		ok = roles_ok,
		text = roles_ok == false and "Couldn't read your omp roles. Jobs still run, but role names aren't checked first. Run `omp config get modelRoles` in the job's folder."
			or "omp roles are readable.",
	})
	local age = wall() - S.last_hb
	local hb_ok = S.last_hb > 0 and age <= 120
	table.insert(rows, {
		id = "heartbeat",
		label = "Scheduler heartbeat",
		ok = hb_ok,
		text = hb_ok and "The scheduler is ticking." or "The scheduler isn't ticking. Reload plugins (palette: Reload plugins).",
	})
	local health = store.health()
	local data_ok = health == "ok" and S.data_probe ~= false
	table.insert(rows, {
		id = "data",
		label = "Data folder writable",
		ok = data_ok,
		text = data_ok and "Plugin data is writable." or "Can't write to Tern's plugin data folder.",
	})
	local ka = S.keepalive
	table.insert(rows, {
		id = "keepalive",
		label = "Keep-alive",
		ok = ka ~= nil and ka.ok or nil,
		text = ka ~= nil and ka.text
			or "Checking whether anything keeps Tern's session service alive…",
	})
	local notify_ok, notify_text = platform.notify_status()
	table.insert(rows, {
		id = "notifications",
		label = "System notifications",
		ok = notify_ok,
		text = notify_text,
	})
	return rows
end

function runner.health(): { health: string, hb: number, setup: { SetupRow } }
	return { health = store.health(), hb = S.last_hb, setup = setup_rows() }
end

-- Re-runs the asynchronous checks (binaries, roles, keep-alive, data probe), then cb(rows).
function runner.check_setup(cb: ({ SetupRow }) -> ())
	local settings = jobs.settings()
	local probe = "probe.txt"
	local wrote = store.write_text(probe, tostring(wall()))
	S.data_probe = wrote and store.read_text(probe, 64) ~= nil
	store.remove(probe)
	bins.resolve(settings, function(b)
		local function after_keepalive()
			cb(setup_rows())
		end
		local function keepalive()
			local tb = tern_bin()
			if tb == nil then
				S.keepalive = { ok = false, text = "Tern's command-line tool wasn't found." }
				return after_keepalive()
			end
			tern_state.snapshot(tb, function(st)
				if st == nil then
					S.keepalive = { ok = false, text = "Tern's session service isn't reachable." }
					return after_keepalive()
				end
				local live = 0
				local mgr: { [string]: boolean } = {}
				for _, m in ipairs(S.managers) do
					mgr[m] = true
				end
				for id, blk in pairs(st.blocks) do
					if blk.live ~= false and not mgr[id] then
						live += 1
					end
				end
				if live > 0 then
					S.keepalive = { ok = true, text = "A terminal or run is open, so Tern's session service stays up after you close windows." }
				else
					S.keepalive = {
						ok = false,
						text = "Nothing is keeping Tern's session service alive. It may stop when you close the last window; jobs won't fire until you open Tern. Keep a terminal open, or leave a Tern window open.",
					}
				end
				after_keepalive()
			end)
		end
		if b == nil then
			return keepalive()
		end
		-- roles: any job folder, else home
		local cwd = home()
		local first = jobs.list()[1]
		if first ~= nil then
			cwd = tostring(first.cwd)
		end
		roles.list(b.omp, cwd, function(list)
			S.roles_probe = list ~= nil
			keepalive()
		end)
	end, true)
end

-- ---------- load ----------

handlers = {
	obs = on_obs,
	run_now = function(id: string)
		return runner.run_now(id, nil)
	end,
	stop = runner.stop,
	focus_run = runner.focus_run,
	open_run = function(id: string)
		runner.open_run(id, nil)
	end,
	ack_failed = runner.ack_failed,
	roles_request = function(cwd: string)
		roles.invalidate(cwd)
		runner.roles(cwd, function()
			S.pub_dirty = true
		end)
	end,
	focus_manager = runner.focus_manager,
	changed = runner.changed,
}

local function restore_runs(now: number)
	local list = jobs.inflight()
	local kept: { string } = {}
	local settings = jobs.settings()
	for _, run in ipairs(ledger.load_inflight(list)) do
		local id = tostring(run.run_id)
		if const.INFLIGHT[tostring(run.state)] == true then
			S.runs[id] = run
			S.rt[id] = {}
			if run.block ~= nil then
				S.by_block[tostring(run.block)] = id
			end
			table.insert(kept, id)
		end
	end
	-- ids without a record (or a terminal one) leave the list
	for i = #list, 1, -1 do
		list[i] = nil
	end
	for _, id in ipairs(kept) do
		table.insert(list, id)
	end
	-- EN §5.4: a scheduled slot that never launched and is now beyond its catch-up window is missed, never launched
	for _, run in ipairs(sorted_runs()) do
		local job = jobs.get(tostring(run.job_id))
		if run.state == "scheduled" and job ~= nil and (run.trigger == "schedule" or run.trigger == "catchup") then
			local window = tonumber(job.catch_up_window_s) or tonumber(settings.catchup_window_s) or const.CATCHUP_DEFAULT_S
			local slot = tonumber(run.slot) or now
			-- same rule as policy.decide: always never expires, skip only tolerates ONTIME_S, within uses the window
			local mode = job.catch_up or "within"
			if mode == "skip" then
				window = const.ONTIME_S
			end
			if mode ~= "always" and now - slot > window then
				transition(run, "missed", "late", { count = 1, first = slot, last = slot, window_s = window, lateness_s = now - slot })
			end
		end
	end
end

local function load_gaps()
	local text = store.read_text("events.jsonl", 262144) or ""
	for line in text:gmatch("[^\n]+") do
		local ok, ev = pcall(function()
			return T().json.decode(line)
		end)
		if ok and type(ev) == "table" and (ev.ev == "gap" or ev.ev == "down") and type(ev.from) == "number" and type(ev.to) == "number" then
			table.insert(S.gaps, { from = ev.from, to = ev.to })
		end
	end
end

function runner.load()
	if S.loaded then
		return
	end
	S.loaded = true
	local now = wall()
	local health = jobs.load(now)
	if health ~= "ok" then
		log_warn("runner: data health", health)
	end
	local settings = jobs.settings()
	restore_runs(now)
	load_gaps()
	note_start_gap(now)
	S.last_wall, S.last_mono = now, T().now()
	S.last_slow = 0
	pcall(function()
		T().on("pane_exited", function(ev: any)
			table.insert(S.events, ev)
		end)
	end)
	S.last_house = now
	housekeeping(now)
	bins.resolve(settings, function()
		refresh_state(function()
			S.ready = true
			S.pub_dirty = true
		end)
	end)
	pcall(function()
		T().timer(1000, pump)
	end)
end

return runner
