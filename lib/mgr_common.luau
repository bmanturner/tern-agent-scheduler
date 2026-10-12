--!strict
-- Manager (host block) shared state type, copy and small helpers. Required by every lib/mgr_*.luau view;
-- calls tern.* only inside functions.

local ui = tern.ui
local textfield = require("./textfield")
local validate = require("./validate")
local platform = require("./platform")

local C = {}

export type Obj = { [string]: any }

-- One selectable row of the list view.
export type Row = {
	sec: string,
	key: string,
	id: string,
	kind: string, -- "job" | "run" | "invalid"
	job: Obj?,
	run: Obj?,
	js: Obj?,
	error: string?,
}

export type Form = {
	id: string?,
	title: string,
	name: textfield.Field,
	prompt: textfield.Field,
	when: textfield.Field,
	only_if: textfield.Field,
	folder: textfield.Field,
	role: string,
	catch_up: string,
	approval: string,
	stop_s: number,
	quiet_ok: boolean,
	enabled: boolean,
	focus: string?,
	-- Text row being edited (name, prompt, when, folder) and its text when editing began.
	editing: { row: string, initial: string }?,
	-- Choice row whose menu is open.
	menu: { row: string, option: string }?,
	touched: { [string]: boolean },
	submitted: boolean,
	-- Extra (async) errors by row: folder existence, role missing.
	extra: { [string]: string },
	roles: { string }?,
	roles_for: string?,
	roles_err: string?,
	folder_ok: { path: string, ok: boolean }?,
	orig: { [string]: any },
	esc_at: number?,
	busy: boolean,
	-- The job's own late limit, kept when editing (nil = the global setting).
	catch_up_window_s: number?,
	-- Draft file opened with ctrl+o and the text written to it then; a different file text means it was edited there.
	draft_path: string?,
	draft_seed: string?,
	-- The job being edited is a finished one-shot: changing When re-activates it.
	was_done: boolean?,
	-- Job id whose Detail the form returns to on close (opened from Detail).
	return_to: string?,
}

export type Sheet = {
	kind: string, -- roles | presets | setup | settings | help | first_run | confirm_stop | run_anyway | conditions | only_if_presets
	-- picker
	query: textfield.Field?,
	sel: string?,
	-- confirm_stop / first_run
	run_id: string?,
	job_id: string?,
	-- settings sheet
	page: string?,
	focus: string?,
	editing: { row: string, initial: string, option: string? }?,
	field: textfield.Field?,
	warnings: { [string]: string }?,
	checking: boolean?,
	text: string?,
	code: string?,
	override: string?,
	verdict: any?,
	draft: any?,
}

