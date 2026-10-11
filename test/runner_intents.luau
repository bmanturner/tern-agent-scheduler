-- The allowlist (13 kinds), dropped kinds, retry of undecodable files, carly_create and its replies.
local jobs, runner, intents = __mods.jobs, __mods.runner, __mods.intents

fake.dirs["/home/u/proj"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))
runner.load()
fake.advance(1000)

local seq = 0
local function send(payload)
	seq += 1
	fake.intent(string.format("%013d-testwin01-%04d", 1760000000000 + seq, seq), payload)
end
local function pending()
	return #tern.fs.list("/d/intents")
end
local function settle(ms)
	fake.advance(ms or 2500)
end

local base = jobs.create({ name = "existing", prompt = "x", when = "manual", cwd = "/home/u/proj" }, "keep me", "user", os.time())
assert(base, "seed job")
local count0 = #jobs.list()

-- 1. create / update / delete / settings are not intents
send({ format = 1, kind = "create", name = "evil", prompt = "p", when = "daily 09:00", cwd = "/home/u/proj" })
send({ format = 1, kind = "update", job_id = base.id, name = "renamed" })
send({ format = 1, kind = "delete", job_id = base.id })
send({ format = 1, kind = "settings", paused_all = true })
send({ format = 2, kind = "pause_all" })
settle()
assert(#jobs.list() == count0 and jobs.get(base.id).name == "existing", "forbidden kinds changed nothing")
assert(jobs.settings().paused_all == false, "settings kind ignored, wrong format ignored")
assert(pending() == 0, "dropped files are removed")
print("PASS create/update/delete/settings dropped")

-- 2. undecodable file: retried, then dropped after INTENT_RETRY_S
fake.write("/d/intents/1760000009999-testwin01-0099.json", "{not json")
settle(5000)
assert(pending() == 1, "kept for retry")
fake.advance(65000)
assert(pending() == 0, "dropped after 60 s")
print("PASS undecodable intent retried then dropped")

-- 3. the simple kinds
send({ format = 1, kind = "pause", job_id = base.id })
settle()
assert(jobs.get(base.id).enabled == false, "pause")
send({ format = 1, kind = "resume", job_id = base.id })
settle()
assert(jobs.get(base.id).enabled ~= false, "resume")
send({ format = 1, kind = "pause_all" })
settle()
assert(jobs.settings().paused_all == true, "pause_all")
send({ format = 1, kind = "run_now", job_id = base.id })
settle(20000)
assert(#fake.calls_of("new") == 0, "run_now refused while everything is paused")
send({ format = 1, kind = "resume_all" })
settle()
assert(jobs.settings().paused_all == false, "resume_all")
send({ format = 1, kind = "run_now", job_id = base.id })
settle(20000)
assert(#fake.calls_of("new") == 1, "run_now launched through the normal pipeline")
fake.live_panes[#fake.live_panes + 1] = "4242"
runner.add_manager("4242")
send({ format = 1, kind = "focus_manager" })
settle()
local focus = fake.calls_of("focus")
assert(focus[#focus][3] == "4242", "focus_manager focuses the newest manager block")
send({ format = 1, kind = "roles_request", cwd = "/home/u/proj" })
settle()
assert(#fake.calls_of("config") >= 1, "roles_request reads roles")
print("PASS pause, resume, pause_all, run_now, focus_manager, roles_request")

-- 4. carly_create
local function carly(reply, fields)
	local p = { format = 1, kind = "carly_create", reply = reply }
	for k, v in pairs(fields) do
		p[k] = v
	end
	send(p)
	settle()
	return fake.reply(reply)
end

local r1 = carly("aaaaaaaaaaaa", { name = "carly-smoke", prompt = "Reply with exactly: RESULT: pong", when = "weekdays 9am", folder = "~/proj" })
assert(r1 and r1.ok == true, "carly_create ok: " .. tern.json.encode(r1))
assert(r1.when == "Weekdays at 09:00", "when text: " .. tostring(r1.when))
assert(r1.name == "carly-smoke" and r1.folder == "~/proj" and r1.role == "@default" and r1.approval == "Hands-off", "reply fields")
assert(type(r1.next) == "string" and r1.next ~= "manual only", "next run text: " .. tostring(r1.next))
local made = jobs.get(r1.job_id)
assert(made and made.approval == "yolo" and made.created_by == "carly" and made.role == "default" and made.cwd == "/home/u/proj", "job fields")
assert(made.enabled == true and jobs.state(made.id).next_run ~= nil, "armed immediately")
assert(jobs.prompt(made.id) == "Reply with exactly: RESULT: pong", "prompt stored")
local snap = tern.json.decode(fake.read("/d/snapshot.json"))
local in_snap = false
for _, j in ipairs(snap.jobs) do
	if j.id == made.id and j.created_by == "carly" then
		in_snap = true
	end
end
assert(in_snap, "snapshot published before the reply")
print("PASS carly_create success (weekdays 9am, hands-off, created_by carly)")

local r2 = carly("bbbbbbbbbbbb", { name = "too-often", prompt = "p", when = "every 2m", folder = "/home/u/proj" })
assert(r2 and r2.ok == false, "interval refused")
assert(r2.error == "Agent runs shorter than 5 minutes apart tend to overlap. Use every 5m or more.", "interval copy: " .. tostring(r2.error))
print("PASS carly_create interval error")

local r3 = carly("cccccccccccc", { name = "Carly-Smoke", prompt = "p", when = "daily 09:00", folder = "/home/u/proj" })
assert(r3 and r3.ok == false and r3.error:find("already exists", 1, true), "duplicate name refused: " .. tostring(r3 and r3.error))
print("PASS carly_create duplicate name error")

local r4 = carly("dddddddddddd", { prompt = "Summarize the open pull requests on this repo today", when = "daily 09:00", folder = "/home/u/proj", role = "@smol" })
assert(r4 and r4.ok == true and r4.name == "summarize-the-open-pull-requests" and r4.role == "@smol", "derived name and @ stripped: " .. tern.json.encode(r4))
local r5 = carly("eeeeeeeeeeee", { prompt = "Summarize the open pull requests on this repo today", when = "daily 10:00", folder = "/home/u/proj" })
assert(r5 and r5.ok == true and r5.name == "summarize-the-open-pull-requests-2", "derived name made unique: " .. tostring(r5 and r5.name))
print("PASS carly_create name derivation")

local r6 = carly("ffffffffffff", { name = "nofolder", prompt = "p", when = "daily 09:00", folder = "/nope/nothing" })
assert(r6 and r6.ok == false and r6.error == "That folder doesn't exist: /nope/nothing", "folder copy: " .. tostring(r6 and r6.error))
local r7 = carly("gggggggggggg", { name = "long", prompt = string.rep("x", 12001), when = "daily 09:00", folder = "/home/u/proj" })
assert(r7 and r7.ok == false and r7.error == "That prompt is too long for Carly. Use the manager.", "prompt cap copy")
local r8 = carly("hhhhhhhhhhhh", { name = "nowhen", prompt = "p", when = "whenever you like", folder = "/home/u/proj" })
assert(r8 and r8.ok == false, "unparsable schedule refused")
print("PASS carly_create folder, prompt cap, schedule errors")

-- cached roles: an absent role is refused with the list
local got
runner.roles("/home/u/proj", function(list)
	got = list
end)
settle(1000)
assert(got and got[1] == "default" and got[2] == "smol", "roles read and sorted")
local r9 = carly("iiiiiiiiiiii", { name = "badrole", prompt = "p", when = "daily 09:00", folder = "/home/u/proj", role = "@nope" })
assert(r9 and r9.ok == false and r9.error == "No role @nope here. Roles: @default, @smol, @task, @plan, @slow, @commit, @advisor, @tiny, @memory, @vision", "role copy: " .. tostring(r9 and r9.error))
print("PASS carly_create cached role check")

-- replies are pruned after REPLY_TTL_S
assert(#tern.fs.list("/d/replies") > 0, "replies exist")
intents.prune(os.time())
fake.jump_wall(400)
intents.prune(os.time())
assert(#tern.fs.list("/d/replies") == 0, "replies pruned")
print("PASS replies pruned")

assert(#fake.errors == 0, "no error logs: " .. table.concat(fake.errors, "; "))
print("PASS no errors")
