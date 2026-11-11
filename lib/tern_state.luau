--!strict
-- lib/tern_state.luau : the one reader of `tern ls --json` / `tern inspect --json` (LA §2.0, R14). Sessions, blocks,
-- liveness. Ids are turned into strings BEFORE decoding. A block is "ours" only when it was started as a shell
-- `-c '<omp command>'` (Tern lists the argv as {"-c", cmd}, or {"-l", "-c", cmd} for a login shell) whose
-- command carries `/runs/<job>/<run>/prompt.md` (V29): after a daemon restart a pane keeps its block id but
-- becomes a bare shell (no "-c") while `command` still shows the old command line, so `command` is never used
-- for ownership.
-- Sessions belong to one window, and the host has no window of its own: without `--window KEY` every `tern`
-- command acts on the first window. snapshot_all reads every window, so a block knows the window it lives in.
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
	window: string?, -- the window key whose sessions hold it; nil when only the first window was read
	[string]: any,
}
export type State = {
	sessions: { any },
	session_ids: { [string]: string }, -- session name -> id (string)
	blocks: { [string]: Block },
	by_run: { [string]: Block }, -- "<job>/<run>" -> block
	windows: { string }, -- keys of the open windows (`tern inspect` only; empty from `tern ls`)
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

-- `argv` with `--window KEY` added (before a `--` command separator, else at the end); unchanged for nil.
function tern_state.with_window(argv: { string }, window: string?): { string }
	if window == nil then
		return argv
	end
	local out: { string } = {}
	local placed = false
	for _, a in ipairs(argv) do
		if a == "--" and not placed then
			table.insert(out, "--window")
			table.insert(out, window)
			placed = true
		end
		table.insert(out, a)
	end
	if not placed then
		table.insert(out, "--window")
		table.insert(out, window)
	end
	return out
end

-- True when a `tern` result says the window key it was given is gone (the window closed, or Tern restarted).
function tern_state.window_gone(r: any): boolean
	local text = tostring(r and r.stderr or "") .. tostring(r and r.stdout or "")
	return text:find("no window has key", 1, true) ~= nil
end

-- Parses `tern ls --json` or `tern inspect --json` stdout into a State; nil when it is not decodable.
-- Every block is labelled with `window`.
function tern_state.parse(stdout: string, window: string?): State?
	local s = stdout:gsub('("id"%s*:%s*)(%d+)', '%1"%2"')
	local ok, j = pcall(function()
		return (tern :: any).json.decode(s)
	end)
	if not ok or type(j) ~= "table" or type(j.sessions) ~= "table" then
		return nil
	end
	local st: State = { sessions = j.sessions, session_ids = {}, blocks = {}, by_run = {}, windows = {} }
	if type(j.clients) == "table" then
		local seen: { [string]: boolean } = {}
		for _, c in ipairs(j.clients) do
			if type(c) == "table" and c.kind == "window" and type(c.window) == "string" and not seen[c.window] then
				seen[c.window] = true
				table.insert(st.windows, c.window)
			end
		end
	end
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
				b.window = window
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

-- Runs `tern <args> --json` and parses it. cb(State) on success; cb(nil, result) when it failed or printed
-- something undecodable.
local function read(tern_bin: string, args: { string }, window: string?, cb: (State?, any) -> ())
	local argv = { tern_bin }
	for _, a in ipairs(args) do
		table.insert(argv, a)
	end
	local ok, err = pcall(function()
		(tern :: any).process.run(tern_state.with_window(argv, window), { timeout_ms = 8000 }, function(r: any)
			if r.status ~= 0 then
				return cb(nil, r)
			end
			local st = tern_state.parse(r.stdout, window)
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

-- One window's sessions: `window`'s, or the first window's for nil. Blocks are labelled with `window`.
function tern_state.snapshot(tern_bin: string, cb: (State?, any) -> (), window: string?)
	read(tern_bin, { "ls", "--json" }, window, cb)
end

-- Every window's sessions, each block labelled with its window's key. Sessions/session_ids are the first
-- window's. cb(nil, result) when any window couldn't be read: a partial picture would make the panes of the
-- unread window look closed.
function tern_state.snapshot_all(tern_bin: string, cb: (State?, any) -> ())
	read(tern_bin, { "inspect", "--json" }, nil, function(first, r)
		if first == nil then
			return cb(nil, r)
		end
		local keys = first.windows
		if #keys == 1 then
			-- the first window is the only one
			for _, b in pairs(first.blocks) do
				b.window = keys[1]
			end
			return cb(first)
		elseif #keys == 0 then
			return cb(first)
		end
		local pending = #keys
		local failed: any = nil
		local parts: { State } = {}
		for _, key in ipairs(keys) do
			tern_state.snapshot(tern_bin, function(st, r2)
				if st == nil then
					failed = failed or r2 or { status = -1, stdout = "", stderr = "", timed_out = false }
				else
					table.insert(parts, st)
				end
				pending -= 1
				if pending > 0 then
					return
				end
				if failed ~= nil then
					return cb(nil, failed)
				end
				for _, part in ipairs(parts) do
					for id, b in pairs(part.blocks) do
						first.blocks[id] = b
					end
					for k, b in pairs(part.by_run) do
						first.by_run[k] = b
					end
				end
				cb(first)
			end, key)
		end
	end)
end

return tern_state
