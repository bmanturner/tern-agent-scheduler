--!strict
-- A program-owned text field for host blocks: text plus a byte cursor kept on UTF-8 boundaries.
-- Movement is by codepoint; `utf16` converts the cursor for the `cursor` prop of `input`/`editor`.
-- Every mutator returns true when the text or the cursor changed.

local textfield = {}

export type Field = { text: string, cur: number }

local NL = 10

-- True when byte `i` (1-based) is a UTF-8 continuation byte.
local function is_cont(s: string, i: number): boolean
	local b = string.byte(s, i)
	return b ~= nil and b >= 0x80 and b < 0xC0
end

-- Cursor (byte offset) of the codepoint boundary before `cur`.
local function prev_boundary(s: string, cur: number): number
	if cur <= 0 then
		return 0
	end
	local i = cur -- 1-based index of the byte just before the cursor
	while i > 1 and is_cont(s, i) do
		i -= 1
	end
	return i - 1
end

-- Cursor (byte offset) of the codepoint boundary after `cur`.
local function next_boundary(s: string, cur: number): number
	local n = #s
	if cur >= n then
		return n
	end
	local i = cur + 2 -- 1-based index of the byte after the one at the cursor
	while i <= n and is_cont(s, i) do
		i += 1
	end
	return i - 1
end

-- Byte offset where the line holding `cur` starts.
local function line_start_of(s: string, cur: number): number
	local i = cur
	while i > 0 and string.byte(s, i) ~= NL do
		i -= 1
	end
	return i
end

-- Byte offset where the line holding `cur` ends (before its newline, or the end of the text).
local function line_end_of(s: string, cur: number): number
	local n = #s
	local i = cur
	while i < n and string.byte(s, i + 1) ~= NL do
		i += 1
	end
	return i
end

-- Codepoints between byte offsets `from` and `to`.
local function count_cps(s: string, from: number, to: number): number
	local n = 0
	for i = from + 1, to do
		if not is_cont(s, i) then
			n += 1
		end
	end
	return n
end

-- Byte offset `cols` codepoints after `from`, stopping at `limit`.
local function advance(s: string, from: number, cols: number, limit: number): number
	local cur = from
	for _ = 1, cols do
		if cur >= limit then
			break
		end
		cur = next_boundary(s, cur)
	end
	return math.min(cur, limit)
end

local function set(f: Field, text: string, cur: number): boolean
	if f.text == text and f.cur == cur then
		return false
	end
	f.text = text
	f.cur = cur
	return true
end

function textfield.new(text: string?): Field
	local t = text or ""
	return { text = t, cur = #t }
end

function textfield.insert(f: Field, s: string): boolean
	if s == "" then
		return false
	end
	local t = f.text
	return set(f, string.sub(t, 1, f.cur) .. s .. string.sub(t, f.cur + 1), f.cur + #s)
end

function textfield.backspace(f: Field): boolean
	if f.cur <= 0 then
		return false
	end
	local p = prev_boundary(f.text, f.cur)
	return set(f, string.sub(f.text, 1, p) .. string.sub(f.text, f.cur + 1), p)
end

function textfield.delete(f: Field): boolean
	if f.cur >= #f.text then
		return false
	end
	local n = next_boundary(f.text, f.cur)
	return set(f, string.sub(f.text, 1, f.cur) .. string.sub(f.text, n + 1), f.cur)
end

function textfield.left(f: Field): boolean
	return set(f, f.text, prev_boundary(f.text, f.cur))
end

function textfield.right(f: Field): boolean
	return set(f, f.text, next_boundary(f.text, f.cur))
end

local function is_space(b: number?): boolean
	return b == 32 or b == 9 or b == 10 or b == 13
end

-- Deletes the word before the cursor and the whitespace after it (alt+backspace).
function textfield.word_back(f: Field): boolean
	local s = f.text
	local i = f.cur
	while i > 0 and is_space(string.byte(s, i)) do
		i -= 1
	end
	while i > 0 and not is_space(string.byte(s, i)) do
		i -= 1
	end
	-- Stops after an ASCII whitespace byte or at 0, so `i` is a boundary.
	return set(f, string.sub(s, 1, i) .. string.sub(s, f.cur + 1), i)
end

function textfield.line_start(f: Field, multiline: boolean?): boolean
	return set(f, f.text, if multiline then line_start_of(f.text, f.cur) else 0)
end

function textfield.line_end(f: Field, multiline: boolean?): boolean
	return set(f, f.text, if multiline then line_end_of(f.text, f.cur) else #f.text)
end

-- Same codepoint column on the previous line, clamped to its length; no-op on the first line.
function textfield.up(f: Field): boolean
	local s = f.text
	local ls = line_start_of(s, f.cur)
	if ls == 0 then
		return false
	end
	local col = count_cps(s, ls, f.cur)
	local prev_end = ls - 1 -- before the newline at byte `ls`
	local prev_start = line_start_of(s, prev_end)
	return set(f, s, advance(s, prev_start, col, prev_end))
end

-- Same codepoint column on the next line, clamped to its length; no-op on the last line.
function textfield.down(f: Field): boolean
	local s = f.text
	local le = line_end_of(s, f.cur)
	if le >= #s then
		return false
	end
	local col = count_cps(s, line_start_of(s, f.cur), f.cur)
	local next_start = le + 1 -- after the newline at byte `le + 1`
	return set(f, s, advance(s, next_start, col, line_end_of(s, next_start)))
end

-- Replaces the text and puts the cursor at the end.
function textfield.set(f: Field, text: string)
	f.text = text
	f.cur = #text
end

-- Editing keys for a field (backspace, delete, movement, typed and pasted text). Single-line
-- fields fold newlines into spaces. Returns whether anything changed.
function textfield.key(f: Field, k: Key, multiline: boolean): boolean
	local name = k.name
	if name == "backspace" then
		return if k.alt then textfield.word_back(f) else textfield.backspace(f)
	elseif name == "delete" then
		return textfield.delete(f)
	elseif name == "left" then
		return if k.meta then textfield.line_start(f, multiline) else textfield.left(f)
	elseif name == "right" then
		return if k.meta then textfield.line_end(f, multiline) else textfield.right(f)
	elseif name == "home" then
		return textfield.line_start(f, multiline)
	elseif name == "end" then
		return textfield.line_end(f, multiline)
	elseif multiline and name == "up" then
		return textfield.up(f)
	elseif multiline and name == "down" then
		return textfield.down(f)
	end
	local text = k.text
	if text ~= nil and text ~= "" and (name == "paste" or not (k.ctrl or k.meta)) then
		if not multiline then
			text = string.gsub(text, "\r\n", " ")
			text = string.gsub(text, "[\r\n]", " ")
		else
			text = string.gsub(text, "\r\n?", "\n")
		end
		return textfield.insert(f, text)
	end
	return false
end

-- The cursor in UTF-16 code units (codepoints above 0xFFFF, 4-byte UTF-8, count 2).
function textfield.utf16(f: Field): number
	local s = f.text
	local n = 0
	for i = 1, f.cur do
		local b = string.byte(s, i) :: number
		if b < 0x80 or b >= 0xC0 then
			n += if b >= 0xF0 then 2 else 1
		end
	end
	return n
end

return textfield
