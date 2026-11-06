-- Native job form: collapsed conditions retain drafts and share keyboard structure.
tern.ui = {
 span = function(t, s) return { t = t, s = s } end,
 node = function(k, p, c) return { k = k, props = p, children = c } end,
}
local F, P = __mods.mgr_form, __mods.mgr_prefs
local form = F.new({ name = "Review", prompt = "Review changes", cwd = "/home/u/proj" }, nil, "New job")
local state = { form = form, cx = { render = function() end } }
form.page = "only_when"
local sections = F.sections(state)
assert(#P.flat(sections) == 6, "only status and five toggles when all off")
local now = P.find(sections, "c_now")
assert(now.control.k == "keys" and now.control.act == nil)
assert(now.hint == "Nothing to check: this job always runs when due.")
form.focus = "c_now"
assert(not F.key(state, { name = "enter" }), "no keyboard check with all off")
F.event(state, { ev = "action", act = "c_now" })
assert(form.checking == nil and form.verdict == nil)
print("PASS all-off conditions collapse; Check now absent and inert")
local groups = {
 { "c_commits", "c_branch", "c_paths" },
 { "c_window", "c_days", "c_from", "c_to", "c_outside" },
 { "c_limits", "c_runs", "c_usd", "c_per" },
 { "c_check", "c_script" },
 { "c_ask", "c_ask_prompt", "c_ask_role" },
}
form.c_branch = "develop"
__mods.textfield.set(form.c_paths, "src docs")
__mods.textfield.set(form.c_script, "./check.sh")
__mods.textfield.set(form.c_ask_prompt, "Is there work?")
for _, group in groups do
 local toggle = group[1]
 F.event(state, { ev = "change", item = toggle, value = true })
 sections = F.sections(state)
 assert(form.focus == toggle)
 assert(P.find(sections, "c_now").control.label == "Check now")
 for i = 2, #group do assert(P.find(sections, group[i]) ~= nil, group[i]) end
 assert(P.move(sections, toggle, 1) == group[2], "keyboard enters expanded fields")
 F.event(state, { ev = "change", item = toggle, value = false })
 sections = F.sections(state)
 for i = 2, #group do assert(P.find(sections, group[i]) == nil, group[i]) end
 assert(form.focus == toggle, "collapse keeps focus on switch")
 assert(P.find(sections, "c_now").control.act == nil)
end
assert(form.c_branch == "develop" and form.c_paths.text == "src docs")
assert(form.c_script.text == "./check.sh" and form.c_ask_prompt.text == "Is there work?")
assert(form.c_from == 540 and form.c_to == 1080 and form.c_runs == 3)
assert(next(F.only_when_input(form)) == nil, "hidden drafts do not enable conditions")
print("PASS every toggle reveals dependents, preserves drafts and keyboard order")
form.c_commits = true
form.verdict = { ok = true, results = { { type = "commits", result = "pass", text = "New commits" } } }
assert(P.find(F.sections(state), "c_commits_now") ~= nil)
F.event(state, { ev = "change", item = "c_commits", value = false })
assert(form.verdict == nil and P.find(F.sections(state), "c_commits_now") == nil)
print("PASS collapsing clears stale Check now results")
form.page = "job"
form.catch_up_window_s = 5400
local row = P.find(F.sections(state), "catch_up")
assert(row.control.options[1].label == "Run once if under 90m late")
assert(row.control.options[2].label == "Run once, however late")
assert(row.control.options[3].label == "Skip missed runs")
print("PASS compact missed-run labels preserve threshold and policy")

-- Stop after menu reaches the validator's limit, and every choice validates.
local STOPS, const = __mods.mgr_common.STOPS, __mods.const
assert(STOPS[#STOPS].s == const.MAXRUN_MAX_S, "longest stop is the 8h limit")
for _, o in STOPS do
	local ok, errs = __mods.validate.job({ max_runtime_s = o.s }, { jobs = {}, now = 0, home = "/home/u" })
	assert(ok, o.label .. " validates: " .. tostring(errs and errs.max_runtime_s))
end
print("PASS stop menu covers 5 min to 8 hours")

-- After a validation error, the prompt editor and text fields never trap focus.
do
	local f2 = F.new({ name = "Trap", prompt = "", cwd = "/home/u/proj" }, nil, "New job")
	local s2 = { form = f2, cx = { render = function() end, focus = function() end, cols = 100 } }
	F.save(s2, false)
	assert(f2.focus == "prompt" and f2.submitted, "error sends focus to Prompt")
	F.key(s2, { name = "enter" })
	assert(f2.editing ~= nil and f2.editing.row == "prompt", "enter opens the prompt editor")
	F.key(s2, { name = "h", text = "h" })
	F.key(s2, { name = "tab" })
	assert(f2.editing == nil and f2.focus == "when" and f2.prompt.text == "h", "tab leaves the prompt editor, keeping text")
	F.key(s2, { name = "tab", shift = true })
	assert(f2.focus == "prompt", "shift+tab moves back")
	F.key(s2, { name = "down" })
	F.key(s2, { name = "enter" })
	assert(f2.editing ~= nil and f2.editing.row == "when", "When is editable")
	F.event(s2, { ev = "select", id = "main.prefs", item = "folder" })
	assert(f2.editing == nil and f2.focus == "folder", "a click on Folder leaves the When edit")
end
print("PASS no focus trap after a validation error")
