--!strict
-- lib/const.luau : every numeric constant of the engine (EN §0.4) plus plugin identity. Pure: no `tern`.
local policy = require("./policy")

local const = {
	-- identity
	PLUGIN_ID = "tern-agent-scheduler",
	MANAGER_KIND = "tern-agent-scheduler.manager",
	DISPLAY_NAME = "Agent Scheduler",
	SESSION_NAME_DEFAULT = "Scheduled runs",
	FIXED_POSITIONAL = "Run the scheduled job described in the attached file.",

	-- clock and loops
	PUMP_MS = 2000,
	TICK_S = 15,
	LIVE_TAIL_S = 15, -- session-tail refresh cadence for the manager's live run rows
	OBS_POLL_S = 3,
	OBS_HEARTBEAT_S = 30,
	OBS_STALE_S = 45,
	STATUS_REFRESH_S = 60,
	-- launch
	LAUNCH_TIMEOUT_MS = 15000,
	ORPHAN_WAIT_S = 20,
	NO_RESPONSE_S = 180,
	-- run limits
	MAXRUN_MIN_S = 300,
	MAXRUN_DEFAULT_S = 1800,
	MAXRUN_MAX_S = 28800,
	MAXRUN_GRACE_S = 60,
	EXIT_NEAR_LIMIT_S = 15,
	-- observation thresholds
	NEEDS_INPUT_S = 10,
	NEEDS_INPUT_REMIND_S = 1800,
	FINISH_CONFIRM_S = 6,
	LAST_MESSAGE_MAX = 4096,
	SUMMARY_MAX = 200,
	JSONL_TAIL_BYTES = 1048576,
	-- policy (defined in policy.luau)
	ONTIME_S = policy.ONTIME_S,
	MAX_SCAN = policy.MAX_SCAN,
	DEFAULT_WINDOW_S = policy.DEFAULT_WINDOW_S,
	CATCHUP_DEFAULT_S = 10800,
	CATCHUP_MIN_S = 900,
	CATCHUP_MAX_S = 604800,
	MAX_CONCURRENT_DEFAULT = 2,
	CAP_WAIT_S_DEFAULT = 600,
	CATCHUP_SPACING_S_DEFAULT = 30,
	-- panes
	MAX_FINISHED_PANES = 5,
	MAX_FINISHED_PANES_MIN = 1,
	MAX_FINISHED_PANES_MAX = 20,
	-- storage / intents
	INTENT_RETRY_S = 60,
	INTENT_MAX_BYTES = 16384,
	ROLE_CACHE_S = 1800,
	-- additions
	MAX_JOBS = 50,
	CARLY_PROMPT_MAX = 12000,
	REPLY_TTL_S = 300,
	PROMPT_MAX = 65536,
	NAME_MAX = 40,
	UNDO_DELETE_S = 10,
	-- file caps (read caps; writes are capped at 90 %)
	CAP_SETTINGS = 65536,
	CAP_CACHE = 65536,
	CAP_JOBS = 262144,
	CAP_STATE = 262144,
	CAP_LEDGER = 131072,
	CAP_SNAPSHOT = 131072,
	WRITE_CAP_RATIO = 0.9,
}

const.INTENT_KINDS = {
	obs = true,
	run_now = true,
	pause = true,
	resume = true,
	pause_all = true,
	resume_all = true,
	stop_run = true,
	focus_run = true,
	open_run = true,
	roles_request = true,
	ack_failed = true,
	focus_manager = true,
	carly_create = true,
} :: { [string]: boolean }

-- Run states (EN §7.2)
const.TERMINAL = {
	finished = true,
	failed = true,
	timed_out = true,
	cancelled = true,
	skipped = true,
	missed = true,
	blocked = true,
} :: { [string]: boolean }

const.INFLIGHT = {
	scheduled = true,
	launching = true,
	running = true,
	needs_input = true,
} :: { [string]: boolean }

return const
