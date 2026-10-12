-- Review fixes in the IO modules: run marker (F1), built-in roles (F10), provider errors in the session
-- tail (F11), invalidation on raised spawns (F12), omp lookup (F18/F68), summary clean-up (F17), notify.plain (F65).
local tern_state, session_tail, roles, bins, notify = __mods.tern_state, __mods.session_tail, __mods.roles, __mods.bins, __mods.notify

local function res(stdout)
	return { status = 0, stdout = stdout, stderr = "", timed_out = false }
end

-- F1: only a launch argv (`@<run dir>/prompt.md`) carries the marker; a resumed conversation does not
local launch = {
	args = { "-l", "-c", "'/opt/homebrew/bin/omp' --model '@default' --session-dir '/d/runs/j_ab12cd34/r_ab12cd34_1760000000/session' "
		.. "--config '/d/runs/j_ab12cd34/r_ab12cd34_1760000000/omp.yml' '@/d/runs/j_ab12cd34/r_ab12cd34_1760000000/prompt.md' 'Run the scheduled job.'" },
}
local spaced = {
	args = { "-l", "-c", "'/opt/homebrew/bin/omp' '@/Users/u/Library/Application Support/Tern/plugin-data/x/runs/j_ab12cd34/r_ab12cd34_5/prompt.md' 'Run.'" },
}
local resume = {
	args = { "-l", "-c", "'/opt/homebrew/bin/omp' --session-dir '/d/runs/j_ab12cd34/r_ab12cd34_1760000000/session' --resume '/d/runs/j_ab12cd34/r_ab12cd34_1760000000/session/a.jsonl' "
		.. "--config '/d/runs/j_ab12cd34/r_ab12cd34_1760000000/omp.yml'" },
}
local bare = { args = { "-l" } }
assert(tern_state.marker(launch) == "j_ab12cd34/r_ab12cd34_1760000000", "launch argv is marked: " .. tostring(tern_state.marker(launch)))
assert(tern_state.marker(spaced) == "j_ab12cd34/r_ab12cd34_5", "launch argv with a spaced data path is marked")
assert(tern_state.marker(resume) == nil, "resume argv is not marked")
assert(tern_state.marker(bare) == nil, "bare login shell is not marked")
print("PASS F1 marker only on launch argv")

-- F14: sessions listed under `detached` still map their panes
local st = tern_state.parse(
	'{"sessions":[],"detached":[{"id":7,"name":"Scheduled runs","tabs":[{"id":8,"name":"t","blocks":[{"id":9,"args":["-l","-c","omp \'@/d/runs/j_ab12cd34/r_ab12cd34_1/prompt.md\'"]}]}]}]}'
)
assert(st ~= nil and st.session_ids["Scheduled runs"] == "7", "detached session id mapped")
assert(st.by_run["j_ab12cd34/r_ab12cd34_1"] ~= nil and st.by_run["j_ab12cd34/r_ab12cd34_1"].session_shown == false, "detached pane mapped as hidden")
print("PASS F14 detached sessions parsed")

-- F10: an empty modelRoles still lists the built-in roles; configured custom roles are added, kind roles stay hidden
fake.override.config = function()
	return res('{"key":"modelRoles","value":{},"type":"record"}')
end
local listed
roles.list(fake.omp_bin, "/home/u/proj", function(l)
	listed = l
end)
fake.advance(100)
assert(listed ~= nil, "roles listed")
print("roles (empty config): " .. table.concat(listed, ","))
assert(table.concat(listed, ",") == "default,smol,task,plan,slow,commit,advisor,tiny,memory,vision", "built-in roles present")
roles.invalidate("/home/u/proj")
fake.override.config = function()
	return res('{"key":"modelRoles","value":{"default":"a/b","zeta":"c/d","judge":"e/f"},"type":"record"}')
