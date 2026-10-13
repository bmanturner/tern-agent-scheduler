-- "Ask an AI" condition: the headless read-only gate call and its prompt file, run/skip verdicts, same-day folding of
-- AI skips with summed cost, short-circuiting behind a failing window, commits context in the prompt, unclear
-- answers and timeouts (alert once), spend counted by Limits, and the dry run.
local jobs, runner, ledger = __mods.jobs, __mods.runner, __mods.ledger

fake.dirs["/home/u/proj"] = true
fake.write(fake.omp_bin, "binary")
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 30)) -- Monday 10:00:30
runner.load()
fake.advance(1000)

-- ---------- fakes: git, the gate's omp call, finished sessions ----------
local SHA1 = string.rep("a", 40)
local SHA2 = string.rep("b", 40)
local git = { head = SHA1, count = 0 }
fake.override.git = function(argv)
	local sub = argv[7]
	if sub == "rev-parse" then
		return { status = 0, stdout = git.head .. "\n", stderr = "", timed_out = false }
	elseif sub == "rev-list" then
		return { status = 0, stdout = tostring(git.count) .. "\n", stderr = "", timed_out = false }
	elseif sub == "log" then
		return { status = 0, stdout = "bbbbbbb Dev Fix the parser\n", stderr = "", timed_out = false }
	elseif sub == "diff" then
		return { status = 0, stdout = " lib/x.luau | 2 +-\n", stderr = "", timed_out = false }
	end
	return nil
end

