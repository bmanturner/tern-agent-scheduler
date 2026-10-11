--!strict
-- lib/platform.luau : the few things that differ between macOS and Linux (verified on Ubuntu 24.04,
-- Tern 0.8.0). Everything is computed on call, never at load, so tests can switch `tern.runtime.os`.
-- Windows is not supported: run panes, `/bin/test` and `tail` all assume a POSIX system.
local platform = {}

local function T(): any
	return tern :: any
end

-- "macos", "linux", or whatever Tern reports; "macos" when unknown (the only other tested system).
function platform.os(): string
	local rt = T().runtime
	local os_name = if type(rt) == "table" then rt.os else nil
	return if type(os_name) == "string" and os_name ~= "" then os_name else "macos"
end

function platform.is_mac(): boolean
	return platform.os() == "macos"
end

local function home(): string
	return (T().getenv("HOME") :: string?) or ""
end

local function exists(path: string): boolean
	local ok, yes = pcall(function()
		return T().fs.exists(path)
	end)
	return ok and yes == true
end

-- How copy names the machine: "Mac" on macOS, "computer" elsewhere ("while your Mac was asleep").
function platform.machine(): string
	return if platform.is_mac() then "Mac" else "computer"
end

-- $XDG_DATA_HOME, else ~/.local/share (Linux only).
local function data_home(): string
	local x = T().getenv("XDG_DATA_HOME") :: string?
	if type(x) == "string" and x:sub(1, 1) == "/" then
		return x
	end
	return home() .. "/.local/share"
end

-- Folders where Tern's own omp manager may keep omp (`<dir>/state.json`, `<dir>/bin/omp`).
function platform.tern_omp_dirs(): { string }
	if platform.is_mac() then
		return { home() .. "/Library/Application Support/Tern/omp" }
	end
	local d = data_home()
	return { d .. "/tern/omp", d .. "/Tern/omp" }
end

-- Where a `tern` binary usually lives, most specific first.
function platform.tern_paths(): { string }
	local h = home()
	if platform.is_mac() then
		return {
			"/Applications/Tern.app/Contents/MacOS/tern",
			h .. "/Applications/Tern.app/Contents/MacOS/tern",
			h .. "/.local/bin/tern",
			"/opt/homebrew/bin/tern",
			"/usr/local/bin/tern",
		}
	end
	return { h .. "/.local/bin/tern", h .. "/.local/opt/tern/tern", "/usr/local/bin/tern", "/usr/bin/tern" }
end

-- Common omp locations outside Tern's manager, before the login-shell lookup.
function platform.omp_paths_before(): { string }
	if platform.is_mac() then
		return { "/opt/homebrew/bin/omp" }
	end
	return {}
end

-- A POSIX login shell for `-l -c` scripts: the user's zsh/bash/sh, else the system default.
function platform.login_shell(): string
	local sh = T().getenv("SHELL") :: string?
	if type(sh) == "string" and sh:sub(1, 1) == "/" then
		local base = sh:match("([^/]+)$")
		if base == "zsh" or base == "bash" or base == "sh" or base == "dash" then
			return sh
		end
	end
	if platform.is_mac() then
		return "/bin/zsh"
	end
	return if exists("/bin/bash") then "/bin/bash" else "/bin/sh"
end

-- True when `shell` reads rc files with `-i` (zsh, bash); plain sh/dash would print errors instead.
function platform.interactive_ok(shell: string): boolean
	local base = shell:match("([^/]+)$")
	return base == "zsh" or base == "bash"
end

-- argv for one desktop notification, or nil when this system has no way to show one. Text and title
-- are argv elements, never script source.
function platform.notify_argv(title: string, text: string): { string }?
	if platform.is_mac() then
		return {
			"/usr/bin/osascript",
			"-e",
			"on run argv",
			"-e",
			"display notification (item 1 of argv) with title (item 2 of argv)",
			"-e",
			"end run",
			text,
			title,
		}
	end
	for _, bin in { "/usr/bin/notify-send", "/usr/local/bin/notify-send" } do
		if exists(bin) then
			return { bin, "--app-name=Agent Scheduler", "--", title, text }
		end
	end
	return nil
end

-- Setup row text for notifications.
function platform.notify_status(): (boolean?, string)
	if platform.is_mac() then
		return nil, "Banners come from macOS. If they're off you'll still see toasts."
	end
	if platform.notify_argv("", "") ~= nil then
		return nil, "Banners use notify-send. If none appear, your desktop has no notification service; toasts still work."
	end
	return false, "notify-send isn't installed (libnotify), so there are no desktop banners. Toasts still work."
end

-- argv that opens a folder in the file manager, or nil.
function platform.open_argv(path: string): { string }?
	if platform.is_mac() then
		return { "/usr/bin/open", path }
	end
	for _, bin in { "/usr/bin/xdg-open", "/usr/local/bin/xdg-open" } do
		if exists(bin) then
			return { bin, path }
		end
	end
	return nil
end

return platform
