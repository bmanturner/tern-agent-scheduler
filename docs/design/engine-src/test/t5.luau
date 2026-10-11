local fake, cron, P = __mods.fake, __mods.cron, __mods.policy
cron.clock = fake
local function T(y,m,d,h,mi,s) return fake.time{year=y,month=m,day=d,hour=h,min=mi,sec=s or 0} end
local function fmt(t) local w=fake.date("*t",t); return string.format("%02d-%02d %02d:%02d:%02d",w.month,w.day,w.hour,w.min,w.sec) end
local out = {}
local function job(expr, cursor, extra) local j={sched={kind="cron",spec=cron.parse(expr)},cursor=cursor} for k,v in pairs(extra or {}) do j[k]=v end return j end
local function run(label, j, now)
  local r = P.decide(j, now)
  out[#out+1] = string.format("%-34s now=%s fire=%s%s missed=%s next=%s done=%s", label, fmt(now),
    r.fire and fmt(r.fire.slot) or "-", r.fire and r.fire.catchup and "(catchup)" or "", r.missed and (r.missed.count.." since "..fmt(r.missed.first)) or "-", r.next_run and fmt(r.next_run) or "-", tostring(r.done))
end
local cur = T(2026,10,9,9,0) -- Fri 09:00 last handled
run("on time (15s late)", job("0 9 * * 1-5", cur), T(2026,10,12,9,0,15))
run("slept Fri night->Mon 10:00", job("0 9 * * 1-5", cur), T(2026,10,12,10,0))
run("slept Fri night->Mon 22:00", job("0 9 * * 1-5", cur), T(2026,10,12,22,0))
run("slept Fri->Wed 10:00 (3 slots)", job("0 9 * * 1-5", cur), T(2026,10,14,10,0))
run("catch_up=skip, 1h late", job("0 9 * * 1-5", cur, {catch_up="skip"}), T(2026,10,12,10,0))
run("not due yet", job("0 9 * * 1-5", cur), T(2026,10,12,8,59))
run("*/15 after 3h sleep", job("*/15 * * * *", T(2026,10,11,12,0)), T(2026,10,11,15,0,40))
local ij = {sched={kind="interval",secs=1800,anchor=T(2026,10,11,8,0)},cursor=T(2026,10,11,10,0)}
run("interval 30m after 2h40 sleep", ij, T(2026,10,11,12,40,10))
local oj = {sched={kind="once",run_at=T(2026,10,11,12,0)},cursor=T(2026,10,11,11,0)}
run("once, fires 10s late", oj, T(2026,10,11,12,0,10))
run("once, 5h late (default 3h window)", oj, T(2026,10,11,17,0))
local oj2 = {sched={kind="once",run_at=T(2026,10,11,12,0)},cursor=T(2026,10,11,11,0),catch_up="always"}
run("once, 5h late, catch_up=always", oj2, T(2026,10,11,17,0))
run("daily, 2h50 late (<3h)", job("0 9 * * *", T(2026,10,10,9,0)), T(2026,10,11,11,50))
run("daily, 3h10 late (>3h)", job("0 9 * * *", T(2026,10,10,9,0)), T(2026,10,11,12,10))
print(table.concat(out,"\n")) return 0
