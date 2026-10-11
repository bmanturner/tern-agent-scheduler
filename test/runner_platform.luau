-- macOS vs Linux: binary locations, notifier, folder opener, shell fallback and wording (lib/platform).
local platform = __mods.platform
local env = { HOME = "/home/u" }
tern.getenv = function(k)
	return env[k]
end
local function show(label, v)
	print(label, if type(v) == "table" then table.concat(v, " | ") elseif v == nil then "nil" else tostring(v))
end

-- macOS (also the default when Tern reports no OS)
tern.runtime = nil
show("default os", platform.os())
tern.runtime = { os = "macos" }
show("mac machine", platform.machine())
show("mac tern", platform.tern_paths()[1])
show("mac omp dirs", platform.tern_omp_dirs())
show("mac notify", platform.notify_argv("T", "x")[1])
show("mac open", platform.open_argv("/d"))
env.SHELL = "/usr/local/bin/fish"
show("mac shell (fish)", platform.login_shell())

-- Linux: XDG data dir, ~/.local/bin, notify-send / xdg-open only when installed
tern.runtime = { os = "linux" }
show("linux machine", platform.machine())
show("linux tern", platform.tern_paths())
show("linux omp dirs", platform.tern_omp_dirs())
env.XDG_DATA_HOME = "/xdg"
show("linux omp dirs (XDG)", platform.tern_omp_dirs())
show("linux notify (none)", platform.notify_argv("T", "x"))
local ok, text = platform.notify_status()
show("linux notify status (none)", tostring(ok) .. " " .. text)
fake.files["/usr/bin/notify-send"] = "x"
show("linux notify", platform.notify_argv("Title", "Body"))
fake.files["/usr/bin/xdg-open"] = "x"
show("linux open", platform.open_argv("/d"))
env.SHELL = "/usr/bin/zsh"
show("linux shell (zsh)", platform.login_shell())
env.SHELL = "/usr/bin/fish"
show("linux shell (fish, no bash)", platform.login_shell())
fake.files["/bin/bash"] = "x"
show("linux shell (fish, bash)", platform.login_shell())
show("interactive dash", platform.interactive_ok("/bin/dash"))

-- the wording follows the platform
tern.runtime = { os = "linux" }
local ledger = __mods.ledger
show("missed copy", ledger.reason_text("asleep_or_closed", { slot = 0, count = 1 }):match("your %a+ was asleep"))
