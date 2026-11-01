--!strict
-- An error card with copyable fixes, and a props helper; both halves.
-- Cards set no `key` themselves: callers key them with cards.with.

local ui = tern.ui

local cards = {}

export type ErrorOpts = {
	-- Monospace detail under the message (an error string, a path).
	detail: string?,
	-- Commands to run in a terminal; each line copies itself on click.
	fixes: { string }?,
}

-- `node` with `props` merged into its props (key, tone, actions, …).
function cards.with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- Copyable terminal commands under a muted lead line; each line copies itself on click. Lines are
-- keyed `<key_prefix><i>` (default "fix").
function cards.commands(lines: { string }, key_prefix: string?): { Node }
	if #lines == 0 then
		return {}
	end
	local prefix = key_prefix or "fix"
	local nodes: { Node } = { ui.text({ ui.span("Run in a terminal (click a line to copy it):", "muted") }) }
	for i, line in lines do
		table.insert(nodes, cards.with(ui.text({ ui.span(line, "code") }), { key = prefix .. i, actions = { click = "copy" } }))
	end
	return nodes
end

function cards.error(title: string, message: string, opts: ErrorOpts?): Node
	local o: ErrorOpts = opts or {}
	local body: { Node } = { ui.text(message) }
	if o.detail then
		table.insert(body, ui.text({ ui.span(o.detail, "mono") }))
	end
	for _, n in cards.commands(o.fixes or {}) do
		table.insert(body, n)
	end
	return cards.with(ui.card({ ui.span(title, "strong") }, body, { icon = "warn" }), { tone = "error" })
end

return cards
