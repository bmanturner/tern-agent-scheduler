--!strict
-- lib/ids.luau : job, run, draft, window and reply ids. Randomness is seeded lazily on first use.
local ids = {}

local ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"
local seeded = false

-- math.randomseed keeps only seeds in the 32-bit range: every larger seed gives the same sequence
-- (Tern's Luau and luau-web alike), so a millisecond timestamp would make every VM draw the same
-- ids. The seed is the time in microseconds folded into 31 bits.
local function seed()
	if seeded then
		return
	end
	seeded = true
	local n = os.time() * 1000000
	local ok, ms = pcall(function()
		return (tern :: any).now()
	end)
	if ok and type(ms) == "number" then
		n += math.floor(ms * 1000) % 1000000
	end
	math.randomseed(n % 2147483647)
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

-- A random 16-character nonce.
function ids.nonce(): string
	return rand(16)
end

-- FNV-1a 64-bit hash as 16 hex chars, computed on two 32-bit lanes.
function ids.fnv64(s: string): string
	local hi, lo = 0xcbf29ce4, 0x84222325
	for i = 1, #s do
		lo = bit32.bxor(lo, string.byte(s, i))
		local x = lo * 0x1b3
		local nlo = x % 4294967296
		local carry = (x - nlo) / 4294967296
		hi = (hi * 0x1b3 + carry + lo * 256) % 4294967296
		lo = nlo
	end
	return string.format("%08x%08x", hi, lo)
end

return ids
