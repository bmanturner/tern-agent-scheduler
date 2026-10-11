--!strict
-- Window half: queue intents for the host (intents/<t_ms13>-<win8>-<seq4>.json) and wait for the
-- host's reply file (replies/<id>.json). Nothing here runs at load time.

local outbox = {}

local INTENT_MAX_BYTES = 16384
local REPLY_MAX_BYTES = 65536
local POLL_MS = 250

local win8: string? = nil
local last_ms = 0
local seq = 0

local ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"

-- Eight [a-z0-9] characters naming this VM; the RNG is seeded on first use, never at load.
local function window_id(): string
	if win8 == nil then
		math.randomseed(os.time() + math.floor(tern.now() * 1000))
		local out: { string } = {}
		for _ = 1, 8 do
			local i = math.random(1, #ALPHABET)
			table.insert(out, string.sub(ALPHABET, i, i))
		end
		win8 = table.concat(out)
	end
	return win8 :: string
end

-- A fresh reply id: 12 [a-z0-9] characters.
function outbox.reply_id(): string
	window_id() -- seeds the RNG
	local out: { string } = {}
	for _ = 1, 12 do
		local i = math.random(1, #ALPHABET)
		table.insert(out, string.sub(ALPHABET, i, i))
	end
	return table.concat(out)
end

function outbox.intents_dir(): string
	return tern.plugin.data .. "/intents"
end

function outbox.replies_dir(): string
	return tern.plugin.data .. "/replies"
end

-- The next file name: 13-digit unix milliseconds (strictly increasing in this VM), the window id and
-- a 4-digit per-VM counter, so names sort in write order.
function outbox.next_name(): string
	local ms = os.time() * 1000 + math.floor(tern.now() % 1000)
	if ms <= last_ms then
		ms = last_ms + 1
	end
	last_ms = ms
	seq = (seq + 1) % 10000
	return string.format("%013.0f-%s-%04d.json", ms, window_id(), seq)
end

-- Writes one intent `{format = 1, kind = kind, …payload}`. Returns the file name, or nil and why.
function outbox.send(kind: string, payload: { [string]: any }?): (string?, string?)
	local body: { [string]: any } = {}
	if payload then
		for k, v in payload do
			body[k] = v
		end
	end
	body.format = 1
	body.kind = kind
	local okj, text = pcall(tern.json.encode, body)
	if not okj then
		return nil, "Couldn't encode the request."
	end
	if #text > INTENT_MAX_BYTES then
		return nil, "That request is too large."
	end
	local dir = outbox.intents_dir()
	local name = outbox.next_name()
	local ok, err = pcall(function()
		if not tern.fs.exists(dir) then
			tern.fs.mkdir(dir)
		end
		tern.fs.write(dir .. "/" .. name, text)
	end)
	if not ok then
		return nil, "Couldn't write to the Agent Scheduler data folder: " .. tostring(err)
	end
	return name, nil
end

-- Polls for replies/<id>.json every 250 ms until `timeout_ms`. `cb` gets the decoded reply (the file
-- is deleted after reading) or nil on timeout, plus a fresh cx from the timer.
function outbox.await_reply(reply_id: string, timeout_ms: number, cb: ({ [string]: any }?, WindowCx?) -> ())
	local path = outbox.replies_dir() .. "/" .. reply_id .. ".json"
	local waited = 0
	local function poll(cx: WindowCx?)
		local present = false
		pcall(function()
			present = tern.fs.exists(path)
		end)
		if present then
			local okr, text = pcall(tern.fs.read, path, REPLY_MAX_BYTES)
			if okr then
				local okd, reply = pcall(tern.json.decode, text)
				if okd and type(reply) == "table" then
					pcall(tern.fs.remove, path)
					cb(reply :: any, cx)
					return
				end
			end
			-- Half-written file: try again on the next poll.
		end
		waited += POLL_MS
		if waited >= timeout_ms then
			cb(nil, cx)
			return
		end
		tern.timer(POLL_MS, poll)
	end
	tern.timer(POLL_MS, poll)
end

return outbox
