--!strict
-- lib/notify.luau : host OS notifications (LA §8.7, DEC R8). Argv-passing osascript only: text and title
-- are NEVER interpolated into script source. Deduped by (run, transition) on `run.notified`.
local jobs = require("./jobs")
local ledger = require("./ledger")

local notify = {}

-- Control characters out, whitespace collapsed, a leading "-" out (osascript must not read it as an
-- option), at most 200 characters.
function notify.clean(s: string): string
	local out = s:gsub("%c", " "):gsub("%s+", " "):gsub("^[%s%-]+", "")
	local cut = utf8.offset(out, 201)
	if cut ~= nil then
		return out:sub(1, cut - 1)
	end
	return out
end

-- Sends one banner; failure is cosmetic.
function notify.raw(text: string, title: string)
	pcall(function()
		(tern :: any).process.run({
			"/usr/bin/osascript",
			"-e",
			"on run argv",
			"-e",
			"display notification (item 1 of argv) with title (item 2 of argv)",
			"-e",
			"end run",
			notify.clean(text),
			notify.clean(title),
		}, { timeout_ms = 5000 }, function() end)
	end)
end

-- One banner with no run record and no dedupe (e.g. Carly created a job). Failure is cosmetic.
function notify.plain(title: string, text: string)
	notify.raw(text, title)
end

-- true when a banner was sent. `transition` is the dedupe key stored in run.notified.
function notify.send(run: any, transition: string, title: string, text: string): boolean
	local notified = run.notified
	if type(notified) ~= "table" then
		notified = {}
		run.notified = notified
	end
	if notified[transition] ~= nil then
		return false
	end
	notified[transition] = os.time()
	pcall(function()
		ledger.save(run)
	end)
	local job = jobs.get(run.job_id)
	if job ~= nil and (job.system_notification == false or job.notify == "off") then
		return false
	end
	notify.raw(text, title)
	return true
end

return notify
