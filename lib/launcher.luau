--!strict
-- lib/launcher.luau : LA §2-§4, §7.2. Single-flight FIFO launch queue: write the run files, ensure the run
-- session, `tern new tab|session … --keep-open -- omp …`, parse ids as strings, best-effort rename/focus.
-- No user text ever enters argv: the prompt and preamble travel as files; the job name only reaches
-- `tern rename`, which is exec'd without a shell.
local const = require("./const")
local store = require("./store")
local validate = require("./validate")
local tern_state = require("./tern_state")
local bins_mod = require("./bins")

export type Bins = bins_mod.Bins
export type LaunchRequest = {
	run: { [string]: any },
	job: { [string]: any },
	prompt: string,
	bins: Bins,
	session_name: string,
	where: string, -- "session" | "tab"
	focus: string, -- "keep" | "front"
	trigger: string,
	slot_local: string?,
}
export type LaunchResult = { block: string, tab: string?, session: string?, placement_used: string }
export type LaunchError = { code: string, text: string }

local launcher = {}

local APPROVAL_CLI: { [string]: string } = { write = "write", always_ask = "always-ask", yolo = "yolo" }
local RETRY_MS = 15000
local MAX_ATTEMPTS = 3

local function warn(...: any)
	local args = table.pack(...)
	pcall(function()
		(tern :: any).log.warn(table.unpack(args, 1, args.n))
	end)
end

-- ---------- pure helpers ----------

local function field(req: LaunchRequest, key: string): any
	local v = req.run[key]
	if v == nil then
		v = req.job[key]
	end
	return v
end

-- Run directory, relative to the data root and absolute.
function launcher.run_dir_rel(req: LaunchRequest): string
	local rel = req.run.run_dir
	if type(rel) == "string" and rel ~= "" then
		return rel
	end
	return string.format("runs/%s/%s", tostring(req.run.job_id or req.job.id), tostring(req.run.run_id))
end

function launcher.run_dir(req: LaunchRequest): string
	return store.path(launcher.run_dir_rel(req))
end

function launcher.approval_cli(approval: string): string
	return APPROVAL_CLI[approval] or "always-ask"
end

-- The omp part of the argv (LA §2.2), starting with the binary.
function launcher.omp_argv(req: LaunchRequest): { string }
	local dir = launcher.run_dir(req)
	local a: { string } = {
		req.bins.omp,
		"--model",
		"@" .. tostring(field(req, "role") or "default"),
		"--approval-mode",
		launcher.approval_cli(tostring(field(req, "approval") or "yolo")),
		"--max-time",
		string.format("%d", tonumber(field(req, "max_runtime_s")) or const.MAXRUN_DEFAULT_S),
		"--session-dir",
		dir .. "/session",
		"--append-system-prompt",
		dir .. "/preamble.md",
		"--config",
		dir .. "/omp.yml",
	}
	if field(req, "allow_home") == true then
		table.insert(a, "--allow-home")
	end
	table.insert(a, "@" .. dir .. "/prompt.md")
	table.insert(a, const.FIXED_POSITIONAL)
	return a
end

-- Full `tern new …` argv. verb: "new_session" (create the run session), "new_tab" (tab in the run
-- session), "new_tab_shown" (tab in the shown session).
function launcher.argv(req: LaunchRequest, verb: string?): { string }
	local v = verb or "new_session"
	local a: { string } = { req.bins.tern, "new" }
	if v == "new_session" then
		table.insert(a, "session")
		table.insert(a, req.session_name)
	elseif v == "new_tab" then
		table.insert(a, "tab")
		table.insert(a, req.session_name)
	else
		table.insert(a, "tab")
	end
	for _, s in ipairs({ "--json", "--cwd", tostring(field(req, "cwd")), "--keep-open", "--" }) do
		table.insert(a, s)
	end
	for _, s in ipairs(launcher.omp_argv(req)) do
		table.insert(a, s)
	end
	return a
end

