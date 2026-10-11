--!strict
-- lib/session_tail.luau : end-of-run facts from omp's session JSONL (LA §8.6), read asynchronously with
-- `/usr/bin/tail -c 1048576` through tern.process.run (never a large synchronous fs.read in the host).
-- Layout (verified): `<run>/session/<ISO>_<id>.jsonl` flat; ignore names starting with "." (lock files).
local const = require("./const")

export type Facts = {
	session_file: string,
	session_id: string?,
	last_message: string?,
	summary: string?,
	failed_reason: string?,
	cost: number?,
	cost_approx: boolean,
	completed_turn: boolean,
	tools: number,
	requests: number,
	tool: { id: string?, name: string, detail: string? }?, -- last toolCall with no later toolResult
}

local session_tail = {}

local function clip(s: string, n: number): string
	if #s <= n then
		return s
	end
	local i = n
	while i > 0 do
		local b = s:byte(i + 1)
		if b ~= nil and b >= 0x80 and b < 0xC0 then
			i -= 1 -- do not cut inside a multi-byte character
		else
			break
		end
	end
	return s:sub(1, i)
end
session_tail.clip = clip

local function trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Strips Tern's trailing per-turn cost line ("pong\n2.1s · 308 tok · $0.01 this turn").
function session_tail.body(message: string): string
	local body = message:match("^(.*)\n[^\n]*this turn%s*$")
	if body ~= nil then
		return (body:gsub("%s+$", ""))
	end
	return message
end

-- summary + failure reason from a final assistant message (R6): the last `RESULT:` line, else the first
-- non-empty line. `RESULT: FAILED - why` => failed_reason = why.
function session_tail.summarize(message: string): (string, string?)
	local body = session_tail.body(message)
	local result: string? = nil
	for line in body:gmatch("[^\r\n]+") do
		local r = line:match("^%s*[%*_`]*RESULT:[%*_`]*%s*(.-)%s*$")
		if r ~= nil then
			r = (r:gsub("[%*_`%s]+$", ""))
		end
		if r ~= nil and r ~= "" then
			result = r
		end
	end
	if result ~= nil then
		local why = result:match("^FAILED(.*)$")
		if why ~= nil then
			why = (why:gsub("^%s*[:%-]*%s*", ""))
			why = (why:gsub("^\u{2013}%s*", "")) -- en dash
			why = (why:gsub("^\u{2014}%s*", "")) -- em dash
		end
		if why ~= nil then
			-- The run's state already says it failed; the summary is the reason alone.
			why = if why ~= "" then why else "the agent reported failure"
			return clip(why, const.SUMMARY_MAX), why
		end
		return clip(result, const.SUMMARY_MAX), nil
	end
	for line in body:gmatch("[^\r\n]+") do
		local t = trim(line)
		if t ~= "" then
			return clip(t, const.SUMMARY_MAX), nil
		end
	end
	return "", nil
end

local function newest_session_file(dir: string): string?
	local ok, names = pcall(function()
		return (tern :: any).fs.list(dir)
	end)
	if not ok or type(names) ~= "table" then
		return nil
	end
	local best: string? = nil
	for _, name in ipairs(names :: { string }) do
		if name:sub(1, 1) ~= "." and name:match("%.jsonl$") then
			if best == nil or name > best then
				best = name
			end
		end
	end
	return best
end

local DETAIL_KEYS: { [string]: { string } } = {
	bash = { "command" },
	read = { "path", "file_path" },
	edit = { "path", "file_path" },
	write = { "path", "file_path" },
	grep = { "pattern" },
	glob = { "pattern" },
	web_search = { "query" },
}

-- Short single-line human text for a tool call's arguments (<= 120 bytes).
local function tool_detail(name: string, args: any): string?
	if type(args) ~= "table" then
		return nil
	end
	local found: string? = nil
	local keys = DETAIL_KEYS[string.lower(name)]
	if keys ~= nil then
		for _, k in ipairs(keys) do
			if type(args[k]) == "string" and args[k] ~= "" then
				found = args[k]
				break
			end
		end
	end
	if found == nil then
		local names: { string } = {}
		for k, v in pairs(args) do
			if type(k) == "string" and type(v) == "string" and v ~= "" then
				table.insert(names, k)
			end
		end
		table.sort(names)
		if names[1] ~= nil then
			found = args[names[1]]
		end
	end
	if found == nil then
		return nil
	end
	local one = trim((found:gsub("%s+", " ")))
	if one == "" then
		return nil
	end
	return clip(one, 120)
end

