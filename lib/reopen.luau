--!strict
-- lib/reopen.luau : the host `reopen` filter. When Tern reopens an omp chat (after a restart, or in a fork) whose
-- session lives in a run's session dir, the chat reopens with the run's own omp settings (session dir, approval
-- mode, config, --allow-home) and without the run's `@…/prompt.md`, so the prompt isn't sent again. Tern appends
-- the flag (--resume/--restore/--fork) and the session file to the returned command.
local ledger = require("./ledger")
local bins = require("./bins")
local launcher = require("./launcher")

local reopen = {}

-- The run's omp writes its session under `<data>/runs/<job>/<run>/session/` (its --session-dir).
local SESSION_PAT = "/runs/(j_[%w]+)/(r_[%w_]+)/session/"

local function warn(...: any)
	local args = table.pack(...)
	pcall(function()
		(tern :: any).log.warn(table.unpack(args, 1, args.n))
	end)
end

-- One argument for the reopen command line: unchanged when it holds only [%w%-%._/@:=+,],
-- else single-quoted. nil when it holds a single quote or a control character (no portable quoting).
function reopen.quote(s: string): string?
	if s:find("[%c']") then
		return nil
	end
	if s:find("^[%w%-%._/@:=+,]+$") then
		return s
	end
	return "'" .. s .. "'"
end

-- The `reopen` filter: the run's omp command (Tern appends the flag and the session), or nil to keep Tern's.
function reopen.command(ev: any): string?
	if type(ev) ~= "table" or ev.agent ~= "omp" or type(ev.session) ~= "string" then
		return nil
	end
	local job, run_id = (ev.session :: string):match(SESSION_PAT)
	if job == nil or run_id == nil then
		return nil
	end
	local run: any = ledger.get(run_id)
	if run == nil or tostring(run.job_id) ~= job then
		return nil
	end
	local b = bins.get()
	if b == nil then
		warn("tern-agent-scheduler: reopen: omp not resolved yet")
		return nil
	end
	local quoted: { string } = {}
	for _, a in launcher.resume_args(run, b) do
		local q = reopen.quote(a)
		if q == nil then
			warn("tern-agent-scheduler: reopen: can't quote the command for", run_id)
			return nil
		end
		table.insert(quoted, q)
	end
	return table.concat(quoted, " ")
end

return reopen
