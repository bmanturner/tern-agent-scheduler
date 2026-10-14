--!strict
-- Shared presentation only. No filesystem, process, or scheduler dependencies.
local timefmt = {}
local resolved = "24h"

function timefmt.set(value: any)
	resolved = if value == "12h" then "12h" else "24h"
end

function timefmt.get(): string
	return resolved
end

function timefmt.clock(hour: number, minute: number): string
	if resolved == "12h" then
		hour %= 24
		return string.format("%d:%02d %s", if hour % 12 == 0 then 12 else hour % 12, minute, if hour < 12 then "am" else "pm")
	end
	return string.format("%02d:%02d", hour, minute)
end

-- Presentation patterns retain their calendar fields; clocks share the selected format.
function timefmt.date(pattern: string, at: number?): string
	if not pattern:find("%%H:%%M") then return os.date(pattern, at) :: string end
	local stamp = at or os.time()
	local clock = timefmt.clock(tonumber(os.date("%H", stamp)) or 0, tonumber(os.date("%M", stamp)) or 0)
	local display = string.gsub(pattern, "%%H:%%M", clock)
	return os.date(display, stamp) :: string
end

return timefmt
