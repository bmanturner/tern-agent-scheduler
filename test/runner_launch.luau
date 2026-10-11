-- Two cron jobs due in the same tick: first launch creates the "Scheduled runs" session, the second a tab in it.
local jobs, runner, launcher = __mods.jobs, __mods.runner, __mods.launcher

fake.dirs["/home/u/proj"] = true
fake.dirs["/home/u/proj2"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 8, 59, 30)) -- Monday

runner.load()
fake.advance(1000)
local a = jobs.create({ name = "job-a", prompt = "x", when = "0 9 * * *", cwd = "/home/u/proj" }, "Do thing A\nwith 'quotes' and $vars", "user", os.time())
local b = jobs.create({ name = "job-b", prompt = "x", when = "0 9 * * *", cwd = "/home/u/proj2", approval = "write" }, "Do thing B", "user", os.time())
assert(a and b, "jobs created")
assert(a.approval == "yolo" and b.approval == "write", "default approval is Hands-off")

local launched = fake.run_until(function()
	return #fake.calls_of("new") >= 2
end, 120000, 1000)
assert(launched, "both jobs launched")
fake.advance(2000)

local news = fake.calls_of("new")
local by_cwd = {}
for _, argv in ipairs(news) do
	by_cwd[argv[7]] = argv
end
local TERN, OMP = fake.tern_bin, fake.omp_bin
local function runs_of(job)
	for _, r in ipairs(runner.inflight()) do
		if r.job_id == job.id then
			return r
		end
	end
end
local ra, rb = runs_of(a), runs_of(b)
assert(ra and rb, "both runs in flight")
print("PASS runs claimed")

-- which one went first?
local first, second = news[1], news[2]
assert(first[3] == "session" and first[4] == "Scheduled runs", "first launch creates the session: " .. fake.join(first))
assert(second[3] == "tab" and second[4] == "Scheduled runs", "second launch is a tab in it: " .. fake.join(second))
print("PASS session then tab (queue serialized)")

local function expect_argv(argv, job, run, approval, verb)
	local dir = "/d/runs/" .. job.id .. "/" .. run.run_id
	local head = { TERN, "new", verb, "Scheduled runs", "--json", "--cwd", job.cwd, "--keep-open", "--", OMP, "--model", "@default", "--approval-mode", approval }
	for i, v in ipairs(head) do
		assert(argv[i] == v, string.format("argv[%d] = %s, want %s", i, tostring(argv[i]), v))
	end
	assert(argv[#argv] == "Run the scheduled job described in the attached file.", "fixed positional last")
	assert(argv[#argv - 1] == "@" .. dir .. "/prompt.md", "attachment second to last: " .. tostring(argv[#argv - 1]))
	local joined = table.concat(argv, " ")
	assert(joined:find("--max-time 1800", 1, true), "max time")
	assert(joined:find("--session-dir " .. dir .. "/session", 1, true), "session dir")
	assert(joined:find("--append-system-prompt " .. dir .. "/preamble.md", 1, true), "preamble")
	assert(joined:find("--config " .. dir .. "/omp.yml", 1, true), "overlay")
end
local function arg_for(job)
	return by_cwd[job.cwd]
end
expect_argv(arg_for(a), a, ra, "yolo", arg_for(a) == first and "session" or "tab")
expect_argv(arg_for(b), b, rb, "write", arg_for(b) == first and "session" or "tab")
print("PASS argv shape (yolo and write)")

assert(type(ra.block) == "string" and ra.block:match("^%d+$"), "block is a string")
assert(type(rb.block) == "string", "block is a string")
assert(ra.state == "running" and rb.state == "running", "both running")
assert(ra.placement_used == "session", "placement recorded")
print("PASS run records carry string block ids")

-- run files
local dir_a = "/d/runs/" .. a.id .. "/" .. ra.run_id
assert(fake.read(dir_a .. "/prompt.md") == "Do thing A\nwith 'quotes' and $vars", "prompt snapshot verbatim")
assert(fake.read(dir_a .. "/omp.yml") == "ask:\n  enabled: false\n", "hands-off overlay disables ask")
assert(fake.read("/d/runs/" .. b.id .. "/" .. rb.run_id .. "/omp.yml"):find("bash: prompt", 1, true), "ask-mode overlay pins exec tier")
local pre = fake.read(dir_a .. "/preamble.md")
assert(pre:find('unattended run of the scheduled job "job-a"', 1, true), "preamble names the job")
assert(pre:find("RESULT: FAILED - <reason>", 1, true), "preamble asks for RESULT")
assert(pre:find("about 30 minutes", 1, true), "preamble time limit")
assert(pre:find("started on schedule", 1, true), "preamble how")
print("PASS run directory files")

-- best-effort rename of the tab
local renamed = {}
for _, argv in ipairs(fake.calls_of("rename")) do
	renamed[argv[4]] = true
end
assert(renamed["⏲ job-a"] and renamed["⏲ job-b"], "tabs renamed")
assert(#fake.calls_of("focus") == 0, "focus=keep never focuses")
print("PASS tab rename, no focus steal")

-- state files and snapshot
local snap = tern.json.decode(fake.read("/d/snapshot.json"))
assert(#snap.inflight == 2 and type(snap.inflight[1].block) == "string", "snapshot lists in-flight runs with string blocks")
local hot = tern.kv.get("hot")
assert(hot and hot.running == 2 and hot.scheduler == "ok", "kv hot")
assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS snapshot and hot state")

-- the launcher argv helper builds the same thing for the third verb
local req = { run = ra, job = a, prompt = "x", bins = { tern = TERN, omp = OMP }, session_name = "Scheduled runs", where = "tab", focus = "keep", trigger = "schedule" }
local shown = launcher.argv(req, "new_tab_shown")
assert(shown[3] == "tab" and shown[4] == "--json", "tab placement passes no session name")
print("PASS shown-session tab argv")
