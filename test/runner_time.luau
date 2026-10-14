-- Presentation, host detection/cache, persisted choice and host -> window propagation.
local timefmt, host, bins = __mods.timefmt, __mods.time_host, __mods.bins
local jobs, cron = __mods.jobs, __mods.cron
local midnight = fake.chicago(2026, 10, 13, 0, 0)
local noon = fake.chicago(2026, 10, 13, 12, 0)
fake.set_wall(noon)
for mode, expected in { ["12h"] = { "12:00 am", "12:00 pm", "2:00 pm" }, ["24h"] = { "00:00", "12:00", "14:00" } } do
 timefmt.set(mode)
 assert(timefmt.date("%H:%M", midnight) == expected[1])
 assert(timefmt.date("%H:%M", noon) == expected[2])
 assert(timefmt.date("%H:%M", noon + 7200) == expected[3])
 assert(timefmt.clock(0, 0) == expected[1] and timefmt.clock(12, 0) == expected[2])
 assert(cron.describe(cron.parse("0 14 * * *")):find(expected[3], 1, true))
 assert(__mods.ledger.day_time(noon):find(expected[2], 1, true))
 assert(jobs.describe({ schedule = { kind = "once", run_at = noon } }):find(expected[2], 1, true))
 assert(__mods.mgr_common.abs(noon):find(expected[2], 1, true))
 assert(__mods.conditions.hhmm(0) == expected[1])
end
print("PASS midnight/noon and shared schedule, manager, condition and notification clocks")

local function result(stdout, status)
 return { stdout = stdout, status = status or 0, timed_out = false }
end
local function detect(os_name, twelve, twenty_four, locale)
 bins.cache().time_format = nil
 tern.runtime = { os = os_name }
 fake.override.defaults = function(argv)
  return result(if argv[4] == "AppleICUForce12HourTime" then twelve else twenty_four)
 end
 fake.override.locale = function() return result(locale) end
 host.configure("automatic")
 fake.advance(0)
 return timefmt.get()
end
assert(detect("macos", "1\n", "0\n", 't_fmt="%H:%M:%S"') == "12h")
assert(detect("macos", "0\n", "1\n", 't_fmt="%I:%M:%S %p"') == "24h")
assert(detect("macos", "", "", 't_fmt="%I:%M:%S %p"') == "12h")
assert(detect("linux", "", "", 't_fmt="%I:%M:%S"') == "12h")
assert(detect("linux", "", "", 't_fmt="%H:%M:%S %p"') == "12h")
assert(detect("linux", "", "", 't_fmt="%H:%M:%S"\nt_fmt_ampm="%I:%M:%S %p"') == "24h")
assert(detect("linux", "", "", "garbage") == "24h")
bins.cache().time_format = nil
fake.override.locale = function() error("spawn failed") end
host.configure("automatic")
assert(timefmt.get() == "24h")
bins.cache().time_format = nil
fake.override.locale = function() return result("", 1) end
host.configure("automatic")
fake.advance(0)
assert(timefmt.get() == "24h")
assert(detect("linux", "", "", 't_fmt="%I:%M %p"') == "12h")
local cached = tern.json.decode(fake.read("/d/cache.json"))
assert(cached.time_format == "12h")
local calls = #fake.calls
host.configure("automatic")
assert(#fake.calls == calls and timefmt.get() == "12h", "cache avoids another probe")
print("PASS macOS preferences, locale detection, fallback and persisted probe cache")

jobs.load(noon)
assert(jobs.settings().time_format == "automatic")
for _, mode in { "12h", "24h", "automatic" } do
 assert(jobs.set_settings({ time_format = mode }))
 assert(tern.json.decode(fake.read("/d/settings.json")).time_format == mode)
 jobs.load(noon)
 assert(jobs.settings().time_format == mode)
 assert(timefmt.get() == (if mode == "24h" then "24h" else "12h"))
end
assert(not jobs.set_settings({ time_format = "bad" }))
assert(#fake.calls == calls, "explicit settings and cached automatic never probe")
-- An asynchronous detection must not overwrite a newer explicit choice.
bins.cache().time_format = nil
host.configure("automatic")
assert(jobs.set_settings({ time_format = "24h" }))
fake.advance(0)
assert(timefmt.get() == "24h")
print("PASS setting default, validation, persistence and in-flight preference change")

assert(jobs.set_settings({ time_format = "12h" }))
__mods.snapshot.publish({ inflight = {}, managers = {}, setup_ok = true, scheduler = "ok", welcome = false }, noon)
assert(tern.json.decode(fake.read("/d/snapshot.json")).time_format == "12h")
timefmt.set("24h") -- stand in for the window's separate module instance
local run = tern.process.run
local window_spawns = 0
tern.process.run = function()
 window_spawns += 1
 error("window must never spawn")
end
__mods.wsnap.reset()
assert(__mods.wsnap.poll())
assert(timefmt.date("%H:%M", noon) == "12:00 pm")
assert(window_spawns == 0)
tern.process.run = run
-- A new host module instance reuses the on-disk cache after a plugin reload.
__mods.bins = nil
__mods.time_host = nil
calls = #fake.calls
__mods.time_host.configure("automatic")
assert(timefmt.get() == "12h" and #fake.calls == calls)
print("PASS snapshot carries resolved format; window consumes it without spawning")
