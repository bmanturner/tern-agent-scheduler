-- Open manager and New job open the manager on the window's current host. On this machine an open
-- manager is focused instead; on a remote host this machine's snapshot doesn't apply, so they open
-- one there, starting in the focused remote pane's folder.
local commands = __mods.commands

local defs = {}
tern.command = function(def)
	defs[def.id] = def
end
local buttons = {}
tern.files = { button = function(def) buttons[def.id] = def end }
commands.register()

-- This machine's snapshot lists manager block 77, which the window can see as pane 9.
local current_sel = nil
fake.files["/d/snapshot.json"] = tern.json.encode({ format = 1, managers = { "77" }, jobs = {}, inflight = {} })

local opened = {}
local function window(host_kind, cwd)
	return {
		hosts = {
			current = function(_self)
				return { kind = host_kind }
			end,
		},
		session = {
			focused = function(_self)
				return 5
			end,
			pane = function(_self, _pane)
				return { cwd = cwd }
			end,
			resolve = function(_self, id)
				return if id == "77" then 9 else nil
			end,
			selection = function(_self, _pane, _opts)
				return current_sel
			end,
		},
		new_block = function(_self, kind, args, how)
			table.insert(opened, { kind = kind, args = args, how = how })
			return 1
		end,
		toast = function() end,
	}
end

-- On this machine, the open manager is focused (no new block).
defs["open-manager"].run(window("local", "/Users/u/app"))
assert(#opened == 0, "local: focuses the open manager instead of opening another")

-- On a remote host, a manager opens there in the remote pane's folder.
defs["open-manager"].run(window("remote", "/home/needz/app"))
assert(#opened == 1, "remote: opens a manager on the remote host")
assert(opened[1].kind == "tern-agent-scheduler.manager" and opened[1].args[1] == "list", "manager list")
assert(opened[1].args[2] == "/home/needz/app", "remote pane's folder: " .. tostring(opened[1].args[2]))

-- New job on a remote host starts the form in the remote pane's folder.
defs["new-job"].run(window("remote", "/home/needz/app"))
assert(opened[2].args[1] == "new" and opened[2].args[2] == "/home/needz/app", "new job in the remote folder")

defs["settings"].run(window("remote", "/home/needz/app"))
assert(opened[3].args[1] == "settings" and opened[3].how == "tab", "Settings opens its manager sheet")

-- Carly creates jobs on this machine, so a remote pane's folder is still refused there.
local cwd, why = commands.focused_cwd(window("remote", "/home/needz/app"))
assert(cwd == "" and why ~= nil, "focused_cwd refuses a remote pane")
print("PASS Open manager and New job follow the window's current host")

-- The Files button opens a new job in the folder the pane shows.
local n0 = #opened
buttons["new-job"].run({ root = "/Users/u/app", host = "", selection = {}, tab = "files" }, window("local", "/x"))
assert(#opened == n0 + 1 and opened[n0 + 1].args[1] == "new" and opened[n0 + 1].args[2] == "/Users/u/app" and #opened[n0 + 1].args == 2, "Files button opens a job in the root")
assert(opened[n0 + 1].how == "tab", "Files button opens a tab")
buttons["new-job"].run({ root = nil, host = "", selection = {}, tab = "files" }, window("local", "/x"))
assert(#opened == n0 + 1, "no root opens nothing")

-- "New job from selection…" seeds the prompt with the trimmed selection, in the selected pane's folder.
current_sel = { pane = 5, kind = "terminal", text = "  Fix the flaky test\n" }
defs["new-job-from-selection"].run(window("local", "/Users/u/app"))
assert(#opened == n0 + 2, "selection opens a form")
local a = opened[n0 + 2].args
assert(a[1] == "new" and a[2] == "/Users/u/app" and a[3] == "Fix the flaky test", "selection args: " .. tostring(a[3]))
current_sel = nil
defs["new-job-from-selection"].run(window("local", "/Users/u/app"))
assert(#opened == n0 + 2, "no selection opens nothing")
print("PASS Files button and New job from selection open a prefilled form")
