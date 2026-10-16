-- test/fake_tern.luau : a global `tern` for the runner tests (prepended by test/run.ts to runner_*.luau).
-- In-memory fs / kv, a virtual clock (monotonic ms + wall seconds, both driven by fake.advance), a JSON codec
-- with tern semantics, and a scripted `tern.process.run` that models the tern CLI (ls/new/rename/focus/close),
-- omp, /bin/test, /usr/bin/tail and osascript. Every spawn is recorded in fake.calls.
-- `os` here is the writable copy made by the test prelude; time and date are driven from the fake.
local fake_clock = __mods.fake -- America/Chicago fake (test/fake_chicago.luau)
__mods.cron.clock = fake_clock

local fake = {
	mono = 0, -- monotonic ms
	wall_ms = 0, -- wall clock, ms since the epoch
	seq = 0,
	events = {},
	files = {},
	dirs = { ["/"] = true, ["/d"] = true, ["/p"] = true },
	kv = {},
	calls = {},
	handlers = {},
	errors = {},
	warns = {},
	override = {}, -- key -> function(argv, opts) -> result | nil
	hooks = {}, -- hooks.new(info) after a successful `tern new`
	latency = 0,
	tern_bin = "/Applications/Tern.app/Contents/MacOS/tern",
	omp_bin = "/opt/homebrew/bin/omp",
	sessions = {},
	blocks = {},
	next_id = 18043157610500,
	roles_json = '{"key":"modelRoles","value":{"default":"anthropic/claude-opus-5-5:medium","smol":"anthropic/claude-haiku-5-5:low","tiny":"anthropic/claude-haiku-5-5","judge":"x/y"},"type":"record"}',
}
fake.live_panes = {} -- pane ids (strings) reported by tern.pane.list()
fake.installed = {
	[fake.tern_bin] = "tern 0.9.0 (test)\n",
	[fake.omp_bin] = "omp/18.9.1\n",
}

-- ---------- clock ----------
local real_time, real_date = os.time, os.date
local function step_to(t)
	fake.wall_ms += t - fake.mono
	fake.mono = t
end
function fake.wall()
	return math.floor(fake.wall_ms / 1000)
end
function fake.set_wall(unix)
	fake.wall_ms = unix * 1000
end
-- A wall-clock jump with no monotonic movement (suspend / manual change).
function fake.jump_wall(secs)
	fake.wall_ms += secs * 1000
end
os.time = function(t)
	if t == nil then
		return fake.wall()
	end
	return real_time(t)
end
local function chicago_offset(t)
	local l, u = fake_clock.date("*t", t), fake_clock.date("!*t", t)
	local d = (l.hour * 3600 + l.min * 60) - (u.hour * 3600 + u.min * 60)
	if d > 12 * 3600 then
		d -= 86400
	elseif d < -12 * 3600 then
		d += 86400
	end
	return d
end
os.date = function(fmt, t)
	t = t or fake.wall()
	if fmt == "*t" or fmt == "!*t" then
		return fake_clock.date(fmt, t)
	end
	if fmt:sub(1, 1) == "!" then
		return real_date(fmt, t)
	end
	return real_date("!" .. fmt, t + chicago_offset(t))
end
function fake.chicago(y, m, d, h, mi, s)
	return fake_clock.time({ year = y, month = m, day = d, hour = h, min = mi, sec = s or 0 })
end

function fake.at(ms, fn)
	fake.seq += 1
	table.insert(fake.events, { at = fake.mono + ms, seq = fake.seq, fn = fn })
end

function fake.advance(ms)
	local target = fake.mono + ms
	while true do
		local best, bi = nil, nil
		for i, e in ipairs(fake.events) do
			if e.at <= target and (best == nil or e.at < best.at or (e.at == best.at and e.seq < best.seq)) then
				best, bi = e, i
			end
		end
		if best == nil then
			break
		end
		table.remove(fake.events, bi)
		step_to(best.at)
		local ok, err = pcall(best.fn)
		if not ok then
			table.insert(fake.errors, "event: " .. tostring(err))
		end
	end
	step_to(target)
