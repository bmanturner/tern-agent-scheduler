--!strict
-- lib/tern_state.luau : the one reader of `tern ls --json` (LA §2.0, R14). Sessions, blocks, liveness.
-- Ids are turned into strings BEFORE decoding. A block is "ours" only when it was started as a shell
-- `-c '<omp command>'` (Tern lists the argv as {"-c", cmd}, or {"-l", "-c", cmd} for a login shell) whose
-- command carries `/runs/<job>/<run>/prompt.md` (V29): after a daemon restart a pane keeps its block id but
-- becomes a bare shell (no "-c") while `command` still shows the old command line, so `command` is never used
-- for ownership.

local bins = require("./bins")

export type Block = {
	id: string,
	session: string,
	tab: string,
	tab_shown: boolean,
	session_shown: boolean,
	cwd: string?,
	command: string?,
	args: { string }?,
	live: boolean?,
	exited: number?,
	focused: boolean?,
	keep_open: boolean?,
	title: string?,
	[string]: any,
}
export type State = {
	sessions: { any },
	session_ids: { [string]: string }, -- session name -> id (string)
	blocks: { [string]: Block },
	by_run: { [string]: Block }, -- "<job>/<run>" -> block
}

local tern_state = {}

-- The marker is only in a launch argv: `@<run dir>/prompt.md` is the attached prompt. A resumed
-- conversation (`--session-dir <run dir>/session --resume …`) mentions the run dir but never prompt.md.
local MARKER = "@.-/runs/(j_[%w]+)/(r_[%w_]+)/prompt%.md"

-- Run key ("<job>/<run>") a block belongs to, or nil.
function tern_state.marker(b: any): string?
	local args = b.args
	if type(args) ~= "table" then
		return nil
	end
	local at = if args[1] == "-c" then 2 elseif args[2] == "-c" then 3 else nil
	local cmd = if at ~= nil then args[at] else nil
	if type(cmd) ~= "string" then
		return nil
	end
	local job, run = cmd:match(MARKER)
	if job == nil then
		return nil
	end
	return job .. "/" .. run
end

-- Parses `tern ls --json` stdout into a State; nil when it is not decodable.
function tern_state.parse(stdout: string): State?
	local s = stdout:gsub('("id"%s*:%s*)(%d+)', '%1"%2"')
	local ok, j = pcall(function()
		return (tern :: any).json.decode(s)
	end)
	if not ok or type(j) ~= "table" or type(j.sessions) ~= "table" then
		return nil
	end
	local st: State = { sessions = j.sessions, session_ids = {}, blocks = {}, by_run = {} }
	-- sessions no window currently shows are listed apart (`detached`); they still hold our panes
	local all: { any } = {}
	for _, se in ipairs(j.sessions) do
		table.insert(all, se)
	end
	if type(j.detached) == "table" then
		for _, se in ipairs(j.detached) do
			if type(se) == "table" and type(se.tabs) == "table" then
				if se.shown == nil then
					se.shown = false
				end
				table.insert(all, se)
			end
		end
	end
	for _, se in ipairs(all) do
		if type(se.name) == "string" and st.session_ids[se.name] == nil then
			st.session_ids[se.name] = tostring(se.id)
		end
		for _, tab in ipairs(se.tabs or {}) do
			for _, b in ipairs(tab.blocks or {}) do
				b.session, b.tab, b.tab_shown, b.session_shown = se.name, tostring(tab.id), tab.shown == true, se.shown == true
				st.blocks[b.id] = b
				local key = tern_state.marker(b)
				if key ~= nil then
					st.by_run[key] = b
				end
			end
		end
	end
	return st
end

-- cb(State) on success; cb(nil, result) when `tern ls` failed or printed something undecodable.
function tern_state.snapshot(tern_bin: string, cb: (State?, any) -> ())
	local ok, err = pcall(function()
		(tern :: any).process.run({ tern_bin, "ls", "--json" }, { timeout_ms = 8000 }, function(r: any)
			if r.status ~= 0 then
				return cb(nil, r)
			end
			local st = tern_state.parse(r.stdout)
			if st == nil then
				return cb(nil, r)
			end
			cb(st)
		end)
	end)
	if not ok then
		bins.invalidate() -- the tern binary is gone or moved: re-resolve on the next use
		cb(nil, { status = -1, stdout = "", stderr = tostring(err), timed_out = false })
	end
end

return tern_state