local function human_duration(secs: number): string
	local m = math.max(1, math.floor(secs / 60 + 0.5))
	local h, rest = m // 60, m % 60
	local parts: { string } = {}
	if h > 0 then
		table.insert(parts, h == 1 and "1 hour" or string.format("%d hours", h))
	end
	if rest > 0 then
		table.insert(parts, rest == 1 and "1 minute" or string.format("%d minutes", rest))
	end
	return table.concat(parts, " ")
end

local function local_time(t: number): string
	local ok, s = pcall(function()
		return os.date("%a %Y-%m-%d %H:%M %Z", t)
	end)
	if ok and type(s) == "string" then
		return s
	end
	return tostring(t)
end

local function safe_name(name: string): string
	local s = name:gsub("[%c`]", " "):gsub("%s+", " ")
	s = s:gsub("^ ", ""):gsub(" $", "")
	if #s > 80 then
		local i = 80
		while i > 0 do
			local b = s:byte(i + 1)
			if b ~= nil and b >= 0x80 and b < 0xC0 then
				i -= 1
			else
				break
			end
		end
		s = s:sub(1, i)
	end
	return s
end

-- LA §3 text, verbatim, with the substitutions.
function launcher.preamble(req: LaunchRequest): string
	local run, job = req.run, req.job
	local slot = tonumber(run.slot) or os.time()
	local how
	if req.trigger == "manual" then
		how = "was started manually (Run now)"
	elseif req.trigger == "test" then
		how = "was started as a test run"
	else
		how = string.format("was started on schedule (slot %s)", req.slot_local or local_time(slot))
	end
	local fire = local_time(tonumber(run.created) or slot)
	local cwd = tostring(field(req, "cwd"))
	local max_h = human_duration(tonumber(field(req, "max_runtime_s")) or const.MAXRUN_DEFAULT_S)
	local lines = {
		string.format(
			'This is an unattended run of the scheduled job "%s" (job %s, run %s).',
			safe_name(tostring(run.job_name or job.name or "")),
			tostring(run.job_id or job.id),
			tostring(run.run_id)
		),
		string.format("It %s, at %s. Nobody is watching this terminal and nobody will answer questions.", how, fire),
		"",
		"- Do the task in the user's message completely and on your own. Make reasonable assumptions and say what you assumed. Ask a question only if you truly cannot continue without the answer.",
		"- If you are blocked (missing access, a tool keeps failing, an instruction you cannot resolve), stop and say exactly what is blocking you. Do not retry the same failing step more than twice.",
		string.format("- Your working directory is %s. Do not change files outside it unless the task says to.", cwd),
		"- Do not leave background processes or servers running when you finish.",
		string.format("- You have about %s before this run is stopped. Finish before then.", max_h),
		"- End your final message with one line starting `RESULT:` followed by a one-sentence summary, for example `RESULT: 3 PRs merged, 1 risky change in auth/session.ts`. If you could not complete the task, write `RESULT: FAILED - <reason>`.",
	}
	return table.concat(lines, "\n") .. "\n"
end

-- LA §7.2: hands-off disables the ask tool; every other mode pins the exec tier to `prompt` so a repo's own
-- .omp/config.yml cannot widen "Ask before commands"; "Ask for everything" also pins the write tier.
-- Tool names come from `omp --help`'s tool list [SUSPECT: only `bash` was exercised by V31].
function launcher.overlay(approval: string): string
	if approval == "yolo" then
		return "ask:\n  enabled: false\n"
	end
	local lines = {
		"tools:",
		"  approval:",
		"    bash: prompt",
		"    eval: prompt",
		"    task: prompt",
		"    browser: prompt",
		"    python: prompt",
		"    computer: prompt",
	}
	if approval == "always_ask" then
		table.insert(lines, "    edit: prompt")
		table.insert(lines, "    write: prompt")
		table.insert(lines, "    notebook: prompt")
	end
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

