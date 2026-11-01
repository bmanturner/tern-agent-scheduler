-- Window events: `agent_state` sends a run's new state at once, and `budget` pauses show
-- in the status line until every paused hook resumes.
tern.chrome = tern.chrome or { refresh = function() end }
local observer = __mods.observer
local status = __mods.status

-- Run block 12 is in flight; the window sees it as pane 4.
fake.files["/d/snapshot.json"] = tern.json.encode({
	format = 1,
	jobs = {},
	inflight = { { block = "12", run_id = "r1", job_id = "j1", state = "running" } },
})
local cx = {
	session = {
		resolve = function(_self, id)
			return if id == "12" then 4 else nil
		end,
	},
	agents = {
		list = function(_self)
			return { { pane = 4, state = "working", model = "Opus 5.5", last_message = "Approve?" } }
		end,
	},
}

local function intents()
	local out = {}
	for path, text in fake.files do
		if type(path) == "string" and path:sub(1, #"/d/intents/") == "/d/intents/" then
			table.insert(out, tern.json.decode(text))
		end
	end
	return out
end

observer.on_state({ pane = 4, old = "working", new = "waiting_input" }, cx)
local sent = intents()
assert(#sent == 1, "one intent, got " .. #sent)
local i = sent[1]
local p = i.payload or i
assert(i.kind == "obs", "obs intent: " .. tostring(i.kind))
assert(p.block == "12", "run block: " .. tostring(p.block))
assert(p.state == "waiting_input", "new state: " .. tostring(p.state))
assert(p.last_message == "Approve?", "last message: " .. tostring(p.last_message))
print("PASS agent_state sends the run's new state at once")

observer.on_state({ pane = 4, old = "waiting_input", new = "exited" }, cx)
observer.on_state({ pane = 7, old = "idle", new = "working" }, cx)
assert(#intents() == 1, "no new intents, got " .. #intents())
print("PASS agent_state ignores exits and other panes")

observer.on_session_ended({ session = 3, name = "Scheduled runs", shown = false }, cx)
local ended = intents()
assert(#ended == 2, "one new intent, got " .. #ended)
local n_ended = 0
for _, it in ended do
	if it.kind == "session_ended" then
		n_ended += 1
	end
end
assert(n_ended == 1, "one session_ended intent, got " .. n_ended)
fake.files["/d/snapshot.json"] = tern.json.encode({ format = 1, jobs = {}, inflight = {} })
__mods.wsnap.reset()
observer.on_session_ended({ session = 3, name = "Scheduled runs", shown = false }, cx)
assert(#intents() == 2, "no intent without runs in flight, got " .. #intents())
print("PASS session_ended sends one intent only while runs are in flight")

local PAUSED = "Agent Scheduler paused · it ran too long"
status.budget("timer", "paused")
local seg = status.view().seg
assert(seg ~= nil and seg.text == PAUSED, "paused segment")
assert(seg.command == "plugin.tern-agent-scheduler.reload", "reload command: " .. tostring(seg.command))
status.budget("command run-job-now", "paused")
status.budget("timer", "resumed")
seg = status.view().seg
assert(seg ~= nil and seg.text == PAUSED, "still paused while another hook is")
status.budget("command run-job-now", "resumed")
seg = status.view().seg
assert(seg == nil or seg.text ~= PAUSED, "cleared once all resume")
print("PASS paused hooks show in the status line until all resume")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
