local timefmt = require("./timefmt")
-- lib/cron.luau : pure, no tern.* calls. Local time zone only.
local cron = {}
-- cron.clock = { time, date }: injectable for tests; the default is set after civil_secs below.

local HORIZON_YEARS = 9 -- covers the 8-year Feb-29 gap across 2100
local MIN_INTERVAL_S = 300

local MONTH_NAMES = { JAN=1, FEB=2, MAR=3, APR=4, MAY=5, JUN=6, JUL=7, AUG=8, SEP=9, OCT=10, NOV=11, DEC=12 }
local DOW_NAMES = { SUN=0, MON=1, TUE=2, WED=3, THU=4, FRI=5, SAT=6 }
local MACROS = {
  ["@hourly"] = "0 * * * *", ["@daily"] = "0 0 * * *", ["@midnight"] = "0 0 * * *",
  ["@weekly"] = "0 0 * * 0", ["@monthly"] = "0 0 1 * *",
  ["@yearly"] = "0 0 1 1 *", ["@annually"] = "0 0 1 1 *",
}

-- ---------- pure civil-calendar arithmetic (no os.*) ----------
local function days_from_civil(y: number, m: number, d: number): number
  y -= m <= 2 and 1 or 0
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end
local function civil_from_days(z: number): (number, number, number)
  z += 719468
  local era = (z >= 0 and z or z - 146096) // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp + (mp < 10 and 3 or -9)
  return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end
function cron.add_days(y: number, m: number, d: number, n: number): (number, number, number)
  return civil_from_days(days_from_civil(y, m, d) + n)
end
local function is_leap(y: number): boolean return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end
local DIM = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function dim(y: number, m: number): number return (m == 2 and is_leap(y)) and 29 or DIM[m] end
local function dow_of(y: number, m: number, d: number): number return (days_from_civil(y, m, d) + 4) % 7 end
local function wkey(y, m, d, h, mi, s) -- monotone over wall-clock fields
  return ((((y * 12 + m) * 31 + d) * 24 + h) * 60 + mi) * 60 + (s or 0)
end
local function civil_secs(w) return days_from_civil(w.year, w.month, w.day) * 86400 + w.hour * 3600 + w.min * 60 + w.sec end
local function utc_offset(t: number): number -- seconds east of UTC at instant t; no mktime involved
  return civil_secs(cron.clock.date("*t", t)) - civil_secs(cron.clock.date("!*t", t))
end

-- Local wall-clock fields -> instant, like C mktime. The default clock checks the guess against
-- `os.date("*t")` and corrects it until the requested fields show. In a DST gap no instant matches;
-- the last guess is returned and `resolve` below classifies it as a gap.
local function local_time(tb: any): number
  local want = days_from_civil(tb.year, tb.month, tb.day) * 86400 + tb.hour * 3600 + tb.min * 60 + (tb.sec or 0)
  local t = os.time(tb)
  for _ = 1, 4 do
    local diff = want - civil_secs(os.date("*t", t) :: any)
    if diff == 0 then return t end
    t += diff
  end
  return t
end
cron.clock = { time = local_time, date = os.date }
cron.utc_offset = utc_offset

