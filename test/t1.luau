local fake, cron = __mods.fake, __mods.cron
cron.clock = fake
local out = {}
local function fmt(t) local w=fake.date("*t",t); return string.format("%04d-%02d-%02d %02d:%02d %s", w.year,w.month,w.day,w.hour,w.min, fake.date("*t",t) and (fake.date("!*t",t).hour*100+fake.date("!*t",t).min) .."Z") end
local function T(y,m,d,h,mi) return fake.time{year=y,month=m,day=d,hour=h,min=mi,sec=0} end
local function show(expr, after, n)
  local spec, err = cron.parse(expr)
  if not spec then table.insert(out, expr.." => ERR "..err) return end
  local ups = cron.upcoming(spec, n or 3, after)
  local s = {}
  for _,t in ipairs(ups) do table.insert(s, fmt(t)) end
  table.insert(out, expr.." => "..table.concat(s," | "))
end
show("30 2 * * *", T(2026,3,7,12,0), 3)       -- gap
show("30 1 * * *", T(2026,10,31,12,0), 3)     -- overlap
show("0 * * * *", T(2026,11,1,0,30), 6)       -- wildcard across fall back
show("30 * * * *", T(2026,3,8,1,0), 4)        -- wildcard across spring forward
show("0 0 29 2 *", T(2026,1,1,0,0), 2)
show("0 0 29 2 *", T(2096,3,1,0,0), 1)
show("0 0 30 2 *", T(2026,1,1,0,0), 1)
show("0 9 1 * MON", T(2026,10,11,12,0), 4)
show("*/20 9-10 * * 1-5", T(2026,10,9,9,50), 4)
show("0 9 * * 5-7", T(2026,10,11,12,0), 4)
show("0 9 * * FRI-MON", T(2026,10,11,12,0), 4)
show("0 9 31 4,6 *", T(2026,10,11,12,0), 4)
show("@daily", T(2026,10,11,12,0), 2)
show("5 4 */2 * *", T(2026,10,11,12,0), 3)
show("*/2 * * * *", T(2026,10,11,12,0), 3)
print(table.concat(out, "\n")) return 0
