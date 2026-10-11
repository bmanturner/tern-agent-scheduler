--!strict
-- The [[blocks]] declarations of plugin.toml (id and title), read by both halves: tern.plugin
-- carries no block list. Supports one-line, unescaped `id = "…"` / `title = "…"` strings only.

local manifest = {}

export type BlockDecl = { id: string, title: string }

-- Every [[blocks]] entry that has an id, in file order; title defaults to the id.
function manifest.blocks(): { BlockDecl }
	local text = tern.fs.read("plugin.toml", 65536)
	local out: { BlockDecl } = {}
	local id: string? = nil
	local title: string? = nil
	local inside = false

	local function flush()
		if inside and id then
			table.insert(out, { id = id, title = title or id })
		end
		inside, id, title = false, nil, nil
	end

	for raw in string.gmatch(text, "[^\n]*") do
		local line = string.match(raw, "^%s*(.-)%s*$") or ""
		if string.find(line, "^%[%[%s*blocks%s*%]%]") then
			flush()
			inside = true
		elseif string.sub(line, 1, 1) == "[" then
			flush()
		elseif inside then
			local key, value = string.match(line, '^(%w+)%s*=%s*"([^"]*)"')
			if key == nil then
				key, value = string.match(line, "^(%w+)%s*=%s*'([^']*)'")
			end
			if key == "id" then
				id = value
			elseif key == "title" then
				title = value
			end
		end
	end
	flush()
	return out
end

return manifest
