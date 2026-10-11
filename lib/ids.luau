--!strict
-- lib/ids.luau : job, run, draft, window and reply ids. Randomness is seeded lazily on first use.
local ids = {}

local ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"
local seeded = false

local function seed()
	if seeded then
		return
	end
	seeded = true
	local n = os.time()
	local ok, ms = pcall(function()
		return (tern :: any).now()
	end)
	if ok and type(ms) == "number" then
		n = n * 1000 + math.floor(ms) % 1000
	end
	math.randomseed(n)
end

local function rand(n: number): string
	seed()
	local out = table.create(n)
	for i = 1, n do
		local k = math.random(1, #ALPHABET)
		out[i] = ALPHABET:sub(k, k)
	end
	return table.concat(out)
end

-- `j_` + 8 × [a-z0-9], retried until `exists` is false.
function ids.job_id(exists: (string) -> boolean): string
	for _ = 1, 100 do
		local id = "j_" .. rand(8)
		if not exists(id) then
			return id
		end
	end
	return "j_" .. rand(8)
end

-- The 8 characters after `j_`.
function ids.job8(job_id: string): string
	return (job_id:gsub("^j_", ""))
end

function ids.run_id(job_id: string, slot: number): string
	return string.format("r_%s_%.0f", ids.job8(job_id), slot)
end

function ids.manual_run_id(job_id: string, now: number): string
	return string.format("r_%s_%.0f_%s", ids.job8(job_id), now, rand(4))
end

function ids.draft_id(): string
	return rand(12)
end

function ids.win8(): string
	return rand(8)
end

function ids.reply_id(): string
	return rand(12)
end

return ids