-- ---------- parse ----------
local function parse_field(src: string, lo: number, hi: number, names: { [string]: number }?, dow: boolean?)
  local set, list = {}, {}
  local star = src:sub(1, 1) == "*"
  local top = dow and 7 or hi
  local function val(tok: string): number?
    local n = tonumber(tok)
    if n == nil and names then n = names[tok:upper()] end
    if n == nil or n % 1 ~= 0 or n < lo or n > top then return nil end
    return n
  end
  for part in src:gmatch("[^,]+") do
    local range, step = part, 1
    local r, s = part:match("^(.-)/(.*)$")
    if r then
      range = r
      step = tonumber(s) :: any
      if step == nil or step % 1 ~= 0 or step < 1 then return nil, "bad step in '" .. part .. "'" end
    end
    local a, b
    if range == "*" then a, b = lo, hi
    else
      local x, y = range:match("^([%w]+)%-([%w]+)$")
      if x then a, b = val(x), val(y) else
        a = val(range); b = (r ~= nil) and top or a  -- 'a/n' reads as 'a-max/n' (Vixie)
      end
      if a == nil or b == nil then return nil, "bad value '" .. part .. "'" end
      if a > b then return nil, "range goes backwards '" .. part .. "'" end
    end
    for v = a, b, step do
      local k = (dow and v == 7) and 0 or v
      set[k] = true
    end
  end
  for v = lo, hi do if set[v] then table.insert(list, v) end end
  if #list == 0 then return nil, "empty field '" .. src .. "'" end
  return { set = set, list = list, star = star }
end

function cron.parse(expr: string)
  local src = expr:gsub("^%s+", ""):gsub("%s+$", "")
  local macro = MACROS[src:lower()]
  if src:sub(1, 1) == "@" and not macro then return nil, "unsupported macro " .. src .. " (use @hourly @daily @weekly @monthly @yearly)" end
  local canon = macro or src
  local f = {}
  for w in canon:gmatch("%S+") do table.insert(f, w) end
  if #f ~= 5 then return nil, "need 5 fields: minute hour day-of-month month day-of-week" end
  if canon:find("[LW#?]") and not canon:find("%a%a%a") then return nil, "L, W, # and ? are not supported" end
  local mi, e1 = parse_field(f[1], 0, 59);               if not mi then return nil, "minute: " .. e1 end
  local hr, e2 = parse_field(f[2], 0, 23);               if not hr then return nil, "hour: " .. e2 end
  local dm, e3 = parse_field(f[3], 1, 31);               if not dm then return nil, "day of month: " .. e3 end
  local mo, e4 = parse_field(f[4], 1, 12, MONTH_NAMES);  if not mo then return nil, "month: " .. e4 end
  local dw, e5 = parse_field(f[5], 0, 6, DOW_NAMES, true); if not dw then return nil, "day of week: " .. e5 end
  local spec = {
    minute = mi.set, hour = hr.set, dom = dm.set, month = mo.set, dow = dw.set,
    minutes = mi.list, hours = hr.list, months = mo.list,
    dom_star = dm.star, dow_star = dw.star,
    wild = f[1]:sub(1, 1) == "*" or f[2]:sub(1, 1) == "*", -- Vixie: wildcard jobs follow real elapsed time
    src = table.concat(f, " "),
  }
  -- Statically impossible: day-of-month only (AND case) that no selected month has (e.g. 30 Feb).
  if spec.dow_star and not spec.dom_star then
    local ok = false
    for _, m in ipairs(spec.months) do
      for d in pairs(spec.dom) do if d <= dim(2000, m) or (m == 2 and d == 29) then ok = true end end
    end
    if not ok then return nil, "never fires: that day does not exist in the chosen month(s)" end
  end
  return spec
end

-- ---------- matching / resolving ----------
local function day_ok(spec, y, m, d): boolean
  local a, b = spec.dom[d] == true, spec.dow[dow_of(y, m, d)] == true
  if spec.dom_star or spec.dow_star then return a and b end -- Vixie: a '*' on either side means AND
  return a or b                                              -- both restricted: OR
end
local function matches(spec, w): boolean
  return spec.minute[w.min] == true and spec.hour[w.hour] == true and spec.month[w.month] == true
    and day_ok(spec, w.year, w.month, w.day)
end

-- first instant whose wall clock is >= target (DST gap end)
local function gap_end(target: number, guess: number): number
  local clock = cron.clock
  local function k(t) local w = clock.date("*t", t) return wkey(w.year, w.month, w.day, w.hour, w.min, w.sec) end
  local lo, hi = guess - 4 * 3600, guess + 4 * 3600
  while lo + 1 < hi do
    local mid = (lo + hi) // 2
    if k(mid) >= target then hi = mid else lo = mid end
  end
  return hi