-- Writes prompt.md, preamble.md, omp.yml into the run dir. ok, err.
function launcher.write_files(req: LaunchRequest): (boolean, string?)
	local data = store.root()
	if validate.unsafe_path(data) then
		return false, "Tern's data folder path contains a character the launcher can't pass safely."
	end
	local cwd = tostring(field(req, "cwd") or "")
	if cwd == "" or cwd:find("%c") ~= nil then
		-- cwd is only ever a `--cwd` argv element (no shell); only the data root and omp path reach shell text
		return false, "The folder name has characters Agent Scheduler can't pass safely."
	end
	local rel = launcher.run_dir_rel(req)
	store.mkdirs(rel)
	local files = {
		{ "prompt.md", req.prompt },
		{ "preamble.md", launcher.preamble(req) },
		{ "omp.yml", launcher.overlay(tostring(field(req, "approval") or "yolo")) },
	}
	for _, f in ipairs(files) do
		local ok, err = store.write_text(rel .. "/" .. f[1], f[2])
		if not ok then
			return false, tostring(err)
		end
	end
	req.run.overlay = true
	return true, nil
end

-- ---------- process helpers ----------

-- process.run that never raises: cb gets a result table (status -1 and `raised` when the spawn failed).
local function proc(argv: { string }, opts: { [string]: any }, cb: (any) -> ())
	local ok, err = pcall(function()
		(tern :: any).process.run(argv, opts, cb)
	end)
	if not ok then
		pcall(function()
			bins_mod.invalidate()
		end)
		cb({ status = -1, stdout = "", stderr = tostring(err), timed_out = false, raised = true })
	end
end

local function tab_title(name: string): string
	local s = safe_name(name)
	if utf8.len(s) ~= nil and (utf8.len(s) :: number) > 40 then
		local cut = utf8.offset(s, 41)
		if cut ~= nil then
			s = s:sub(1, cut - 1) .. "…"
		end
	end
	return "⏲ " .. s
end

-- ---------- the queue ----------

local queue: { { req: LaunchRequest, cb: (LaunchResult?, LaunchError?) -> () } } = {}
local busy = false

local function pump()
	if busy then
		return
	end
	local item = table.remove(queue, 1)
	if item == nil then
		return
	end
	busy = true
	local req, cb = item.req, item.cb
	local released = false
	local function release()
		if released then
			return
		end
		released = true
		busy = false
		pump()
	end
	local replied = false
	local function reply(res: LaunchResult?, err: LaunchError?)
		if replied then
			return
		end
		replied = true
		local ok, e = pcall(cb, res, err)
		if not ok then
			warn("launcher: callback failed", tostring(e))
		end
	end

	local okw, werr = launcher.write_files(req)
	if not okw then
		reply(nil, { code = "data_unwritable", text = tostring(werr) })
		return release()
	end

	local run_key = tostring(req.run.job_id or req.job.id) .. "/" .. tostring(req.run.run_id)

	local function succeeded(block: string, tab: string?, session: string?, placement: string)
		reply({ block = block, tab = tab, session = session, placement_used = placement }, nil)
		-- best effort, after the run has its block id
		local function focus()
			if req.focus == "front" then
				proc({ req.bins.tern, "focus", block }, { timeout_ms = 8000 }, function()
					release()
				end)
			else
				release()
			end
		end
		proc({ req.bins.tern, "rename", block, tab_title(tostring(req.run.job_name or req.job.name or "run")) }, { timeout_ms = 8000 }, function()
			focus()
		end)
	end

	local attempt: (number) -> ()
	local function failed(n: number, code: string, text: string)
		if n < MAX_ATTEMPTS then
			local okt = pcall(function()
				(tern :: any).timer(RETRY_MS, function()
					attempt(n + 1)
				end)
			end)
			if okt then
				return
			end
		end
		reply(nil, { code = code, text = text })
		release()
	end

	attempt = function(n: number)
		tern_state.snapshot(req.bins.tern, function(st, r)
			local state = st
			if state == nil then
				local text = tostring(r and r.stdout or "") .. tostring(r and r.stderr or "")
				if text:find("no sessions", 1, true) then
					state = { sessions = {}, session_ids = {}, blocks = {}, by_run = {} }
				elseif text:find("no Tern is running", 1, true) then
					return failed(n, "tern_unreachable", "Tern's session service isn't reachable.")
				else
					return failed(n, (r and r.timed_out) and "launch_timeout" or "launch_error", "tern ls failed: " .. text:sub(1, 200))
				end
			end
			local s = state :: tern_state.State
			-- idempotent: a pane carrying this run's marker already exists (an earlier attempt that timed out)
			local existing = s.by_run[run_key]
			if existing ~= nil then
				return succeeded(existing.id, existing.tab, existing.session ~= nil and s.session_ids[existing.session] or nil, "session")
			end
			local verb: string
			local placement: string
			if req.where == "tab" then
				local shown = false
				for _, se in ipairs(s.sessions) do
					if se.shown == true then
						shown = true
					end
				end
				if shown then
					verb, placement = "new_tab_shown", "tab"
				else
					verb, placement = (s.session_ids[req.session_name] ~= nil) and "new_tab" or "new_session", "session"
				end
			else
				verb, placement = (s.session_ids[req.session_name] ~= nil) and "new_tab" or "new_session", "session"
			end
			local tried: { [string]: boolean } = {}
			local function launch(v: string)
				tried[v] = true
				proc(launcher.argv(req, v), { timeout_ms = const.LAUNCH_TIMEOUT_MS }, function(res)
					local text = tostring(res.stderr or "") .. tostring(res.stdout or "")
					if res.status == 0 then
						local block = tostring(res.stdout):match('"block"%s*:%s*(%d+)')
						if block ~= nil then
							local tab = tostring(res.stdout):match('"tab"%s*:%s*(%d+)')
							local session = tostring(res.stdout):match('"session"%s*:%s*(%d+)')
							return succeeded(block, tab, session, placement)
						end
						return failed(n, "launch_error", "tern new printed no block id")
					end
					-- each fallback verb is tried at most once, then the attempt fails normally (MAX_ATTEMPTS applies)
					if v == "new_tab" and text:find("there is no session", 1, true) and not tried.new_session then
						placement = "session"
						return launch("new_session")
					end
					if v == "new_session" and text:find("already exists", 1, true) and not tried.new_tab then
						return launch("new_tab")
					end
					failed(n, res.timed_out and "launch_timeout" or "launch_error", text:sub(1, 200))
				end)
			end
			launch(verb)
		end)
	end
	attempt(1)
