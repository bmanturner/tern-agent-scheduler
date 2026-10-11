-- Data-layer review regressions: F19 cache.json damage, F20 blocked jobs.json, F21 one-shot edit, F54 delete + undo.
local jobs, ledger, store = __mods.jobs, __mods.ledger, __mods.store
local const = __mods.const

fake.dirs["/d"] = true
fake.dirs["/home/u/proj"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))

-- F19: an unreadable cache.json (and backup) never pauses jobs; it is set aside and treated as empty.
fake.write("/d/cache.json", "{ truncated")
fake.write("/d/cache.json.bak", "also bad")
local cache, why = store.load("cache", const.CAP_CACHE)
assert(cache == nil and why == "missing", "damaged cache loads as missing: " .. tostring(why))
assert(store.health() == "ok", "health stays ok: " .. store.health())
assert(#store.blocked_names() == 0, "nothing blocked")
assert(store.save("cache", { format = 1, bin = {} }, const.CAP_CACHE), "cache can be rewritten")
jobs.load(os.time())
assert(jobs.paused_all() == false, "jobs are not paused by a bad cache")
print("PASS F19 corrupt cache.json does not pause jobs")

-- F20: with jobs.json unusable, create is refused and leaves nothing behind.
fake.write("/d/jobs.json", "not json")
fake.write("/d/jobs.json.bak", "not json either")
jobs.load(os.time())
assert(store.health() == "damaged", "jobs.json damaged: " .. store.health())
assert(jobs.paused_all() == true, "damaged data pauses everything")
local made, errs = jobs.create({ name = "ghost", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "boo", "user", os.time())
assert(made == nil and errs ~= nil and errs.name == "Agent Scheduler can't save right now. Check Setup.", "create refused")
assert(#jobs.list() == 0, "no job in memory")
for path in pairs(fake.files) do
	assert(not path:find("^/d/prompts/"), "no prompt written: " .. path)
end
assert(fake.files["/d/jobs.json"] == "not json", "damaged file untouched")
print("PASS F20 create fails cleanly when jobs.json is blocked")

-- F22: start fresh sets the bad files aside and writes work again.
assert(table.concat(store.blocked_names(), ",") == "jobs", "jobs is the blocked name")
assert(jobs.start_fresh(os.time()) == true, "start fresh")
assert(store.health() == "ok" and #store.blocked_names() == 0, "healthy after start fresh")
local corrupt = 0
for path in pairs(fake.files) do
	if path:find("^/d/jobs%.json%.corrupt%-") then
		corrupt += 1
	end
end
assert(corrupt == 1, "bad bytes kept: " .. corrupt)
print("PASS F22 start fresh recovers")

-- F21: editing a pending relative one-shot without touching When keeps its run_at.
local once = assert(jobs.create({ name = "later", prompt = "x", when = "in 30m", cwd = "/home/u/proj" }, "later", "user", os.time()))
local run_at = once.schedule.run_at
fake.jump_wall(600)
local edited, e2 = jobs.update(once.id, { name = "later-renamed", when = once.schedule.input }, "changed prompt", os.time())
assert(edited ~= nil, "edit accepted: " .. tostring(e2 and (e2.when or e2.name)))
assert(edited.schedule.run_at == run_at, "run_at unchanged: " .. tostring(edited.schedule.run_at) .. " vs " .. tostring(run_at))
assert(jobs.state(once.id).next_run == run_at, "next_run unchanged")
print("PASS F21 editing a one-shot without changing When keeps run_at")

-- F54: delete keeps ledger and run folders for the undo window; undo brings the history back.
local keep = assert(jobs.create({ name = "history", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "hist", "user", os.time()))
local run = ledger.new(keep, { run_id = "r_" .. keep.id:sub(3) .. "_1760000000", trigger = "manual", slot = os.time(), now = os.time() })
assert(ledger.transition(run, "failed", "launch_error", {}, os.time()))
local run_file = "/d/runs/" .. keep.id .. "/" .. run.run_id .. "/prompt.md"
fake.write(run_file, "x")
assert(#ledger.recent(keep.id, 10) == 1, "one record before delete")

assert(jobs.delete(keep.id, os.time()))
assert(jobs.get(keep.id) == nil, "job gone")
assert(fake.files["/d/ledger/" .. keep.id .. ".jsonl"] ~= nil and fake.files[run_file] ~= nil, "history kept for undo")
for _, r in ipairs(ledger.recent(nil, 50)) do
	assert(r.job_id ~= keep.id, "deleted job's runs are hidden")
end
fake.advance(3000)
local back = jobs.undo_delete(os.time())
assert(back ~= nil and back.id == keep.id, "undo restores the job")
local hist = ledger.recent(keep.id, 10)
assert(#hist == 1 and hist[1].run_id == run.run_id, "history restored")
assert(hist[1].run_dir == "runs/" .. keep.id .. "/" .. run.run_id, "run_dir derived from ids")
local seen = false
for _, r in ipairs(ledger.recent(nil, 50)) do
	seen = seen or r.run_id == run.run_id
end
assert(seen, "run visible in the global list again")
assert(fake.files[run_file] ~= nil, "run folder intact")
print("PASS F54 undo restores run history")

-- a delete that is not undone is purged once the window passes
assert(jobs.delete(keep.id, os.time()))
fake.advance((const.UNDO_DELETE_S + 2) * 1000)
assert(fake.files["/d/ledger/" .. keep.id .. ".jsonl"] == nil and fake.files[run_file] == nil, "purged after the window")
assert(jobs.undo_delete(os.time()) == nil, "no undo after the window")
assert(ledger.save(run) == true and fake.files["/d/ledger/" .. keep.id .. ".jsonl"] == nil, "late save doesn't recreate the ledger")
print("PASS F54 purge after the undo window")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