end
-- Advance in `step` ms slices until pred() or `max` ms elapsed. Returns pred().
function fake.run_until(pred, max, step)
	local spent = 0
	step = step or 500
	while spent < max do
		if pred() then
			return true
		end
		fake.advance(step)
		spent += step
	end
	return pred()
end

-- ---------- json ----------
local NULL = setmetatable({}, { __tostring = function() return "null" end })
local ARR = {}
local json = { null = NULL }
function json.array(t)
	t = t or {}
	return setmetatable(t, ARR)
end
local function is_array(t)
	if getmetatable(t) == ARR then
		return true
	end
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n > 0 and #t == n
end
local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function enc_str(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return ESC[c] or string.format("\\u%04x", c:byte())
	end) .. '"'
end
local function enc(v, out)
	local tv = type(v)
	if v == NULL or v == nil then
		out[#out + 1] = "null"
	elseif tv == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif tv == "number" then
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			out[#out + 1] = string.format("%.0f", v)
		else
			out[#out + 1] = string.format("%.14g", v)
		end
	elseif tv == "string" then
		out[#out + 1] = enc_str(v)
	elseif tv == "table" then
		if is_array(v) then
			out[#out + 1] = "["
			for i = 1, #v do
				if i > 1 then
					out[#out + 1] = ","
				end
				enc(v[i], out)
			end
			out[#out + 1] = "]"
		else
			local keys = {}
			for k in pairs(v) do
				keys[#keys + 1] = tostring(k)
			end
			table.sort(keys)
			out[#out + 1] = "{"
			local first = true
			for _, k in ipairs(keys) do
				if not first then
					out[#out + 1] = ","
				end
				first = false
				out[#out + 1] = enc_str(k) .. ":"
				enc(v[k], out)
			end
			out[#out + 1] = "}"
		end
	else
		error("json.encode: unsupported " .. tv)
	end
end
function json.encode(v, _pretty)
	local out = {}
	enc(v, out)
	return table.concat(out)
end
function json.decode(text)
	local i = 1
	local function ws()
		i = text:find("[^ \t\r\n]", i) or #text + 1
	end
	local val
	local function str()
		i += 1
		local buf = {}
		while true do
			local c = text:sub(i, i)
			if c == "" then
				error("json: unterminated string")
			elseif c == '"' then
				i += 1
				return table.concat(buf)
			elseif c == "\\" then
				local n = text:sub(i + 1, i + 1)
				local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				if n == "u" then
					local cp = tonumber(text:sub(i + 2, i + 5), 16)
					if cp == nil then
						error("json: bad escape")
					end
					i += 6
					if cp >= 0xD800 and cp < 0xDC00 and text:sub(i, i + 1) == "\\u" then
						local lo = tonumber(text:sub(i + 2, i + 5), 16)
						if lo then
							cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
							i += 6
						end
					end
					buf[#buf + 1] = utf8.char(cp)
				elseif map[n] then
					buf[#buf + 1] = map[n]
					i += 2
				else
					error("json: bad escape")
				end
			else
				local j = text:find('["\\]', i) or #text + 1
				buf[#buf + 1] = text:sub(i, j - 1)
				i = j
			end
		end
	end
	function val()
		ws()
		local c = text:sub(i, i)
		if c == "{" then
			i += 1
			local o = {}
			ws()
			if text:sub(i, i) == "}" then
				i += 1
				return o
			end
			while true do
				ws()
				if text:sub(i, i) ~= '"' then
					error("json: expected key at " .. i)
				end
				local k = str()
				ws()
				if text:sub(i, i) ~= ":" then
					error("json: expected : at " .. i)
				end
				i += 1
				local v = val()
				if v ~= NULL then
					o[k] = v
				end
				ws()
				local d = text:sub(i, i)
				i += 1
				if d == "}" then
					return o
				elseif d ~= "," then
					error("json: expected , or } at " .. (i - 1))
				end
			end
		elseif c == "[" then
			i += 1
			local a = json.array({})
			ws()
			if text:sub(i, i) == "]" then
				i += 1
				return a
			end
			while true do
				a[#a + 1] = val()
				ws()
				local d = text:sub(i, i)
				i += 1
				if d == "]" then
					return a
				elseif d ~= "," then
					error("json: expected , or ] at " .. (i - 1))
				end
			end
		elseif c == '"' then
			return str()
		elseif text:sub(i, i + 3) == "true" then
			i += 4
			return true
		elseif text:sub(i, i + 4) == "false" then
			i += 5
			return false
		elseif text:sub(i, i + 3) == "null" then
			i += 4
			return NULL
		else
			local num = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
			if num == nil or num == "" then
				error("json: unexpected character at " .. i)
			end
			i += #num
			return tonumber(num)
		end
	end
	local v = val()
	ws()
	if i <= #text then
		error("json: trailing data at " .. i)
	end
	return v
end

-- ---------- fs ----------
local function dirname(p)
	return p:match("^(.*)/[^/]*$") or ""
end
local function mkdirs(p)
	local cur = ""
	for part in p:gmatch("[^/]+") do
		cur = cur .. "/" .. part
		fake.dirs[cur] = true
	end
end
local fs = {}
function fs.read(path, max)
	local t = fake.files[path]
	if t == nil then
		error("tern.fs.read " .. path .. ": No such file or directory")
	end
	if max ~= nil and #t > max then
		error("tern.fs.read " .. path .. ": file too large")
	end
	return t
end
function fs.write(path, text)
	local d = dirname(path)
	if d ~= "" and not fake.dirs[d] then
		error("tern.fs.write " .. path .. ": No such file or directory")
	end
	fake.files[path] = text
end
function fs.list(path)
	if not fake.dirs[path] then
		error("tern.fs.list " .. path .. ": No such file or directory")
	end
	local seen, out = {}, {}
	local prefix = path .. "/"
	local function add(p)
		if p:sub(1, #prefix) == prefix then
			local name = p:sub(#prefix + 1):match("^([^/]+)")
			if name and not seen[name] then
				seen[name] = true
				out[#out + 1] = name
			end
		end
	end
	for p in pairs(fake.files) do
		add(p)
	end
	for p in pairs(fake.dirs) do
		add(p)
	end
	table.sort(out)
	return out
end
function fs.exists(path)
	return fake.files[path] ~= nil or fake.dirs[path] == true or fake.installed[path] ~= nil
end
function fs.mkdir(path)
	mkdirs(path)
end
function fs.remove(path)
	fake.files[path] = nil
	fake.dirs[path] = nil
	local prefix = path .. "/"
	for p in pairs(fake.files) do
		if p:sub(1, #prefix) == prefix then
			fake.files[p] = nil
		end
	end
	for p in pairs(fake.dirs) do
		if p:sub(1, #prefix) == prefix then
			fake.dirs[p] = nil
		end
	end
end
function fake.write(path, text)
	mkdirs(dirname(path))
	fake.files[path] = text
end
function fake.read(path)
	return fake.files[path]
end

-- ---------- tern CLI model ----------
local function quote(a)
	if a:find("[^%w@%._/%-:=,+]") or a == "" then
		return "'" .. a:gsub("'", "'\\''") .. "'"
	end
	return a
end
local function new_id()
	fake.next_id += 1
	return fake.next_id
end
local function find_session(name)
	for _, s in ipairs(fake.sessions) do
		if s.name == name then
			return s
		end
	end
	return nil
end
function fake.ls_json()
	local sessions = json.array({})
	for _, s in ipairs(fake.sessions) do
		local tabs = json.array({})
		for n, t in ipairs(s.tabs) do
			local blocks = json.array({})
			for _, id in ipairs(t.blocks) do
				local b = fake.blocks[id]
				if b then
					local entry = {
						id = b.id, title = b.title, cwd = b.cwd, program = b.program, args = json.array({ table.unpack(b.args) }),
						command = b.command, cols = 80, rows = 24, exited = b.exited, keep_open = b.keep_open,
						focused = b.focused == true, live = b.live ~= false,
					}
					blocks[#blocks + 1] = entry
				end
			end
			tabs[#tabs + 1] = { id = t.id, number = n, name = t.name, shown = t.shown == true, zoomed = false, blocks = blocks }
		end
		sessions[#sessions + 1] = { id = s.id, name = s.name, shown = s.shown == true, tabs = tabs }
	end
	return json.encode({ sessions = sessions, detached = json.array({}) })
end
function fake.block_for_run(run_id)
	for id, b in pairs(fake.blocks) do
		if b.command:find(run_id, 1, true) then
			return id, b
		end
	end
	return nil
end
function fake.exit_block(id, status)
	fake.blocks[id].exited = status
end
function fake.remove_block(id)
	fake.blocks[id] = nil
	for _, s in ipairs(fake.sessions) do
		for ti = #s.tabs, 1, -1 do
			local t = s.tabs[ti]
			for bi = #t.blocks, 1, -1 do
				if t.blocks[bi] == id then
					table.remove(t.blocks, bi)
				end
			end
			if #t.blocks == 0 then
				table.remove(s.tabs, ti)
			end
		end
	end
end
function fake.emit(name, ev)
	for _, fn in ipairs(fake.handlers[name] or {}) do
		fn(ev)
	end
end

local function ok(stdout)
	return { status = 0, stdout = stdout or "", stderr = "", timed_out = false }
end
local function fail(stderr)
	return { status = 1, stdout = "", stderr = stderr, timed_out = false }
end

local function tern_new(argv)
	local kind = argv[3]
	local name, i = nil, 4
	if argv[i] and argv[i]:sub(1, 2) ~= "--" then
		name, i = argv[i], i + 1
	end
	local cwd, cmd = "", {}
	while i <= #argv do
		local a = argv[i]
		if a == "--cwd" then
			cwd, i = argv[i + 1], i + 2
		elseif a == "--" then
			for j = i + 1, #argv do
				cmd[#cmd + 1] = argv[j]
			end
			break
		else
			i += 1
		end
	end
	local session, tab
	if kind == "session" then
		if find_session(name) then
			return fail("session already exists")
		end
		session = { id = new_id(), name = name, shown = false, tabs = {} }
		table.insert(fake.sessions, session)
	elseif name ~= nil then
		session = find_session(name)
		if session == nil then
			return fail("there is no session named " .. name)
		end
	else
		for _, s in ipairs(fake.sessions) do
			if s.shown then
				session = s
			end
		end
		if session == nil then
			return fail("there is no session")
		end
	end
	tab = { id = new_id(), name = nil, shown = false, blocks = {} }
	table.insert(session.tabs, tab)
	local quoted = {}
	for k, a in ipairs(cmd) do
		quoted[k] = quote(a)
	end
	local b = {
		id = new_id(), title = "omp", cwd = cwd, program = "/bin/zsh", args = { "-c", table.concat(quoted, " ") },
		command = table.concat(quoted, " "), keep_open = true, live = true,
	}
	fake.blocks[b.id] = b
	table.insert(tab.blocks, b.id)
	if fake.hooks.new then
		local sdir
		for k = 1, #cmd do
			if cmd[k] == "--session-dir" then
				sdir = cmd[k + 1]
			end
		end
		fake.hooks.new({ block = b.id, session_dir = sdir, cmd = cmd, kind = kind, session_name = session.name })
	end
	return ok(string.format('{"session":%.0f,"tab":%.0f,"block":%.0f}\n', session.id, tab.id, b.id))
end

local function find_tab(id)
	for _, s in ipairs(fake.sessions) do
		for _, t in ipairs(s.tabs) do
			for _, bid in ipairs(t.blocks) do
				if bid == id then
					return t
				end
			end
		end
	end
	return nil
end

local function respond(argv, opts)
	local base = argv[1]:match("([^/]+)$")
	local key
	if argv[2] == "--version" then
		key = "--version"
	elseif base == "tern" then
		key = argv[2]
	elseif base == "omp" then
		key = if argv[2] == "-p" then "omp_print" else "config"
	else
		key = base
	end
	fake.calls[#fake.calls + 1] = { argv = argv, opts = opts, key = key }
	local custom = fake.override[key]
	if custom then
		local r = custom(argv, opts)
		if r ~= nil then
			return r
		end
	end
	if key == "--version" then
		local v = fake.installed[argv[1]]
		if v == nil then
			error("tern.process.run " .. argv[1] .. ": No such file or directory")
		end
		return ok(v)
	elseif key == "ls" then
		return ok(fake.ls_json())
	elseif key == "new" then
		return tern_new(argv)
	elseif key == "rename" then
		local t = find_tab(tonumber(argv[3]))
		if t then
			t.name = argv[4]
		end
		return ok()
	elseif key == "focus" then
		for id, b in pairs(fake.blocks) do
			b.focused = (string.format("%.0f", id) == argv[3])
		end
		return ok()
	elseif key == "close" then
		fake.remove_block(tonumber(argv[3]))
		return ok()
	elseif key == "capture" then
		return ok("something failed\n")
	elseif key == "config" then
		return ok(fake.roles_json)
	elseif key == "test" then
		return { status = fake.dirs[argv[3]] and 0 or 1, stdout = "", stderr = "", timed_out = false }
	elseif key == "tail" then
		local f = fake.files[argv[4]]
		if f == nil then
			return { status = 1, stdout = "", stderr = "tail: No such file", timed_out = false }
		end
		local n = tonumber(argv[3]) or #f
		return ok(#f > n and f:sub(-n) or f)
	elseif key == "zsh" then
		return ok(fake.omp_bin .. "\n")
	end
	return ok() -- osascript, open, git, …
end

-- ---------- the global ----------
local function timer(ms, fn)
	fake.at(ms, fn)
	return {}
end
tern = {
	fs = fs,
	json = json,
	kv = {
		get = function(k)
			local v = fake.kv[k]
			if v == nil then
				return nil
			end
			return json.decode(json.encode(v))
		end,
		set = function(k, v)
			if v == nil then
				fake.kv[k] = nil
			else
				fake.kv[k] = json.decode(json.encode(v))
			end
		end,
	},
	now = function()
		return fake.mono
	end,
	timer = timer,
	getenv = function(name)
		if name == "HOME" then
			return "/home/u"
		end
		return nil
	end,
	on = function(name, fn)
		fake.handlers[name] = fake.handlers[name] or {}
		table.insert(fake.handlers[name], fn)
	end,
	log = {
		debug = function() end,
		info = function() end,
		warn = function(...)
			table.insert(fake.warns, table.concat({ ... }, " "))
		end,
		error = function(...)
			local parts = {}
			for _, a in ipairs({ ... }) do
				parts[#parts + 1] = tostring(a)
			end
			table.insert(fake.errors, table.concat(parts, " "))
		end,
	},
	plugin = { id = "tern-agent-scheduler", data = "/d", dir = "/p" },
	process = {
		run = function(argv, opts, cb)
			if type(opts) == "function" then
				cb, opts = opts, nil
			end
			local result = respond(argv, opts)
			local copy = result
			fake.at(fake.latency, function()
				cb(copy)
			end)
		end,
	},
	pane = {
		list = function()
			local out = {}
			for _, id in ipairs(fake.live_panes) do
				out[#out + 1] = { pane = tonumber(id) }
			end
			return out
		end,
	},
}

-- ---------- helpers for tests ----------
function fake.calls_of(key)
	local out = {}
	for _, c in ipairs(fake.calls) do
		if c.key == key then
			out[#out + 1] = c.argv
		end
	end
	return out
end
function fake.join(argv)
	return table.concat(argv, " ")
end
function fake.intent(name, payload)
	fake.write("/d/intents/" .. name .. ".json", json.encode(payload))
end
function fake.reply(id)
	local t = fake.files["/d/replies/" .. id .. ".json"]
	return t and json.decode(t) or nil
end
