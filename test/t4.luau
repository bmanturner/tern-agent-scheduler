local fake, cron, sch = __mods.fake, __mods.cron, __mods.schedule
cron.clock = fake
local now = fake.time{year=2026,month=10,day=11,hour=12,min=0,sec=0}
local out = {}
for _, e in ipairs({"0 9 * * 1-5","30 18 * * MON,THU","0 7 * * *","15 * * * *","*/5 * * * *","0 9 1 * *","0 9 1,15 * MON","0 9,17 * * *","0 0 1 JAN *","0 9 * * 0,6","0 9 1 * 1-5","*/20 9-17 * * *"}) do
  out[#out+1] = e.."  =>  "..cron.describe(cron.parse(e))
end
for _, s in ipairs({"at 15:00","in 20m"}) do local r=sch.parse(s,now); out[#out+1]=s.." => "..r.kind.." +"..(r.run_at-now) end
print(table.concat(out,"\n")) return 0
