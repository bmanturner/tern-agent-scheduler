--!strict
-- Host only: resolve Automatic once and persist it alongside the other regenerable caches.
local bins = require("./bins")
local platform = require("./platform")
local timefmt = require("./timefmt")
local time_host = {}
local selected = "automatic"
local probing = false

local function run(argv: { string }, cb: (string?) -> ())
	local ok = pcall(function()
		(tern :: any).process.run(argv, { timeout_ms = 2000 }, function(r: any)
			cb(if r.status == 0 and not r.timed_out then tostring(r.stdout) else nil)
		end)
	end)
	if not ok then cb(nil) end
end

function time_host.locale_format(text: string?): string
	-- Only t_fmt, never t_fmt_ampm (which exists even in 24-hour locales).
	local pattern = if text then ("\n" .. text):match("\nt_fmt=([^\r\n]*)") else nil
	return if pattern and (pattern:find("%%p") or pattern:find("%%I") or pattern:find("%%r")) then "12h" else "24h"
end

local function enabled(text: string?): boolean
	local value = if text then text:match("^%s*(.-)%s*$") else nil
	return value == "1" or value == "true" or value == "YES"
end

function time_host.configure(value: any)
	selected = if value == "12h" or value == "24h" then value else "automatic"
	if selected ~= "automatic" then
		timefmt.set(selected)
		return
	end
	local cached = bins.cache().time_format
	if cached == "12h" or cached == "24h" then
		timefmt.set(cached)
		return
	end
	timefmt.set("24h")
	if probing then return end
	probing = true
	local function finish(format: string)
		probing = false
		bins.cache().time_format = format
		bins.cache_save()
		-- A setting may have changed while the probe was in flight.
		if selected == "automatic" then timefmt.set(format) end
	end
	local function locale()
		run({ "/usr/bin/locale", "-k", "LC_TIME" }, function(text)
			finish(time_host.locale_format(text))
		end)
	end
	if platform.is_mac() then
		run({ "/usr/bin/defaults", "read", "-g", "AppleICUForce12HourTime" }, function(twelve)
			if enabled(twelve) then return finish("12h") end
			run({ "/usr/bin/defaults", "read", "-g", "AppleICUForce24HourTime" }, function(twenty_four)
				if enabled(twenty_four) then finish("24h") else locale() end
			end)
		end)
	else
		locale()
	end
end

return time_host
