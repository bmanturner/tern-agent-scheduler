-- lib/schedule.luau : text -> normalized schedule record (pure). Requires lib/cron.
local cron = require("./cron") -- (in the plugin: require("./cron"))
local M = {}

local DOW = { sun=0, sunday=0, mon=1, monday=1, tue=2, tues=2, tuesday=2, wed=3, wednesday=3,
              thu=4, thur=4, thurs=4, thursday=4, fri=5, friday=5, sat=6, saturday=6 }
local UNIT = { m=60, min=60, mins=60, minute=60, minutes=60, h=3600, hr=3600, hrs=3600, hour=3600, hours=3600,
               d=86400, day=86400, days=86400, w=604800, week=604800, weeks=604800 }
local DOW_CRON = { [0]="SUN","MON","TUE","WED","THU","FRI","SAT" }

local function time_of_day(s: string): (number?, number?)       -- "9am" "9:30pm" "09:00" "noon" ":15"(minute only handled elsewhere)
  if s == "noon" then return 12, 0 elseif s == "midnight" then return 0, 0 end
  local h, m, ap = s:match("^(%d%d?):(%d%d)%s*([ap]m)$")
  if not h then h, m, ap = s:match("^(%d%d?):(%d%d)()$") ap = nil end
  if not h then h, ap = s:match("^(%d%d?)%s*([ap]m)$") m = "0" end
  if not h then h = s:match("^(%d%d?)$") m = "0" end            -- bare "9" = 09:00 (24 h clock)
  if not h then return nil, nil end
  local raw, Mi = tonumber(h) or 0, tonumber(m) or 0
  if ap and (raw < 1 or raw > 12) then return nil, nil end
  local H = raw
  if ap == "pm" and H < 12 then H += 12 elseif ap == "am" and H == 12 then H = 0 end
  if H > 23 or Mi > 59 then return nil, nil end
  return H, Mi
end

local function dow_list(s: string): string?                       -- "mon,thu" "monday and wednesday" "weekdays"
  if s == "weekdays" or s == "every weekday" then return "1-5" end
  if s == "weekends" then return "0,6" end
  local out = {}
  for tok in s:gsub(" and ", ","):gsub("^every%s+", ""):gmatch("[^,%s]+") do
    local d = DOW[tok] or DOW[tok:gsub("s$", "")]
    if d == nil then return nil end
    table.insert(out, DOW_CRON[d])
  end
  return #out > 0 and table.concat(out, ",") or nil
end

-- returns { kind="cron"|"interval"|"once"|"manual", expr=..., input=..., run_at?=..., secs?=... } | nil, hint
function M.parse(input: string, now: number)
  local s = input:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  local rec = function(kind, expr) return { kind = kind, expr = expr, input = input } end
  local function cronrec(expr: string) -- every NL result is re-validated by the cron parser
    local spec, err = cron.parse(expr)
    if not spec then return nil, err end
    return rec("cron", spec.src)
  end
  if s == "" then return nil, "Enter a schedule, e.g. 'weekdays at 9am' or '0 9 * * 1-5'" end
  if s == "manual" or s == "never" or s == "off" then return rec("manual", "") end

  -- (a) raw cron / macro
  local nf = 0 for _ in s:gmatch("%S+") do nf += 1 end
  if s:sub(1, 1) == "@" or (nf == 5 and s:match("^[%d%*]")) then
    local spec, err = cron.parse(s)
    if not spec then return nil, err end
    return rec("cron", spec.src)
  end

  -- (d) relative one-shot: in 20m / in 2 hours
  local n, u = s:match("^in (%d+)%s*(%a+)$")
  if n and UNIT[u] then
    local secs = tonumber(n) * UNIT[u]
    if secs < 60 then return nil, "Minimum is 1 minute" end
    local r = rec("once", "") r.run_at = -((-(now + secs)) // 60) * 60 return r
  end

  -- (c) interval: every 30m / every 2 hours / every hour
  local n2, u2 = s:match("^every (%d*)%s*(%a+)$")
  if n2 and UNIT[u2] then
    local secs = (n2 == "" and 1 or tonumber(n2)) * UNIT[u2]
    if secs < cron.MIN_INTERVAL_S then return nil, "Minimum interval is 5 minutes" end
    if secs > 86400 then return nil, "Maximum interval is 24 hours; for longer periods use 'daily at 09:00', 'weekly' or a cron expression" end
    local r = rec("interval", tostring(secs)) r.secs = secs return r
  end

  -- one-shot "at 15:00": next occurrence of that time, today or tomorrow
  local at = s:match("^at (.+)$")
  if at then
    local H, Mi = time_of_day(at)
    if H then
      local w = cron.clock.date("*t", now)
      local t = cron.resolve(w.year, w.month, w.day, H, Mi)
      if t <= now then
        local y2, m2, d2 = cron.add_days(w.year, w.month, w.day, 1)
        t = cron.resolve(y2, m2, d2, H, Mi)
      end
      local r = rec("once", "") r.run_at = t return r
    end
  end

  -- hourly [at :15]
  local mm = s:match("^hourly at :(%d%d)$") or s:match("^every hour at :(%d%d)$") or s:match("^hourly$") and "00"
  if mm then return cronrec(tonumber(mm) .. " * * * *") end

  -- strip a leading "at"/"on" in "weekdays at 9am", "mon,thu at 18:30", "every monday 9am"
  local days, tod = s:match("^(.-) at ([%w:]+ ?[ap]?m?)$")
  if not days then days, tod = s:match("^(.-) ([%d:]+ ?[ap]?m?)$") end
  if not days then days, tod = s:match("^(%a[%a%s,]-) (noon)$") end
  if days and tod then
    local H, Mi = time_of_day(tod)
    if not H then return nil, "I can't read the time '" .. tod .. "' (try 9am, 09:30, noon)" end
    local hm = Mi .. " " .. H
    if days == "daily" or days == "every day" then return cronrec(hm .. " * * *") end
    local dl = dow_list(days)
    if dl then return cronrec(hm .. " * * " .. dl) end
    local dom = days:match("^monthly on the (%d+)%a*$") or days:match("^monthly on day (%d+)$") or days:match("^monthly$") and "1"
    if dom then return cronrec(hm .. " " .. tonumber(dom) .. " * *") end
    -- (d) dated one-shot: "tomorrow 9am", "today 17:00", "2026-10-12 09:00"
    local base: number? = nil
    local ys, ms, ds = days:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if ys then
      local y, mo, d = tonumber(ys) or 0, tonumber(ms) or 0, tonumber(ds) or 0
      if mo < 1 or mo > 12 or d < 1 or d > cron.dim(y, mo) then return nil, "That date does not exist" end
      base = cron.resolve(y, mo, d, H, Mi)
    elseif days == "tomorrow" or days == "today" then
      local w = cron.clock.date("*t", now)
      local y2, m2, d2 = cron.add_days(w.year, w.month, w.day, days == "tomorrow" and 1 or 0)
      base = cron.resolve(y2, m2, d2, H, Mi)
    end
    if base then
      if base <= now then return nil, "That time has already passed" end
      local r = rec("once", "") r.run_at = base return r
    end
  end
  return nil, "Not understood. Try: 'weekdays at 9am', 'every monday 9am', 'mon,thu 18:30', 'every 2h', 'in 20m', 'tomorrow 9am', or cron '0 9 * * 1-5'"
end
return M
