-- Two plugin VMs (two windows, or a reload) seed their ids from different moments and must not draw
-- the same ids: math.randomseed keeps only 32-bit seeds, and a larger seed repeats one sequence.
local none = function()
	return false
end
-- A new module instance seeded at this moment, as a new VM loads it. The test VM has one RNG, so
-- each instance draws everything before the next one seeds.
local function vm_ids(unix, mono_ms)
	fake.set_wall(unix)
	fake.mono = mono_ms
	local ids = __fn.ids()
	return { job = ids.job_id(none), win = ids.win8(), reply = ids.reply_id() }
end

local a = vm_ids(1791816000, 1234.5)
local b = vm_ids(1791816000, 1234.75)
local c = vm_ids(1791816037, 98765.25)
assert(a.job ~= b.job, "same second, different microsecond: " .. a.job)
assert(a.job ~= c.job and b.job ~= c.job, "different seconds: " .. c.job)
assert(a.win ~= b.win and a.reply ~= b.reply, "window and reply ids differ")
print("PASS VMs started at different moments draw different ids")
