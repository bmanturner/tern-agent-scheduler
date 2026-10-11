local fake, cron, sch = __mods.fake, __mods.cron, __mods.schedule
cron.clock = fake
local now = fake.time{year=2026,month=10,day=11,hour=12,min=0,sec=0}
local out = {}
for _, s in ipairs({"weekdays at 9am","every monday 9am","mon,thu 18:30","monday and wednesday at 9am","daily at 7am","every day at noon","hourly at :15","hourly","every 30m","every 2 hours","every hour","every 2m","in 20m","tomorrow 9am","today 5pm","2026-10-12 09:00","monthly on the 15th at 8:30","0 9 * * 1-5","@weekly","every friday at 5:30pm","weekends 10:00","tomorrow at 13:00","at 15:00","gibberish","manual","weekdays at 25:00"}) do
  local r, e = sch.parse(s, now)
  out[#out+1] = string.format("%-32s => %s", s, r and (r.kind..": "..r.expr..(r.run_at and (" run_at+"..(r.run_at-now)) or "")) or ("ERR "..e))
end
print(table.concat(out,"\n")) return 0
