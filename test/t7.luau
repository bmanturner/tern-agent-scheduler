local fake, cron = __mods.fake, __mods.cron
cron.clock = fake
local s = cron.parse("30 2 * * *")
local t, kind, nom = cron.next(s, fake.time{year=2026,month=3,day=7,hour=12,min=0})
print(kind, nom.hour, nom.min, fake.date("*t",t).hour)
local s2 = cron.parse("30 1 * * *")
local t2, k2 = cron.next(s2, fake.time{year=2026,month=10,day=31,hour=12,min=0}); local t3,k3 = cron.next(s2, fake.time{year=2026,month=11,day=1,hour=0,min=0})
print(k2, k3)
return 0