end
roles.list(fake.omp_bin, "/home/u/proj", function(l)
	listed = l
end)
fake.advance(100)
print("roles (custom): " .. table.concat(listed, ","))
assert(listed[#listed] == "zeta" and not table.find(listed, "judge"), "custom added, kind role hidden")
assert(roles.selector("/home/u/proj", "default") == "a/b", "selector kept for configured roles")
fake.override.config = nil
print("PASS F10 built-in roles merged")

-- F11: a final assistant message that is a provider error fails the run instead of reporting stale narration
local text = table.concat({
	'{"type":"session","id":"sess1"}',
	'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Let me check the tests"}],"stopReason":"toolUse"}}',
	'{"type":"message","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"429 rate limited"}}',
}, "\n")
local facts = session_tail.parse(text, false, "/d/runs/j/r/session/x_sess1.jsonl")
assert(facts.failed_reason == "429 rate limited", "failed_reason set: " .. tostring(facts.failed_reason))
assert(facts.completed_turn == true, "completed_turn true")
assert(facts.summary == "429 rate limited", "summary is the error, not stale narration")
local fine = session_tail.parse(
	'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"RESULT: pong"}],"stopReason":"stop"}}',
	false,
	"/d/x_s.jsonl"
)
assert(fine.failed_reason == nil and fine.completed_turn == true and fine.summary == "pong", "normal finish unchanged")
local recovered = session_tail.parse(
	'{"type":"message","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"boom"}}\n'
		.. '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"RESULT: ok"}],"stopReason":"stop"}}',
	false,
	"/d/x_s.jsonl"
)
assert(recovered.failed_reason == nil and recovered.summary == "ok", "a later good message clears the error")
print("PASS F11 provider error fails the run")

-- F17: markdown and dashes around RESULT lines
local s1 = session_tail.summarize("**RESULT: pong**")
assert(s1 == "pong", "markdown stripped: " .. s1)
local s2, why2 = session_tail.summarize("RESULT: FAILED \u{2014} no access")
assert(s2 == "no access" and why2 == "no access", "em dash after FAILED: " .. s2)
local s3, why3 = session_tail.summarize("RESULT: FAILED - no access")
assert(s3 == "no access" and why3 == "no access", "hyphen after FAILED")
local s4, why4 = session_tail.summarize("RESULT: FAILED: disk full")
assert(s4 == "disk full" and why4 == "disk full", "colon after FAILED")
local s5, why5 = session_tail.summarize("RESULT: FAILED")
assert(why5 == "the agent reported failure" and s5 == why5, "bare FAILED")
print("PASS F17 summaries cleaned")

-- F18/F68: omp_path first, then ~/.bun/bin, and an interactive login-shell lookup that ignores rc noise
local function resolve_with(settings)
	local got, err
	bins.resolve(settings, function(b, e)
		got, err = b, e
	end, true)
	fake.advance(2000)
	return got, err
end
local custom_omp = "/home/u/custom/omp"
fake.installed = { [fake.tern_bin] = "tern 0.8.2 (test)\n", [custom_omp] = "omp/18.9.1\n", ["/home/u/.bun/bin/omp"] = "omp/18.9.1\n" }
local b1 = resolve_with({ omp_path = custom_omp })
assert(b1 ~= nil and b1.omp == custom_omp, "omp_path setting wins")
fake.installed[custom_omp] = nil
local b2 = resolve_with({})
assert(b2 ~= nil and b2.omp == "/home/u/.bun/bin/omp", "~/.bun/bin/omp is a candidate: " .. tostring(b2 and b2.omp))
fake.installed["/home/u/.bun/bin/omp"] = nil
fake.installed["/home/u/nvm/bin/omp"] = "omp/18.9.1\n"
fake.override.zsh = function()
	return res("Last login: today\nwelcome to zsh\n/home/u/nvm/bin/omp\n")
end
fake.calls = {}
local b3 = resolve_with({})
assert(b3 ~= nil and b3.omp == "/home/u/nvm/bin/omp", "last absolute-path line of the lookup is used: " .. tostring(b3 and b3.omp))
local lookup = fake.calls_of("zsh")[1]
assert(lookup ~= nil and fake.join(lookup) == "/bin/zsh -l -i -c command -v omp", "interactive login lookup: " .. tostring(lookup and fake.join(lookup)))
fake.override.zsh = nil
print("PASS F18/F68 omp lookup")

-- F15: a forced re-resolve keeps the known paths while probes run
fake.installed = { [fake.tern_bin] = "tern 0.8.2 (test)\n", [fake.omp_bin] = "omp/18.9.1\n" }
resolve_with({})
bins.resolve({}, function() end, true)
assert(bins.found().tern == fake.tern_bin and bins.found().omp == fake.omp_bin, "paths kept while re-resolving")
fake.advance(2000)
print("PASS F15 found kept during re-resolve")

-- F12: a raised `tern ls` drops the cached paths
assert(bins.found().tern == fake.tern_bin, "resolved before")
fake.override.ls = function()
	error("No such file or directory")
end
local snap_err
tern_state.snapshot(fake.tern_bin, function(s, r)
	snap_err = r
end)
fake.advance(100)
assert(snap_err ~= nil and bins.found().tern == nil and bins.found().omp == nil, "cached bins invalidated")
fake.override.ls = nil
print("PASS F12 raised spawn invalidates bins")

-- F65: plain OS notification, argv only
fake.calls = {}
notify.plain("Agent Scheduler", "Carly scheduled nightly \u{00B7} Hands-off \u{00B7} ~/proj")
fake.advance(100)
local osa = fake.calls_of("osascript")
assert(#osa == 1, "one osascript call")
assert(osa[1][#osa[1] - 1] == "Carly scheduled nightly \u{00B7} Hands-off \u{00B7} ~/proj" and osa[1][#osa[1]] == "Agent Scheduler", "text and title passed as argv")
print("PASS F65 notify.plain")
