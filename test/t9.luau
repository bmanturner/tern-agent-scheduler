-- Tern's Luau reads os.time(table) as UTC while os.date("*t") is local. The default cron clock must
-- still map local wall times to the right instants (regression: weekdays 9am fired at 08:00 CDT).
local fake = __mods.fake
local function timegm(tb)
  local y, m, d = tb.year, tb.month, tb.day
  y -= m <= 2 and 1 or 0
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  return days * 86400 + tb.hour * 3600 + tb.min * 60 + (tb.sec or 0)
end
os.time = function(tb) if tb == nil then return 0 end return timegm(tb) end
os.date = fake.date
local cron = __mods.cron -- loaded after the patch, so its default clock uses the patched os
local function T(y, m, d, h, mi) return fake.time({ year = y, month = m, day = d, hour = h, min = mi, sec = 0 }) end
local function show(label, t, kind)
  local w = fake.date("*t", t)
  print(string.format("%s => %04d-%02d-%02d %02d:%02d %s", label, w.year, w.month, w.day, w.hour, w.min, kind or ""))
end
local t, kind = cron.resolve(2026, 10, 12, 9, 0)
assert(t == T(2026, 10, 12, 9, 0), "09:00 CDT")
show("resolve 2026-10-12 09:00", t, kind)
t, kind = cron.resolve(2026, 3, 8, 2, 30)
assert(kind == "gap" and t == T(2026, 3, 8, 3, 0), "spring-forward gap resolves to 03:00 CDT")
show("resolve 2026-03-08 02:30", t, kind)
t, kind = cron.resolve(2026, 11, 1, 1, 30)
assert(kind == "overlap", "fall-back overlap")
show("resolve 2026-11-01 01:30", t, kind)
local spec = cron.parse("0 9 * * 1-5")
local nxt = cron.next(spec, T(2026, 10, 11, 10, 0))
assert(nxt == T(2026, 10, 12, 9, 0), "next weekday 09:00")
show("next 0 9 * * 1-5 after Sun 10:00", nxt)
return 0