end

-- wall time -> instant. kind: "exact" | "gap" (wall time does not exist: first instant after the gap)
-- | "overlap" (wall time happens twice: the first occurrence). Powers the form's DST preview line.
local function resolve(y, mo, d, h, mi)
  local clock = cron.clock
  local t = clock.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })
  local w = clock.date("*t", t)
  if w.year == y and w.month == mo and w.day == d and w.hour == h and w.min == mi then
    for _, delta in ipairs({ -3600, -1800, 3600, 1800 }) do -- same wall time one step away => repeated hour
      local w2 = clock.date("*t", t + delta)
      if w2.day == d and w2.hour == h and w2.min == mi then return (delta < 0) and (t + delta) or t, "overlap" end
    end
    return t, "exact"
  end
  return gap_end(wkey(y, mo, d, h, mi, 0), t), "gap"
end

cron.resolve = resolve -- (y, mo, d, h, mi) -> instant, kind
cron.dim = dim

-- ---------- next ----------
-- Smallest slot strictly after `after` (unix seconds). Returns t, kind, nominal where kind is
-- "exact"|"gap"|"overlap"|"real" and nominal = the wall time the expression named; or nil, "never"|"budget".
function cron.next(spec, after: number, budget: number?)
  local clock = cron.clock
  local left = budget or 8000
  local w0 = clock.date("*t", after)
  local sy, sm, sd, sh = w0.year, w0.month, w0.day, w0.hour
  local startkey = wkey(sy, sm, sd, w0.hour, w0.min + 1, 0)
  local found: number? = nil
  local fkind, fnom = "exact", nil
  for y = sy, sy + HORIZON_YEARS do
    for _, mo in ipairs(spec.months) do
      if y == sy and mo < sm then continue end
      for d = 1, dim(y, mo) do
        left -= 1
        if left <= 0 then return nil, "budget" end
        if y == sy and mo == sm and d < sd then continue end
        if not day_ok(spec, y, mo, d) then continue end
        for _, h in ipairs(spec.hours) do
          if y == sy and mo == sm and d == sd and h < sh then continue end
          for _, mi in ipairs(spec.minutes) do
            if wkey(y, mo, d, h, mi, 0) >= startkey then
              local t, kind = resolve(y, mo, d, h, mi)
              if t > after and not (kind == "gap" and spec.wild) then
                found, fkind, fnom = t, kind, { year = y, month = mo, day = d, hour = h, min = mi }
                break
              end
            end
          end
          if found then break end
        end
        if found then break end
      end
      if found then break end
    end
    if found then break end
  end
  if spec.wild then
    -- Real-time rule across a fall-back: the repeated hour runs again for wildcard jobs.
    if utc_offset(after + 3 * 3600) < utc_offset(after - 3 * 3600) then
      local limit = found and math.min(found, after + 3 * 3600) or after + 3 * 3600
      local t = (after // 60 + 1) * 60
      while t < limit do
        if matches(spec, clock.date("*t", t)) then return t, "real", nil end
        t += 60
      end
    end
  end
  if found then return found, fkind, fnom end
  return nil, "never"
end

function cron.upcoming(spec, n: number, after: number, budget: number?)
  local out, t = {}, after
  for _ = 1, n do
    local nt = cron.next(spec, t, budget)
    if not nt then break end
    table.insert(out, nt)
    t = nt
  end
  return out
end

-- interval + once
function cron.next_interval(anchor: number, secs: number, after: number): number
  if after < anchor then return anchor end
  return anchor + ((after - anchor) // secs + 1) * secs
end

-- gap between the slot after `slot` and `slot` (the job's local "period" for catch-up windows)
function cron.period_at(spec, slot: number): number
  local nxt = cron.next(spec, slot, 4000)
  return nxt and (nxt - slot) or 86400
end

-- min spacing over the next 6 slots (validation: >= MIN_INTERVAL_S)
function cron.min_gap(spec, after: number): number
  local ups = cron.upcoming(spec, 6, after, 4000)
  local g = math.huge
  for i = 2, #ups do g = math.min(g, ups[i] - ups[i - 1]) end
  return g
end
cron.MIN_INTERVAL_S = MIN_INTERVAL_S

-- ---------- describe ----------
local DOWN = { [0]="Sun","Mon","Tue","Wed","Thu","Fri","Sat" }
local function hhmm(h, m) return timefmt.clock(h, m) end
local function ranges(list: { number }, name: (number) -> string): string
  local out, i = {}, 1
  while i <= #list do
    local j = i
    while j < #list and list[j + 1] == list[j] + 1 do j += 1 end
    if j - i >= 2 then table.insert(out, name(list[i]) .. "-" .. name(list[j]))
    else for k = i, j do table.insert(out, name(list[k])) end end
    i = j + 1
  end
  return table.concat(out, ", ")
end
local MON = { "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec" }
function cron.describe(spec): string
  local dows, doms = {}, {}
  for v = 0, 6 do if spec.dow[v] then table.insert(dows, v) end end
  for v = 1, 31 do if spec.dom[v] then table.insert(doms, v) end end
  local nm, nh = #spec.minutes, #spec.hours
  -- times phrase
  local every: string? = nil
  local when: string
  local function step(xs, limit)
    if #xs < 2 or xs[1] ~= 0 then return nil end
    local n = xs[2]
    for i, v in xs do if v ~= (i - 1) * n then return nil end end
    return if xs[#xs] + n >= limit then n else nil
  end
  local hs, ms = step(spec.hours, 24), step(spec.minutes, 60)
  if nm == 1 and hs ~= nil and hs > 1 then
    every = "Every " .. hs .. " hours" .. (if spec.minutes[1] == 0 then "" else " at :" .. string.format("%02d", spec.minutes[1])); when = every
  elseif nm == 1 and nh == 24 then every = "Every hour at :" .. string.format("%02d", spec.minutes[1]); when = every
  elseif ms ~= nil then
    every = "Every " .. ms .. " minutes" .. (nh < 24 and (" during hours " .. ranges(spec.hours, tostring)) or ""); when = every
  elseif nh * nm <= 6 then
    local ts = {}
    for _, h in ipairs(spec.hours) do for _, m in ipairs(spec.minutes) do table.insert(ts, hhmm(h, m)) end end
    when = "at " .. table.concat(ts, ", ")
  else when = "at minutes " .. ranges(spec.minutes, tostring) .. " of hours " .. ranges(spec.hours, tostring) end
  -- day phrase
  local day: string? = nil
  local dom_all, dow_all = #doms == 31, #dows == 7
  local dnames = function(v) return DOWN[v] end
  if dom_all and dow_all then day = nil
  elseif dom_all or spec.dom_star then
    if #dows == 5 and dows[1] == 1 and dows[5] == 5 then day = "Weekdays"
    elseif #dows == 2 and dows[1] == 0 and dows[2] == 6 then day = "Weekends"
    else day = ranges(dows, dnames) end
  elseif dow_all or spec.dow_star then day = "Monthly on day " .. ranges(doms, tostring)
  else day = "Day " .. ranges(doms, tostring) .. " or " .. ranges(dows, dnames) end
  local s
  if every then s = every .. ((day and ", " .. day:lower()) or "")
  else s = (day or "Daily") .. " " .. when end
  if #spec.months < 12 then s ..= ", in " .. ranges(spec.months, function(v) return MON[v] end) end
  if not spec.dom_star and not spec.dow_star and not dom_all and not dow_all then s ..= " (day-of-month OR day-of-week)" end
  return s
end

return cron
