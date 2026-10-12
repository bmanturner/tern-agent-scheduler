-- Open manager and New job open the manager on the window's current host. On this machine an open
-- manager is focused instead; on a remote host this machine's snapshot doesn't apply, so they open
-- one there, starting in the focused remote pane's folder.
local commands = __mods.commands

local defs = {}
tern.command = function(def)
	defs[def.id] = def
end
commands.register()

-- This machine's snapshot lists manager block 77, which the window can see as pane 9.
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

-- Carly creates jobs on this machine, so a remote pane's folder is still refused there.
local cwd, why = commands.focused_cwd(window("remote", "/home/needz/app"))
assert(cwd == "" and why ~= nil, "focused_cwd refuses a remote pane")
print("PASS Open manager and New job follow the window's current host")
