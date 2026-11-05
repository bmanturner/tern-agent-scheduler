-- A folder with ' $ ! and spaces saves and launches: cwd reaches `tern new --cwd` as one verbatim argv element.
local jobs, runner = __mods.jobs, __mods.runner

local CWD = "/Volumes/VINH MAC/VINH's WORKS/2026/T11-2026/084 MAPPING - TPHCM $NOV! 22-24"
fake.dirs[CWD] = true
fake.set_wall(fake.chicago(2026, 10, 12, 8, 59, 30))

runner.load()
fake.advance(1000)
local job, errs = jobs.create({ name = "mapping", prompt = "x", when = "0 9 * * *", cwd = CWD }, "x", "user", os.time())
assert(job ~= nil, "quoted folder saves: " .. tostring(errs and errs.cwd))
assert(job.cwd == CWD, "cwd stored verbatim")
print("PASS quoted folder saves")

local _, nl = jobs.create({ name = "nl", prompt = "x", when = "0 9 * * *", cwd = "/tmp/a\nb" }, "x", "user", os.time())
assert(nl ~= nil and nl.cwd ~= nil, "control characters still refused")
print("PASS control characters refused")

assert(fake.run_until(function()
	return #fake.calls_of("new") >= 1
end, 120000, 1000), "job launched")
local argv = fake.calls_of("new")[1]
local at = table.find(argv, "--cwd")
assert(at ~= nil and argv[at + 1] == CWD, "cwd is one verbatim argv element")
print("PASS launch argv carries the folder")
