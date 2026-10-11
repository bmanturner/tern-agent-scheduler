--!strict
-- Helpers shared by the job form and the Settings sheet, both `prefs` nodes driven by block keys.

local P = {}

export type Row = {
	id: string,
	label: string,
	hint: string?,
	warning: string?,
	disabled: string?,
	changed: boolean?,
	defaultLabel: string?,
	control: { [string]: any },
}

export type Section = { id: string, title: string?, rows: { Row } }

-- The values of a choice control's options, in order.
function P.option_values(c: { [string]: any }): { string }
	local out: { string } = {}
	for _, o in c.options or {} do
		table.insert(out, o.value)
	end
	return out
end

-- The next value of a number control one step `dir` away; nil with nowhere to go.
function P.step_number(c: { [string]: any }, dir: number): number?
	local v = tonumber(c.value) or c.min or 0
	local n = math.clamp(v + dir * (c.step or 1), c.min or -math.huge, c.max or math.huge)
	return if n ~= v then n else nil
end

-- All rows of `sections` in order.
function P.flat(sections: { Section }): { Row }
	local out: { Row } = {}
	for _, s in sections do
		for _, r in s.rows do
			table.insert(out, r)
		end
	end
	return out
end

function P.find(sections: { Section }, id: string?): Row?
	if id == nil then
		return nil
	end
	for _, r in P.flat(sections) do
		if r.id == id then
			return r
		end
	end
	return nil
end

-- The id of the row `delta` away from `focus`, skipping disabled rows; nil at an end.
function P.move(sections: { Section }, focus: string?, delta: number): string?
	local rows = P.flat(sections)
	if #rows == 0 then
		return nil
	end
	local at = 0
	for i, r in rows do
		if r.id == focus then
			at = i
			break
		end
	end
	local j = if at == 0 and delta < 0 then #rows + 1 else at
	while true do
		j += delta
		if j < 1 or j > #rows then
			return nil
		end
		if rows[j].disabled == nil then
			return rows[j].id
		end
	end
end

-- Sections as the prefs node wants them (rows array-tagged so an empty page encodes as []).
function P.node_sections(sections: { Section }): { any }
	local out: { any } = {}
	for _, s in sections do
		local rows: { any } = {}
		for _, r in s.rows do
			table.insert(rows, {
				id = r.id,
				label = r.label,
				hint = r.hint,
				warning = r.warning,
				disabled = r.disabled,
				changed = r.changed,
				defaultLabel = r.defaultLabel,
				control = r.control,
			})
		end
		table.insert(out, { id = s.id, title = s.title, rows = tern.json.array(rows) })
	end
	return tern.json.array(out)
end

return P