export type State = {
	cx: BlockCx,
	pane_id: string,
	token: number?,
	mode: string, -- "list" | "detail" | "form"
	sel: { sec: string, key: string }?,
	sel_idx: number,
	folds: { [string]: boolean },
	detail: { job_id: string, sel: string?, expanded: string? }?,
	form: Form?,
	sheet: Sheet?,
	-- Job id armed for deletion by a first `d`.
	armed: string?,
	-- A short message for the dock's first line (errors from Run now, discard prompt).
	notice: string?,
	notice_at: number,
	example_sel: number,
	-- Folder the manager was opened for (the focused pane's); default for new jobs.
	cwd_hint: string?,
	-- tern.now() (ms) until which the last delete can be undone.
	undo_until: number?,
}

C.AVAILABILITY = "Jobs run while Tern's session service is running. It keeps running after you close windows as long as a terminal or run is still open. Nothing runs while your "
	.. platform.machine()
	.. " is asleep, or after a restart until you open Tern."

C.NO_WINDOW =
	"With no Tern window open, a run that stops to ask for approval waits silently until you open a window or its time limit is reached. Launch failures, early exits, time-outs and blocked jobs still send a notification."

C.WINDOWS = "With several Tern windows open, scheduled runs start in the first window."

C.HANDS_OFF_WARNING =
	"Hands-off runs commands and edits files as you, with your credentials, while you're away. Only use it for prompts you'd trust unattended."

C.APPROVALS = {
	{ value = "yolo", label = "Hands-off (default)", detail = "Never asks. Runs commands and edits files as you." },
	{ value = "write", label = "Ask before commands", detail = "Edits files on its own; waits for you before running shell commands." },
	{ value = "always_ask", label = "Ask for everything", detail = "Waits for you before any edit or command." },
}

C.CATCH_UPS = {
	{ value = "within", label = "Run once when you're back, if under 3h late" },
	{ value = "always", label = "Run once, however late" },
	{ value = "skip", label = "Skip missed runs" },
}

C.STOPS = {
	{ s = 300, label = "5 min" },
	{ s = 900, label = "15 min" },
	{ s = 1800, label = "30 min" },
	{ s = 3600, label = "1 hour" },
	{ s = 7200, label = "2 hours" },
	{ s = 14400, label = "4 hours" },
}

function C.trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

-- `node` with `props` merged into its props.
function C.with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

function C.badge(label: string, tone: string, act: string, key: string, value: string?): Node
	local click = if value ~= nil then act .. "=" .. value else act
	return C.with(ui.badge(label, tone), { key = key, actions = { click = click } })
end

local SHORT_LABELS: { [string]: string } = {
	["+ New"] = "+",
	["Open run"] = "Open",
	["Run now"] = "Run",
	["Confirm delete"] = "Del?",
	History = "Hist",
	["Resume run"] = "Resume",
	Delete = "Del",
	Settings = "Set",
}

-- A badge label for 56–69 cells (UX §8.3): shortened, never ambiguous.
function C.short_label(label: string): string
	return SHORT_LABELS[label] or label
end

function C.text(spans: Spans, key: string): Node
	return C.with(ui.text(spans), { key = key })
end

function C.now(): number
	return os.time()
end

function C.home(): string
	return tern.getenv("HOME") or ""
end

function C.tilde(path: string): string
	return validate.tilde(path, C.home())
end

-- Posts a toast; host block cx has toast.
function C.toast(state: State, level: string, text: string, sub: string?)
	pcall(function()
		state.cx:toast(level :: any, text, sub)
	end)
end

function C.notice(state: State, text: string?)
	state.notice = text
	state.notice_at = tern.now()
end

-- Sends a raw `focus` frame op (`target` nil = clear focus).
function C.focus(cx: BlockCx, target: string?)
	pcall(function()
		local t: any = if target ~= nil then target else tern.json.null
		cx:frame({ { "focus", t } })
	end)
end

-- Seconds as "14h", "12m", "2h 20m" (minutes dropped over 3 h), "3d".
function C.span_text(secs: number): string
	local s = math.max(0, secs)
	if s < 60 then
		return "<1m"
	elseif s < 3600 then
		return string.format("%dm", s // 60)
	elseif s < 10800 then
		local m = (s % 3600) // 60
		return if m == 0 then string.format("%dh", s // 3600) else string.format("%dh %dm", s // 3600, m)
	elseif s < 86400 then
		return string.format("%dh", s // 3600)
	end
	return string.format("%dd", s // 86400)
end

function C.in_text(t: number, now: number): string
	local d = t - now
	if d < 60 and d > -60 then
		return "now"
	elseif d < 0 then
		return C.span_text(-d) .. " ago"
	end
	return "in " .. C.span_text(d)
end

function C.abs(t: number): string
	return (string.gsub(os.date("%a %d %b %H:%M", t), "^(%a+) 0", "%1 "))
end

local function day_key(t: number): string
	return os.date("%Y-%m-%d", t)
end

-- UX §0 relative time rules: time today, "tomorrow 09:00", "Mon 09:00" within 6 days, else "12 Oct 09:00".
function C.when_text(t: number, now: number): string
	local hm = os.date("%H:%M", t)
	if day_key(t) == day_key(now) then
		return hm
	elseif day_key(t) == day_key(now + 86400) then
		return "tomorrow " .. hm
	elseif day_key(t) == day_key(now - 86400) then
		return "yesterday " .. hm
	elseif math.abs(t - now) < 6 * 86400 then
		return os.date("%a ", t) .. hm
	end
	return (string.gsub(os.date("%d %b ", t), "^0", "")) .. hm
end

function C.cost_text(cost: any): string
	if type(cost) ~= "number" then
		return "—"
	elseif cost < 0.005 then
		return "<$0.01"
	end
	return string.format("$%.2f", cost)
end

function C.duration_text(secs: number): string
	local s = math.max(0, math.floor(secs))
	if s < 60 then
		return string.format("%ds", s)
	elseif s < 3600 then
		return string.format("%dm %02ds", s // 60, s % 60)
	end
	return string.format("%dh %02dm", s // 3600, (s % 3600) // 60)
end

function C.stop_label(s: number): string
	for _, o in C.STOPS do
		if o.s == s then
			return o.label
		end
	end
	if s % 3600 == 0 then
		return string.format("%d h", s // 3600)
	end
	return string.format("%d min", s // 60)
end

function C.approval_label(v: string?): string
	for _, o in C.APPROVALS do
		if o.value == v then
			return (string.gsub(o.label, " %(default%)$", ""))
		end
	end
	return tostring(v)
end

function C.catch_up_label(v: string?, window_s: number?): string
	if v == "always" then
		return "Run once, however late"
	elseif v == "skip" then
		return "Skip missed runs"
	end
	local w = window_s or 10800
	local text = if w % 3600 == 0 then string.format("%dh", w // 3600) else string.format("%dm", w // 60)
	return "Run once when you're back, if under " .. text .. " late"
end

-- Width tiers of the main region (UX §3.3): 4 everything, 3 drops the folder, 2 drops role chip and cost, 1 name + value.
function C.tier(cols: number): number
	if cols >= 100 then
		return 4
	elseif cols >= 80 then
		return 3
	elseif cols >= 60 then
		return 2
	end
	return 1
end

-- The item id of row `key` in list `sec`, and the reverse.
function C.item_id(sec: string, key: string): string
	return "main." .. sec .. "." .. key
end

function C.parse_item(item: any): (string?, string?)
	if type(item) ~= "string" then
		return nil, nil
	end
	local sec, key = string.match(item, "^main%.([%w_%-]+)%.([%w_%-:]+)$")
	return sec, key
end

function C.is_shift_letter(k: Key, letter: string): boolean
	local n = k.name
	return n == string.upper(letter) or (n == letter and k.shift)
end

function C.arr<T>(t: T): T
	return tern.json.array(t)
end

-- Re-renders after an async callback; the pane may be gone by then.
function C.render(state: State)
	pcall(function()
		state.cx:render()
	end)
end

return C
