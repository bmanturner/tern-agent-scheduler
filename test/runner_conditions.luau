-- Job conditions ("Only when"): commits baseline/skip folding/launch with trigger.md/watermark commit, window,
-- budget, script checks (say no, errors alert once and pause, changed script), Run now and Run anyway, the dry
-- run, jobs without conditions, quiet results, and Carly's check_conditions intent.
local jobs, runner, ledger, ids = __mods.jobs, __mods.runner, __mods.ledger, __mods.ids

fake.dirs["/home/u/proj"] = true
fake.write(fake.omp_bin, "binary")
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 30)) -- Monday 10:00:30
runner.load()
fake.advance(1000)

-- ---------- fakes: git, the script read, the check itself, finished sessions ----------
local SHA1 = string.rep("a", 40)
local SHA2 = string.rep("b", 40)
local SHA3 = string.rep("c", 40)
local git = { head = SHA1, count = 0, count_status = 0 }
local revlists = {}
fake.override.git = function(argv)
	local sub = argv[7]
	if sub == "rev-parse" then
		return { status = 0, stdout = git.head .. "\n", stderr = "", timed_out = false }
	elseif sub == "rev-list" then
		table.insert(revlists, fake.join(argv))
		return { status = git.count_status, stdout = tostring(git.count) .. "\n", stderr = "", timed_out = false }
	elseif sub == "log" then
		return { status = 0, stdout = "bbbbbbb Dev Fix the parser\n", stderr = "", timed_out = false }
	elseif sub == "diff" then
		return { status = 0, stdout = " lib/x.luau | 2 +-\n", stderr = "", timed_out = false }
	end
	return nil
end
local SCRIPT = "#!/bin/sh\necho REASON: queue empty\nexit 1\n"
local script = { text = SCRIPT, read_status = 0 }
fake.override.sh = function(argv)
	if argv[2] == "-c" and argv[4] == "sh" then
		return { status = script.read_status, stdout = if script.read_status == 0 then script.text else "", stderr = "", timed_out = false }
	end
	return nil
end
local check = { status = 1, stdout = "REASON: queue empty\n" }
local check_inputs = {}
fake.override["has-work.sh"] = function(argv)
	table.insert(check_inputs, fake.read(argv[2]) or "")
	return { status = check.status, stdout = check.stdout, stderr = "", timed_out = false }
end

