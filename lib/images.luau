--!strict
-- lib/images.luau : finds the images a Markdown prompt refers to, resolves their destinations to local paths and
-- rewrites the links. Pure: no tern.* calls, so the launcher and the tests share it.
local images = {}

export type Ref = { s: number, e: number, dest: string }

local EXTS: { [string]: boolean } = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true }

local function percent_decode(s: string): string
	local r = s:gsub("%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end)
	return r
end

-- Byte ranges of `code` spans on one line: a backtick run closes at the next run of the same length.
local function code_spans(text: string, ls: number, le: number): { { number } }
	local spans: { { number } } = {}
	local i = ls
	while i <= le do
		local a, b = text:find("`+", i)
		if a == nil or a > le then
			break
		end
		local n = (b :: number) - a + 1
		local k = (b :: number) + 1
		local closed = false
		while k <= le do
			local c, d = text:find("`+", k)
			if c == nil or c > le then
				break
			end
			if (d :: number) - c + 1 == n then
				table.insert(spans, { a, d :: number })
				i = (d :: number) + 1
				closed = true
				break
			end
			k = (d :: number) + 1
		end
		if not closed then
			i = (b :: number) + 1
		end
	end
	return spans
end

local function is_space(c: number?): boolean
	return c == 32 or c == 9
end

-- `![alt](dest "title")` starting at the `!` in position i. Returns the ref and the index to resume at.
local function inline_image(text: string, i: number, le: number): (Ref?, number)
	local j = i + 2
	local depth = 1
	while j <= le do
		local c = text:byte(j)
		if c == 92 then -- backslash
			j += 1
		elseif c == 91 then
			depth += 1
		elseif c == 93 then
			depth -= 1
			if depth == 0 then
				break
			end
		end
		j += 1
	end
	if depth ~= 0 or text:byte(j + 1) ~= 40 or j + 1 > le then
		return nil, i + 2
	end
	j += 2
	while j <= le and is_space(text:byte(j)) do
		j += 1
	end
	local s: number, e: number = 0, 0
	if text:byte(j) == 60 then -- <dest>
		s = j + 1
		local k = s
		while k <= le do
			local c = text:byte(k)
			if c == 92 then
				k += 1
			elseif c == 62 or c == 60 then
				break
			end
			k += 1
		end
		if k > le or text:byte(k) ~= 62 then
			return nil, i + 2
		end
		e = k - 1
		j = k + 1
	else
		s = j
		local pdepth = 0
		while j <= le do
			local c = text:byte(j) :: number
			if c == 92 then
				j += 1
			elseif c <= 32 then
				break
			elseif c == 40 then
				pdepth += 1
			elseif c == 41 then
				if pdepth == 0 then
					break
				end
				pdepth -= 1
			end
			j += 1
		end
		e = j - 1
	end
	if e < (s :: number) then
		return nil, i + 2
	end
	while j <= le and is_space(text:byte(j)) do
		j += 1
	end
	local c = text:byte(j)
	if c == 34 or c == 39 or c == 40 then -- "title" 'title' (title)
		local close = if c == 40 then 41 else c
		j += 1
		while j <= le and text:byte(j) ~= close do
			if text:byte(j) == 92 then
				j += 1
			end
			j += 1
		end
		if j > le then
			return nil, i + 2
		end
		j += 1
		while j <= le and is_space(text:byte(j)) do
			j += 1
		end
		c = text:byte(j)
	end
	if c ~= 41 or j > le then
		return nil, i + 2
	end
	local raw = text:sub(s :: number, e :: number)
	local dest = percent_decode((raw:gsub("\\(%p)", "%1")))
	return { s = s :: number, e = e :: number, dest = dest }, j + 1
end

-- `<img … src="dest" …>` starting at the `<` in position i.
local function html_image(text: string, i: number, le: number): (Ref?, number)
	local j = i + 4
	local quote: number? = nil
	local close: number? = nil
	while j <= le do
		local c = text:byte(j)
		if quote ~= nil then
			if c == quote then
				quote = nil
			end
		elseif c == 34 or c == 39 then
			quote = c
		elseif c == 62 then
			close = j
			break
		end
		j += 1
	end
	if close == nil then
		return nil, i + 4
	end
	local tag = text:sub(i, close - 1)
	local from = 1
	while true do
		local a, b, q = tag:find("%s[sS][rR][cC]%s*=%s*([\"'])", from)
		if a == nil then
			break
		end
		local qs = (b :: number) + 1
		local qe = tag:find(q :: string, qs, true)
		if qe == nil then
			break
		end
		if qe > qs then
			return { s = i + qs - 1, e = i + qe - 2, dest = percent_decode(tag:sub(qs, qe - 1)) }, close + 1
		end
		from = qe + 1
	end
	return nil, close + 1
end

function images.refs(text: string): { Ref }
	local out: { Ref } = {}
	local fence: string? = nil
	local fence_len = 0
	local pos = 1
	local n = #text
	while pos <= n + 1 do
		local nl = text:find("\n", pos, true)
		local le = if nl ~= nil then nl - 1 else n
		local line = text:sub(pos, le)
		local marks = line:match("^ ? ? ?(```+)") or line:match("^ ? ? ?(~~~+)")
		if fence ~= nil then
			if marks ~= nil and marks:sub(1, 1) == fence and #marks >= fence_len and line:match("^ ? ? ?%" .. fence .. "+%s*$") ~= nil then
				fence = nil
			end
		elseif marks ~= nil then
			fence = marks:sub(1, 1)
			fence_len = #marks
		else
			local spans = code_spans(text, pos, le)
			local function in_code(p: number): boolean
				for _, sp in ipairs(spans) do
					if p >= sp[1] and p <= sp[2] then
						return true
					end
				end
				return false
			end
			local i = pos
			while i <= le do
				local a = text:find("[!<]", i)
				if a == nil or a > le then
					break
				end
				local ref: Ref? = nil
				local nxt = a + 1
				if in_code(a) then
					nxt = a + 1
				elseif text:byte(a) == 33 and text:byte(a + 1) == 91 then
					ref, nxt = inline_image(text, a, le)
				elseif text:byte(a) == 60 and text:sub(a, a + 3):lower() == "<img" and text:sub(a + 4, a + 4):match("^[%s/>]") ~= nil then
					ref, nxt = html_image(text, a, le)
				end
				if ref ~= nil then
					table.insert(out, ref)
				end
				i = nxt
			end
		end
		pos = le + 2
	end
	return out
end

function images.is_image(path: string): boolean
	local ext = path:match("%.(%w+)$")
	return ext ~= nil and EXTS[ext:lower()] == true
end

local function normalize(path: string): string
	local stack: { string } = {}
	for seg in path:gmatch("[^/]+") do
		if seg == ".." then
			if #stack > 0 then
				table.remove(stack)
			end
		elseif seg ~= "." then
			table.insert(stack, seg)
		end
	end
	return "/" .. table.concat(stack, "/")
end

function images.resolve(dest: string, base_dir: string, home: string?): string?
	if dest == "" or dest:sub(1, 1) == "#" then
		return nil
	end
	if dest:match("^%a[%w+.-]*:") ~= nil then
		local lower = dest:lower()
		if lower:sub(1, 5) ~= "file:" then
			return nil
		end
		local rest = dest:sub(6)
		if rest:sub(1, 2) == "//" then
			rest = rest:sub(3)
			if rest:sub(1, 9):lower() == "localhost" then
				rest = rest:sub(10)
			end
		end
		if rest:sub(1, 1) ~= "/" then
			return nil
		end
		return normalize(rest)
	end
	if dest:sub(1, 2) == "~/" then
		if home == nil or home == "" then
			return nil
		end
		return normalize(home .. "/" .. dest:sub(3))
	end
	if dest:sub(1, 1) == "/" then
		return normalize(dest)
	end
	return normalize(base_dir .. "/" .. dest)
end

function images.rewrite(text: string, subs: { { s: number, e: number, with: string } }): string
	local sorted = table.clone(subs)
	table.sort(sorted, function(a, b)
		return a.s < b.s
	end)
	local out: { string } = {}
	local at = 1
	for _, sub in ipairs(sorted) do
		table.insert(out, text:sub(at, sub.s - 1))
		table.insert(out, sub.with)
		at = sub.e + 1
	end
	table.insert(out, text:sub(at))
	return table.concat(out)
end

return images
