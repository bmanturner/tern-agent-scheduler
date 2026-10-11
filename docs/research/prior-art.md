# Prior art: scheduled / recurring AI-agent jobs (research as of 2026-10-11)

Scope: how shipping products let users create, manage, and review scheduled agent jobs, for a Tern-plugin / omp-native scheduler. All claims cite the page I read. `[snippet]` = taken only from a search-result excerpt, not the full page. `[INFERENCE]` = my reading, not stated by the source. Pages are undated unless noted; most docs are "live" pages read on 2026-10-11.

Note on a consolidation trend: the products below keep converging on the same shape, which is *a saved prompt + trigger(s) + run-as-new-session + inbox/history*. Devin folded "Scheduled Sessions" into "Automations" (<https://docs.devin.ai/product-guides/scheduled-sessions.md>). OpenAI folded Codex "Automations" into ChatGPT/Codex "Scheduled tasks" (<https://learn.chatgpt.com/docs/automations?surface=app>; the ChatGPT help article still says "Codex uses separate automations" at <https://help.openai.com/en/articles/10291617-scheduled-tasks-in-chatgpt>, so the two pages disagree. Treat the learn.chatgpt.com page as newer `[INFERENCE]`). GitHub renamed to "automations" (<https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-automations>).

---

## 1. Anthropic

### 1a. Claude Code Desktop, local scheduled tasks (closest analogue to the Tern use case)
Source: <https://code.claude.com/docs/en/desktop-scheduled-tasks>

- **Form fields**: Name (lowercased to kebab-case, used as the on-disk folder name, must be unique), Description, Instructions (prompt) with pickers for **permission mode** and **model**, **working folder** (required; untrusted folders prompt to trust), **worktree toggle** (each run gets an isolated Git worktree; default runs against the live working dir including uncommitted changes), Schedule.
- **Schedule input**: presets only in the picker: **Manual** (run-now only), **Hourly**, **Daily** (time), **Weekdays**, **Weekly** (day + time). Anything else (every 15 min, 1st of month, one-shot at a time) is created by *asking Claude in plain language* in any session. "Remind me at 3pm tomorrow" makes a one-time task that disables itself after firing.
- **Storage**: `~/.claude/scheduled-tasks/<name>/SKILL.md` (YAML frontmatter `name`, `description`; body = prompt). Schedule, folder, model and enabled state are *not* in the file (edit via form). Editing the file takes effect next run.
- **Management**: Routines list → detail page: **Run now**, Active/Paused toggle, Edit, run **history incl. skipped runs** (hover shows why: asleep, previous run still in progress, other tasks already running), "Always allowed" permission panel (view/revoke saved approvals), Delete (archives its sessions; optional "also delete files on disk"). Claude can also list/create/edit/pause via chat; a running task can edit its own schedule/prompt via an `update_scheduled_task` MCP tool.
- **Execution**: Desktop checks the schedule **every minute while the app is open**; starts a fresh session. Deterministic per-task stagger of a few minutes after the nominal time.
- **Output/notify**: desktop notification on fire; new session under a **Scheduled** sidebar section; open it to review changes or answer permission prompts.
- **Sleep/closed-app**: only runs while app is running and computer awake. Sleeping through a slot = **skipped**. Settings → "Keep computer awake" prevents idle sleep (lid-close still sleeps).
- **Missed-run catch-up**: on app start/wake, looks back **7 days**; if any slot was missed, runs **exactly one** catch-up for the most recent missed time and discards older ones; notifies. Docs explicitly advise writing time-guardrails in the prompt ("if it's after 5pm, skip...").
- **Permissions**: per-task permission mode + `~/.claude/settings.json` allow rules apply. In Manual mode an unapproved tool **stalls the run** until you answer (session stays open in sidebar). Recommended workflow: create, click **Run now**, watch prompts, "always allow" each one so later runs auto-approve. MCP tools marked `requiresUserInteraction` stall every run.
- **Concurrency**: history shows runs skipped because "the previous run was still in progress" or "other scheduled tasks were already running" (same page), so overlap is skip-not-queue, and there is a global cap `[INFERENCE: cap value not documented]`.
- **Known pitfalls** (users): scheduler silently stops firing after 24-30 h uptime on Windows, only OS reboot recovers, no error surfaced, catch-up burst on reboot then eats the day's real slots (<https://github.com/anthropics/claude-code/issues/55631>, closed stale/locked); recurring tasks spawn headless `claude --resume` workers that never exit and leak until OOM on Windows (<https://github.com/anthropics/claude-code/issues/68626> [snippet]); Cowork tasks "don't run when app is closed, all fire at once on next launch" plus app auto-quit on idle made it "unusable" (<https://github.com/anthropics/claude-code/issues/44128>, closed as duplicate); desktop upgrade losing scheduled tasks (<https://github.com/anthropics/claude-code/issues/35131> [snippet]).

### 1b. Claude Code in-session `/loop` + Cron tools (CLI)
Source: <https://code.claude.com/docs/en/scheduled-tasks>
- Session-scoped: `CronCreate` (5-field cron, prompt, recurring/one-shot), `CronList`, `CronDelete`; max **50 tasks/session**; 8-char task IDs. `/loop 5m <prompt>`, or no interval = Claude self-paces 1 min-1 h; bare `/loop` runs a built-in maintenance prompt or `.claude/loop.md`.
- Scheduler ticks every second, fires **between turns** at low priority (queues if Claude is mid-response); local timezone.
- **Deterministic jitter** derived from task ID: recurring tasks run up to 10% of period late (max 30 min); one-shots on :00/:30 up to 90 s early. **7-day expiry** on recurring tasks (fires a last time then deletes). No catch-up for missed fires (only one fire when idle again). Resumed sessions restore tasks except expired/passed.
- Env kill-switch `CLAUDE_CODE_DISABLE_CRON=1`.
- Comparison table of the three Claude options (cloud/desktop/loop): min interval 1 h cloud vs 1 min local (same page).

### 1c. Claude Code Routines (cloud, `/schedule`)
Source: <https://code.claude.com/docs/en/routines> (research preview; blog 2026-04-14: <https://claude.com/blog/introducing-routines-in-claude-code>)
- A routine = prompt + repos + connectors + environment + triggers (**schedule**, **API** `POST /fire` with bearer token and optional `text`, **GitHub** PR/release events with filters); multiple triggers per routine. Runs on Anthropic cloud, "no permission-mode picker"; fully autonomous. Model selector in prompt box. `claude/`-prefixed branches.
- Schedule: presets hourly/daily/weekdays/weekly, **or one-off at a timestamp** (auto-disables, UI marks "Ran"); custom cron only via `/schedule update` in the CLI; **min interval 1 h**. Times entered locally, converted. Top-of-hour runs "can start several minutes late"; docs recommend e.g. 9:07.
- `/schedule` is conversational (incl. natural-language one-offs "tomorrow at 9am..."); also `/schedule list|update|run`; can ask "why did my nightly review do nothing?" and Claude reads run logs (needs v2.1.227+).
- Management: list, detail page with past runs, **Run now** (optional run-specific text), on/off switch, Edit, Delete. Each run = full session you can open/continue/PR.
- **Status caveat**: green = "started and exited without infrastructure error", *not* that the task succeeded.
- Limits: 100 scheduled runs/h per account (waits); Run-now/API 30/h per routine; no overage. GitHub connection missing → skips up to 72 h then auto-disables. Routines are per-account, not shared.
- Prompt-injection design: saved prompt is framed as the assigned task, while fire `text` is wrapped as untrusted data.

### 1d. Claude Cowork / "new Claude" scheduled tasks
Source: <https://support.claude.com/en/articles/13854387-schedule-recurring-tasks-in-claude-cowork>
- Create via chat ("Create with Claude": proposes name/schedule/instructions then click Schedule) or **Set up manually**: task name, prompt, **approval mode**, frequency (**hourly, daily, weekly, weekdays, manually**), optional model, optional folder.
- "Scheduled" sidebar page: list, upcoming + past runs, edit, pause/resume, delete, **run on demand**. Each run is its own Cowork session.
- **Where it runs**: article says tasks "run remotely... even when your computer is asleep or the Desktop app is closed", *but* "if a scheduled task requires local files or apps, it will only run locally", and pre-Oct-6 tasks on Pro/Max keep running on the computer. (An earlier-dated issue shows the opposite, local-app-dependent behavior: #44128 above.) Treat the local/remote split as in flux.
- Available on all paid plans (same page).

---

## 2. OpenAI

### 2a. ChatGPT Scheduled tasks (formerly "Tasks")
Sources: <https://help.openai.com/en/articles/10291617-scheduled-tasks-in-chatgpt> (updated "10 days ago" at fetch), <https://learn.chatgpt.com/docs/automations?surface=app>
- **Create**: chat-first (ask ChatGPT, it confirms), plus a dedicated **Scheduled** page with a "Schedule a task" input, Active filter, examples. Task panel shows prompt and a **Custom repeat / Never end** setting.
- **Schedules**: one-time, recurring, monitoring (checks for changes; can stop on an end condition), event-triggered (Gmail/Slack/GitHub via webhooks, web/mobile only, cannot combine events with time schedule). Free: one-time or ≤1/day with flexible windows ("morning/afternoon/night"); paid: hourly + exact times. Advanced recurrence is **RFC 5545 RRULE** (`RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0`) editable in the desktop app.
- **Limits on count**: active tasks 3 (Free/Go), 5 (Plus), 10 (Business/Edu), 15 (Pro/Enterprise); "if you reach the limit, pause or delete one". Event-triggered: 30/h, 720/day.
- **Management**: list, pause/resume, edit, delete, **Run now**, **share a task as a link** (snapshot of title, instructions, schedule, original timezone, maybe model; recipient schedules own copy; local-only tasks can't be shared).
- **Notifications**: Settings → Notifications push/email; desktop browser permission prompt.
- **Auto-pause**: "may pause if inactive, requires additional action, or associated chat is deleted"; actions needing approval pause the task. Connecting a finance account auto-created a "Weekly finances update" task (unwanted auto-created tasks are a known surprise).
- **Desktop/local project tasks** (learn.chatgpt.com, "app" mode): run in the project dir **or an isolated worktree**; machine must be on and app running; selected project must exist on disk; standalone tasks start a **new chat per run**; the **Scheduled view acts as an inbox** (unread indicator; runs with findings appear, nothing-to-report runs auto-archive per the Codex-era page, see 2b); optional model and reasoning effort; `$skill-name` in prompt; can also schedule *inside an existing chat* (minute-based follow-up loops, uses chat context); same task can span multiple projects.
- **Permissions**: unattended with your default sandbox; uses `approval_policy="never"` when org policy allows, otherwise falls back to the selected mode. Docs warn full-access + background = elevated risk; recommend narrowest sandbox + rules allowlist.
- **Hygiene advice**: "frequent schedules can create many worktrees over time. Archive scheduled runs you no longer need and avoid pinning runs" (same page).
- **Model retirement hazard**: banner telling users to re-pick a model before GPT-5.5 retires on 2026-10-14 ("If a scheduled task uses a retired model, update it") (same page), meaning a pinned model can silently break jobs.
- **Complaints**: "tasks sometimes don't run, timezones not consistently set, no real interface to make changes" (<https://www.reddit.com/r/ChatGPT/comments/1muyccr/does_anyone_use_scheduled_tasks_they_seem> [snippet]); "as of March 2026... notifications don't arrive many/most of the times" (<https://www.reddit.com/r/ChatGPTcomplaints/comments/1rqyr32/scheduled_tasks_must_be_revamped_asap> [snippet]); "Scheduled Tasks are breaking" (<https://community.openai.com/t/scheduled-tasks-are-breaking/1390827> [snippet], 2026-08-17); desktop: "Scheduled tasks won't run while ChatGPT is closed" with a confusing quit popup (<https://github.com/openai/codex/issues/32425>, open); "ACTIVE scheduled task skipped its 08:40 run" on Windows (<https://github.com/openai/codex/issues/38137> [snippet]).

### 2b. Codex app Automations (older/standalone docs, mirrored)
Sources: mirror <https://doc.jarvisuni.com/openai/codex/app/automations> [snippet], issues below.
- Codex adds findings to the **inbox** or **auto-archives** the run if nothing to report [snippet]. Project-scoped automations need the app running and the project on disk [snippet].
- Pitfall: automations failing and **archiving themselves with no retrievable history/reason**, after sandbox/network restrictions changed (<https://github.com/openai/codex/issues/15875>, 2026-03, closed duplicate). "Automations don't run the commands in the worktree" (<https://github.com/openai/codex/issues/10728> [snippet]). Reporter's takeaway: failures must be visible and diagnosable.

---

## 3. Other products

### 3a. Cursor Automations (cloud agents)
Sources: <https://cursor.com/docs/cloud-agent/automations>, <https://cursor.com/help/ai-features/automations>, changelog 2026-03-05 <https://cursor.com/changelog/03-05-26>
- Create in Agents Window / cursor.com/automations / **`/automate` skill** (describe in plain language) / marketplace templates. Fields: trigger(s) (OR semantics), prompt, optional tools (PR comment, Slack, MCP, memories, computer use), repo scope (none / single repo+branch / multi-repo env), **model**, Share (Run as Me vs Service account; Private/view/edit access).
- Scheduled trigger: **presets or cron expression**; "may run with a delay but will not start before the indicated time".
- **Memories**: per-automation persistent notes (`MEMORIES.md`) across runs; docs warn about poisoned memories from untrusted input. Cloud-only (no local cwd), so it isn't a direct analogue, but it is a good prior-art for per-job state.
- Billing: normal cloud-agent usage; to creator or team pool. No documented max-runtime/cost cap or catch-up semantics found in the pages read `[INFERENCE: absent or elsewhere]`.

### 3b. GitHub Copilot automations (cloud agent + Copilot app local automations)
Sources: <https://docs.github.com/en/copilot/how-tos/github-copilot-app/using-automations>, <https://docs.github.com/copilot/concepts/agents/cloud-agent/about-automations>, changelog 2026-06-02 <https://github.blog/changelog/2026-06-02-schedule-and-automate-tasks-with-copilot-cloud-agent/> [snippet]
- App form: Name; **Trigger** dropdown: Manual / Hourly / Daily (multiple hours + a minute) / Weekly (multiple days + time) / **CRON** (local only; app validates and shows **human-readable preview**) / Issue / Pull request; multiple triggers OR'd; **"Run in the cloud"** toggle (otherwise a **Local automation** from your machine); Tools dropdown (cloud); prompt box with `/` skills; model, reasoning effort, agent pickers; project; **Create and run** (save + test immediately).
- List card shows name, schedule, repo, **last run status**; play button = run now; edit/disable/delete.
- Cloud: repo must be private/internal; sessions started are visible to anyone with repo read; PRs attributed to creator (who therefore cannot approve them); untrusted-event filtering by default; automation scoped to a single repo. Billing to creator via Actions minutes + AI credits.
- **Automations stored outside repo, not versioned**, but a documented path to store as code via GitHub Agentic Workflows (below).
- Rationale/confidence/approvals for issue changes: high-confidence applied automatically, others proposed for review (about-automations page), a nice "propose vs apply" pattern.

### 3c. GitHub Agentic Workflows (gh-aw), schedule syntax
Source: <https://github.github.com/gh-aw/reference/schedule-syntax>
- Markdown-file workflows compiled to Actions. **Fuzzy schedules** (`daily`, `daily around 9am on weekdays`, `weekly on monday`, `every 2h`) deterministically scatter minute/time per workflow file path to avoid load spikes; fixed cron available; optional IANA `timezone`; min 5 minutes for minute intervals.

### 3d. Jules (Google)
Sources: <https://jules.google/docs/scheduled-tasks/>, changelog 2025-12-10 <https://jules.google/docs/changelog/2025-12-101>
- Create: task input → "Planning" dropdown → **Scheduled Task**; set **Frequency and Cadence** (daily/weekly), write prompt, Submit. Management: **Scheduled tab** shows last run / next run; only **Delete**, **editing is not supported** (delete + recreate). Ships 3 template tasks (performance/design/security). Result is a PR. No sleep/missed-run semantics needed (cloud).

### 3e. Devin
Sources: <https://docs.devin.ai/product-guides/scheduled-sessions.md>, <https://docs.devin.ai/product-guides/automations.md>
- Legacy Scheduled Sessions → now an Automation with a **Schedule trigger**: presets Every hour/day/week, **Run once**, **Custom** (visual builder or raw **RRULE**); **per-schedule timezone** (defaults to browser, follows DST).
- Legacy fields: name, recurring/one-time, agent type, playbook, repos, email notify (Always / **On failure only (default)** / Never), Slack channel, **Run as** reassignment when ownership changes. Statuses: Active / Paused / **Error** (consecutive failures).
- Automations add: conditions, **Preflight script** (small VM script decides run/skip/emit items; persists 64 KiB state; dedupes by item id) so a cheap script gates an expensive agent, **ACU cap per session**, **invocation (rate) limit** (default 50/h), **queueing** with concurrent-run cap and queue depth (full queue drops events), Activity tab (success/skipped/error + session links + 30-day sparkline). **Run now bypasses Preflight** (a documented footgun).
- Past Sessions tab per schedule; paused/ disabled keep config.

### 3f. Warp / Oz scheduled agents
Sources: <https://docs.warp.dev/platform/triggers/scheduled-agents.md>, <https://docs.warp.dev/platform/triggers/scheduled-agents-quickstart>
- Cloud agent on **cron**; required: name, cron, prompt-or-skill; optional environment (otherwise barebones sandbox, no repo), model, MCP, `--host` self-hosted worker, `--file` YAML/JSON config. CLI: `oz schedule create|list|get|update|pause|unpause|delete`. `list` shows ID, name, cron, paused, last run (+task/session links), next run, scope.
- Fresh session each run, no state carried; a failed run does not block future runs; delete keeps run history. **Run identity** ("Quick run" = as creator vs "Cloud agent") controls PR authorship; CLI can't set it (a documented foot-gun). Web UI also has **Run now**, Runs page filtered "Recurring"; Agent Management Panel filter "Scheduled".

### 3g. Raycast AI Automations (closest desktop-local UX)
Source: <https://manual.raycast.com/ai/automations> (Pro; Mac+Windows)
- Form: name + icon, **AI model**, **New Chat vs continue existing chat**, prompt with `@` mentions (extensions/MCP/skills), schedule **Once / Hourly (every 1-24 h + weekday chips) / Daily (time + day chips)**; "Custom" shown read-only with cron only if AI created something more complex. "Create with AI" or `@automations` in chat. Local device time.
- **Where output goes**: always an AI Chat message labelled "Automated by <name>"; new chat per run, or accumulate in one chat (model sees history). Target chat deleted → starts new; **archived → runs skipped**.
- **Runs**: checks every minute while Raycast is running; Mac must be awake. **Missed runs fold into one run at next launch, however old.** **Busy chat** → waits for idle, occurrences fold (no backlog). Tools needing approval **pause the run** (docs tell you to preconfigure "run without confirmation" for hands-off). "Prevent Sleep During AI Runs" setting. **Background Notifications**: finished / needs approval / needs answer; suppressed if you're already looking at that chat. **No chained automations** (an automation can't create/modify automations). **Not synced; per-device; cap of 20 per device.** Actions: Edit, Run Now (kept across restart if chat busy), Disable/Enable, Delete; list shows next-run / "overdue" on hover.

### 3h. OpenClaw cron / "automations" (open source, local gateway)
Sources: <http://docs.openclaw.ai/cli/cron> (`openclaw cron`, alias `openclaw automations`), <https://docs.openclaw.ai/automation/cron-jobs/schedules.md>, <https://openclawlab.com/en/docs/automation/cron-jobs/> (dated 2026-03-11, older)
- Scheduler lives **in the long-running Gateway process**; jobs persisted (now SQLite; earlier `~/.openclaw/cron/jobs.json`). Schedule kinds: `--at` (ISO or `20m`; one-shot, deletes after *successful completion*, `--keep-after-run` to retain), `--every`, `--cron` (+ `--tz` IANA; host TZ default; offset-less `--at` = UTC), `--on-exit`, `--stream-command` (event-driven), plus **condition-gate scripts** that skip the model on quiet ticks (min interval 30 s) and **dynamic pacing** (`pacing.min/max`; the run itself may call `next_check`).
- **Auto-stagger** top-of-hour cron by up to 5 min; `--exact` / `--stagger` override. Vixie OR semantics for DOM+DOW documented as a footgun.
- **Session modes**: `main`, `isolated` (fresh transcript per run, default for new agent jobs), `current`, `session:<id>`.
- **Delivery**: `announce` (to a chat channel, default), `webhook`, `none`; best-effort flag; delivery preview shown at add/list/show; `[NO_REPLY]`/heartbeat-only responses suppressed.
- **Per-job**: `--model`, `--fallbacks` (empty = strict), `--thinking`, `--timeout-seconds` (0 = no ceiling), `--agent`, `--command` (deterministic shell jobs, no LLM).
- **Retry/failure**: exponential backoff 30 s → 1 m → 5 m → 15 m → 60 m on consecutive errors; provider/network errors first re-run at 30 s/1 m/5 m before alerting; failure alerts after 2 consecutive failures with 1 h cooldown, grouped as one incident; skipped runs tracked separately; local-model provider preflight → `skipped`.
- **Manual**: `run <id>` (force; returns runId; `--wait` blocks and sets exit code), `runs <id>` with filters (`--status`, `--delivery-status`, `--query`), `enable/disable`, `edit`, `rm` (cancels in-flight run).
- Safety: unattended condition-scripts run with the agent's **full tool policy incl. exec**; global kill `cron.triggers.enabled=false`.

### 3i. Hermes Agent cron (open source, Nous Research)
Sources: <https://hermes-agent.nousresearch.com/docs/user-guide/features/cron?format=full>
- **Schedule input is the richest**: relative one-shot (`in 30m`), intervals (`every 2h`, bare `30m`), natural (`every monday 9am`, `weekdays at 9am`, `daily at 7am`, `monday, wednesday at 9am`), cron expressions (named days ok), ISO timestamps. One-shot repeat=1; `repeat=N` override.
- Create via `/cron add "<schedule>" "<prompt>"`, `hermes cron create`, or plain chat; one `cronjob_manage` tool (create/list/pause/resume/run/edit/remove). Jobs addressable by **ID or case-insensitive name**; ambiguous name refused (names aren't unique).
- **Per-job**: model/provider pin (`--pin` locks current main model; unpinned follows main model *at fire time*, so changing chat model silently changes jobs; global `cron.model` default for the fleet), reasoning effort, attached **skills**, **`--workdir`** (absolute existing dir; loads AGENTS.md/CLAUDE.md/.cursorrules from it; default is detached from any repo), `deliver:` targets (origin chat, local file, platforms, comma-separated), `continuity` (inject own previous output for dedupe), `context_from` (chain jobs), **no-agent mode** (script only, stdout delivered, empty stdout = silent tick), **`[SILENT]`** marker suppresses delivery on success, `[CRON_FAILURE]` first line lets the agent declare failure.
- **Safety/robustness**: cron-run sessions **cannot create further cron jobs**; **pre-dispatch validation** (provider key, skills, delivery target, MCP servers) records `blocked_config`, alerts once, and spends no tokens; create a job **paused** as a canary; global **`hermes pause`** emergency stop; `hermes cron doctor` fleet health (late dispatches, delivery failures, `next_run_at` parked in the past).
- **Missed runs**: after downtime a recurring job **catches up once** (long outage collapses to one run; paused jobs never catch up); `cron.catch_up_missed:false` re-anchors instead; grace window = half the period clamped 120 s-2 h. Resume of a paused job keeps one due slot.
- **Overlap**: a job mid-run is refused with "already running"; file lock prevents overlapping ticks; `cron.max_parallel_jobs` caps concurrency; per-run `workdir` isolation lets jobs parallelize. **Stale-run reclaim** after PID proof or `max(3×timeout, 2 h)` silence (execution ledger with claimed/running/completed/failed/unknown states).
- **Failure UX**: `failure_streak`, review-nudge, failure-incident lifecycle (detected → alerted → resolved/closed with repeat reminder every N hours), delivery failure tracked separately from execution failure (`delivery_failed`), auto re-runs when the model was unreachable, **quota-hold** (don't re-fire into a closed provider usage window).

### 3j. Raycast "Command Scheduler" (3rd-party store extension)
<https://www.raycast.com/cps/scheduler> [snippet]: schedules any Raycast command at times/intervals, i.e. a community workaround before native automations existed (shows user demand).

### 3k. Not found / not covered
- **n8n-style AI agent triggers**: not researched in depth (time budget). They are workflow engines (Schedule Trigger node, cron or interval, execute workflow with AI Agent node) `[INFERENCE]`; no primary source read.
- **Claude.ai chat scheduled tasks**: merged into Cowork/"new Claude" (see 1d).
- **Cursor local (non-cloud) scheduling**: none found; Cursor Automations are cloud only.

---

## 4. Feature matrix

Legend: ✔ documented · ✘ documented absent · — not found / n/a · (c)=cloud-run · (l)=local-run

| Feature | Claude Code Desktop (l) | Claude Routines (c) | Claude `/loop` | Cowork | ChatGPT/Codex Scheduled | Cursor Autom. (c) | Copilot Autom. | Jules (c) | Devin (c) | Warp/Oz (c) | Raycast (l) | OpenClaw (l) | Hermes (l) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Create via natural language | ✔ | ✔ `/schedule` | ✔ | ✔ | ✔ | ✔ `/automate` | — | — | ✔ "Generate with Devin" | — | ✔ | ✔ (agent tool) | ✔ |
| Preset picker | ✔ manual/hourly/daily/weekdays/weekly | ✔ hourly/daily/weekdays/weekly | interval token | ✔ hourly/daily/weekly/weekdays/manual | ✔ + RRULE | ✔ | ✔ manual/hourly/daily/weekly | ✔ daily/weekly | ✔ hour/day/week | ✔ presets (web) | ✔ once/hourly/daily | CLI flags | `every 2h`, `daily at 9am` |
| Raw cron | via chat/tool only | CLI `/schedule update` only | ✔ (internal) | — | RRULE (not cron) | ✔ | ✔ (local only) | — | cron-based legacy / RRULE | ✔ | read-only "Custom" | ✔ (+6-field) | ✔ |
| One-shot datetime | ✔ via chat | ✔ | ✔ | — | ✔ | — | — | — | ✔ Run once | — | ✔ Once | ✔ `--at` | ✔ `in 30m`, ISO |
| Timezone | local | local→UTC | local | local `[INFERENCE]` | stored (shared tasks show original TZ) | — | — | — | **per-schedule** | UTC cron `[INFERENCE]` | local | `--tz` IANA | host TZ `[INFERENCE]` |
| Model choice | ✔ | ✔ | session | ✔ optional | ✔ + reasoning effort | ✔ | ✔ + effort | — | agent type | ✔ | ✔ + effort | ✔ + fallbacks | ✔ pin/effort |
| Workspace / cwd | ✔ required folder | repos (cloud clone) | session cwd | optional folder | project (multi) | repo/multi/none | repo | repo | repos hint | environment | — | `--command-cwd`, agent | **`--workdir`** |
| Permission/approval mode | ✔ per-task | none (autonomous) | inherits | ✔ approval mode | sandbox default, approval=never | tool allowlist | tool allowlist | — | — | — | chat perms; pauses | exec approvals | toolsets |
| Worktree isolation | ✔ toggle | n/a | — | — | ✔ toggle | n/a | n/a | n/a | n/a | n/a | — | — | — |
| Max runtime / cost cap | — | usage limits only | — | — | — | — | — | — | **ACU cap**, rate limit | credits | — | **`--timeout-seconds`** | timeout, inactivity budget |
| List / pause / resume | ✔ | ✔ | list/cancel | ✔ | ✔ | ✔ | ✔ | list+delete only | ✔ | ✔ | ✔ | ✔ | ✔ |
| Run now | ✔ | ✔ (+text) | — | ✔ | ✔ | — | ✔ | — | ✔ (bypasses preflight) | ✔ | ✔ | ✔ `--wait` | ✔ async |
| Edit | ✔ + SKILL.md on disk | ✔ | — | ✔ | ✔ | ✔ | ✔ | **✘** | ✔ | ✔ | ✔ | ✔ | ✔ |
| Duplicate / share | — | — | — | — | **share link** | Copy link | — | — | template | team shared | — | UI duplicate (pacing preserved) | — |
| Count limits | — | 100 sched runs/h | 50/session | — | 3/5/10/15 active | — | — | — | rate limit 50/h | — | **20/device** | — | — |
| Run history | ✔ incl. **skipped + reason** | ✔ list of sessions | — | ✔ upcoming+past | ✔ Scheduled view | ✔ | last status | last/next run | ✔ Activity + sparkline | ✔ Runs page | chat messages | ✔ filterable | ✔ + doctor |
| Output location | Scheduled sidebar section → new session | session | in-session | session | inbox / new chat | session/PR/Slack | session | PR | session | session | chat "Automated by" | chat/webhook/none | chat/file/platform |
| Notifications | desktop notif on fire | — | — | — | push/email | Slack tool | — | — | email (fail-only default), Slack | — | background notif | failure alerts | failure incidents |
| Asleep/closed behavior | skipped; app+awake required; keep-awake setting | runs in cloud | needs open session | partly remote (see §1d) | desktop needs app on | cloud | local needs app; cloud ok | cloud | cloud | cloud | wait → 1 catch-up | needs Gateway up | gateway-down catch-up once |
| Missed-run catch-up | **1 run, 7-day window** | n/a | none | burst on launch (issue) | — | — | — | — | — | — | **1 run, any age** | restart catch-up (quiet evals count) | **1 run**, optional off |
| Overlap/concurrency | skip if prior running; global cap | — | queue between turns | — | — | — | — | — | optional queue + depth | independent | waits for idle chat, folds | per-job lane | refuse "already running"; max_parallel |
| Retry / failure | stalls on permission; no auto-retry documented | status ≠ success | — | — | auto-pause | — | — | — | **Error** status after consecutive fails; preflight no retry | failure doesn't block next | — | **backoff ladder + alerts** | **re-runs, incidents, streak, quota hold** |
| Jitter/stagger | deterministic few-min | several min late | deterministic ≤30 min | — | — | delay only | — | — | — | — | — | top-of-hour ≤5 min | — |
| Kill switch | pause per task | org toggle | env var | admin toggle | — | admin disable | policy | — | — | — | — | `cron.triggers.enabled` | `hermes pause` global |

---

## 5. Patterns worth adopting for a terminal-native Tern/omp scheduler (ranked)

1. **Fresh session per run + a "Scheduled" inbox with run history that records *skipped* runs and the reason.** Claude Code Desktop shows every past run including skips with hover-reason (asleep / previous still running / others running); ChatGPT's Scheduled view acts as an inbox with unread indicator; Hermes/OpenClaw keep `runs` with status filters. The top user complaint across products is silent failure/skips with no diagnosis (Codex #15875, Claude #55631, ChatGPT Reddit threads). Why: this is the reliability trust anchor; cheap with a state file plus one pane/tab per run.
2. **Presets-first schedule picker + cron escape hatch + natural-language entry + one-shot datetime, with a live human-readable preview and next-run time.** Claude Desktop and Cowork: manual/hourly/daily/weekdays/weekly. Copilot validates cron and previews in English. Hermes accepts `every monday 9am`, `in 30m`, ISO. Raycast shows "next run / overdue" on hover. Why: the user asked for "cron-style input, presets welcome"; preview prevents the classic cron mistakes (OpenClaw documents the DOM/DOW OR trap).
3. **Explicit, single-catch-up missed-run policy, per job, surfaced in the UI.** The convergent design (Claude Desktop 7-day window, Raycast any-age, Hermes grace + opt-out) is: on wake/start, run **at most once** for the most recent missed slot, notify that it is a catch-up, and discard older ones. Add a per-job `catch up: once | skip` toggle (Hermes has it only globally and flags that as a limitation). Why: Tern is a desktop app on a laptop, so asleep/closed is the normal case; a burst of N stale runs is the failure mode seen in Claude #44128/#55631.
4. **Overlap policy = skip (recorded) or fold, never pile up; plus a global concurrency cap.** Claude Desktop skips if the prior run is in progress; Raycast folds occurrences while a chat is busy; Hermes refuses "already running"; Devin offers queue + depth. Why: agent runs are long and expensive; recording the skip (pattern 1) makes it legible.
5. **Per-job permission/approval mode with a "Run now → approve → remember" first-run flow, and a loud rule for stalled runs.** Claude Desktop: a Manual-mode run stalls waiting for approval (session stays open); the recommended path is Run now then "always allow", with a revocable "Always allowed" panel. Raycast/ChatGPT pause on approval. Why: unattended agents need either pre-approved scope or a visible "needs you" state (notification + badge). The doc'd stall is also the biggest pitfall (§6).
6. **Worktree-isolation toggle per job (git repos only), default on for jobs that write**, with auto-cleanup guidance. Claude Desktop and Codex/ChatGPT both offer it, and OpenAI warns frequent schedules pile up worktrees. Why: protects the user's in-progress checkout; needs a retention policy (see §6).
7. **Delivery target as a first-class field (user's request: "where the agent's block appears in Tern").** Analogues: OpenClaw `announce|webhook|none` with route preview at create-time; Hermes `deliver:` targets; Raycast new chat vs continue existing chat; Claude "Scheduled" sidebar section. Offer: new tab / split in a chosen window / background-only (visible in the Scheduled inbox) / append to an existing pane. Include "continue previous session" as an option (Raycast's cumulative mode; Hermes `continuity` injecting last output for dedupe).
8. **Quiet-success mode.** Hermes `[SILENT]` token, OpenClaw `NO_REPLY` and gate scripts, ChatGPT/Codex auto-archive runs with nothing to report. Why: for monitoring-style jobs the inbox otherwise fills with noise; combine with "only notify on failure" default (Devin's email default).
9. **Job = a file on disk (prompt as markdown with frontmatter) plus a registry.** Claude Desktop stores `SKILL.md` per task; Cursor/Copilot/Devin keep them server-side and are criticised for not being versionable (Copilot notes this and points to gh-aw). Why: git-friendly, editable in `$EDITOR`, fits omp skills/slash commands `[INFERENCE]`.
10. **Deterministic stagger/jitter for top-of-hour jobs** (Claude: derived from task ID; OpenClaw ≤5 min with `--exact` override; gh-aw fuzzy). Low value for a single-user local scheduler, so make it optional/off; worth it only if it ever calls a shared API at :00 `[INFERENCE]`.
11. **Safety rails borrowed from Hermes/OpenClaw**: scheduled runs cannot create/modify schedules (Hermes, Raycast "no chained automations"; Claude Desktop is the opposite, allowing self-edit via `update_scheduled_task`, so pick deliberately); pre-flight validation before spending tokens (model/role exists, cwd exists, delivery target resolvable) with one alert, not one per tick; create-paused / dry "Run now" button; global pause-all switch.
12. **Failure handling modest but real**: consecutive-failure streak, auto-pause after N, alert once then reminder on cooldown (OpenClaw 30 s→60 m backoff; Hermes incidents). Don't copy the full ladder; start with: record status, retry once for provider/network errors, auto-pause after N consecutive failures, single notification.
13. **Resolve model role at fire time and show it in the form.** Hermes unpinned jobs follow the main model at fire time and its docs tell users how to pin. ChatGPT's retiring-model banner shows what pinned ids do. For omp `@default` (a role, not a model id), "role resolved at fire time" is the right default; show the resolved model in run history so a role change is visible.

## 6. Pitfalls to avoid

- **Silent stalls / dead scheduler**: Claude desktop scheduler stopped firing after ~24-30 h with no error and only an OS reboot fixed it (#55631); `hermes cron doctor` and OpenClaw `next_run_at` parked-in-past checks exist because this is common. Build a heartbeat/last-tick timestamp and show "scheduler last ticked X ago" in the UI.
- **Catch-up bursts**: all missed tasks firing at once on launch (#44128), and a burst "satisfying" today's slots so the real run is skipped (#55631 comment). Coalesce to one run per job; stagger catch-ups.
- **Permission stalls**: a run blocked waiting for approval that nobody sees (Claude Desktop Manual mode; MCP tools with `requiresUserInteraction` stall every run). Surface "needs approval" as a notification/badge, give a timeout, and prefer first-run approval capture.
- **Failures that hide their own evidence**: Codex automations archived themselves on failure with no retrievable history (#15875). Never auto-archive failed runs; keep logs.
- **"Green" ≠ success**: Claude Routines status only means the session ran without infra error. Capture the agent's final message/summary and an explicit success/fail marker (Hermes `[CRON_FAILURE]`).
- **Process leaks**: recurring runs leaving headless workers alive until OOM (Claude Windows #68626 [snippet]). Enforce max runtime, kill on timeout, reap on startup (Hermes stale-run reclaim via PID + start-time fingerprint).
- **Worktree/session pile-up**: OpenAI's own docs warn frequent schedules create many worktrees; sessions/tabs accumulate. Provide retention (keep last N runs per job) and cleanup.
- **Running against the live checkout by default**: Claude/Codex local mode edits files the user is working on. Default to worktree for write jobs, or at least warn.
- **Timezone and DST ambiguity**: ChatGPT users report inconsistent timezones; OpenClaw treats offset-less ISO as UTC; Devin stores UTC but shows local. Store an IANA zone with each job, show it, and define DST gap/overlap behavior.
- **Unattended + full-access sandbox + untrusted content** is the prompt-injection corridor (Claude routines wrap fire text as untrusted; Copilot ignores events from non-writers; OpenClaw warns condition scripts get full exec). A time-only scheduler has less exposure, but any "include file/web content" prompt does too; default to a narrow permission mode.
- **Run-now bypasses the real pipeline**: Devin Run-now skips Preflight; OpenClaw force-run skips the condition gate. Make Run-now run *exactly* what a scheduled fire runs (or label the difference).
- **Duplicate names / name-based addressing**: Claude requires unique kebab-case names (becomes a folder); Hermes allows duplicate names and had to add "ambiguous → refuse". Use stable IDs, enforce unique slug.
- **Edit-not-supported** (Jules) and **hidden auto-created tasks** (ChatGPT "Weekly finances update") both frustrate users: always allow edit; never create jobs implicitly.
- **Model drift/retirement**: pinned model ids get retired (ChatGPT GPT-5.5 banner); unpinned jobs drift when the main model changes (Hermes). Record the resolved model per run and warn on resolution failure at preflight rather than at fire time.
- **Hard-coded app-must-be-open dependency without telling the user**: ChatGPT desktop shows a confusing quit/warning popup (#32425); Claude says "only while app open and awake". State the requirement in the creation form, and decide whether a headless daemon (Tern has a session daemon, per task context) should own the clock rather than the window `[INFERENCE: depends on Tern platform findings from sibling reports]`.
- **Jitter surprising users**: Claude's one-shot runs up to 90 s early, recurring up to 30 min late; Cursor "may run with a delay". Document it or avoid it for a local scheduler.

---

## 7. Source index
- Claude Code Desktop scheduled tasks: <https://code.claude.com/docs/en/desktop-scheduled-tasks>
- Claude Code `/loop` + cron tools: <https://code.claude.com/docs/en/scheduled-tasks>
- Claude Code routines: <https://code.claude.com/docs/en/routines>; blog <https://claude.com/blog/introducing-routines-in-claude-code>
- Cowork scheduling: <https://support.claude.com/en/articles/13854387-schedule-recurring-tasks-in-claude-cowork>
- ChatGPT scheduled tasks: <https://help.openai.com/en/articles/10291617-scheduled-tasks-in-chatgpt>; <https://learn.chatgpt.com/docs/automations?surface=app>
- Cursor: <https://cursor.com/docs/cloud-agent/automations>; <https://cursor.com/help/ai-features/automations>
- Copilot: <https://docs.github.com/en/copilot/how-tos/github-copilot-app/using-automations>; <https://docs.github.com/en/enterprise-cloud@latest/copilot/how-tos/use-copilot-agents/cloud-agent/create-automations>; <https://docs.github.com/copilot/concepts/agents/cloud-agent/about-automations>; gh-aw <https://github.github.com/gh-aw/reference/schedule-syntax>
- Jules: <https://jules.google/docs/scheduled-tasks/>
- Devin: <https://docs.devin.ai/product-guides/scheduled-sessions.md>; <https://docs.devin.ai/product-guides/automations.md>
- Warp: <https://docs.warp.dev/platform/triggers/scheduled-agents.md>; <https://docs.warp.dev/platform/triggers/scheduled-agents-quickstart>
- Raycast: <https://manual.raycast.com/ai/automations>
- OpenClaw: <http://docs.openclaw.ai/cli/cron>; <https://docs.openclaw.ai/automation/cron-jobs/schedules.md>
- Hermes: <https://hermes-agent.nousresearch.com/docs/user-guide/features/cron?format=full>
- Issues: <https://github.com/anthropics/claude-code/issues/44128>, `/55631`, `/68626`, `/35131`; <https://github.com/openai/codex/issues/15875>, `/32425`, `/38137`, `/10728`