end

-- cb(LaunchResult) as soon as `tern new` returned the ids (before the best-effort rename/focus), or
-- cb(nil, LaunchError). One launch in flight at a time.
function launcher.enqueue(req: LaunchRequest, cb: (LaunchResult?, LaunchError?) -> ())
	table.insert(queue, { req = req, cb = cb })
	pump()
end

function launcher.queued(): number
	return #queue + (busy and 1 or 0)
end

-- LA §10 "Open run" when the pane is gone: a new tab in the shown session resuming omp's session file.
-- cb(ok, err). The resumed pane is a user session; its command has no `@…/prompt.md` attachment, which is
-- what tern_state anchors the run marker on, so it is not mistaken for the run's pane.
function launcher.resume(run: { [string]: any }, bins: Bins, cb: (boolean, string?) -> ())
	local file = run.session_file
	if type(file) ~= "string" or file == "" then
		return cb(false, "That run's session was removed, so it can't be reopened.")
	end
	local dir = store.path(tostring(run.run_dir))
	local argv: { string } = {
		bins.tern,
		"new",
		"tab",
		"--json",
		"--cwd",
		tostring(run.cwd),
		"--keep-open",
		"--",
		bins.omp,
		"--session-dir",
		dir .. "/session",
		"--resume",
		file,
		"--approval-mode",
		launcher.approval_cli(tostring(run.approval or "yolo")),
		"--config",
		dir .. "/omp.yml",
	}
	if run.allow_home == true then
		table.insert(argv, "--allow-home")
	end
	proc(argv, { timeout_ms = const.LAUNCH_TIMEOUT_MS }, function(res)
		if res.status == 0 then
			cb(true, nil)
		else
			cb(false, "Couldn't reopen the run: " .. tostring(res.stderr or ""):sub(1, 120))
		end
	end)
end

return launcher
