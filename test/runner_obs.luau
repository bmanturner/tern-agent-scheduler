-- Raw window samples in, host decisions out: needs_input (+ one OS notification), finished with RESULT:,
-- no_response, unobserved finish from the session tail, and the host deadline.
local jobs, runner, ledger = __mods.jobs, __mods.runner, __mods.ledger

fake.dirs["/home/u/proj"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))
runner.load()
fake.advance(1000)

local seq = 0
local function send(block, state, last_message)
	seq += 1
	fake.intent(string.format("%013d-testwin01-%04d", 1760000000000 + seq, seq), {
		format = 1, kind = "obs", block = block, state = state, last_message = last_message, seen_at = os.time(),
	})
end
-- keep sending the same raw sample every 3 s (window observer cadence) for `secs`
local function hold(block, state, last_message, secs)
	local spent = 0
	while spent < secs do
		send(block, state, last_message)
		fake.advance(3000)
		spent += 3
	end
end

local session_text = nil
fake.hooks.new = function(info)
	if session_text ~= nil and info.session_dir ~= nil then
		fake.write(info.session_dir .. "/2026-10-12T10-00-05-000Z_sess0001.jsonl", session_text)
		session_text = nil
	end
end
local function jsonl(lines)
	local out = {}
	for _, l in ipairs(lines) do
		out[#out + 1] = tern.json.encode(l)
	end
	return table.concat(out, "\n") .. "\n"
end
local function session(final_text, cost)
	return jsonl({
		{ type = "session", id = "sess0001", cwd = "/home/u/proj" },
		{ type = "message", message = { role = "user", content = { { type = "text", text = "go" } } } },
		{ type = "message", message = { role = "assistant", content = { { type = "toolCall", name = "bash", arguments = {} } }, usage = { cost = { total = 0.004 } } } },
		{ type = "message", message = { role = "toolResult", content = { { type = "text", text = "ok" } } } },
		{ type = "message", message = { role = "assistant", content = { { type = "text", text = final_text } }, usage = { cost = { total = cost } } } },
	})
end

local function start_run(job, opts)
	local ok, why = runner.run_now(job.id, opts)
	assert(ok, "run_now: " .. tostring(why))
	local run
	assert(fake.run_until(function()
		run = runner.inflight()[1]
		return run ~= nil and run.state == "running"
	end, 30000, 500), "run reached running")
	return run
end
local function finished(run)
	return ledger.get(run.run_id)
end

local job = jobs.create({ name = "obs-job", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "do it", "user", os.time())

-- 1. waiting_input held >= 10 s => needs_input, one OS notification, none for the return to working
local run = start_run(job)
local osa0 = #fake.calls_of("osascript")
hold(run.block, "working", "", 3)
hold(run.block, "waiting_input", "", 6)
assert(run.state == "running", "not needs_input before the hold elapsed")
hold(run.block, "waiting_input", "", 9)
assert(run.state == "needs_input", "needs_input after 10 s held, state: " .. run.state)
assert(#fake.calls_of("osascript") == osa0 + 1, "exactly one OS notification")
local osa = fake.calls_of("osascript")[osa0 + 1]
assert(osa[#osa] == "Agent Scheduler · obs-job" and osa[#osa - 1] == "Waiting for you.", "notification text via argv")
assert(osa[3] == "on run argv" and osa[5]:find("item 1 of argv", 1, true), "argv-passing osascript form")
hold(run.block, "waiting_input", "", 6)
assert(#fake.calls_of("osascript") == osa0 + 1, "no repeat notification")
hold(run.block, "working", "", 3)
assert(run.state == "running", "working sample returns to running")
print("PASS needs_input after 10 s hold, one notification")

-- 2. working then idle held >= 6 s with a RESULT: line => finished, summary pong, cost from the tail
session_text = nil
hold(run.block, "idle", "RESULT: pong\n2.1s · 8 tok · $0.01 this turn", 3)
assert(run.state == "running", "idle must hold FINISH_CONFIRM_S")
fake.write((function()
	local dir = "/d/runs/" .. job.id .. "/" .. run.run_id .. "/session"
	return dir .. "/2026-10-12T10-00-05-000Z_sess0001.jsonl"
end)(), session("All done.\nRESULT: pong", 0.0123))
hold(run.block, "idle", "RESULT: pong\n2.1s · 8 tok · $0.01 this turn", 9)
local rec = finished(run)
assert(rec.state == "finished" and rec.reason_code == "ok", "finished/ok: " .. tostring(rec.state) .. "/" .. tostring(rec.reason_code))
assert(rec.summary == "pong", "summary from the RESULT: line: " .. tostring(rec.summary))
assert(math.abs(rec.cost - 0.0163) < 1e-9, "cost summed from the session JSONL: " .. tostring(rec.cost))
assert(rec.session_file:find("sess0001.jsonl", 1, true) and rec.session_id == "sess0001", "session file and id")
assert(rec.observed == true, "observed")
assert(#fake.calls_of("osascript") == osa0 + 1, "success never notifies")
assert(#runner.inflight() == 0, "run left the in-flight list")
local st = jobs.state(job.id)
assert(st.last_run.state == "finished" and st.failure_streak == 0, "job state updated")
print("PASS idle held 6 s with RESULT: pong => finished")

-- 3. no working sample within 180 s => failed/no_response
local run3 = start_run(job)
send(run3.block, "idle", "")
fake.advance(2500)
assert(run3.observed == true, "observed by a window")
hold(run3.block, "idle", "", 168)
assert(run3.state == "running", "still waiting before 180 s")
hold(run3.block, "idle", "", 21)
local rec3 = finished(run3)
assert(rec3.state == "failed" and rec3.reason_code == "no_response", "no_response: " .. tostring(rec3.state) .. "/" .. tostring(rec3.reason_code))
assert(rec3.reason == "Couldn't start: the prompt wasn't delivered.", "reason sentence")
assert(#fake.calls_of("osascript") == osa0 + 2, "failure notifies once")
assert(jobs.state(job.id).failure_streak == 1, "streak counts the failure")
print("PASS no working sample in 180 s => failed/no_response")

-- 4. no window: the session tail shows a completed turn that stopped growing => finished (unobserved)
session_text = session("Checked everything.\nRESULT: ok", 0.02)
local run4 = start_run(job)
fake.advance(90000)
local rec4 = finished(run4)
assert(rec4.state == "finished" and rec4.reason_code == "ok_unobserved", "unobserved finish: " .. tostring(rec4.state) .. "/" .. tostring(rec4.reason_code))
assert(rec4.summary == "ok" and rec4.observed == false, "summary from the tail")
assert(jobs.state(job.id).failure_streak == 0, "success resets the streak")
print("PASS unobserved finish from the session tail")

-- 5. RESULT: FAILED - ... => failed/agent_failed
session_text = session("Could not log in.\nRESULT: FAILED - credentials expired", 0.01)
local run5 = start_run(job)
hold(run5.block, "working", "", 3)
hold(run5.block, "idle", "RESULT: FAILED - credentials expired", 9)
local rec5 = finished(run5)
assert(rec5.state == "failed" and rec5.reason_code == "agent_failed" and rec5.detail == "credentials expired", "agent_failed: " .. tostring(rec5.state) .. "/" .. tostring(rec5.reason_code))
print("PASS RESULT: FAILED => failed/agent_failed")

-- 6. the host deadline: omp does not exit at --max-time, so max_runtime + grace closes the run
local slow = jobs.create({ name = "slow-job", prompt = "x", when = "manual", cwd = "/home/u/proj", max_runtime_s = 300 }, "slow", "user", os.time())
local run6 = start_run(slow)
local closes0 = #fake.calls_of("close")
hold(run6.block, "working", "", 3)
fake.advance(330000)
assert(run6.state == "running", "alive inside max_runtime + grace")
hold(run6.block, "working", "", 45)
local rec6 = finished(run6)
assert(rec6.state == "timed_out" and rec6.reason_code == "max_runtime", "timed_out: " .. tostring(rec6.state) .. "/" .. tostring(rec6.reason_code))
assert(rec6.close_requested == true and #fake.calls_of("close") == closes0 + 1, "pane closed by the host")
print("PASS host deadline => timed_out/max_runtime, pane closed")

-- 6b. a model call that failed right at the deadline is not a success. After a sleep, omp's own --max-time
-- aborts the request ("Deadline exceeded") just as the host deadline comes due; the session then shows a
-- complete turn with a failure reason.
local working_lines = {
	{ type = "session", id = "sess0001", cwd = "/home/u/proj" },
	{ type = "message", message = { role = "user", content = { { type = "text", text = "go" } } } },
	{ type = "message", message = { role = "assistant", content = { { type = "toolCall", id = "t1", name = "bash", arguments = {} } }, usage = { cost = { total = 0.004 } } } },
}
local sess_dir
local hook_new = fake.hooks.new
fake.hooks.new = function(info)
	sess_dir = info.session_dir
	hook_new(info)
end
session_text = jsonl(working_lines)
local slow2 = jobs.create({ name = "slow-abort", prompt = "x", when = "manual", cwd = "/home/u/proj", max_runtime_s = 300 }, "slow", "user", os.time())
local run6b = start_run(slow2)
fake.hooks.new = hook_new
hold(run6b.block, "working", "", 3)
fake.advance(330000)
assert(run6b.state == "running", "still running before the abort")
table.insert(working_lines, { type = "message", message = { role = "toolResult", toolCallId = "t1", content = { { type = "text", text = "ok" } } } })
table.insert(working_lines, { type = "message", message = { role = "assistant", content = {}, stopReason = "aborted", errorMessage = "Deadline exceeded", usage = { cost = { total = 0 } } } })
fake.write(sess_dir .. "/2026-10-12T10-00-05-000Z_sess0001.jsonl", jsonl(working_lines))
hold(run6b.block, "working", "", 45)
local rec6b = finished(run6b)
assert(rec6b.state == "timed_out" and rec6b.reason_code == "max_runtime", "model error at the deadline: " .. tostring(rec6b.state) .. "/" .. tostring(rec6b.reason_code))
assert(rec6b.detail == "Deadline exceeded", "failure reason kept: " .. tostring(rec6b.detail))
assert(jobs.state(slow2.id).failure_streak == 1, "counts as a failure")
print("PASS model error at the host deadline => timed_out/max_runtime")

-- 7. stop
local run7 = start_run(job)
assert(runner.stop(run7.run_id) == true, "stop")
fake.advance(1000)
local rec7 = finished(run7)
assert(rec7.state == "cancelled" and rec7.reason_code == "user_stop" and rec7.close_requested == true, "cancelled/user_stop")
print("PASS stop => cancelled/user_stop")

-- 8. the pane vanishing without our close => cancelled/closed_by_user
local run8 = start_run(job)
fake.remove_block(tonumber(run8.block))
fake.advance(40000)
local rec8 = finished(run8)
assert(rec8.state == "cancelled" and rec8.reason_code == "closed_by_user", "closed by user: " .. tostring(rec8.state) .. "/" .. tostring(rec8.reason_code))
print("PASS pane closed by the user => cancelled/closed_by_user")

-- 9. finished-pane cap: keep at most settings.max_finished_panes finished run panes, oldest unfocused first
local function our_blocks()
	local n = 0
	for _, blk in pairs(fake.blocks) do
		if blk.command:find("/runs/", 1, true) then
			n += 1
		end
	end
	return n
end
assert(our_blocks() == 4, "four finished panes kept before the cap bites, got " .. our_blocks())
jobs.set_settings({ max_finished_panes = 2 })
runner.changed()
fake.advance(40000)
assert(our_blocks() == 2, "closed down to the cap, got " .. our_blocks())
assert(finished(run).pane_closed_at ~= nil and finished(run).close_requested == true, "oldest pane closed by the host")
assert(finished(run5).pane_closed_at == nil, "newest finished pane kept")
assert(finished(run).state == "finished" and finished(run).summary == "pong", "closing a pane keeps the run record")
print("PASS finished-pane cap closes the oldest panes")

local function send_finished(block, result, last_message)
	seq += 1
	fake.intent(string.format("%013d-testwin01-%04d", 1760000000000 + seq, seq), {
		format = 1, kind = "obs", block = block, state = "idle", last_message = last_message, finished = result, seen_at = os.time(),
	})
end

-- 10. agent_finished "done" finishes the run on the next pump, without the 6 s idle hold
local run10 = start_run(job)
hold(run10.block, "working", "", 3)
send_finished(run10.block, "done", "RESULT: quick")
fake.advance(2500)
local rec10 = finished(run10)
assert(rec10.state == "finished" and rec10.reason_code == "ok", "done => finished/ok: " .. tostring(rec10.state) .. "/" .. tostring(rec10.reason_code))
assert(rec10.summary == "quick", "summary from the finished sample: " .. tostring(rec10.summary))
print("PASS agent_finished done => finished without the idle hold")

-- 11. agent_finished "failed" fails the run even when its last message reports no failure
local run11 = start_run(job)
hold(run11.block, "working", "", 3)
send_finished(run11.block, "failed", "Working on it")
fake.advance(2500)
local rec11 = finished(run11)
assert(rec11.state == "failed" and rec11.reason_code == "agent_failed", "failed => failed/agent_failed: " .. tostring(rec11.state) .. "/" .. tostring(rec11.reason_code))
assert(rec11.reason == "The agent reported it couldn't finish.", "reason sentence: " .. tostring(rec11.reason))
print("PASS agent_finished failed => failed/agent_failed")

-- 12. an unknown `finished` value is a plain sample: idle must still hold FINISH_CONFIRM_S
local run12 = start_run(job)
hold(run12.block, "working", "", 3)
send_finished(run12.block, "exited", "RESULT: later")
fake.advance(2500)
assert(run12.state == "running", "unknown finished value does not end the run")
hold(run12.block, "idle", "RESULT: later", 9)
assert(finished(run12).state == "finished", "idle hold still finishes it")
print("PASS unknown finished value waits for the idle hold")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
