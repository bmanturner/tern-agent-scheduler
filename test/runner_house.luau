-- Housekeeping: drafts in prompts/, the legacy drafts/ folder, the pasted-image sweep; and capture_tail --surfaces.
local jobs, runner, ledger = __mods.jobs, __mods.runner, __mods.ledger

local DAY = 86400
fake.dirs["/home/u/proj"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))
local NOW = os.time()

local function has(path)
	return fake.files[path] ~= nil or fake.dirs[path] == true
end
local function res(stdout, status)
	return { status = status or 0, stdout = stdout, stderr = "", timed_out = false }
end

-- ---------- phase A: housekeeping at load ----------
local old_draft = string.format("/d/prompts/%d-aaaa1111.md", NOW - 8 * DAY)
local new_draft = string.format("/d/prompts/%d-bbbb2222.md", NOW - 1 * DAY)
fake.write(old_draft, "old draft")
fake.write(new_draft, "fresh draft")
fake.write("/d/prompts/j_keepme.md", "job prompt\n![kept](ref.png)\n")
fake.write("/d/prompts/ref.png", "png")
fake.write("/d/prompts/old.png", "png")
fake.write("/d/prompts/sub/att.png", "png")
fake.write("/d/prompts/trashed.png", "png")
fake.write(string.format("/d/trash/%d-j_gone.md", NOW - DAY), "was a prompt\n![t](trashed.png)\n")
fake.write("/d/outside/out.png", "png")
-- legacy drafts/ folder holding only old drafts and a pasted image
fake.write(string.format("/d/drafts/%d-cccc3333.md", NOW - 9 * DAY), "legacy old")
fake.write("/d/drafts/pasted.png", "png")

local find_calls = 0
fake.override.find = function(argv, _opts)
	find_calls += 1
	return res(table.concat({
		"/d/prompts/ref.png",
		"/d/prompts/old.png",
		"/d/prompts/sub/att.png",
		"/d/prompts/trashed.png",
		"/d/outside/out.png",
	}, "\n") .. "\n")
end

runner.load()
fake.advance(2000)

assert(not has(old_draft), "8-day-old draft removed")
assert(has(new_draft), "fresh draft kept")
assert(has("/d/prompts/j_keepme.md"), "job prompt never removed")
print("PASS drafts in prompts/ age out after 7 days")

assert(not has("/d/drafts"), "legacy drafts/ folder with only old drafts removed entirely")
assert(not has("/d/drafts/pasted.png"), "image inside legacy drafts/ removed with it")
print("PASS legacy drafts/ retired")

local find_argv = fake.calls_of("find")[1]
assert(find_argv ~= nil and fake.join(find_argv) == "/usr/bin/find /d/prompts -type f ! -name *.md -mtime +7", "find argv: " .. tostring(find_argv and fake.join(find_argv)))
assert(find_calls == 1, "one sweep in flight at load: " .. find_calls)
assert(not has("/d/prompts/old.png"), "unreferenced old image removed")
assert(not has("/d/prompts/sub/att.png"), "unreferenced image in a subfolder removed")
assert(has("/d/prompts/ref.png"), "image linked from a job prompt kept")
assert(has("/d/prompts/trashed.png"), "image linked only from trash/ text kept")
assert(has("/d/outside/out.png"), "candidate outside prompts/ untouched")
assert(has("/d/prompts/j_keepme.md") and has(new_draft), "sweep never touches Markdown")
print("PASS image sweep removes only unreferenced old files under prompts/")

-- ---------- capture_tail: --surfaces and the line choice ----------
local job = jobs.create({ name = "tail-job", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "do it", "user", os.time())
fake.override.capture = function()
	return res(table.concat({
		"omp",
		"Error: No model selected.",
		"",
		"  Update Available",
		"  New version 18.10.3 is available. Run: omp update",
		"Closing session…",
	}, "\n") .. "\n")
end
assert(runner.run_now(job.id))
local run
assert(fake.run_until(function()
	run = runner.inflight()[1]
	return run ~= nil and run.state == "running"
end, 30000, 500), "run reached running")
fake.exit_block(tonumber(run.block), 1)
assert(fake.run_until(function()
	return #runner.inflight() == 0
end, 60000, 500), "run ended")
local capture = fake.calls_of("capture")[1]
assert(capture ~= nil and capture[3] == tostring(run.block) and capture[4] == "--surfaces", "capture argv: " .. tostring(capture and fake.join(capture)))
local rec = ledger.recent(job.id, 1)[1]
assert(rec.state == "failed" and rec.reason_code == "agent_error", "agent_error: " .. tostring(rec.state) .. "/" .. tostring(rec.reason_code))
assert(rec.detail == "Error: No model selected.", "detail: " .. tostring(rec.detail))
fake.override.capture = nil
print("PASS capture_tail passes --surfaces and picks the error line")

-- ---------- phase B: hourly pass, legacy drafts/ with a fresh draft ----------
local t = os.time()
local keep_legacy = string.format("/d/drafts/%d-dddd4444.md", t - 1 * DAY)
local drop_legacy = string.format("/d/drafts/%d-eeee5555.md", t - 9 * DAY)
fake.write(keep_legacy, "legacy fresh")
fake.write(drop_legacy, "legacy old")
fake.write("/d/drafts/pasted2.png", "png")
fake.write("/d/prompts/old2.png", "png")
fake.override.find = function()
	return res("/d/prompts/ref.png\n/d/prompts/old2.png\n")
end
fake.calls = {}
fake.advance((3600 + 120) * 1000)
assert(has(keep_legacy) and has("/d/drafts/pasted2.png"), "legacy drafts/ stays while a fresh draft is in it")
assert(not has(drop_legacy), "old legacy draft removed")
assert(not has("/d/prompts/old2.png") and has("/d/prompts/ref.png"), "hourly sweep ran")
print("PASS legacy drafts/ kept while a fresh draft remains")

-- ---------- phase C: a failing find deletes nothing ----------
fake.write("/d/prompts/old3.png", "png")
fake.override.find = function()
	return res("/d/prompts/old3.png\n", 1)
end
fake.advance((3600 + 120) * 1000)
assert(#fake.calls_of("find") >= 1, "find ran")
assert(has("/d/prompts/old3.png"), "non-zero find status deletes nothing")
print("PASS failed find deletes nothing")
