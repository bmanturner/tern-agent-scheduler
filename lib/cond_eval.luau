--!strict
-- lib/cond_eval.luau : evaluates a job's "Only if" conditions (git, window, budget, script check), keeps the
-- per-job watermarks in state.json (`watch.conditions`), never requires runner. Host only.
local ids = require("./ids")
local jobs = require("./jobs")
local ledger = require("./ledger")
local store = require("./store")
local bins = require("./bins")
local conditions = require("./conditions")
local session_tail = require("./session_tail")

local GIT_TIMEOUT_MS = 5000
local CHECK_TIMEOUT_MS = 30000
local READ_TIMEOUT_MS = 5000
local EVAL_DEADLINE_MS = 120000
local MAX_GATES = 2
local SCRIPT_MAX = 65536
local CONTEXT_COMMITS_MAX = 4096
local CONTEXT_CHECK_MAX = 8192
local CURSOR_MAX = 512
local ASSUMED_COST = 0.5

type Job = { [string]: any }
type Run = { [string]: any }
type Mark = { sig: string, sha: string?, tok: string?, at: number }

export type Verdict = {
	ok: boolean,
	code: string?, -- cond_window|cond_budget|cond_commits|cond_check|cond_baseline|cond_error
	text: string?, -- the sentence fragment stored as run.cond_text
	results: { { id: string, type: string, label: string, result: string, text: string, context: string? } }, -- result: pass|fail|error|skip
	proposals: { [string]: { sig: string, sha: string?, tok: string?, at: number } },
	baselines: { [string]: { sig: string, sha: string, at: number } },
	context: { { title: string, name: string, source: string, text: string } },
	error_code: string?, -- set with code == "cond_error"
	alert: string?, -- notification text overriding the default (check_changed only)
}

type Out = {
	result: string,
	text: string,
	code: string?,
	error_code: string?,
	context: string?,
	alert: string?,
}

local cond_eval = {}

local function T(): any
	return tern
end

local function proc(argv: { string }, opts: { [string]: any }, cb: (any) -> ())
	local ok, err = pcall(function()
		T().process.run(argv, opts, cb)
	end)
	if not ok then
		cb({ status = -1, stdout = "", stderr = tostring(err), timed_out = false, raised = true })
	end
end

local function home(): string
	local ok, h = pcall(function()
		return T().getenv("HOME")
	end)
	if ok and type(h) == "string" then
		return h
	end
	return ""
end

