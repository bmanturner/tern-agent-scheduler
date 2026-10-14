-- Manager timeline, retained counters, seen behavior and cron humanizer.
tern.ui = {
 span = function(t, s) return { t = t, s = s } end,
 node = function(k, p, c) return { k = k, p = p, c = c } end,
}
local jobs, ledger, runner = __mods.jobs, __mods.ledger, __mods.runner
local H, T, C = __mods.mgr_history, __mods.mgr_timeline, __mods.mgr_common
fake.dirs["/home/u/proj"] = true
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))
runner.load()
local now = os.time()
local job = jobs.create({ name = "Recurring", when = "every 2h", cwd = "/home/u/proj" }, "review", "user", now)
local manual = jobs.create({ name = "Manual", when = "manual", cwd = "/home/u/proj" }, "review", "user", now)
local function finish(i, status)
 local t = now - 300 + i
 local r = ledger.new(job, { run_id = "r_" .. job.id:sub(3) .. "_" .. i, now = t, slot = t })
 ledger.transition(r, status, nil, { summary = "Result " .. i }, t)
 H.record(r)
 return r
end
finish(1, "failed")
finish(2, "missed")
finish(3, "cancelled")
assert(H.ensure(job.id).totals.failed == 1)
assert(H.ensure(job.id).totals.missed == 1)
assert(H.ensure(job.id).failed, "missed/cancelled must not clear the failure")
local function base(live)
 local rows = {
  { sec = "upcoming", key = job.id, job = job, js = jobs.state(job.id), kind = "job" },
  { sec = "upcoming", key = manual.id, job = manual, js = jobs.state(manual.id), kind = "job" },
 }
 local sections = { { id = "upcoming", rows = rows } }
 if live then table.insert(sections, { id = "running", rows = { { sec = "running", key = "r_live", kind = "run", job = job, run = { run_id = "r_live", job_id = job.id } } } }) end
 return { sections = sections }
end
local state = { looked_at = now - 400, mode = "list", cx = { pane = 123, render = function() end } }
local m = T.model(state, base(false))
assert(#m.sections[1].rows == 3)
assert(m.sections[1].rows[1].run.state == "failed", "results ascend toward now")
assert(m.sections[#m.sections].title == "Paused & needs fixing")
local busy = T.model(state, base(true))
local next_count, live_count = 0, 0
for _, r in busy.flat do
 if r.job.id == job.id and r.sec == "upcoming" then next_count += 1 end
 if r.job.id == job.id and r.sec == "running" then live_count += 1 end
end
assert(next_count == 0 and live_count == 1, "running job has no next-run duplicate")
print("PASS timeline order, manual group, running deduplication, missed != failed")
for i = 4, 84 do finish(i, "skipped") end
ledger.prune(job.id, { retain_runs = 5, retain_days = 90 }, now)
local h = H.ensure(job.id)
assert(h.totals.total == 84 and h.pending.total == 84, "counts survive pruning")
m = T.model(state, base(false))
local summary = m.sections[1].rows[#m.sections[1].rows]
assert(summary.error:find("84 runs", 1, true), summary.error)
assert(summary.error:find("1 failed, shown above", 1, true), summary.error)
assert(not summary.error:find("✗", 1, true), "summary uses words, not glyph counts")
print("PASS backlog counts independent of retention")
-- A newer completion must remain pending when an older three-second cohort fades.
local cutoff = now - 219
H.clear(cutoff)
assert(h.pending.total == 3, "only results through the checkpoint are seen")
assert(jobs.settings().last_looked == cutoff)
T.clear(state)
assert(h.pending.total == 0 and state.looked_at == now)
print("PASS host checkpoint and mark-all-seen")
for expr, expected in { ["0 */2 * * *"] = "Every 2 hours", ["0 */5 * * *"] = "Every 5 hours", ["*/7 * * * *"] = "Every 7 minutes", ["*/15 * * * *"] = "Every 15 minutes" } do
 assert(__mods.cron.describe(__mods.cron.parse(expr)) == expected, expr)
end
assert(jobs.set_settings({ manager_layout = "classic", manager_results = "stay" }))
assert(not jobs.set_settings({ manager_layout = "bad" }))
print("PASS cron steps and manager setting validation")
-- Stay does not schedule a fade. Fade pauses under sheets and checks pane liveness.
fake.live_panes = { "123" }
local result = { key = "result", job = job, run = { state = "finished", ended = now, summary = "Reviewed" } }
T.result(state, result)
fake.advance(3100)
assert(next(state.seen_results) == nil, "stay keeps the highlight")
jobs.set_settings({ manager_results = "fade" })
T.result(state, result)
state.sheet = { kind = "settings" }
fake.advance(3100)
assert(next(state.seen_results) == nil, "covered list is not marked seen")
state.sheet = nil
T.result(state, result)
fake.advance(3100)
assert(next(state.seen_results) ~= nil, "three-second fade")
print("PASS stay/fade settings, sheet guard and live-pane timer")
-- Review regressions: start times agree, future minutes ceil, previews omit heading syntax.
assert(C.in_text(now + 1501, now) == "in 26m")
assert(C.in_text(now + 1, now) == "in 1m")
assert(C.in_text(now + 6 * 3600 + 61, now) == "in 6h 2m")
assert(C.in_text(now, now) == "now")
assert(__mods.mgr_detail.prompt_preview("\n# Nightly tests\n\nDo the work.\nExtra") == "Nightly tests · Do the work.")
result.run.started = now - 600
result.run.created = now - 601
local result_node = T.result(state, result)
assert(result_node.p.label[1].t == __mods.timefmt.date("%a %H:%M", now - 600) .. "  ")
local timed = T.model(state, base(false), now)
assert(timed.sections[2].title == "now · " .. __mods.timefmt.date("%H:%M", now))
