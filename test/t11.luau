-- lib/conditions.luau (build, describe, to_input, days_label, from_fields), ids.fnv64, quiet RESULT lines, Carly's job_add doc length and request context.
local conditions, ids, session_tail = __mods.conditions, __mods.ids, __mods.session_tail

local function ser(v)
	if type(v) ~= "table" then
		return if type(v) == "string" then string.format("%q", v) else tostring(v)
	end
	local keys = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in keys do
		table.insert(parts, tostring(k) .. "=" .. ser(v[k]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function show(label, input, want)
	local list, errs = conditions.build(input)
	local got = if list == nil then "errors " .. ser(errs) else "[" .. conditions.describe(list) .. "]"
	if want ~= nil then
		assert(got == want, string.format("%s: want %s, got %s", label, want, got))
	end
	print(string.format("build %s => %s", label, got))
	return list, errs
end

-- each condition alone
local c1 = show("commits default", { commits = {} }, "[new commits]")
assert(c1 and #c1 == 1 and c1[1].id == "commits" and c1[1].ref == "HEAD" and #c1[1].paths == 0, "commits defaults")
local c2 = show("commits branch+folders", { commits = { branch = "main", folders = { "./src/", "docs" } } }, "[new commits on main in src docs]")
assert(c2 and c2[1].ref == "main" and c2[1].paths[1] == "src" and c2[1].paths[2] == "docs", "folders normalised")
show("commits empty branch", { commits = { branch = "" } }, "[new commits]")
local w1 = show("window weekdays", { window = { days = { 5, 3, 1, 2, 4, 3 }, from = 540, to = 1080 } }, "[weekdays 09:00–18:00]")
assert(w1 and #w1[1].days == 5 and w1[1].days[1] == 1 and w1[1].negate == false, "days sorted and deduped")
show("window outside", { window = { days = { 0, 1, 2, 3, 4, 5, 6 }, from = 1320, to = 420, outside = true } }, "[quiet hours 22:00–07:00]")
show("window weekends all day", { window = { days = { 6, 0 }, from = 0, to = 1440 } }, "[weekends]")
show("window mon,wed", { window = { days = { 1, 3 }, from = 0, to = 1440 } }, "[Mon, Wed]")
local b1 = show("limits runs", { limits = { runs = 3 } }, "[max 3 runs a day]")
assert(b1 and b1[1].per == "day" and b1[1].max_runs == 3 and b1[1].max_usd == nil, "limits default per")
show("limits usd week", { limits = { usd = 2, per = "week" } }, "[max $2.00 a week]")
show("limits both", { limits = { runs = 1, usd = 0.5 } }, "[max 1 run and $0.50 a day]")
local k1 = show("check", { check = { path = "./scripts/has-work.sh" } }, "[./scripts/has-work.sh]")
assert(k1 and k1[1].id == "check" and k1[1].type == "check", "check id")
show("check home", { check = { path = "~/bin/c.sh" } }, "[~/bin/c.sh]")

-- all four together, in evaluation order
local all = show("all four", {
	check = { path = "/opt/c.sh" },
	commits = { branch = "main" },
	limits = { runs = 3, usd = 2 },
	window = { days = { 1, 2, 3, 4, 5 }, from = 540, to = 1080 },
}, "[weekdays 09:00–18:00 and max 3 runs and $2.00 a day and new commits on main and /opt/c.sh]")
assert(all and all[1].id == "window" and all[2].id == "budget" and all[3].id == "commits" and all[4].id == "check", "evaluation order")
assert(conditions.check_stored(all) == nil, "built list passes the stored check")

-- nothing
local n1 = show("nil input", nil, "[]")
assert(n1 and #n1 == 0, "nil is empty")
show("empty input", {}, "[]")

-- errors, one per key
show("branch bad", { commits = { branch = "../x" } }, 'errors {branch="“../x” isn\'t a branch name Agent Scheduler can check."}')
show("branch dash", { commits = { branch = "-x" } }, 'errors {branch="“-x” isn\'t a branch name Agent Scheduler can check."}')
show("folders bad", { commits = { folders = { "../up" } } }, 'errors {folders="“../up” isn\'t a folder Agent Scheduler can check (no spaces, .. or leading -)."}')
show("folders many", { commits = { folders = { "a", "b", "c", "d", "e", "f", "g", "h", "i" } } }, 'errors {folders="Pick at most 8 folders."}')
show("days none", { window = { days = {}, from = 0, to = 1440 } }, 'errors {days="Pick at least one day."}')
show("days range", { window = { days = { 7 }, from = 0, to = 1440 } }, 'errors {days="Pick at least one day."}')
show("hours range", { window = { days = { 1 }, from = 0, to = 1500 } }, 'errors {hours="Pick a time between 00:00 and 24:00."}')
show("hours from 24", { window = { days = { 1 }, from = 1440, to = 1440 } }, 'errors {hours="Pick a time between 00:00 and 24:00."}')
show("hours equal", { window = { days = { 1 }, from = 600, to = 600 } }, 'errors {hours="Pick two different times."}')
show("limits none", { limits = {} }, 'errors {limits="Set a number of runs, an amount, or both."}')
show("limits runs 0", { limits = { runs = 0 } }, 'errors {limits="Runs must be 1 to 100."}')
show("limits runs 101", { limits = { runs = 101 } }, 'errors {limits="Runs must be 1 to 100."}')
show("limits runs 1.5", { limits = { runs = 1.5 } }, 'errors {limits="Runs must be 1 to 100."}')
show("limits usd low", { limits = { usd = 0.001 } }, 'errors {limits="Spend must be $0.01 to $1,000."}')
show("limits usd high", { limits = { usd = 2000 } }, 'errors {limits="Spend must be $0.01 to $1,000."}')
show("limits per", { limits = { runs = 1, per = "year" } }, 'errors {limits="Per must be a day or a week."}')
show("script empty", { check = { path = "" } }, 'errors {script="Enter the script\'s path, e.g. ./scripts/has-work.sh."}')
show("script prefix", { check = { path = "scripts/x.sh" } }, 'errors {script="Start the path with ./ (the job\'s folder), ~/ or /."}')
show("script space", { check = { path = "./my script.sh" } }, 'errors {script="“./my script.sh” can\'t be used as a script path (no spaces, quotes, $ or ..)."}')
show("script dollar", { check = { path = "./x$y.sh" } }, 'errors {script="“./x$y.sh” can\'t be used as a script path (no spaces, quotes, $ or ..)."}')
show("script dotdot", { check = { path = "./../x.sh" } }, 'errors {script="“./../x.sh” can\'t be used as a script path (no spaces, quotes, $ or ..)."}')
show("many errors", { commits = { branch = "..", folders = { "-a" } }, check = { path = "" } }, nil)

-- to_input is the inverse of build
local function round(label, input)
	local list = conditions.build(input)
	local back = conditions.to_input(list)
	local again = conditions.build(back)
	assert(conditions.describe(again) == conditions.describe(list), label .. " round trip")
	print(string.format("to_input %s => %s", label, ser(back)))
	return back
end
local r1 = round("commits head", { commits = {} })
assert(r1.commits ~= nil and r1.commits.branch == nil, "HEAD maps to a nil branch")
round("commits main", { commits = { branch = "main", folders = { "src" } } })
round("window", { window = { days = { 1, 3 }, from = 60, to = 120, outside = true } })
round("limits", { limits = { runs = 2, usd = 1.5, per = "week" } })
round("check", { check = { path = "./a.sh" } })
round("all", { commits = { branch = "dev" }, window = { days = { 0 }, from = 0, to = 1440 }, limits = { usd = 3 }, check = { path = "~/c" } })
assert(next(conditions.to_input(nil)) == nil and next(conditions.to_input({})) == nil, "to_input of nothing is empty")

-- days_label and hhmm
for _, d in ipairs({ { 0, 1, 2, 3, 4, 5, 6 }, { 5, 4, 3, 2, 1 }, { 6, 0 }, { 3, 1 }, { 0, 2, 6 }, { 0 } }) do
	print(string.format("days_label %s => %s", table.concat(d, ","), conditions.days_label(d)))
end
assert(conditions.days_label({ 0, 1, 2, 3, 4, 5, 6 }) == "Every day", "every day")
assert(conditions.days_label({ 5, 4, 3, 2, 1 }) == "Weekdays", "weekdays")
assert(conditions.days_label({ 6, 0 }) == "Weekends", "weekends")
assert(conditions.days_label({ 3, 1 }) == "Mon, Wed", "custom, Monday first")
assert(conditions.days_label({ 0, 2 }) == "Tue, Sun", "Sunday last")
assert(conditions.hhmm(540) == "09:00" and conditions.hhmm(1440) == "24:00" and conditions.hhmm(0) == "00:00", "hhmm")
print("hhmm => ok")

-- from_fields (Carly)
local function ff(label, t, want)
	local input, err = conditions.from_fields(t)
	local got
	if input == nil then
		got = "error: " .. tostring(err)
	else
		local list, errs = conditions.build(input)
		got = if list == nil then "build errors " .. ser(errs) else ser(input) .. " => [" .. conditions.describe(list) .. "]"
	end
	if want ~= nil then
		assert(got == want, string.format("%s: want %s, got %s", label, want, got))
	end
	print(string.format("from_fields %s => %s", label, got))
	return input, err
end
local f1 = ff("commits", { new_commits = true, branch = "main" }, nil)
assert(f1 and f1.commits and f1.commits.branch == "main" and f1.window == nil and f1.limits == nil, "commits fields")
ff("commits folders string", { new_commits = true, folders = "src, docs lib" }, nil)
ff("commits folders table", { folders = { "src" } }, nil)
ff("commits off", { new_commits = false, branch = "main" }, "{} => []")
ff("days from to", { days = "weekdays", from = "09:00", to = "18:00" }, nil)
ff("quiet hours", { from = "22:00", to = "07:00", quiet_hours = true }, nil)
ff("12 hour clock", { from = "9am", to = "6pm" }, nil)
ff("bare hours", { from = "9", to = "18", days = "Mon,Wed" }, nil)
ff("midnight end", { from = "18:00", to = "24:00" }, nil)
ff("only days", { days = "weekends" }, nil)
ff("max runs per", { max_runs = 3, per = "day" }, nil)
ff("max usd", { max_usd = 2.5 }, nil)
ff("runs and usd per week", { max_runs = 5, max_usd = 10, per = "week" }, nil)
ff("everything", { new_commits = true, branch = "main", days = "daily", from = "8", to = "20", max_runs = 2 }, nil)
ff("empty", {}, "{} => []")
ff("unknown key", { script = "./x.sh" }, "error: Unknown field “script” in only_when.")
ff("not a table", "weekdays", "error: only_when must be a table of fields.")
ff("only from", { from = "9am" }, "error: Give both from and to.")
ff("only to", { to = "9am" }, "error: Give both from and to.")
ff("bad days", { days = "sometimes" }, "error: days: use “weekdays”, “weekends”, “every day” or names like “mon,wed”.")
ff("bad times", { from = "soon", to = "later" }, "error: from/to: use times like 09:00 or 6pm.")
ff("equal times", { from = "9am", to = "9am" }, nil)
ff("bad branch", { branch = "../x" }, nil)
ff("limits none", { per = "week" }, nil)
ff("limits bad", { max_runs = 500 }, nil)
ff("per bad", { max_runs = 2, per = "month" }, nil)

-- signatures and stored checks
local c = (all :: any)[3]
assert(conditions.sig(c) == ids.fnv64("commits\0main\0"), "commits sig")
assert(conditions.sig((all :: any)[1]) == "", "window has no sig")
assert(conditions.sig((all :: any)[4]) == ids.fnv64("check\0/opt/c.sh"), "check sig")
assert(conditions.check_stored({ { id = "x", type = "commits" } }) == "Its conditions can't be read.", "bad id rejected")
assert(conditions.check_stored({ { id = "check1", type = "check", path = "./a" } }) == "Its conditions can't be read.", "old check id rejected")
assert(
	conditions.check_stored({ { id = "commits", type = "commits", ref = "HEAD", paths = {} }, { id = "commits", type = "commits", ref = "HEAD", paths = {} } })
		== "Its conditions can't be read.",
	"one condition per type"
)
assert(conditions.script_path("./a.sh", "/w", "/h") == "/w/a.sh" and conditions.script_path("~/a.sh", "/w", "/h") == "/h/a.sh" and conditions.script_path("/a.sh", "/w", "/h") == "/a.sh", "script_path")
print("sig/check_stored/script_path => ok")
-- ask: build, errors, describe, round trip, from_fields, check_stored
local a1 = show("ask default role", { ask = { prompt = "  Are there open PRs?  " } }, "[the AI says run (“Are there open PRs?”)]")
assert(a1 and a1[1].id == "ask" and a1[1].type == "ask" and a1[1].prompt == "Are there open PRs?" and a1[1].role == "smol", "ask defaults")
local a2 = show("ask role @", { ask = { prompt = "x", role = "@judge" } }, "[the AI says run (“x”)]")
assert(a2 and a2[1].role == "judge", "leading @ stripped")
show("ask long prompt", { ask = { prompt = "Run only if there are open pull requests that need a review today.\nReally." } }, "[the AI says run (“Run only if there are open pull requests…”)]")
show("ask empty", { ask = { prompt = "   " } }, 'errors {ask="Write the question the AI should answer."}')
show("ask nul", { ask = { prompt = "a\0b" } }, 'errors {ask="Write the question the AI should answer."}')
show("ask too long", { ask = { prompt = string.rep("a", 4001) } }, 'errors {ask="Keep the question under 4,000 characters."}')
show("ask bad role", { ask = { prompt = "x", role = "bad role" } }, 'errors {ask_role="Pick a model role from the list."}')
show("ask both bad", { ask = { prompt = "", role = "a/b" } }, nil)
local a3 = show("ask last", {
	ask = { prompt = "go?" },
	check = { path = "/opt/c.sh" },
	commits = {},
	limits = { runs = 3 },
	window = { days = { 1 }, from = 0, to = 1440 },
}, "[Mon and max 3 runs a day and new commits and /opt/c.sh and the AI says run (“go?”)]")
assert(a3 and #a3 == 5 and a3[5].id == "ask" and conditions.check_stored(a3) == nil, "ask is last and passes the stored check")
assert(conditions.sig(a3[5]) == "", "ask has no sig")
round("ask", { ask = { prompt = "Open PRs?", role = "judge" } })
ff("ask", { ask = "Open PRs?" }, nil)
local fa = ff("ask with model", { ask = "Open PRs?", ask_model = "@tiny" }, nil)
assert(fa and fa.ask and fa.ask.prompt == "Open PRs?" and fa.ask.role == "@tiny", "ask_model passes through")
ff("ask wrong type", { ask = 5 }, "error: ask in only_when has the wrong type.")
ff("ask_model alone", { ask_model = "smol" }, nil)
assert(conditions.check_stored({ { id = "ask", type = "ask", prompt = "x", role = "smol" } }) == nil, "stored ask ok")
assert(conditions.check_stored({ { id = "ask", type = "ask", prompt = "x" } }) == "Its conditions can't be read.", "stored ask needs a role")
assert(conditions.check_stored({ { id = "ask", type = "ask", prompt = 5, role = "smol" } }) == "Its conditions can't be read.", "stored ask needs a prompt")
print("ask => ok")

-- untrusted
local untrusted = __mods.untrusted
assert(untrusted.clean("a\27[31mb\r\nc\1d\xE2\x80\xAEe") == "ab\nc de", "clean")
assert(untrusted.fence("n1", "commits", "git", "T") == "----- BEGIN UNTRUSTED DATA n1 [name=commits source=git] -----\nT\n----- END UNTRUSTED DATA n1 -----", "fence")
print("untrusted => ok")

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
local s1, f1b, q1 = sum("RESULT: [quiet]")
assert(s1 == "nothing to report" and f1b == nil and q1 == true, "bare quiet")
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
print("ADD_DOC bytes", #carly.ADD_DOC)

-- The request context keeps the whole routing guide within Tern's 400-character cap
assert(carly.context_text(nil) == carly.GUIDE, "guide alone without a status line")
local line = "Agent Scheduler: 2 active, 0 paused; 0 need you."
assert(carly.context_text(line) == line .. " " .. carly.GUIDE, "status line first")
local long = carly.context_text(string.rep("x", 500))
assert(#long <= 400 and string.sub(long, -#carly.GUIDE) == carly.GUIDE, "long status clipped, guide kept: " .. #long)
print("context fits => true")
print("GUIDE bytes", #carly.GUIDE)
return 0
