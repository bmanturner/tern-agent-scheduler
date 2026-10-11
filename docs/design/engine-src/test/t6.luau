local fake, cron = __mods.fake, __mods.cron
cron.clock = fake
local function T(y,m,d,h,mi) return fake.time{year=y,month=m,day=d,hour=h,min=mi,sec=0} end
local function dowof(w) return w.wday-1 end
local function match(spec,w)
  if not (spec.minute[w.min] and spec.hour[w.hour] and spec.month[w.month]) then return false end
  local a,b = spec.dom[w.day]==true, spec.dow[dowof(w)]==true
  if spec.dom_star or spec.dow_star then return a and b end
  return a or b
end
local out, bad = {}, 0
local start = T(2026,10,28,0,0)
for _, e in ipairs({"*/7 * * * *","17 3,15 * * 1-5","0 0 1,15 * *","30 9 * * MON","0 */6 * * *","59 23 31 * *","15 10 29 2 *","*/10 9-17 * * 1-5","5 * * * *","0 12 * * SUN","45 4 1 * 0"}) do
  local spec = cron.parse(e)
  local got = cron.upcoming(spec, 60, start, 20000)
  -- oracle: minute scan 120 days
  local want, t = {}, start
  for i=1,120*1440 do t = start + i*60; if match(spec, fake.date("*t",t)) then want[#want+1]=t; if #want==60 then break end end end
  local same = #got>=#want
  if same then for i=1,#want do if got[i]~=want[i] then same=false; out[#out+1]=e.." first diff idx "..i.." got "..got[i].." want "..want[i] break end end end
  if not same then bad+=1 end
  out[#out+1]=e.." n="..#got.."/"..#want.." "..(same and "OK" or "DIFF")
end
print(table.concat(out,"\n")) return 0
