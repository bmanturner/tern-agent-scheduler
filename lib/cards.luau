--!strict
-- Standard cards (loading, error with copyable fixes, empty) and a props helper; both halves.
-- Cards set no `key` themselves: callers key them with cards.with.

local ui = tern.ui

local cards = {}

export type ErrorOpts = {
	-- Monospace detail under the message (an error string, a path).
	detail: string?,
	-- Commands to run in a terminal; each line copies itself on click.
	fixes: { string }?,
	-- Action name of a Retry button; the block's `event` receives it as `ev.act`.
	retry: string?,
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

-- A block's status card: a strong title over aligned `{label, value spans}` rows.
function cards.status(title: string, rows: { { Spans } }): Node
	return ui.card({ ui.span(title, "strong") }, { ui.kv(rows) })
end

function cards.loading(label: string): Node
	return ui.card({ ui.span(label, "strong") }, { ui.progress(nil, { ui.span("Loading…", "muted") }) })
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
	if o.retry then
		table.insert(body, ui.row({ cards.with(ui.badge("Retry", "accent"), { actions = { click = o.retry } }) }))
	end
	return cards.with(ui.card({ ui.span(title, "strong") }, body), { tone = "error" })
end

function cards.empty(title: string, hint: string?): Node
	local body: { Node } = {}
	if hint then
		table.insert(body, ui.text({ ui.span(hint, "muted") }))
	end
	return cards.with(ui.card({ ui.span(title, "strong") }, body), { tone = "muted" })
end

return cards
