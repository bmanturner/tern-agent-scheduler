-- fake America/Chicago clock; mimics macOS mktime (gap shifts forward, overlap prefers DST)
local M = {}
local function dfc(y,m,d) y -= m<=2 and 1 or 0; local era=(y>=0 and y or y-399)//400; local yoe=y-era*400
  local doy=(153*(m+(m>2 and -3 or 9))+2)//5+d-1; local doe=yoe*365+yoe//4-yoe//100+doy; return era*146097+doe-719468 end
local function cfd(z) z+=719468; local era=(z>=0 and z or z-146096)//146097; local doe=z-era*146097
  local yoe=(doe-doe//1460+doe//36524-doe//146096)//365; local y=yoe+era*400; local doy=doe-(365*yoe+yoe//4-yoe//100)
  local mp=(5*doy+2)//153; local d=doy-(153*mp+2)//5+1; local m=mp+(mp<10 and 3 or -9); return y+(m<=2 and 1 or 0),m,d end
local function nth_sunday(y,m,n) local first=dfc(y,m,1); local dow=(first+4)%7; local off=(7-dow)%7; return dfc(y,m,1+off+7*(n-1)) end
local function dst_range(y) -- UTC instants: starts 08:00Z 2nd Sun Mar (02:00 CST), ends 07:00Z 1st Sun Nov (02:00 CDT)
  return nth_sunday(y,3,2)*86400+8*3600, nth_sunday(y,11,1)*86400+7*3600 end
local function off(t) local y=cfd(t//86400); local s,e=dst_range(y); return (t>=s and t<e) and -5*3600 or -6*3600 end
M.mode = "bsd"
local function fields(secs)
  local days=secs//86400; local rem=secs-days*86400; local y,m,d=cfd(days)
  return {year=y,month=m,day=d,hour=rem//3600,min=(rem%3600)//60,sec=rem%60,wday=(days+4)%7+1,yday=0,isdst=false}
end
function M.date(fmt,t) if fmt=="*t" then return fields(t+off(t)) elseif fmt=="!*t" then return fields(t) end error("fmt") end
function M.time(tb)
  local y,mo=tb.year,tb.month; y+=(mo-1)//12; mo=(mo-1)%12+1
  local civ=dfc(y,mo,1)*86400+(tb.day-1)*86400+tb.hour*3600+tb.min*60+(tb.sec or 0)
  -- candidate instants for each offset
  local a=civ+5*3600 -- as CDT
  local b=civ+6*3600 -- as CST
  local av=off(a)==-5*3600; local bv=off(b)==-6*3600
  if av and bv then return a end         -- overlap: prefer DST (first)
  if av then return a end
  if bv then return b end
  return M.mode=="bsd" and b or a        -- gap: bsd = pre-gap offset (CST) -> shifts forward; glibc-ish alt = a
end
return M