local function jsonl(lines)
	local out = {}
	for _, l in ipairs(lines) do
		out[#out + 1] = tern.json.encode(l)
	end
	return table.concat(out, "\n") .. "\n"
end
local omp = { text = "ANSWER: run\nREASON: two PRs are open", cost = 0.001, timed_out = false, status = 0 }
local omp_argvs, prompts = {}, {}
fake.override.omp_print = function(argv)
	table.insert(omp_argvs, argv)
	table.insert(prompts, fake.read(argv[#argv]:sub(2)) or "")
	if omp.timed_out then
		return { status = -1, stdout = "", stderr = "", timed_out = true }
	end
	return {
		status = omp.status,
		stdout = jsonl({
			{ type = "agent_start" },
			{
				type = "agent_end",
				messages = {
					{ role = "user", content = { { type = "text", text = "q" } } },
					{ role = "assistant", content = { { type = "text", text = "Looking." } }, usage = { cost = { total = omp.cost / 2 } } },
					{ role = "assistant", content = { { type = "text", text = omp.text } }, usage = { cost = { total = omp.cost / 2 } } },
				},
			},
		}),
		stderr = "",
		timed_out = false,
	}
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
local function omp_calls()
	return #fake.calls_of("omp_print")
end
local function no_tmp_leftovers()
	for p in pairs(fake.files) do
		assert(not p:find("/d/tmp/ask-", 1, true), "leftover prompt file " .. p)
	end
end
local QUESTION = "Are there open PRs to review?"

-- 1. run: the gate argv, the prompt file, trigger.md with the reason, cond_cost
local aj = jobs.create({ name = "asker", prompt = "x", when = "manual", cwd = "/home/u/proj", only_when = { ask = { prompt = QUESTION } } }, "do it", "user", os.time())
assert(aj and aj.conditions and #aj.conditions == 1 and aj.conditions[1].id == "ask" and aj.conditions[1].role == "smol", "job with an ask condition")
assert(runner.run_now(aj.id))
settle_until(function()
	return #fake.calls_of("new") == 1
end, 60000)
assert(omp_calls() == 1, "one model call")
local argv1 = omp_argvs[1]
local joined = fake.join(argv1)
assert(argv1[1] == fake.omp_bin and argv1[2] == "-p", "omp -p: " .. joined)
assert(joined:find("--mode json --no-session --no-extensions --no-skills --no-rules --model @smol --approval-mode always-ask --tools read,grep,glob --thinking off --max-time 55 @", 1, true), "gate argv: " .. joined)
assert(argv1[#argv1]:find("^@/d/tmp/ask%-%w+%.md$"), "prompt file arg: " .. argv1[#argv1])
assert(not joined:find("PRs", 1, true) and not joined:find("asker", 1, true), "no user text in argv")
local p1 = prompts[1]
assert(p1:find("# Should this scheduled job run now?", 1, true) and p1:find("## The question\n\n" .. QUESTION .. "\n", 1, true), "prompt has the question")
assert(p1:find("- Job: asker", 1, true) and p1:find("- Folder: /home/u/proj", 1, true) and p1:find("- Started by: Run now", 1, true) and p1:find("- Last run: never ran", 1, true), "prompt facts")
assert(p1:find("## How to answer", 1, true) and p1:find("ANSWER: run   (or ANSWER: skip)", 1, true), "prompt answer section")
assert(not p1:find("UNTRUSTED", 1, true), "no context block on a first run")
no_tmp_leftovers()
local run1 = newest(aj)
local trig = fake.read("/d/runs/" .. aj.id .. "/" .. run1.run_id .. "/trigger.md")
assert(trig and trig:find("Why the AI said run", 1, true) and trig:find("two PRs are open", 1, true) and trig:find("BEGIN UNTRUSTED DATA", 1, true), "trigger.md carries the reason")
assert(math.abs(tonumber(run1.cond_cost) - 0.001) < 1e-9, "cond_cost recorded: " .. tostring(run1.cond_cost))
print("PASS run => launches with the reason; gate argv, prompt file and cost")

settle_until(function()
	return ledger.get(run1.run_id).state == "finished"
end)

-- 2. skip, then a second skip the same day with another reason folds
local sj = jobs.create({ name = "skipper", prompt = "x", when = "manual", cwd = "/home/u/proj", only_when = { ask = { prompt = QUESTION } } }, "do it", "user", os.time())
omp.text, omp.cost = "ANSWER: skip\nREASON: queue empty", 0.002
assert(runner.run_now(sj.id))
settle_until(function()
	return newest(sj) ~= nil and newest(sj).state == "skipped"
end, 60000)
local s1 = newest(sj)
assert(s1.reason_code == "cond_ask" and s1.reason == 'Skipped: the AI said skip: "queue empty".', "skip sentence: " .. tostring(s1.reason))
fake.advance(60000)
omp.text, omp.cost = "ANSWER: no\nREASON: still nothing", 0.003
assert(runner.run_now(sj.id))
settle_until(function()
	return omp_calls() == 3
end, 60000)
fake.advance(3000)
local sl = rows(sj)
assert(#sl == 1, "folded into one row, got " .. #sl)
assert(sl[1].count == 2 and sl[1].reason_code == "cond_ask", "count 2")
assert(sl[1].reason:find("^Skipped 2 times since ") and sl[1].reason:find('the AI said skip: "still nothing".', 1, true), "latest reason wins: " .. sl[1].reason)
assert(math.abs(tonumber(sl[1].cond_cost) - 0.005) < 1e-9, "cond_cost summed: " .. tostring(sl[1].cond_cost))
assert(#fake.calls_of("new") == 1, "no launch from skips")
print("PASS skip => skipped/cond_ask; same-day skips fold with the latest reason and summed cost")

-- 3. a failing window never reaches the model
local wj = jobs.create({
	name = "weekend-ask", prompt = "x", when = "manual", cwd = "/home/u/proj",
	only_when = { window = { days = { 0, 6 }, from = 0, to = 1440 }, ask = { prompt = QUESTION } },
}, "do it", "user", os.time())
assert(wj and #wj.conditions == 2 and wj.conditions[2].id == "ask", "window then ask")
local before3 = omp_calls()
assert(runner.run_now(wj.id))
settle_until(function()
	return newest(wj) ~= nil and newest(wj).state == "skipped"
end, 60000)
assert(newest(wj).reason_code == "cond_window" and omp_calls() == before3, "omp not called behind a failing window")
print("PASS a window that says no never calls the model")

-- 4. commits + ask: the commit subjects reach the prompt inside an UNTRUSTED DATA block
local cj = jobs.create({
	name = "commit-ask", prompt = "x", when = "manual", cwd = "/home/u/proj",
	only_when = { commits = {}, ask = { prompt = QUESTION } },
}, "do it", "user", os.time())
local before4 = omp_calls()
assert(runner.run_now(cj.id))
settle_until(function()
	return newest(cj) ~= nil and newest(cj).state == "skipped"
end, 60000)
assert(newest(cj).reason_code == "cond_baseline" and omp_calls() == before4, "baseline first, no model call")
git.head, git.count = SHA2, 2
omp.text, omp.cost = "ANSWER: run\nREASON: the parser fix needs review", 0.001
local launches4 = #fake.calls_of("new")
assert(runner.run_now(cj.id))
settle_until(function()
	return #fake.calls_of("new") == launches4 + 1
end, 60000)
local p4 = prompts[#prompts]
local b4 = p4:find("----- BEGIN UNTRUSTED DATA ", 1, true)
local f4 = p4:find("bbbbbbb Dev Fix the parser", 1, true)
local e4 = p4:find("----- END UNTRUSTED DATA ", 1, true)
assert(b4 and f4 and e4 and b4 < f4 and f4 < e4, "commit subject inside an untrusted block")
assert(p4:find("## What the other conditions found", 1, true) and p4:find("### New commits (2)", 1, true), "context headings")
local run4 = newest(cj)
local trig4 = fake.read("/d/runs/" .. cj.id .. "/" .. run4.run_id .. "/trigger.md")
assert(trig4:find("Fix the parser", 1, true) and trig4:find("the parser fix needs review", 1, true), "trigger.md has both")
print("PASS commits + ask: commit subjects reach the prompt as untrusted data")

-- 5. unclear answer and timeout: blocked/cond_error, alert once per incident
local uj = jobs.create({ name = "unclear", prompt = "x", when = "manual", cwd = "/home/u/proj", only_when = { ask = { prompt = QUESTION } } }, "do it", "user", os.time())
omp.text = "Hard to say."
local osa5 = #fake.calls_of("osascript")
for i = 1, 2 do
	assert(runner.run_now(uj.id))
	settle_until(function()
		return #rows(uj) == i and newest(uj).state == "blocked"
	end, 60000)
end
local u = rows(uj)
assert(u[1].reason_code == "cond_error" and u[1].reason == "Blocked: the AI didn't answer run or skip.", "unclear sentence: " .. tostring(u[1].reason))
assert(u[1].incident_repeat == true and u[2].incident_repeat == nil, "second error is a repeat")
assert(#fake.calls_of("osascript") == osa5 + 1, "one alert for the incident, got " .. (#fake.calls_of("osascript") - osa5))
local tj = jobs.create({ name = "slow-ai", prompt = "x", when = "manual", cwd = "/home/u/proj", only_when = { ask = { prompt = QUESTION } } }, "do it", "user", os.time())
omp.timed_out = true
assert(runner.run_now(tj.id))
settle_until(function()
	return newest(tj) ~= nil and newest(tj).state == "blocked"
end, 60000)
assert(newest(tj).reason == "Blocked: the AI check took longer than 60 s.", "timeout sentence: " .. tostring(newest(tj).reason))
omp.timed_out = false
no_tmp_leftovers()
print("PASS unclear answer and timeout => blocked/cond_error, one alert")

-- 6. Limits count the gate's spend: a skip that cost $0.02 uses up "max $0.01 a day"
local lj = jobs.create({
	name = "limited", prompt = "x", when = "manual", cwd = "/home/u/proj",
	only_when = { limits = { usd = 0.01 }, ask = { prompt = QUESTION } },
}, "do it", "user", os.time())
omp.text, omp.cost = "ANSWER: skip\nREASON: nothing", 0.02
assert(runner.run_now(lj.id))
settle_until(function()
	return newest(lj) ~= nil and newest(lj).state == "skipped"
end, 60000)
assert(newest(lj).reason_code == "cond_ask", "first run reaches the model")
local before6 = omp_calls()
assert(runner.run_now(lj.id))
settle_until(function()
	return newest(lj).reason_code == "cond_budget"
end, 60000)
assert(newest(lj).reason == "Skipped: $0.02 of $0.01 spent today.", "budget sentence: " .. tostring(newest(lj).reason))
assert(omp_calls() == before6, "no model call once the limit is reached")
print("PASS Limits count AI check spend")

-- 7. the dry run calls the model and records nothing
local dj = jobs.create({ name = "dry", prompt = "x", when = "manual", cwd = "/home/u/proj", only_when = { ask = { prompt = QUESTION } } }, "do it", "user", os.time())
jobs.save_state()
local state7 = fake.read("/d/state.json")
local rows7 = #rows(dj)
local before7 = omp_calls()
omp.text, omp.cost = "ANSWER: skip\nREASON: dry no", 0.004
local got7
runner.check_conditions(dj.id, function(v)
	got7 = v
end)
fake.advance(3000)
assert(got7 and got7.ok == false and got7.code == "cond_ask" and got7.results[1].type == "ask", "dry verdict")
assert(got7.results[1].text == 'the AI said skip: "dry no"', "dry text: " .. tostring(got7.results[1].text))
assert(omp_calls() == before7 + 1, "the dry run calls the model")
assert(prompts[#prompts]:find("- Started by: a check that doesn't start anything", 1, true), "dry run says so in the prompt")
assert(#rows(dj) == rows7 and fake.read("/d/state.json") == state7, "nothing recorded or changed")
no_tmp_leftovers()
print("PASS check_conditions calls the model and records nothing")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