local function jsonl(lines)
	local out = {}
	for _, l in ipairs(lines) do
		out[#out + 1] = tern.json.encode(l)
	end
	return table.concat(out, "\n") .. "\n"
end
local session_text = "Done.\nRESULT: ok"
fake.hooks.new = function(info)
	if info.session_dir ~= nil then
		fake.write(info.session_dir .. "/2026-10-12T10-00-05-000Z_sess0001.jsonl", jsonl({
			{ type = "session", id = "sess0001", cwd = "/home/u/proj" },
			{ type = "message", message = { role = "user", content = { { type = "text", text = "go" } } } },
			{ type = "message", message = { role = "assistant", content = { { type = "text", text = session_text } }, usage = { cost = { total = 0.02 } } } },
		}))
	end
end

local function rows(job)
	return ledger.recent(job.id, 50)
end
local function newest(job)
	return rows(job)[1]
end
local function settle_until(pred, max)
	assert(fake.run_until(pred, max or 400000, 1000), "condition not reached")
end
local function finished_runs(job)
	local n = 0
	for _, r in ipairs(rows(job)) do
		if r.state == "finished" then
			n += 1
		end
	end
	return n
end
local function watermark(job)
	local st = jobs.state(job.id)
	return st.watch and st.watch.conditions and st.watch.conditions.c.commits
end

-- 1. first slot: records where the branch is and waits (no launch)
local cj = jobs.create({ name = "on-commits", prompt = "x", when = "every 5m", cwd = "/home/u/proj", only_when = { commits = {} } }, "summarise", "user", os.time())
assert(cj and cj.conditions and #cj.conditions == 1, "job with one condition")
settle_until(function()
	return newest(cj) ~= nil and newest(cj).state == "skipped"
end)
local r1 = newest(cj)
assert(r1.state == "skipped" and r1.reason_code == "cond_baseline", "baseline skip: " .. tostring(r1.state) .. "/" .. tostring(r1.reason_code))
assert(r1.reason == "Watching this folder's branch from aaaaaaa. The first run waits for something new.", "baseline sentence: " .. tostring(r1.reason))
assert(#fake.calls_of("new") == 0, "no launch")
assert(watermark(cj).sha == SHA1, "watermark at HEAD")
print("PASS first slot records the baseline and waits")

-- 2. two more slots with HEAD unchanged fold into one row
fake.advance(660000)
local list2 = rows(cj)
assert(#list2 == 2, "baseline row plus one folded row, got " .. #list2)
local r2 = list2[1]
assert(r2.state == "skipped" and r2.reason_code == "cond_commits" and r2.count == 2, "folded skip: " .. tostring(r2.reason_code) .. " x" .. tostring(r2.count))
assert(r2.reason:find("^Skipped 2 times since ") and r2.reason:find("no new commits since", 1, true), "fold sentence: " .. r2.reason)
assert(#fake.calls_of("new") == 0, "still no launch")
print("PASS repeated skips fold into one row")

-- 3. HEAD moves: one launch with trigger.md
git.head, git.count = SHA2, 3
settle_until(function()
	return #fake.calls_of("new") == 1
end)
local news = fake.calls_of("new")
local argv3 = news[1]
local trig_arg
for _, a in ipairs(argv3) do
	if a:find("trigger.md", 1, true) then
		trig_arg = a
	end
end
assert(trig_arg and trig_arg:sub(1, 1) == "@", "argv attaches trigger.md: " .. fake.join(argv3))
assert(revlists[#revlists]:find(SHA1 .. ".." .. SHA2, 1, true), "counted from the watermark: " .. revlists[#revlists])
local run3 = newest(cj)
local trig = fake.read("/d/runs/" .. cj.id .. "/" .. run3.run_id .. "/trigger.md")
assert(trig and trig:find("BEGIN UNTRUSTED DATA", 1, true) and trig:find("bbbbbbb Dev Fix the parser", 1, true), "trigger.md content")
assert(trig:find("New commits (3)", 1, true), "context title")
local pre3 = fake.read("/d/runs/" .. cj.id .. "/" .. run3.run_id .. "/preamble.md")
assert(pre3:find("trigger.md", 1, true), "preamble mentions trigger.md")
print("PASS new commits launch with trigger.md")

-- 4. the run finishes: watermark re-baselined to where HEAD is now
git.head = SHA3
settle_until(function()
	return ledger.get(run3.run_id).state == "finished"
end)
fake.advance(2000)
assert(watermark(cj).sha == SHA3, "watermark re-baselined after the run: " .. tostring(watermark(cj).sha))
print("PASS finished run moves the watermark")

-- 5. a failing run leaves the watermark alone
local marked = watermark(cj).sha
git.head, git.count = SHA1, 1
session_text = "Could not.\nRESULT: FAILED - broken"
local launches5 = #fake.calls_of("new")
settle_until(function()
	return #fake.calls_of("new") == launches5 + 1
end)
local run5 = newest(cj)
settle_until(function()
	return ledger.get(run5.run_id).state == "failed"
end)
fake.advance(2000)
assert(watermark(cj).sha == marked, "watermark unchanged after a failure")
local before5 = #revlists
settle_until(function()
	return #revlists > before5
end)
assert(revlists[#revlists]:find(SHA3 .. ".." .. SHA1, 1, true), "same range evaluated again: " .. revlists[#revlists])
jobs.pause(cj.id, "user")
fake.advance(400000)
session_text = "Done.\nRESULT: ok"
print("PASS failed run keeps the watermark")

-- 6. window
local wj = jobs.create({ name = "weekend-only", prompt = "x", when = "manual", cwd = "/home/u/proj", only_when = { window = { days = { 0, 6 }, from = 0, to = 1440 } } }, "x", "user", os.time())
local launches6 = #fake.calls_of("new")
assert(runner.run_now(wj.id))
settle_until(function()
	return newest(wj) ~= nil and newest(wj).state == "skipped"
end, 60000)
assert(newest(wj).reason_code == "cond_window" and newest(wj).trigger == "manual", "skipped/cond_window")
assert(newest(wj).reason == "Skipped: outside weekends.", "window sentence: " .. tostring(newest(wj).reason))
assert(#fake.calls_of("new") == launches6, "no launch")
print("PASS window outside => skipped")

-- 7. budget: one run a day
local bj = jobs.create({ name = "budgeted", prompt = "x", when = "manual", cwd = "/home/u/proj", only_when = { limits = { runs = 1 } } }, "x", "user", os.time())
assert(runner.run_now(bj.id))
settle_until(function()
	return newest(bj) ~= nil and newest(bj).state == "finished"
end)
fake.advance(2000)
assert(runner.run_now(bj.id))
settle_until(function()
	return newest(bj).state == "skipped"
end, 60000)
assert(newest(bj).reason_code == "cond_budget" and newest(bj).reason == "Skipped: 1 of 1 runs already used today.", "budget sentence: " .. tostring(newest(bj).reason))
print("PASS budget reached => skipped")

-- 8. a script check says no
local acks = { ["./scripts/has-work.sh"] = "ck1:" .. ids.fnv64(SCRIPT) }
local kj = jobs.create({ name = "scripted", prompt = "x", when = "manual", cwd = "/home/u/proj", only_when = { check = { path = "./scripts/has-work.sh" } }, check_acks = acks }, "x", "user", os.time())
assert(kj and kj.conditions[1].ack == acks["./scripts/has-work.sh"], "check pinned at save")
assert(runner.run_now(kj.id))
settle_until(function()
	return newest(kj) ~= nil and newest(kj).state == "skipped"
end, 60000)
assert(newest(kj).reason_code == "cond_check" and newest(kj).reason == 'Skipped: your check said no: "queue empty".', "check sentence: " .. tostring(newest(kj).reason))
local input = tern.json.decode(check_inputs[#check_inputs])
assert(input.job == kj.id and input.trigger == "manual" and input.cwd == "/home/u/proj", "check input file")
for p in pairs(fake.files) do
	assert(not p:find("/d/tmp/check-", 1, true), "leftover check input " .. p)
end
print("PASS check says no => skipped with its reason")

-- 9/10. check errors: one alert per incident, then paused after three
check.status, check.stdout = 2, ""
local osa9 = #fake.calls_of("osascript")
for i = 1, 2 do
	assert(runner.run_now(kj.id))
	settle_until(function()
		return newest(kj).state == "blocked" and #rows(kj) == i + 1
	end, 60000)
end
local l9 = rows(kj)
assert(l9[1].reason_code == "cond_error" and l9[2].reason_code == "cond_error", "two blocked/cond_error rows")
assert(l9[1].reason == "Blocked: your check failed to run (exit 2).", "error sentence: " .. tostring(l9[1].reason))
assert(l9[1].incident_repeat == true and l9[2].incident_repeat == nil, "second error is a repeat")
assert(#fake.calls_of("osascript") == osa9 + 1, "one notification for the incident, got " .. (#fake.calls_of("osascript") - osa9))
print("PASS check errors alert once per incident")
assert(runner.run_now(kj.id))
settle_until(function()
	return #rows(kj) == 4 and newest(kj).state == "blocked"
end, 60000)
assert(jobs.get(kj.id).enabled == false and jobs.state(kj.id).paused_reason == "conditions", "paused for conditions: " .. tostring(jobs.state(kj.id).paused_reason))
print("PASS three errors in a row pause the job")

-- 11. the script changed since it was approved
jobs.resume(kj.id, os.time())
script.text = SCRIPT .. "# edited\n"
check.status, check.stdout = 0, ""
local calls11 = #check_inputs
assert(runner.run_now(kj.id))
settle_until(function()
	return #rows(kj) == 5 and newest(kj).state ~= "scheduled"
end, 60000)
assert(newest(kj).state == "blocked" and newest(kj).reason:find("changed since you approved it", 1, true), "changed script: " .. tostring(newest(kj).reason))
assert(#check_inputs == calls11, "a changed script never runs")
jobs.pause(kj.id, "user")
print("PASS changed script is blocked, not run")

-- 12. Run now with a false condition skips; Run anyway launches and leaves the watermark alone
jobs.resume(cj.id, os.time())
local mark12 = watermark(cj).sha
git.head = mark12
assert(runner.run_now(cj.id))
settle_until(function()
	return newest(cj).trigger == "manual" and newest(cj).state == "skipped"
end, 60000)
assert(newest(cj).reason_code == "cond_commits", "manual run skipped on its conditions")
local launches12 = #fake.calls_of("new")
assert(runner.run_now(cj.id, { bypass = "cond_commits" }))
settle_until(function()
	return #fake.calls_of("new") == launches12 + 1
end, 60000)
local run12 = newest(cj)
assert(run12.cond_bypass == "cond_commits", "bypass recorded on the run")
local bypass_argv = fake.calls_of("new")[launches12 + 1]
for _, a in ipairs(bypass_argv) do
	assert(not a:find("trigger.md", 1, true), "no trigger.md for a bypassed run")
end
git.head = SHA2
settle_until(function()
	return ledger.get(run12.run_id).state == "finished"
end)
fake.advance(2000)
assert(watermark(cj).sha == mark12, "watermark unchanged by Run anyway")
jobs.pause(cj.id, "user")
print("PASS Run now asks the conditions; Run anyway bypasses them")

-- 13. the dry run changes nothing
local rows13 = #rows(cj)
jobs.save_state()
local state13 = fake.read("/d/state.json")
local got13
runner.check_conditions(cj.id, function(v)
	got13 = v
end)
fake.advance(3000)
assert(got13 and got13.ok == true and got13.results[1].result == "pass", "dry run sees the new commits")
git.head = mark12
got13 = nil
runner.check_conditions(cj.id, function(v)
	got13 = v
end)
fake.advance(3000)
assert(got13 and got13.ok == false and got13.code == "cond_commits", "dry run says no")
assert(#rows(cj) == rows13 and fake.read("/d/state.json") == state13, "nothing recorded or changed")
print("PASS check_conditions is a dry run")

-- 14. a job without conditions launches exactly as before
local pj = jobs.create({ name = "plain", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "x", "user", os.time())
local launches14 = #fake.calls_of("new")
assert(runner.run_now(pj.id))
settle_until(function()
	return #fake.calls_of("new") == launches14 + 1
end, 60000)
for _, a in ipairs(fake.calls_of("new")[launches14 + 1]) do
	assert(not a:find("trigger.md", 1, true), "no trigger.md argument")
end
local run14 = newest(pj)
local pre14 = fake.read("/d/runs/" .. pj.id .. "/" .. run14.run_id .. "/preamble.md")
assert(not pre14:find("trigger.md", 1, true) and not pre14:find("[quiet]", 1, true), "preamble unchanged")
assert(fake.read("/d/runs/" .. pj.id .. "/" .. run14.run_id .. "/trigger.md") == nil, "no trigger.md file")
settle_until(function()
	return ledger.get(run14.run_id).state == "finished"
end)
assert(jobs.state(pj.id).watch == nil, "no watch state for a plain job")
print("PASS jobs without conditions are unchanged")

-- 15. quiet results
local qj = jobs.create({ name = "quiet-one", prompt = "x", when = "manual", cwd = "/home/u/proj", quiet_ok = true }, "x", "user", os.time())
assert(qj.quiet_ok == true, "quiet_ok stored")
session_text = "Nothing new.\nRESULT: [quiet]"
local launches15 = #fake.calls_of("new")
assert(runner.run_now(qj.id))
settle_until(function()
	return #fake.calls_of("new") == launches15 + 1
end, 60000)
local run15 = newest(qj)
local pre15 = fake.read("/d/runs/" .. qj.id .. "/" .. run15.run_id .. "/preamble.md")
assert(pre15:find("RESULT: [quiet]", 1, true), "preamble offers the quiet result")
settle_until(function()
	return ledger.get(run15.run_id).state == "finished"
end)
run15 = ledger.get(run15.run_id)
assert(run15.outcome_flag == "quiet" and run15.summary == "nothing to report", "quiet outcome: " .. tostring(run15.outcome_flag) .. "/" .. tostring(run15.summary))
assert(jobs.state(qj.id).last_run.quiet == true, "last_run.quiet")
session_text = "Done.\nRESULT: ok"
print("PASS RESULT: [quiet] => finished, quiet")

-- 16. Carly's check_conditions intent
fake.intent("1760000000001-testwin01-0001", { format = 1, kind = "check_conditions", reply = "cccccccccccc", job_id = cj.id, expires = os.time() + 20 })
fake.advance(5000)
local reply = fake.reply("cccccccccccc")
assert(reply and reply.ok == true and reply.pass == false and #reply.conditions == 1, "intent reply: " .. tern.json.encode(reply))
assert(reply.conditions[1].condition == "new commits" and reply.conditions[1].result == "fail", "condition entry")
print("PASS check_conditions intent replies")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