local function tilde(p: string): string
	local h = home()
	if h ~= "" and p:sub(1, #h + 1) == h .. "/" then
		return "~" .. p:sub(#h + 1)
	end
	if h ~= "" and p == h then
		return "~"
	end
	return p
end

local function clip(s: string, n: number): string
	return session_tail.clip(s, n)
end

local function plural(n: number, one: string, many: string): string
	return if n == 1 then one else many
end

-- ---------- watermarks (state.json: watch.conditions) ----------

-- c[id] = {sig, sha?, tok?, at}; err = {n, code}; skips = {code, text, n, since}
local function watch(st: { [string]: any }): { [string]: any }
	if type(st.watch) ~= "table" then
		st.watch = { v = 1, conditions = { c = {} } }
	end
	local w = st.watch
	if type(w.conditions) ~= "table" then
		w.conditions = { c = {} }
	end
	if type(w.conditions.c) ~= "table" then
		w.conditions.c = {}
	end
	return w.conditions
end

-- Read-only view of the watermarks: nil when the job has none yet (never creates state).
local function peek(st: { [string]: any }?): { [string]: any }?
	if st == nil or type(st.watch) ~= "table" or type(st.watch.conditions) ~= "table" or type(st.watch.conditions.c) ~= "table" then
		return nil
	end
	return st.watch.conditions
end

-- ---------- script gate (at most MAX_GATES checks at once, FIFO) ----------

local gate_active = 0
local gate_queue: { () -> () } = {}

local function gate_acquire(fn: () -> ())
	if gate_active < MAX_GATES then
		gate_active += 1
		fn()
	else
		table.insert(gate_queue, fn)
	end
end

local function gate_release()
	local nxt = table.remove(gate_queue, 1)
	if nxt ~= nil then
		nxt() -- the slot passes straight to the next waiter
	else
		gate_active -= 1
	end
end

-- ---------- git ----------

local function git_argv(cwd: string, ...: string): { string }
	local a = { "git", "-C", cwd, "--no-optional-locks", "-c", "core.fsmonitor=false" }
	for _, s in { ... } do
		table.insert(a, s)
	end
	return a
end

local function git_with_paths(cwd: string, paths: { string }, ...: string): { string }
	local a = git_argv(cwd, ...)
	table.insert(a, "--")
	for _, p in ipairs(paths) do
		table.insert(a, p)
	end
	return a
end

-- cb(sha) or cb(nil, text, code)
local function resolve_ref(cwd: string, ref: string, cb: (string?, string?, string?) -> ())
	proc(git_argv(cwd, "rev-parse", "--verify", "--quiet", ref .. "^{commit}"), { timeout_ms = GIT_TIMEOUT_MS }, function(r: any)
		if r.timed_out == true then
			return cb(nil, "git took longer than 5 s", "git_timeout")
		end
		local stderr = tostring(r.stderr or "")
		if r.raised == true then
			return cb(nil, "couldn't run git", "git_failed")
		end
		if r.status == 128 or stderr:find("not a git repository", 1, true) ~= nil then
			return cb(nil, tilde(cwd) .. " isn't a git repository", "not_a_repo")
		end
		if r.status ~= 0 then
			local text = if ref == "HEAD" then "this folder has no commits yet" else string.format("no branch or ref named %s in %s", ref, tilde(cwd))
			return cb(nil, text, "ref_missing")
		end
		local sha = tostring(r.stdout or ""):match("^%x+")
		if sha == nil or #sha < 7 then
			return cb(nil, "git gave an answer Agent Scheduler can't read", "git_failed")
		end
		cb(sha:sub(1, 40))
	end)
end

local function ref_name(c: { [string]: any }): string
	return if c.ref == "HEAD" then "this folder's branch" else tostring(c.ref)
end

-- ---------- spend ----------

function cond_eval.spend(job_id: string, per: string, now: number): { runs: number, usd: number, unknown: number, assumed: number }
	local t = os.date("*t", now) :: any
	local start = now - (t.hour * 3600 + t.min * 60 + t.sec)
	if per == "week" then
		start -= ((t.wday + 5) % 7) * 86400
	end
	local COUNTED = { launching = true, running = true, needs_input = true, finished = true, failed = true, timed_out = true, cancelled = true }
	local recent = ledger.recent(job_id, 200)
	local runs, usd, unknown = 0, 0, 0
	local costs: { number } = {}
	for _, r in ipairs(recent) do
		local cost = tonumber(r.cost)
		if cost ~= nil and #costs < 20 then
			table.insert(costs, cost)
		end
		if r.trigger ~= "test" and COUNTED[tostring(r.state)] == true then
			local row_t = tonumber(r.started)
			if row_t == nil and r.state == "launching" then
				row_t = tonumber(r.created)
			end
			if row_t ~= nil and row_t >= start then
				runs += 1
				if cost ~= nil then
					usd += cost
				else
					unknown += 1
				end
			end
		end
	end
	local assumed = ASSUMED_COST
	if #costs > 0 then
		table.sort(costs)
		local n = #costs
		assumed = if n % 2 == 1 then costs[(n + 1) // 2] else (costs[n // 2] + costs[n // 2 + 1]) / 2
	end
	return { runs = runs, usd = usd, unknown = unknown, assumed = assumed }
end

-- ---------- reading a script ----------

local READ_SH = '[ -f "$1" ] || exit 3; [ -x "$1" ] || exit 4; exec /usr/bin/head -c 65537 "$1"'

function cond_eval.read_script(abs: string, cb: (string?, string?, string?) -> ())
	proc({ "/bin/sh", "-c", READ_SH, "sh", abs }, { timeout_ms = READ_TIMEOUT_MS }, function(r: any)
		if r.timed_out == true or r.raised == true then
			return cb(nil, "couldn't read your check", "check_unreadable")
		end
		if r.status == 3 then
			return cb(nil, "your check wasn't found: " .. tilde(abs), "check_missing")
		elseif r.status == 4 then
			return cb(nil, "your check isn't executable: " .. tilde(abs), "check_not_executable")
		elseif r.status ~= 0 then
			return cb(nil, "couldn't read your check", "check_unreadable")
		end
		local text = tostring(r.stdout or "")
		if #text > SCRIPT_MAX then
			return cb(nil, "your check is over 64 KB", "check_too_large")
		end
		cb(text)
	end)
end

local function check_path(): string
	local dirs: { string } = {}
	local omp = bins.found().omp
	if omp ~= nil then
		local d = omp:match("^(.*)/[^/]*$")
		if d ~= nil and d ~= "" then
			table.insert(dirs, d)
		end
	end
	for _, d in { home() .. "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin" } do
		table.insert(dirs, d)
	end
	return table.concat(dirs, ":")
end

-- ---------- evaluation ----------

local function hhmm(m: number): string
	return string.format("%02d:%02d", m // 60, m % 60)
end

local function eval_window(c: { [string]: any }, label: string, now: number): Out
	local t = os.date("*t", now) :: any
	local m = t.hour * 60 + t.min
	local wday = t.wday - 1
	local from, to = tonumber(c.from) or 0, tonumber(c.to) or 1440
	local inrange = if from < to then (m >= from and m < to) else (m >= from or m < to)
	local day_ok = false
	for _, d in ipairs(c.days or {}) do
		if d == wday then
			day_ok = true
			break
		end
	end
	local inside = day_ok and inrange
	local negate = c.negate == true
	local pass = if negate then not inside else inside
	if negate then
		if pass then
			return { result = "pass", text = "outside the quiet hours" }
		end
		return { result = "fail", text = string.format("inside the quiet hours %s–%s", hhmm(from), hhmm(to)) }
	end
	if pass then
		return { result = "pass", text = "inside " .. label }
	end
	return { result = "fail", text = "outside " .. label }
end

local function eval_budget(job: Job, c: { [string]: any }, now: number): Out
	local ok, s = pcall(cond_eval.spend, tostring(job.id), tostring(c.per), now)
	if not ok or type(s) ~= "table" then
		return { result = "error", text = "couldn't read past runs to check the limit", error_code = "budget_unreadable" }
	end
	local period = if c.per == "week" then "this week" else "today"
	local max_runs, max_usd = tonumber(c.max_runs), tonumber(c.max_usd)
	if max_runs ~= nil and s.runs >= max_runs then
		return { result = "fail", text = string.format("%d of %d runs already used %s", s.runs, max_runs, period) }
	end
	local spent = s.usd + s.unknown * s.assumed
	if max_usd ~= nil and spent >= max_usd then
		local text = string.format("$%.2f of $%.2f spent %s", spent, max_usd, period)
		if s.unknown > 0 then
			text ..= string.format(" (cost unknown for %d %s)", s.unknown, plural(s.unknown, "run", "runs"))
		end
		return { result = "fail", text = text }
	end
	local parts: { string } = {}
	if max_runs ~= nil then
		table.insert(parts, string.format("%d of %d runs used %s", s.runs, max_runs, period))
	end
	if max_usd ~= nil then
		table.insert(parts, string.format("$%.2f of $%.2f spent %s", spent, max_usd, period))
	end
	return { result = "pass", text = table.concat(parts, " and ") }
end

local function eval_commits(job: Job, c: { [string]: any }, base: Mark?, opts: { [string]: any }, v: Verdict, done: (Out) -> ())
	local cwd = tostring(job.cwd)
	local ref = tostring(c.ref or "HEAD")
	local paths: { string } = c.paths or {}
	local sig = conditions.sig(c)
	local now = tonumber(opts.now) or os.time()
	resolve_ref(cwd, ref, function(new, err_text, err_code)
		if new == nil then
			return done({ result = "error", text = tostring(err_text), error_code = err_code })
		end
		if base == nil or base.sha == nil then
			if opts.dry == true then
				return done({
					result = "fail",
					code = "cond_baseline",
					text = string.format(
						"no record yet of where %s was; the first run records it and waits for something new",
						ref_name(c)
					),
				})
			end
			v.baselines[tostring(c.id)] = { sig = sig, sha = new, at = now }
			return done({
				result = "fail",
				code = "cond_baseline",
				text = string.format("Watching %s from %s. The first run waits for something new.", ref_name(c), new:sub(1, 7)),
			})
		end
		local part = ""
		if ref ~= "HEAD" then
			part = " on " .. ref
		elseif #paths > 0 then
			part = " touching " .. table.concat(paths, " ")
		end
		local since = ledger.day_time(tonumber(base.at) or now)
		local function none(note: string): Out
			return { result = "fail", code = "cond_commits", text = "no new commits" .. part .. " since " .. since .. note }
		end
		if base.sha == new then
			return done(none(""))
		end
		local function conclude(n: number, fallback: boolean)
			local note = if fallback then " (history was rewritten; counted by date)" else ""
			if n < 1 then
				return done(none(note))
			end
			v.proposals[tostring(c.id)] = { sig = sig, sha = new, at = now }
			local text = string.format("%d new %s since %s%s", n, plural(n, "commit", "commits"), since, note)
			local range = (base.sha :: string) .. ".." .. new
			proc(git_with_paths(cwd, paths, "log", "--no-color", "--format=%h %an %s", "-n", "30", range), { timeout_ms = GIT_TIMEOUT_MS }, function(lr: any)
				local function finish(diff_text: string)
					local log_text = if lr.status == 0 then tostring(lr.stdout or "") else ""
					local ctx = log_text
					if diff_text ~= "" then
						ctx = if ctx ~= "" then ctx .. "\n" .. diff_text else diff_text
					end
					if ctx ~= "" then
						ctx = clip(ctx, CONTEXT_COMMITS_MAX)
						table.insert(v.context, { title = string.format("New commits%s (%d)", part, n), name = "commits", source = "git", text = ctx })
					end
					done({ result = "pass", text = text, context = if ctx ~= "" then ctx else nil })
				end
				if fallback then
					return finish("")
				end
				proc(git_with_paths(cwd, paths, "diff", "--no-color", "--stat", base.sha :: string, new), { timeout_ms = GIT_TIMEOUT_MS }, function(dr: any)
					finish(if dr.status == 0 then tostring(dr.stdout or "") else "")
				end)
			end)
		end
		proc(git_with_paths(cwd, paths, "rev-list", "--count", (base.sha :: string) .. ".." .. new), { timeout_ms = GIT_TIMEOUT_MS }, function(r: any)
			if r.status == 0 and r.timed_out ~= true then
				return conclude(tonumber(tostring(r.stdout or ""):match("%d+")) or 0, false)
			end
			local since_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(base.at) or now)
			proc(git_with_paths(cwd, paths, "rev-list", "--count", "--since=" .. since_iso, new), { timeout_ms = GIT_TIMEOUT_MS }, function(r2: any)
				if r2.timed_out == true then
					return done({ result = "error", text = "git took longer than 5 s", error_code = "git_timeout" })
				end
				if r2.status ~= 0 then
					return done({ result = "error", text = "git couldn't count the new commits", error_code = "git_failed" })
				end
				conclude(tonumber(tostring(r2.stdout or ""):match("%d+")) or 0, true)
			end)
		end)
	end)
end

local function eval_check(job: Job, c: { [string]: any }, base: Mark?, opts: { [string]: any }, v: Verdict, st: { [string]: any }?, done: (Out) -> ())
	local abs = conditions.script_path(tostring(c.path), tostring(job.cwd), home())
	local sig = conditions.sig(c)
	gate_acquire(function()
		local released = false
		local function finish(out: Out)
			if not released then
				released = true
				gate_release()
			end
			done(out)
		end
		cond_eval.read_script(abs, function(text, err_text, err_code)
			if text == nil then
				return finish({ result = "error", text = tostring(err_text), error_code = err_code })
			end
			if c.ack ~= nil and "ck1:" .. ids.fnv64(text) ~= c.ack then
				local msg = string.format("your check %s changed since you approved it. Open Edit and save to approve it again", tostring(c.path))
				return finish({ result = "error", text = msg, error_code = "check_changed", alert = msg })
			end
			local now = tonumber(opts.now) or os.time()
			local so_far: { { type: string, result: string } } = {}
			for _, r in ipairs(v.results) do
				table.insert(so_far, { type = r.type, result = r.result })
			end
			local null = T().json.null
			local last: any = null
			if st ~= nil and type(st.last_run) == "table" then
				local lr = st.last_run
				last = {
					state = lr.state,
					started = lr.started,
					ended = lr.ended,
					summary = lr.summary,
					quiet = lr.quiet,
				}
			end
			local payload = {
				job = job.id,
				name = job.name,
				cwd = job.cwd,
				now = now,
				trigger = opts.trigger,
				slot = opts.slot,
				last_run = last,
				cursor = if base ~= nil and base.tok ~= nil then base.tok else null,
				conditions_so_far = T().json.array(so_far),
			}
			local in_rel = "tmp/check-" .. ids.nonce() .. ".json"
			local wrote = pcall(function()
				store.mkdirs("tmp")
				local ok = store.write_text(in_rel, T().json.encode(payload))
				if not ok then
					error("write failed")
				end
			end)
			if not wrote then
				return finish({ result = "error", text = "couldn't start your check " .. tostring(c.path), error_code = "check_unstarted" })
			end
			proc(
				{ abs, store.path(in_rel) },
				{ cwd = job.cwd, timeout_ms = CHECK_TIMEOUT_MS, env = { PATH = check_path() } },
				function(r: any)
					pcall(store.remove, in_rel)
					if r.timed_out == true then
						return finish({ result = "error", text = "your check took longer than 30 s", error_code = "check_timeout" })
					end
					if r.raised == true then
						return finish({ result = "error", text = "couldn't start your check " .. tostring(c.path), error_code = "check_unstarted" })
					end
					local reason: string? = nil
					local cursor: string? = nil
					local ctx: { string } = {}
					local ctx_bytes = 0
					for line in tostring(r.stdout or ""):sub(1, SCRIPT_MAX):gmatch("[^\r\n]+") do
						local rs = line:match("^REASON:%s*(.-)%s*$")
						local cs = line:match("^CONTEXT:%s?(.*)$")
						local cu = line:match("^CURSOR:%s*(.-)%s*$")
						if rs ~= nil then
							reason = clip(rs, 120)
						elseif cs ~= nil then
							if #ctx < 40 and ctx_bytes + #cs + 1 <= CONTEXT_CHECK_MAX then
								table.insert(ctx, cs)
								ctx_bytes += #cs + 1
							end
						elseif cu ~= nil then
							cursor = if #cu <= CURSOR_MAX and cu ~= "" then cu else nil
						end
					end
					if r.status == 0 then
						local text = "your check said yes"
						if reason ~= nil and reason ~= "" then
							text ..= string.format(': "%s"', reason)
						end
						if cursor ~= nil then
							v.proposals[tostring(c.id)] = { sig = sig, tok = cursor, at = now }
						end
						local ctx_text: string? = nil
						if #ctx > 0 then
							ctx_text = table.concat(ctx, "\n")
							table.insert(v.context, { title = "Your check " .. tostring(c.path), name = "check", source = "check script", text = ctx_text :: string })
						end
						return finish({ result = "pass", text = text, context = ctx_text })
					elseif r.status == 1 then
						local text: string
						if reason ~= nil and reason ~= "" then
							text = string.format('your check said no: "%s"', reason)
						else
							text = "your check said no"
							local first = tostring(r.stderr or ""):match("[^\r\n]+")
							if first ~= nil then
								text ..= string.format(" (stderr: %s)", clip(first, 80))
							end
						end
						return finish({ result = "fail", text = text })
					end
					finish({ result = "error", text = string.format("your check failed to run (exit %s)", tostring(r.status)), error_code = "check_failed" })
				end
			)
		end)
	end)
end

function cond_eval.evaluate(job: Job, opts: { [string]: any }, cb: (Verdict) -> ())
	local v: Verdict = { ok = false, results = {}, proposals = {}, baselines = {}, context = {} }
	local list: { { [string]: any } } = if type(job.conditions) == "table" then job.conditions else {}
	local start = T().now()
	local now = tonumber(opts.now) or os.time()
	local st: { [string]: any }? = nil
	if job.id ~= nil and jobs.get(tostring(job.id)) ~= nil then
		st = jobs.state(tostring(job.id))
	end
	local W = peek(st)

	local function base_of(c: { [string]: any }): Mark?
		local sig = conditions.sig(c)
		local id = tostring(c.id)
		local best: Mark? = nil
		local function consider(m: any)
			if type(m) == "table" and m.sig == sig and (best == nil or (tonumber(m.at) or 0) > (tonumber(best.at) or 0)) then
				best = m
			end
		end
		if W ~= nil then
			consider(W.c[id])
		end
		for _, r in ipairs(opts.others or {}) do
			if type(r) == "table" and type(r.cursor_next) == "table" then
				consider(r.cursor_next[id])
			end
		end
		return best
	end

	local function stop(i: number, c: { [string]: any }, label: string, out: Out)
		table.insert(v.results, { id = tostring(c.id), type = tostring(c.type), label = label, result = out.result, text = out.text, context = out.context })
		if out.result == "error" then
			v.code = "cond_error"
			v.error_code = out.error_code
			v.alert = out.alert
		elseif out.code ~= nil then
			v.code = out.code
		else
			v.code = "cond_" .. tostring(c.type)
		end
		v.text = out.text
		for j = i + 1, #list do
			local o = list[j]
			table.insert(v.results, { id = tostring(o.id), type = tostring(o.type), label = conditions.describe_one(o), result = "skip", text = "not checked" })
		end
		cb(v)
	end

	local step: (number) -> ()
	step = function(i: number)
		local c = list[i]
		if c == nil then
			v.ok = true
			return cb(v)
		end
		local label = conditions.describe_one(c)
		if T().now() - start > EVAL_DEADLINE_MS then
			return stop(i, c, label, { result = "error", text = "checking conditions took over 2 minutes", error_code = "timeout" })
		end
		local function after(out: Out)
			if out.result == "pass" then
				table.insert(v.results, { id = tostring(c.id), type = tostring(c.type), label = label, result = "pass", text = out.text, context = out.context })
				return step(i + 1)
			end
			stop(i, c, label, out)
		end
		if c.type == "window" then
			after(eval_window(c, label, now))
		elseif c.type == "budget" then
			after(eval_budget(job, c, now))
		elseif c.type == "commits" then
			eval_commits(job, c, base_of(c), opts, v, after)
		elseif c.type == "check" then
			eval_check(job, c, base_of(c), opts, v, st, after)
		else
			after({ result = "error", text = "a condition couldn't be read", error_code = "check_failed" })
		end
	end
	step(1)
end

-- ---------- bookkeeping after a verdict or a run ----------

function cond_eval.apply_baselines(job: Job, v: Verdict)
	if next(v.baselines) == nil then
		return
	end
	local W = watch(jobs.state(tostring(job.id)))
	for id, b in pairs(v.baselines) do
		W.c[id] = b
	end
end

function cond_eval.note_pass(st: { [string]: any })
	local W = watch(st)
	W.err = nil
	W.skips = nil
end

function cond_eval.note_skip(st: { [string]: any }, code: string?, text: string?, slot: number?)
	local W = watch(st)
	local s = W.skips
	if type(s) == "table" and s.code == code and s.text == text then
		s.n = (tonumber(s.n) or 0) + 1
	else
		W.skips = { code = code, text = text, n = 1, since = slot }
	end
	W.err = nil
end

-- Returns the number of consecutive errors before this one.
function cond_eval.note_error(st: { [string]: any }, code: string?): number
	local W = watch(st)
	local before = if type(W.err) == "table" then tonumber(W.err.n) or 0 else 0
	W.err = { n = before + 1, code = code }
	return before
end

function cond_eval.forget(job_id: string)
	local st = jobs.state(job_id)
	st.watch = nil
end

function cond_eval.seen_lines(job: Job): { string }
	local out: { string } = {}
	if job.id == nil or jobs.get(tostring(job.id)) == nil or type(job.conditions) ~= "table" then
		return out
	end
	local W = peek(jobs.state(tostring(job.id)))
	if W == nil then
		return out
	end
	for _, c in ipairs(job.conditions) do
		if c.type == "commits" then
			local m = W.c[tostring(c.id)]
			if type(m) == "table" and m.sig == conditions.sig(c) and type(m.sha) == "string" then
				table.insert(out, string.format("Watching %s from %s (%s)", ref_name(c), m.sha:sub(1, 7), ledger.day_time(tonumber(m.at) or 0)))
			end
		end
	end
	return out
end

-- Called when a run finishes: advances watermarks (only for runs whose conditions passed) and re-baselines
-- the commits conditions to where the branch is now.
function cond_eval.commit(job: Job, run: Run)
	local st = jobs.state(tostring(job.id))
	local W = watch(st)
	local passed = run.cond_passed == true
	if passed then
		for _, c in ipairs(job.conditions or {}) do
			local p = if type(run.cursor_next) == "table" then run.cursor_next[tostring(c.id)] else nil
			if type(p) == "table" and p.sig == conditions.sig(c) then
				local cur = W.c[tostring(c.id)]
				if not (type(cur) == "table" and cur.sig == p.sig and (tonumber(cur.at) or 0) > (tonumber(p.at) or 0)) then
					W.c[tostring(c.id)] = p
				end
			end
		end
	end
	for _, c in ipairs(job.conditions or {}) do
		if c.type == "commits" and (passed or W.c[tostring(c.id)] == nil) then
			local sig = conditions.sig(c)
			resolve_ref(tostring(job.cwd), tostring(c.ref or "HEAD"), function(sha)
				if sha == nil then
					return
				end
				watch(jobs.state(tostring(job.id))).c[tostring(c.id)] = { sig = sig, sha = sha, at = os.time() }
				jobs.save_state()
			end)
		end
	end
end

return cond_eval