local function text_of(content: any): (string, boolean)
	local parts: { string } = {}
	local tool = false
	if type(content) == "string" then
		return content, false
	end
	if type(content) == "table" then
		for _, c in ipairs(content) do
			if type(c) == "table" then
				if c.type == "text" and type(c.text) == "string" then
					table.insert(parts, c.text)
				elseif c.type == "toolCall" then
					tool = true
				end
			end
		end
	end
	return table.concat(parts, "\n"), tool
end

-- Parses the tail text (pure; exposed for tests).
function session_tail.parse(text: string, truncated: boolean, file: string): Facts
	local facts: Facts = { session_file = file, cost_approx = truncated, completed_turn = false, tools = 0, requests = 0 }
	local pending: { { id: string?, name: string, detail: string? } } = {}
	local name = file:match("([^/]+)$") or file
	facts.session_id = name:match("_([^_]+)%.jsonl$")
	local cost, any_cost = 0, false
	local first = true
	local last_text: string? = nil
	local last_is_final = false
	local model_error: string? = nil
	for line in text:gmatch("[^\n]+") do
		if first then
			first = false
			if truncated then
				continue -- partial first line
			end
		end
		if line:sub(1, 15) == '{"type":"title"' then
			continue
		end
		local ok, m = pcall(function()
			return (tern :: any).json.decode(line)
		end)
		if not ok or type(m) ~= "table" then
			continue
		end
		if m.type == "session" and type(m.id) == "string" then
			facts.session_id = m.id
		elseif m.type == "message" and type(m.message) == "table" then
			local msg = m.message
			if msg.role == "assistant" then
				facts.requests += 1
				if type(msg.content) == "table" then
					for _, c in ipairs(msg.content) do
						if type(c) == "table" and c.type == "toolCall" then
							facts.tools += 1
							local tname = if type(c.name) == "string" then c.name else "tool"
							-- omp records a human-readable `intent` ("Reading model role settings") on each
							-- call; it reads better than raw arguments, which stay the fallback.
							local intent = if type(c.intent) == "string" then tool_detail(tname, { intent = c.intent }) else nil
							table.insert(pending, {
								id = if type(c.id) == "string" then c.id else nil,
								name = tname,
								detail = intent or tool_detail(tname, c.arguments),
							})
						end
					end
				end
				local t, tool = text_of(msg.content)
				local c = type(msg.usage) == "table" and type(msg.usage.cost) == "table" and msg.usage.cost.total or nil
				if type(c) == "number" then
					cost += c
					any_cost = true
				end
				if t ~= "" then
					last_text = t
				end
				last_is_final = (not tool) and t ~= ""
				model_error = nil
				if msg.stopReason == "error" or (msg.stopReason == "aborted" and t == "") then
					local why = type(msg.errorMessage) == "string" and trim(msg.errorMessage) or ""
					model_error = clip(if why ~= "" then why else "the model request failed", const.SUMMARY_MAX)
					last_is_final = false
				end
			else
				if msg.role == "toolResult" then
					local rid = if type(msg.toolCallId) == "string" then msg.toolCallId else nil
					local rname = if type(msg.toolName) == "string" then msg.toolName else nil
					for i, p in ipairs(pending) do
						if (rid ~= nil and p.id == rid) or (rid == nil and (rname == nil or p.name == rname)) then
							table.remove(pending, i)
							break
						end
					end
				end
				last_is_final = false
				model_error = nil
			end
		end
	end
	facts.tool = pending[#pending]
	if any_cost then
		facts.cost = cost
	end
	facts.completed_turn = last_is_final
	if last_text ~= nil then
		facts.last_message = clip(last_text, const.LAST_MESSAGE_MAX)
		local summary, failed = session_tail.summarize(last_text)
		facts.summary = summary
		facts.failed_reason = failed
	end
	if model_error ~= nil then
		-- the model call itself failed; an earlier narration message is not the outcome
		facts.failed_reason = model_error
		facts.summary = model_error
		facts.completed_turn = true
	end
	return facts
end

-- cb(Facts) or cb(nil, why). `run_dir` is the absolute run directory.
function session_tail.read(run_dir: string, cb: (Facts?, string?) -> ())
	local sdir = run_dir .. "/session"
	local name = newest_session_file(sdir)
	if name == nil then
		return cb(nil, "no session file")
	end
	local file = sdir .. "/" .. name
	local ok, err = pcall(function()
		(tern :: any).process.run(
			{ "/usr/bin/tail", "-c", tostring(const.JSONL_TAIL_BYTES), file },
			{ timeout_ms = 8000 },
			function(r: any)
				if r.status ~= 0 then
					return cb(nil, "tail failed")
				end
				local text = tostring(r.stdout)
				cb(session_tail.parse(text, #text >= const.JSONL_TAIL_BYTES, file), nil)
			end
		)
	end)
	if not ok then
		cb(nil, tostring(err))
	end
end

return session_tail
