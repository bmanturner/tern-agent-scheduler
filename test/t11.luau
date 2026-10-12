-- lib/conditions.luau (parse, describe), ids.fnv64, quiet RESULT lines, Carly's job_add doc length.
local conditions, ids, session_tail = __mods.conditions, __mods.ids, __mods.session_tail

local function show(text, want)
	local list, err = conditions.parse(text)
	local got = if list == nil then "error: " .. tostring(err) else "[" .. conditions.describe(list) .. "]"
	if want ~= nil then
		assert(got == want, string.format("%q: want %s, got %s", text, want, got))
	end
	print(string.format("parse %q => %s", text, got))
	return list
end

-- accepted forms
local l1 = show("only if new commits on main in src/ docs/", "[new commits on main in src/ docs/]")
assert(l1 and #l1 == 1 and l1[1].id == "commits" and l1[1].ref == "main" and #l1[1].paths == 2, "commits fields")
local l2 = show("weekdays 9-18 and max 3 runs a day and ./scripts/x.sh", "[weekdays 09:00–18:00 and max 3 runs a day and ./scripts/x.sh]")
assert(l2 and l2[1].type == "window" and l2[2].type == "budget" and l2[3].id == "check1", "evaluation order window, budget, check")
local l3 = show("not 22:00-07:00", "[not 22:00–07:00]")
assert(l3 and l3[1].negate == true and l3[1].from == 22 * 60 and l3[1].to == 7 * 60, "negated window")
local l4 = show("max 3 runs and max $2 a day", "[max 3 runs and $2.00 a day]")
assert(l4 and #l4 == 1 and l4[1].max_runs == 3 and l4[1].max_usd == 2 and l4[1].per == "day", "budgets merge")
local l5 = show("always", "[]")
assert(l5 and #l5 == 0, "always is empty")
show("", "[]")
show("new commits", "[new commits]")
show("new commit in lib", "[new commits in lib]")
show("If NEW COMMITS on Release/1.2", "[new commits on Release/1.2]")
show("weekends", "[weekends]")
show("mon,wed 9am-5pm", "[mon,wed 09:00–17:00]")
show("mon, wed", "[mon,wed]")
show("daily 14:00-16:00", "[14:00–16:00]")
show("outside 9-17", "[not 09:00–17:00]")
show("max $2 per week", "[max $2.00 a week]")
show("max 1 run a day", "[max 1 run a day]")
show("~/bin/check.sh and /opt/c.sh", "[~/bin/check.sh and /opt/c.sh]")
local l6 = show("./a.sh and new commits and ./b.sh")
assert(l6 and l6[1].id == "commits" and l6[2].id == "check1" and l6[2].path == "./a.sh" and l6[3].id == "check2", "check ids in text order")

-- errors
show("weekdays 9-18 and max 3 runs a day and new commits and ./x.sh", "error: Use at most 3 conditions.")
show("new commits on ../x", "error: “../x” isn't a branch name Agent Scheduler can check.")
show("new commits on", "error: Say which branch after “on”, e.g. new commits on main.")
show("new commits on -x", "error: “-x” isn't a branch name Agent Scheduler can check.")
show("new commits in ../up", "error: “../up” isn't a folder path Agent Scheduler can check (no spaces, .. or leading -).")
show("foo", "error: Not understood: “foo”. Try “new commits on main”, “weekdays 9-18”, “max 3 runs a day” or “./scripts/has-work.sh”.")
show("./my script.sh", "error: Script paths can't contain spaces.")
show("./x$y.sh", "error: “./x$y.sh” can't be used as a script path.")
show("./../x.sh", "error: “./../x.sh” can't be used as a script path.")
show("max 0 runs a day", "error: Try “max 3 runs a day” or “max $2 a day”.")
show("max 101 runs a day", "error: Try “max 3 runs a day” or “max $2 a day”.")
show("max $2000 a day", "error: Try “max 3 runs a day” or “max $2 a day”.")
show("max 3 runs a day and max $2 a week", "error: Use one period for limits, e.g. max 3 runs and max $2 a day.")
show("9-9", "error: The time range is empty.")
show("new commits and new commits on main", "error: Only one “new commits” condition.")
show("weekdays and 9-18", "error: Only one time window.")
show("./a.sh and ./b.sh and ./c.sh", "error: Use at most 2 script checks.")

-- signatures and stored checks
local c = (l1 :: any)[1]
assert(conditions.sig(c) == ids.fnv64("commits\0main\0src/\0docs/"), "commits sig")
assert(conditions.sig((l2 :: any)[1]) == "", "window has no sig")
assert(conditions.check_stored(l2) == nil, "parsed list passes the stored check")
assert(conditions.check_stored({ { id = "x", type = "commits" } }) == "Its conditions can't be read.", "bad id rejected")
assert(conditions.script_path("./a.sh", "/w", "/h") == "/w/a.sh" and conditions.script_path("~/a.sh", "/w", "/h") == "/h/a.sh" and conditions.script_path("/a.sh", "/w", "/h") == "/a.sh", "script_path")
print("sig/check_stored/script_path => ok")

-- FNV-1a 64
for _, v in ipairs({ { "", "cbf29ce484222325" }, { "a", "af63dc4c8601ec8c" }, { "foobar", "85944171f73967e8" } }) do
	assert(ids.fnv64(v[1]) == v[2], "fnv64 " .. v[1])
	print(string.format("fnv64 %q => %s", v[1], ids.fnv64(v[1])))
end

-- quiet RESULT lines
local function sum(text)
	local s, failed, quiet = session_tail.summarize(text)
	print(string.format("summarize %q => %s | failed=%s | quiet=%s", text, s, tostring(failed), tostring(quiet)))
	return s, failed, quiet
end
local s1, f1, q1 = sum("RESULT: [quiet]")
assert(s1 == "nothing to report" and f1 == nil and q1 == true, "bare quiet")
local s2, f2, q2 = sum("RESULT: [QUIET] - nothing new")
assert(s2 == "nothing new" and f2 == nil and q2 == true, "quiet with words")
local s3, f3, q3 = sum("RESULT: FAILED - x")
assert(s3 == "x" and f3 == "x" and q3 == nil, "failed is not quiet")
local s4, f4, q4 = sum("RESULT: done")
assert(s4 == "done" and f4 == nil and q4 == nil, "plain result is not quiet")

-- Carly's job_add doc must fit Tern's 1024-byte export limit untruncated
local carly = __mods.carly
local doc = carly.fit(carly.ADD_DOC)
assert(doc == carly.ADD_DOC and #doc <= 1024, "ADD_DOC fits: " .. #carly.ADD_DOC)
print("ADD_DOC fits => true")
return 0
