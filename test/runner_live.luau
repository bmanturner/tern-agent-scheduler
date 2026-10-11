-- runner.live(run_id): tail-driven live detail (tool in progress, counts, cost), obs fields, change-only
-- notifications, and nil once the run leaves flight.
local jobs, runner, ledger = __mods.jobs, __mods.runner, __mods.ledger

fake.dirs["/home/u/proj"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))
runner.load()
fake.advance(1000)

local seq = 0
local function send(block, state, last_message, model)
	seq += 1
	fake.intent(string.format("%013d-testwin01-%04d", 1760000000000 + seq, seq), {
		format = 1, kind = "obs", block = block, state = state, last_message = last_message, model = model, seen_at = os.time(),
	})
end
local function hold(block, state, last_message, secs, model)
	local spent = 0
	while spent < secs do
		send(block, state, last_message, model)
		fake.advance(3000)
		spent += 3
	end
end
local function jsonl(lines)
	local out = {}
	for _, l in ipairs(lines) do
		out[#out + 1] = tern.json.encode(l)
	end
	return table.concat(out, "\n") .. "\n"
end
local function call(id, name, args, cost)
	return { type = "message", message = { role = "assistant", content = { { type = "toolCall", id = id, name = name, arguments = args } }, usage = { cost = { total = cost } } } }
end
local function result(id, name)
	return { type = "message", message = { role = "toolResult", toolCallId = id, toolName = name, content = { { type = "text", text = "ok" } } } }
end
local head = { type = "session", id = "sess0001", cwd = "/home/u/proj" }
local function say(text, cost)
	return { type = "message", message = { role = "assistant", content = { { type = "text", text = text } }, usage = { cost = { total = cost } } } }
end

local job = jobs.create({ name = "live-job", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "do it", "user", os.time())
local ok, why = runner.run_now(job.id)
assert(ok, "run_now: " .. tostring(why))
local run
assert(fake.run_until(function()
	run = runner.inflight()[1]
	return run ~= nil and run.state == "running"
end, 30000, 500), "run reached running")
local file = "/d/runs/" .. job.id .. "/" .. run.run_id .. "/session/2026-10-12T10-00-05-000Z_sess0001.jsonl"

local notified = 0
local token = runner.subscribe(function()
	notified += 1
end)

-- 1. before any session file: a Live record from what is known, no counts
local live = runner.live(run.run_id)
assert(live ~= nil and live.tools == nil and live.tool == nil and live.cost == nil, "bare live before any tail")
assert(runner.live("r_nope") == nil, "unknown run has no live")
print("PASS live exists without a session file, no counts")

-- 2. a tool call in progress is reported with its detail
fake.write(file, jsonl({
	head,
	{ type = "message", message = { role = "user", content = { { type = "text", text = "go" } } } },
	call("c1", "bash", { command = "echo   hello\nworld" }, 0.01),
}))
fake.advance(16000)
live = runner.live(run.run_id)
assert(live ~= nil and live.tools == 1 and live.requests == 1, "counts: " .. tostring(live and live.tools) .. "/" .. tostring(live and live.requests))
assert(math.abs(live.cost - 0.01) < 1e-9, "cost")
assert(live.tool ~= nil and live.tool.name == "bash" and live.tool.detail == "echo hello world", "tool in progress: " .. tostring(live.tool and live.tool.detail))
local since1 = live.tool.since
assert(type(since1) == "number", "tool.since set")
assert(notified >= 1, "subscribers notified when Live changed")
print("PASS tool in progress with single-line detail; cost/tools/requests")

-- 3. unchanged tail => same Live, no notification, since kept
fake.advance(1000)
local n0 = notified
fake.advance(16000)
live = runner.live(run.run_id)
assert(live.tool ~= nil and live.tool.since == since1, "since kept while the same call stays in progress")
assert(notified == n0, "no notification when Live content is unchanged, got " .. (notified - n0))
print("PASS unchanged tail keeps since, no notification")

-- 4. toolResult clears the tool; a new call (read) replaces it with its own since
fake.write(file, jsonl({
	head,
	call("c1", "bash", { command = "echo hello" }, 0.01),
	result("c1", "bash"),
	call("c2", "read", { path = "/home/u/proj/README.md", limit = "50" }, 0.02),
}))
local n1 = notified
fake.advance(16000)
live = runner.live(run.run_id)
assert(live.tools == 2 and live.requests == 2, "counts after second call")
assert(live.tool ~= nil and live.tool.name == "read" and live.tool.detail == "/home/u/proj/README.md", "read detail is the path")
assert(live.tool.since >= since1, "new call has its own since")
assert(notified > n1, "notified on tool change")
fake.write(file, jsonl({
	head,
	call("c1", "bash", { command = "echo hello" }, 0.01),
	result("c1", "bash"),
	call("c2", "read", { path = "/home/u/proj/README.md" }, 0.02),
	result("c2", "read"),
}))
fake.advance(16000)
live = runner.live(run.run_id)
assert(live.tool == nil, "tool cleared after its toolResult")
assert(live.tools == 2 and math.abs(live.cost - 0.03) < 1e-9, "totals retained")
print("PASS tool replaced then cleared after toolResult")

-- 5. obs fields flow into Live; a state change refreshes the tail immediately
hold(run.block, "working", "Reading the readme.\n1.0s · 5 tok · $0.01 this turn", 3, "Opus 5.5")
live = runner.live(run.run_id)
assert(live.obs == "working" and live.model == "Opus 5.5", "obs/model in live")
assert(live.last_message == "Reading the readme.", "last_message without the per-turn cost line: " .. tostring(live.last_message))
fake.write(file, jsonl({
	head,
	call("c1", "grep", { pattern = "TODO", path = "src" }, 0.01),
	result("c1", "grep"),
	call("c2", "grep", { pattern = "FIXME" }, 0.01),
	result("c2", "grep"),
	call("c3", "web_search", { query = "luau strict mode" }, 0.01),
}))
local calls0 = #fake.calls_of("tail")
hold(run.block, "waiting_input", "Reading the readme.", 3, "Opus 5.5")
assert(#fake.calls_of("tail") > calls0, "obs state change triggered a tail now")
live = runner.live(run.run_id)
assert(live.obs == "waiting_input" and live.tools == 3 and live.tool.name == "web_search" and live.tool.detail == "luau strict mode", "refreshed on state change")
print("PASS obs fields and immediate refresh on state change")

-- 6. finish: Live is nil afterwards
fake.write(file, jsonl({ head, call("c1", "bash", { command = "true" }, 0.01), result("c1", "bash"), say("All done.\nRESULT: pong", 0.02) }))
hold(run.block, "working", "", 3, "Opus 5.5")
hold(run.block, "idle", "RESULT: pong\n2.1s · 8 tok · $0.01 this turn", 12, "Opus 5.5")
local rec = ledger.get(run.run_id)
assert(rec.state == "finished", "finished: " .. tostring(rec.state))
assert(runner.live(run.run_id) == nil, "live is nil after the run finished")
runner.unsubscribe(token)
print("PASS live nil after finish")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
