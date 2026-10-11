local fake, cron = __mods.fake, __mods.cron
cron.clock = fake
local out = {}
local function fmt(t) local w=fake.date("*t",t); local u=fake.date("!*t",t); return string.format("%04d-%02d-%02d %02d:%02d (utc %02d:%02d)", w.year,w.month,w.day,w.hour,w.min,u.hour,u.min) end
local function T(y,m,d,h,mi) return fake.time{year=y,month=m,day=d,hour=h,min=mi,sec=0} end
local function show(label, expr, after, n)
  local spec, err = cron.parse(expr)
  local ups = cron.upcoming(spec, n or 2, after)
  local s = {} for _,t in ipairs(ups) do table.insert(s, fmt(t)) end
  table.insert(out, label.." "..expr.." => "..table.concat(s," | "))
end
for _, mode in ipairs({"bsd","alt"}) do
  fake.mode = mode
  table.insert(out, "== mode "..mode)
  show("gap", "30 2 * * *", T(2026,3,7,12,0), 2)
  show("gap2", "0 2 8 3 *", T(2026,1,1,0,0), 2)
  show("overlap", "30 1 * * *", T(2026,10,31,12,0), 2)
  show("afterCDT 01:10", "30 1 * * *", 6*3600+10*60 + fake.time{year=2026,month=11,day=1,hour=0,min=0}-5*3600+5*3600 , 2)
end
-- after in second pass of repeated hour: 01:10 CST = 07:10Z
local after2 = (fake.time{year=2026,month=11,day=1,hour=0,min=0,sec=0}) -- 00:00 CDT = 05:00Z
after2 = after2 + 2*3600 + 10*60 -- 07:10Z = 01:10 CST
fake.mode="bsd"
show("2nd pass 01:10 CST", "30 1 * * *", after2, 2)
show("2nd pass wild */20", "*/20 * * * *", after2, 3)
local s = cron.parse("0 9 * * 1-5")
out[#out+1] = "mingap weekdays "..cron.min_gap(s, T(2026,10,9,10,0))
out[#out+1] = "period_at fri "..cron.period_at(s, T(2026,10,9,9,0))
out[#out+1] = "interval "..cron.next_interval(1000, 1800, 5000)..","..cron.next_interval(1000,1800,500)
local t0=os.clock(); for i=1,200 do cron.next(cron.parse("0 0 29 2 *"), T(2096,3,1,0,0)) end
out[#out+1] = "feb29 2100-gap x200 s="..(os.clock()-t0)
show("2nd pass hourly", "0 * * * *", after2, 3)
show("pre-pass hourly", "0 * * * *", after2-4*3600, 5)
print(table.concat(out,"\n")) return 0
