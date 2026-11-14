-- The host `reopen` filter: Tern reopening a run's omp chat gets the run's own settings, never its prompt.
local jobs, runner, ledger = __mods.jobs, __mods.runner, __mods.ledger
local reopen, launcher = __mods.reopen, __mods.launcher

fake.dirs["/home/u/proj"] = true
fake.write(fake.omp_bin, "binary")
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))

runner.load()
fake.advance(1000)
assert(fake.handlers.reopen ~= nil and fake.handlers.reopen[1] ~= nil, "reopen filter registered")
local filter = fake.handlers.reopen[1]

local j = jobs.create({ name = "r", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "x", "user", os.time())
assert(runner.run_now(j.id))
local live
assert(fake.run_until(function()
	local r = runner.inflight()[1]
	if r ~= nil and r.state == "running" then
		live = r
	end
	return live ~= nil
end, 30000, 500), "run is running")
local run = ledger.get(live.run_id)
assert(run ~= nil, "run in the ledger")

local dir = "/d/" .. run.run_dir
local want = fake.omp_bin
	.. " --session-dir "
	.. dir
	.. "/session --approval-mode "
	.. launcher.approval_cli(tostring(run.approval or "yolo"))
	.. " --config "
	.. dir
	.. "/omp.yml"
local function ev(over)
	local e = { pane = 1, cwd = "/home/u/proj", shell = "/bin/zsh", agent = "omp", session = dir .. "/session/s.jsonl", how = "restore", command = "omp" }
	for k, v in pairs(over or {}) do
		e[k] = v
	end
	return e
end
local got = filter(ev())
assert(got == want, "restore: run's settings, got " .. tostring(got))
assert(not got:find("prompt.md", 1, true) and not got:find("--resume", 1, true), "no prompt, no flag")
assert(filter(ev({ how = "fork" })) == want, "fork: same command")
print("PASS reopen keeps the run's settings")

assert(filter(ev({ agent = "acp" })) == nil, "acp chats untouched")
assert(filter(ev({ session = "/home/u/.omp/sessions/x.jsonl" })) == nil, "other omp chats untouched")
assert(filter(ev({ session = "/d/runs/" .. run.job_id .. "/r_nope1/session/s.jsonl" })) == nil, "unknown run untouched")
assert(filter(ev({ session = "/d/runs/j_other/" .. run.run_id .. "/session/s.jsonl" })) == nil, "job must match")
assert(filter("junk") == nil, "bad event untouched")
print("PASS reopen leaves other chats alone")

assert(reopen.quote("/a b/c") == "'/a b/c'", "spaces quoted")
assert(reopen.quote("x'y") == nil, "single quote refused")
assert(reopen.quote("a\nb") == nil, "control character refused")
assert(reopen.quote("--config") == "--config", "plain arg as is")
print("PASS reopen quoting")
