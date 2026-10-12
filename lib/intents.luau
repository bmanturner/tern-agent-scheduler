--!strict
-- lib/intents.luau : host side of the window -> host protocol (EN §2.3 + plan overrides 8-9).
-- Files `intents/<t_ms13>-<win8>-<seq4>.json`, applied in name order inside a time budget and removed
-- after applying. 13 allowlisted kinds (const.INTENT_KINDS); everything else (create/update/delete/
-- settings included) is dropped at once. `carly_create` makes a job directly and answers through
-- `replies/<reply>.json`.
local conditions = require("./conditions")
local const = require("./const")
local jobs = require("./jobs")
local notify = require("./notify")
local roles = require("./roles")
local store = require("./store")
local validate = require("./validate")

export type Handlers = {
	obs: ({ [string]: any }) -> (),
	run_now: (string) -> (boolean, string?),
	stop: (string) -> boolean,
	focus_run: (string) -> (),
	open_run: (string) -> (),
	ack_failed: (string) -> (),
	roles_request: (string) -> (),
	focus_manager: () -> (),
	changed: () -> (),
	check_conditions: (string, (any) -> ()) -> (),
}

local intents = {}

-- name -> os.time() of the first undecodable read (EN §2.3: retried for INTENT_RETRY_S, then dropped)
local first_failed: { [string]: number } = {}

local OBS_STATES: { [string]: boolean } = { working = true, idle = true, waiting_input = true, exited = true }
local FIELD_ORDER = { "name", "prompt", "when", "only_if", "role", "cwd", "approval", "max_runtime_s", "catch_up" }
local function log_warn(...: any)
	local args = table.pack(...)
	pcall(function()
		(tern :: any).log.warn(table.unpack(args, 1, args.n))
	end)
end

local APPROVAL_LABEL: { [string]: string } = {
	yolo = "Hands-off",
	write = "Ask before commands",
	always_ask = "Ask for everything",
}

-- Kinds with an `expires` stamp (unix seconds) are dropped once it has passed: the window told its
-- caller they failed, so applying them later would duplicate or surprise.
local EXPIRING: { [string]: boolean } = { carly_create = true, run_now = true, check_conditions = true }

local function home(): string
	return ((tern :: any).getenv("HOME") :: string?) or ""
end

local function str(v: any, max: number): string?
	if type(v) ~= "string" then
		return nil
	end
	if #v > max then
		return v:sub(1, max)
	end
	return v
end

-- ---------- replies ----------

local function write_reply(id: string, tbl: { [string]: any })
	tbl.format = 1
	store.write_text("replies/" .. id .. ".json", (tern :: any).json.encode(tbl))
end

local function reply_error(id: string, text: string)
	write_reply(id, { ok = false, error = text })
end

local function first_error(errs: { [string]: string }): string
	for _, f in ipairs(FIELD_ORDER) do
		if errs[f] ~= nil then
			return errs[f]
		end
	end
	for _, v in pairs(errs) do
		return v
	end
	return "Couldn't create the job."
end

-- ---------- carly_create ----------

