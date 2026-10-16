-- The single Settings page: layer shape, keys, editing errors, reset, segments, number typing and entry points.
tern.ui = {
 span = function(t, s) return { t = t, s = s } end,
 node = function(k, p, c) return { k = k, p = p, c = c } end,
 el = function(k, p, c) return { k = k, p = p, c = c } end,
 text = function(spans) return { k = "text", p = {}, spans = spans } end,
}
local jobs, runner = __mods.jobs, __mods.runner
local S = __mods.mgr_sheets
fake.set_wall(fake.chicago(2026, 10, 12, 10, 0, 0))
runner.load()

local function key(state, name, extra)
 local k = { name = name, shift = false, ctrl = false, alt = false, meta = false }
 for f, v in extra or {} do k[f] = v end
 return S.key(state, k)
end
local function fresh()
 assert(jobs.set_settings({ max_concurrent = 2, catchup_window_s = 10800, time_format = "automatic", session_name = "Scheduled runs" }))
 local state = { mode = "list", cx = { pane = 1, render = function() end } }
 S.open_settings(state)
 return state
end
local function node(state)
 local n = S.layer(state)
 assert(n ~= nil and n.k == "prefs", "layer is a prefs node")
 return n
end
local function legend(state)
 for _, c in node(state).c or {} do
  if c.p and c.p.role == "tas.settings-keys" then
   local out = ""
   for _, sp in c.spans do out ..= sp.t end
   return out
  end
 end
end
local function row(state, id)
 for _, s in node(state).p.sections do
  for _, r in s.rows do
   if r.id == id then return r end
  end
 end
 error("no row " .. id)
end
local function focus_on(state, id)
 for _ = 1, 20 do
  if state.sheet.focus == id then return end
  key(state, "down")
 end
 error("could not focus " .. id .. " (at " .. tostring(state.sheet.focus) .. ")")
end

-- a. shape
do
 local state = fresh()
 local n = node(state)
 local p = n.p
 assert(p.role == "tas.settings", "role")
 assert(p.lead == nil, "no lead: the brand row carries the title")
 assert(p.focus == "status", "opens on status")
 local want = { "health", "display", "runs", "limits", "setup" }
 assert(#p.sections == #want, "five sections")
 for i, id in want do assert(p.sections[i].id == id, "section " .. i .. " is " .. id) end
 local runs = {}
 for _, s in p.sections do
  if s.id == "runs" then for _, r in s.rows do table.insert(runs, r.id) end end
 end
 local want_runs = { "placement", "session_name", "focus" }
 assert(#runs == #want_runs, "three runs rows")
 for i, id in want_runs do assert(runs[i] == id, "runs row " .. i .. " is " .. id) end
 assert(row(state, "time_format").control.style == "segmented", "time format is segmented")
 assert(row(state, "manager_layout").control.style == "segmented", "layout is segmented")
 assert(legend(state) == "↑↓ move · ←→ change · ⏎ edit · esc close", tostring(legend(state)))
 for _, s in p.sections do
  for _, r in s.rows do
   local c = r.control
   for _, o in (c and c.options) or {} do
    local label = type(o) == "table" and o.label or tostring(o)
    assert(not string.find(label, "(default)", 1, true), "option label carries (default): " .. label)
   end
  end
 end
 print("PASS settings layer: no lead, five sections, segmented controls, key legend")
end

-- b. rejected text keeps the editor open with the error on the row
do
 local state = fresh()
 focus_on(state, "session_name")
 key(state, "enter")
 assert(state.sheet.editing and state.sheet.editing.row == "session_name", "editing opens")
 for _ = 1, 60 do key(state, "backspace") end
 key(state, "paste", { text = "bad/name" })
 key(state, "enter")
 assert(state.sheet.editing ~= nil and state.sheet.editing.row == "session_name", "editor stays open")
 assert(row(state, "session_name").warning == "Session names use letters, numbers, spaces, . _ - (up to 40).", tostring(row(state, "session_name").warning))
 assert(jobs.settings().session_name == "Scheduled runs", "rejected value is not saved")
 key(state, "escape")
 assert(state.sheet.editing == nil, "Esc closes the editor")
 assert(row(state, "session_name").warning == nil, "Esc clears the warning")
 assert(state.sheet ~= nil, "Esc while editing keeps the sheet")
 print("PASS rejected text stays editing with a warning; Esc cancels and clears")
end

-- c. reset
do
 local state = fresh()
 assert(jobs.set_settings({ max_concurrent = 5 }))
 assert(row(state, "max_concurrent").changed == true, "changed before reset")
 S.event(state, { ev = "change", item = "max_concurrent", value = tern.json.null })
 assert(jobs.settings().max_concurrent == 2, "back to default")
 assert(not row(state, "max_concurrent").changed, "row no longer changed")
 print("PASS reset restores the default")
end

-- d. segments
do
 local state = fresh()
 focus_on(state, "time_format")
 key(state, "left")
 assert(jobs.settings().time_format == "automatic", "Left at the first option changes nothing")
 key(state, "right")
 assert(jobs.settings().time_format == "12h", "Right selects the next option: " .. tostring(jobs.settings().time_format))
 assert(jobs.set_settings({ time_format = "24h" }))
 key(state, "enter")
 assert(jobs.settings().time_format == "automatic", "Enter at the last option wraps to the first")
 print("PASS segmented rows: Right selects next, Left stops at the start, Enter wraps")
end

-- d2. number typing
do
 local state = fresh()
 focus_on(state, "max_concurrent")
 key(state, "enter")
 assert(state.sheet.editing and state.sheet.editing.row == "max_concurrent", "number editor opens")
 assert(legend(state) == "⏎ save · esc cancel", tostring(legend(state)))
 for _ = 1, 10 do key(state, "backspace") end
 key(state, "paste", { text = "x" })
 key(state, "enter")
 assert(state.sheet.editing ~= nil and state.sheet.editing.row == "max_concurrent", "editor stays open on a bad draft")
 assert(row(state, "max_concurrent").warning == "Type a whole number from 1 to 10.", tostring(row(state, "max_concurrent").warning))
 assert(jobs.settings().max_concurrent == 2, "rejected draft is not saved")
 key(state, "escape")
 assert(state.sheet.editing == nil, "Esc closes the number editor")
 assert(row(state, "max_concurrent").warning == nil, "Esc clears the warning")
 key(state, "enter")
 for _ = 1, 10 do key(state, "backspace") end
 key(state, "paste", { text = "3" })
 key(state, "enter")
 assert(state.sheet.editing == nil, "a valid draft closes the editor")
 assert(jobs.settings().max_concurrent == 3, "typed value is saved")
 assert(jobs.set_settings({ max_concurrent = 2 }))
 print("PASS number rows: typing validates, Esc cancels, a whole number saves")
end

-- e. Tab
do
 local state = fresh()
 assert(state.sheet.focus == "status")
 key(state, "tab")
 assert(state.sheet.focus == "time_format", "Tab moves to the next row: " .. tostring(state.sheet.focus))
 key(state, "tab", { shift = true })
 assert(state.sheet.focus == "status", "Shift+Tab moves back")
 print("PASS Tab and Shift+Tab move row focus")
end

-- f. entry points
do
 local state = { mode = "list", cx = { pane = 1, render = function() end } }
 S.open_setup(state)
 assert(state.sheet.kind == "settings" and state.sheet.focus == "status", "open_setup opens Settings on Status")
 key(state, "escape")
 assert(state.sheet == nil, "Esc closes the sheet")
 print("PASS open_setup opens Settings at Status; Esc closes")
end
