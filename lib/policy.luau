-- lib/policy.luau : pure decisions. No tern.*, no I/O, `now` is passed in.
local cron = require("./cron")
local P = {}
P.ONTIME_S, P.MAX_SCAN, P.DEFAULT_WINDOW_S = 120, 500, 3 * 3600

-- job.sched = { kind, spec?(parsed cron), secs?, anchor?, run_at? }; job.cursor = last handled slot (or armed_at)
local function next_after(job, t: number): number?
  local s = job.sched
  if s.kind == "cron" then return (cron.next(s.spec, t, 3000))
  elseif s.kind == "interval" then return cron.next_interval(s.anchor, s.secs, t)
  elseif s.kind == "once" then return (s.run_at > t) and s.run_at or nil end
  return nil -- manual
end
P.next_after = next_after

-- Returns { fire = {slot, catchup}?, missed = {count, first, last}?, next_run = number?, done = bool }
function P.decide(job, now: number)
  local out = { done = false }
  local nxt = job.next_run or next_after(job, job.cursor)
  if nxt == nil then out.done = job.sched.kind == "once"; return out end
  if now < nxt then out.next_run = nxt; return out end
  -- collect due slots (bounded)
  local first, latest, n, prev = nxt, nxt, 1, nxt
  local approx = false
  if job.sched.kind == "interval" then
    n = (now - nxt) // job.sched.secs + 1
    latest = nxt + (n - 1) * job.sched.secs
    prev = latest - job.sched.secs
  else
    while n < P.MAX_SCAN do
      local s = next_after(job, latest)
      if s == nil or s > now then break end
      prev, latest, n = latest, s, n + 1
    end
    local more = (n >= P.MAX_SCAN) and next_after(job, latest) or nil
    if more ~= nil and more <= now then
      -- scan truncated: the true latest slot is far past the 500th. Re-anchor close to `now`.
      approx = true
      local window = job.catch_up_window_s or P.DEFAULT_WINDOW_S
      for _, span in ipairs({ window, 86400, 7 * 86400, 60 * 86400 }) do
        local a = math.max(latest, now - span)
        local hit: number?, hitprev: number? = nil, nil
        local cur, steps = a, 0
        while steps < P.MAX_SCAN * 4 do
          local s = next_after(job, cur)
          if s == nil or s > now then break end
          hitprev, hit, cur, steps = hit, s, s, steps + 1
        end
        if hit ~= nil then
          prev, latest = hitprev or a, hit
          break
        end
      end
    end
  end
  local late = now - latest
  local fire_it, catchup = false, false
  if n == 1 and late <= P.ONTIME_S then fire_it = true
  else
    local mode = job.catch_up or "within"             -- "within" | "always" | "skip"
    local window = job.catch_up_window_s or P.DEFAULT_WINDOW_S
    if mode == "always" or (mode == "within" and late <= window) then fire_it, catchup = true, late > P.ONTIME_S end
  end
  local older = n - (fire_it and 1 or 0)
  if older > 0 then out.missed = { count = older, first = first, last = fire_it and prev or latest, approx = approx or nil } end
  if fire_it then out.fire = { slot = latest, catchup = catchup } end
  out.next_run = next_after(job, math.max(latest, now))
  out.done = out.next_run == nil and job.sched.kind == "once"
  return out
end
return P