-- name derived from the prompt: first 5 words, lowercased, joined by "-", ≤ 40 chars, unique.
local function derive_name(prompt: string): string
	local words: { string } = {}
	for w in prompt:lower():gmatch("[%a%d]+") do
		table.insert(words, w)
		if #words == 5 then
			break
		end
	end
	local base = table.concat(words, "-"):sub(1, const.NAME_MAX):gsub("%-+$", "")
	if base == "" then
		base = "job"
	end
	local taken: { [string]: boolean } = {}
	for _, j in ipairs(jobs.list()) do
		taken[(j.name :: string):lower()] = true
		taken[validate.slug(j.name)] = true
	end
	local name = base
	local n = 1
	while taken[name] do
		n += 1
		local suffix = "-" .. tostring(n)
		name = base:sub(1, const.NAME_MAX - #suffix):gsub("%-+$", "") .. suffix
	end
	return name
end

local function carly_create(p: { [string]: any }, h: Handlers)
	local reply = p.reply
	if type(reply) ~= "string" or not reply:match("^[a-z0-9]+$") or #reply ~= 12 then
		log_warn("intents: carly_create without a valid reply id")
		return
	end
	local ok, err = pcall(function()
		local prompt = type(p.prompt) == "string" and p.prompt or ""
		if #prompt > const.CARLY_PROMPT_MAX then
			return reply_error(reply, "That prompt is too long for Carly. Use the manager.")
		end
		local name = str(p.name, 200) or ""
		name = name:gsub("^%s+", ""):gsub("%s+$", "")
		if name == "" then
			name = derive_name(prompt)
		end
		local role = (str(p.role, 100) or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^@", "")
		if role == "" then
			role = "default"
		end
		local folder = str(p.folder, 1100) or ""
		local when = str(p.when, 200) or ""
		local now = os.time()
		local input: { [string]: any } = { name = name, prompt = prompt, when = when, role = role, cwd = folder }
		local only_if = str(p.only_if, 300)
		if only_if ~= nil then
			input.only_if = only_if
		end
		local vok, errs, norm = validate.job(input, {
			jobs = jobs.list(),
			now = now,
			home = home(),
			creating = true,
			defaults = jobs.settings().defaults,
		})
		if not vok or norm == nil then
			return reply_error(reply, first_error(errs))
		end
		for _, c in ipairs((norm.conditions or {}) :: { any }) do
			if c.type == "check" then
				return reply_error(reply, "Carly can't add script checks. Add them in the manager.")
			end
		end
		local cwd = norm.cwd :: string
		-- the folder, checked asynchronously (user-controlled path)
		local spawned = pcall(function()
			(tern :: any).process.run({ "/bin/test", "-d", cwd }, { timeout_ms = 3000 }, function(r: any)
				local cok, cerr = pcall(function()
					if r.status ~= 0 then
						return reply_error(reply, "That folder doesn't exist: " .. folder)
					end
					local known = roles.cached(cwd)
					if known ~= nil then
						local present = false
						for _, r2 in ipairs(known) do
							if r2 == role then
								present = true
							end
						end
						if not present then
							local list: { string } = {}
							for _, r2 in ipairs(known) do
								table.insert(list, "@" .. r2)
							end
							return reply_error(reply, string.format("No role @%s here. Roles: %s", role, table.concat(list, ", ")))
						end
					end
					local job, cerrs = jobs.create(input, prompt, "carly", os.time())
					if job == nil then
						return reply_error(reply, first_error(cerrs or {}))
					end
					h.changed() -- recompute + publish the snapshot before the window sees the reply
					local st = jobs.state(job.id)
					local nxt = "manual only"
					if type(st.next_run) == "number" then
						local dok, d = pcall(function()
							return os.date("%a %d %b %H:%M", st.next_run)
						end)
						if dok and type(d) == "string" then
							nxt = d
						end
					end
					local folder_label = validate.tilde(job.cwd, home())
					local approval = APPROVAL_LABEL[tostring(job.approval)] or tostring(job.approval)
					-- a banner works without any window open; the job is live and may run commands
					pcall(notify.plain, "Agent Scheduler", string.format("Carly scheduled %s · %s · %s", tostring(job.name), approval, folder_label))
					write_reply(reply, {
						ok = true,
						job_id = job.id,
						name = job.name,
						when = jobs.describe(job),
						next = nxt,
						folder = folder_label,
						role = "@" .. tostring(job.role),
						approval = approval,
						only_if = if #conditions.describe(job.conditions) > 0 then conditions.describe(job.conditions) else "always",
					})
				end)
				if not cok then
					log_warn("intents: carly_create failed", tostring(cerr))
					pcall(reply_error, reply, "Agent Scheduler couldn't create the job.")
				end
			end)
		end)
		if not spawned then
			reply_error(reply, "Agent Scheduler couldn't check that folder.")
		end
	end)
	if not ok then
		log_warn("intents: carly_create failed", tostring(err))
		pcall(reply_error, reply, "Agent Scheduler couldn't create the job.")
	end
end

-- ---------- the other kinds ----------

local function run_id_of(p: { [string]: any }): string?
	local id = str(p.run_id, 120)
	if id ~= nil and id:match("^r_[%w_]+$") then
		return id
	end
	return nil
end

local function job_id_of(p: { [string]: any }): string?
	local id = str(p.job_id, 20)
	if id ~= nil and jobs.get(id) ~= nil then
		return id
	end
	return nil
end

local function apply(kind: string, p: { [string]: any }, h: Handlers)
	if kind == "obs" then
		local block = p.block
		if type(block) == "number" then
			block = string.format("%.0f", block)
		end
		if type(block) ~= "string" or not block:match("^%d+$") or #block > 24 then
			return
		end
		local state = str(p.state, 20)
		if state == nil or not OBS_STATES[state] then
			return
		end
		local finished = p.finished
		h.obs({
			block = block,
			state = state,
			model = str(p.model, 120),
			last_message = str(p.last_message, const.LAST_MESSAGE_MAX),
			delivery_error = str(p.delivery_error, 400),
			finished = (finished == "done" or finished == "failed") and finished or nil,
			seen_at = type(p.seen_at) == "number" and p.seen_at or nil,
		})
	elseif kind == "run_now" then
		local id = job_id_of(p)
		if id ~= nil then
			local ok, why = h.run_now(id)
			if not ok then
				log_warn("intents: run_now refused", tostring(why))
			end
		end
	elseif kind == "pause" then
		local id = job_id_of(p)
		local job = id and jobs.get(id)
		if job ~= nil and job.enabled ~= false then
			jobs.pause(job.id, "user")
			h.changed()
		end
	elseif kind == "resume" then
		local id = job_id_of(p)
		local job = id and jobs.get(id)
		if job ~= nil and job.enabled == false then
			jobs.resume(job.id, os.time())
			h.changed()
		end
	elseif kind == "pause_all" then
		jobs.set_paused_all(true)
		h.changed()
	elseif kind == "resume_all" then
		jobs.set_paused_all(false)
		h.changed()
	elseif kind == "stop_run" then
		local id = run_id_of(p)
		if id ~= nil then
			h.stop(id)
		end
	elseif kind == "focus_run" then
		local id = run_id_of(p)
		if id ~= nil then
			h.focus_run(id)
		end
	elseif kind == "open_run" then
		local id = run_id_of(p)
		if id ~= nil then
			h.open_run(id)
		end
	elseif kind == "ack_failed" then
		local id = run_id_of(p)
		if id ~= nil then
			h.ack_failed(id)
		end
	elseif kind == "roles_request" then
		local cwd = str(p.cwd, 1100)
		if cwd ~= nil then
			for _, j in ipairs(jobs.list()) do
				if j.cwd == cwd then
					h.roles_request(cwd)
					break
				end
			end
		end
	elseif kind == "focus_manager" then
		h.focus_manager()
	elseif kind == "carly_create" then
		carly_create(p, h)
	elseif kind == "check_conditions" then
		local reply = p.reply
		if type(reply) ~= "string" or not reply:match("^[a-z0-9]+$") or #reply ~= 12 then
			log_warn("intents: check_conditions without a valid reply id")
			return
		end
		local id = job_id_of(p)
		if id == nil then
			return reply_error(reply, "That job no longer exists.")
		end
		h.check_conditions(id, function(v: any)
			local ok, err = pcall(function()
				local list: { any } = {}
				for _, r in ipairs(v.results or {}) do
					table.insert(list, { condition = r.label, result = r.result, text = r.text })
				end
				write_reply(reply, { ok = true, pass = v.ok == true, conditions = (tern :: any).json.array(list) })
			end)
			if not ok then
				log_warn("intents: check_conditions failed", tostring(err))
			end
		end)
	end
end

-- Applies pending intent files in name order until `deadline_ms` (a tern.now() value). Returns how many
-- files were consumed (applied or dropped).
function intents.drain(deadline_ms: number, h: Handlers): number
	local names = store.list("intents")
	local consumed = 0
	for _, name in ipairs(names) do
		if (tern :: any).now() >= deadline_ms then
			break
		end
		if name:match("^%d+%-[%w]+%-%d+%.json$") then
			local rel = "intents/" .. name
			local abs = store.path(rel)
			local rok, text = pcall(function()
				return (tern :: any).fs.read(abs, const.INTENT_MAX_BYTES)
			end)
			if not rok or type(text) ~= "string" then
				log_warn("intents: dropping unreadable or oversized intent", name)
				store.remove(rel)
				consumed += 1
			else
				local dok, p = pcall(function()
					return (tern :: any).json.decode(text)
				end)
				if not dok or type(p) ~= "table" then
					local now = os.time()
					local first = first_failed[name]
					if first == nil then
						first_failed[name] = now
					elseif now - first >= const.INTENT_RETRY_S then
						log_warn("intents: dropping undecodable intent", name)
						first_failed[name] = nil
						store.remove(rel)
						consumed += 1
					end
				else
					first_failed[name] = nil
					local kind = p.kind
					if p.format ~= 1 or type(kind) ~= "string" or const.INTENT_KINDS[kind] ~= true then
						log_warn("intents: dropping intent", name, tostring(kind))
					elseif EXPIRING[kind] and type(p.expires) == "number" and p.expires < os.time() then
						log_warn("intents: dropping expired intent", name, kind)
						local reply = p.reply
						if kind == "carly_create" and type(reply) == "string" and reply:match("^[a-z0-9]+$") and #reply == 12 then
							pcall(reply_error, reply, "Timed out before Agent Scheduler could create it.")
						end
					else
						local aok, aerr = pcall(apply, kind, p, h)
						if not aok then
							log_warn("intents: apply failed", name, tostring(aerr))
						end
					end
					store.remove(rel)
					consumed += 1
				end
			end
		end
	end
	return consumed
end

-- reply file name -> os.time() first seen (replies carry no timestamp and their names are random)
local seen_reply: { [string]: number } = {}

-- Housekeeping: undecodable intents older than INTENT_RETRY_S (by their t_ms prefix), replies older than
-- REPLY_TTL_S. `now` is unix seconds.
function intents.prune(now: number)
	for _, name in ipairs(store.list("intents")) do
		local t = name:match("^(%d+)%-")
		if t ~= nil and first_failed[name] ~= nil and now - tonumber(t) / 1000 > const.INTENT_RETRY_S then
			store.remove("intents/" .. name)
			first_failed[name] = nil
		end
	end
	local present: { [string]: boolean } = {}
	for _, name in ipairs(store.list("replies")) do
		present[name] = true
		local first = seen_reply[name]
		if first == nil then
			seen_reply[name] = now
		elseif now - first > const.REPLY_TTL_S then
			store.remove("replies/" .. name)
			seen_reply[name] = nil
		end
	end
	for name in pairs(seen_reply) do
		if not present[name] then
			seen_reply[name] = nil
		end
	end
end

return intents
