local fake, cron, sch = __mods.fake, __mods.cron, __mods.schedule
cron.clock = fake
local now = fake.time{year=2026,month=10,day=11,hour=12,min=0,sec=0}
for _, s in ipairs({"2026-02-30 09:00","2026-10-12 09:00","monthly on the 40th at 9am","monthly on the 31st at 9am","tomorrow 9am","every 2 days","every 25h"}) do local r,e=sch.parse(s,now); print(s, r and (r.kind..":"..r.expr..(r.run_at and (" +"..(r.run_at-now)) or "")) or ("ERR "..e)) end
return 0
