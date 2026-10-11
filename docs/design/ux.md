# Schedule — end-user experience spec

> [!NOTE]
> Historical design notes, written before the build under the working name `schedule`. The shipped plugin is `tern-agent-scheduler` ("Agent Scheduler"); where these notes disagree with the code or the [README](../../README.md), the code and README win. Links to `research/`, `review/` and `engine-src/` point at internal notes that aren't published; the engine now lives in `lib/` and its tests in `test/`.

Plugin id `schedule` · repo `tern-schedule` · target Tern 0.7.2 · omp 18.9.1.

> ## Revision 2 (after review, 2026-10-11)
> Conforms to `design/decisions.md` (authoritative; R-ids below) and fixes the review rows that decisions.md does not contradict (RC / RF / RP). Structure, voice and wireframes are kept; the Revision 1 block below is historical and is superseded wherever this one says so.
> - **Scope (R23, RP P3/§4.2):** every surface is tagged M1/M2/M3 (§0 "Scope", §2.1-2.6, §3.2, §3.4, §4.1, §4.6-4.10, §5, §6, §7). M1 form = 9 rows (§4.11); M1 palette = Open manager, New job, Run a job now, Go to run that needs me (§2.2); Test run, Quick add, Recent runs, filter, tab badges, per-job notify/after/overlap, Advanced, quiet success, Carly are M2/M3. Q6 in §9.
> - **Prompt (R1, RP §1c):** source `prompts/<job id>.md`; drafts in `drafts/<draft id>.md` (§2.6, §4.1); `prompt_source="file"` is out of v1; Open run explains the fixed first message with the prompt attached (§5.6).
> - **Pane cap (R5, RP P8):** keep at most 5 finished run panes, copy in §4.8, §5.4, §7.7. Per-job After row is M2.
> - **Preamble (R6, RP P13):** always on in M1, per-job toggle removed from the M1 form (§4.9); summary = last `RESULT:` line (§5.4); `RESULT: FAILED -` ⇒ failed (§5.5); quiet success moved to M2 (§4.9, §5.4).
> - **Notifications (R8, RP P5):** host sends every OS notification; no-window copy in §5.1, §5.3, §6.4. Config overlay mentioned in §4.7 (R7).
> - **Intents (R10, RF S1):** palette New job / Quick add / Carly open a draft in the manager via `cx:new_block`; no create/update/delete/settings intents (§2.2, §2.5, §3.1, §4.10). Hands-off confirmation is bound to prompt/cwd/role, `hands_off_review` copy (§4.7, §6.5, §5.5, §7.3).
> - **States (R12, RP P13):** UI label ↔ engine state table (§5.0); reason sentences corrected, with missed-too-late and caught-up as separate rows, `no_response`, `interrupted`, `closed_by_user`, `hands_off_review`, `role_unverified` (§5.5).
> - **Glyphs (R13):** stopped `■` neutral, blocked `shield-alert`, test/manual as text suffix (§3.5).
> - **Role (R16, RP P9):** `@default` default, bare storage, per-folder role list, "Other model…" removed, role-unreadable behavior fixed (§4.4, §6.2).
> - **Folder (R17, RP P12/P15):** no `~` fallback, `allow_home`, unsafe-character copy (§4.5, §7.5).
> - **Approval (R18, RP P2):** Read-only hidden until verified; default pending Q1; examples rewritten (all `@smol`, with cost, work under their mode, scheduled at awake hours; RP P6) (§4.7, §6.1).
> - **If your Mac was asleep (R19, RP P6):** promoted into the main form (§4.1 row 4, §4.1a).
> - **Availability (R20, RP P1/P7/§2-4):** exact copy everywhere; Setup Keep-alive row (§6.2, §6.4, §7.7). **Multi-window (R21, RP P4):** §4.6, §5.1, §6.4.
> - **Naming (R22, RP P7):** run session is "Scheduled runs"; palette group and manager tab stay "Schedule".
> - **Install/removal (R24, RP P14):** §6.7, Settings "Open data folder" (§7.7). **Discovery (R25, RP walkthrough 2/11):** first-load and first-scheduled-run toasts (§6.6, §7.3).
> - **Walkthrough copy (RP "Dead ends"):** `Details` link target (§3.5, §6.4); the watch overlay is skipped when Active is off or after Save & run now (§6.3); verbs collapsed to Save / Save & run now / Run now, Test run is M2 (§4.10); "Needs you" (runs) and "Needs fixing" (jobs) are separate section headers (§3.2); `not observed` copy (§5.2).
> - **Constants (R15, RC):** needs-you debounce follows engine.md (10 s, not 20 s); status refresh ≤ 1/min unless state changes (§2.3, §5.3).
> - **§9** replaced by decisions.md §4 verbatim.

> ## Changes after architecture decision (2026-10-11)
> Aligned with `design/architecture.md` and `research/tern-probe2.md` (`PR2`). Structure, voice and wireframes unchanged except where noted. **Historical:** superseded by Revision 2 above and `design/decisions.md` where they disagree.
> 1. **Placement** (§4.1 rows 6–7, §4.6, §4.11 wireframe, §3.5 detail wireframe, §5.1, §7.7): removed *Hidden* (`layer:park` fails, PR2 test 1c) and *Tab in the "Scheduled" session*. Options are now: *dedicated session, background tab* (default), *Background tab in the current session*, *Split beside a pane*, *Picture-in-picture*; plus a separate switch **Bring to front when it starts** (off). The session name is a setting (default **`Scheduled runs`**, R22; §7.7). Revision 2 ships the first two in M1 as Settings, splits/PiP in M2.
> 2. **Focus** (§1 principle 2, §4.6, §4.11, §5.1): host `tern new tab` leaves view and focus unchanged (PR2 test 4), so all "may flash" copy and "restore focus after `cx.agents:start`" text is gone.
> 3. **Manager and launcher share the host VM** (§0, §2.1, §3.1, §2.2 #4/#5/#9): Run now, Save & run now, Test run, Stop call the host launcher directly; the `schedule://` host→window hand-off is removed. Palette commands write an intent file + bump kv `rev` (architecture "Responsibilities"). Status-segment clicks use `cx:new_block`/palette (§2.3).
> 4. **Open run / Stop** (§5.6, §2.2 #5/#9): live pane → host `tern focus <block>`; closed → new tab in the shown session running `omp --resume` (user-initiated, may take focus). Stop → `cx.agents:stop(tostring(block))` (window) or `tern close <block>` (host). Un-parking removed.
> 5. **Run tabs** (§2.4, §5.2): the *tab* is named `⏲ <job>` via `tern rename <block>` (PR2 test 4); the block's own title stays omp's.
> 6. **Availability copy** (§3.5 empty state, §4.11 form footer, §6.2, §6.4, §7.7): new disclosure text; `[DEPENDS: launcher]` variants removed; runs start with no window open, so "waiting for a window" is removed (§5.1, §7.6).
> 7. **Run states**: now owned by `design/engine.md` §7; Revision 2 §5.0 maps UI labels to engine states.
> 8. **Open questions** (§9): replaced by `decisions.md` §4 in Revision 2.
> 9. **Source tags** (§0): added `PR2`; `[DEPENDS: launcher]` replaced by `[M1 verify]`.

Audience: the developer who builds it. Everything user-visible is specified here. The launcher is the host half (`tern new …` with a fixed argv and the prompt as an attached file; see `launch.md` §2 and `architecture.md` Decision); it does not change what the user sees or where focus is.

## 0. Conventions

**Source tags** (every design choice is traceable):
`PA §5.n` = `research/prior-art.md` §5 ranked pattern *n*; `PA §6 <keyword>` = a §6 pitfall; `PA §3x` = a product entry. `TP §x.y` = `research/tern-platform.md`. `PR Qn` = `research/tern-probe.md`. `PR2 test n` = `research/tern-probe2.md`. `OC §n` = `research/omp-capabilities.md`. `LP <name>` = `research/local-patterns.md` (swarm / rss / pushover / ternkit). `EL <file>` = `references/docs/elements/<file>.md`; `GD <file>` = `references/docs/guides/<file>.md`. `R<n>` = `design/decisions.md` decision; `RC/RF/RP` = `review/consistency.md` / `feasibility-security.md` / `product.md`. `[INFERENCE]` = unverified. `[M1 verify]` = user-visible behavior not yet confirmed on Tern 0.7.2; the copy shown holds only if the check passes.

**Vocabulary** (use exactly these words in UI): *job* (saved prompt + schedule + settings), *run* (one execution), *fire* (internal; never shown), *needs you* (a run waiting on a human), *needs fixing* (a job that can't start until you change something), *test run* (M2: run the unsaved draft once), *hands-off* (approval mode that never asks).

**Scope** (R23). Every surface in this doc is tagged **M1**, **M2** or **M3**; untagged means M1. **M1 = the minimum lovable loop**: create → it fires → I see it ran / needs me / failed → I open the result. M1: the engine; launcher with *Scheduled runs session* (default) and *Background tab in the current session* + *Bring to front*; minimal observer; status segment (stalled/setup, needs you, failed, running, next); toasts and host OS notifications; Open run (focus or `--resume`); run history with reasons; the finished-pane limit; manager List (Needs you, Needs fixing, Running, Upcoming, Paused & finished) + Detail + the 9-row form; Run now, Pause/Resume, Delete (two-press + undo), Duplicate, Pause all; palette *Open manager, New job, Run a job now, Go to run that needs me*; Setup check; empty state with examples; first-run "Run it now and watch". **M1 gate (spike first):** palette → `cx:new_block` opens the host manager with draft args; multi-line text editing in a host block; `prefs` inside a host block (fallback in §4). **M2:** split and picture-in-picture placements (after V10/V11), tab badges, Interrupt (keep pane), Recent runs and Pause/Stop pickers, per-job notify / after-run / overlap options in Advanced, Quick add, filter, Test run, quiet success, Settings beyond core rows. **M3:** Carly exports (draft-only create), worktree isolation, run-reporter extension, "Allowed commands" overlay (if not shipped earlier), export/backup.

**Voice** (tern-rss PRODUCT.md): sentence case, short, no exclamation marks, no emoji in copy (icons come from Tern's icon set), numbers and times concrete. Errors say what happened, then what to do.

**Times**: local time zone, 24-hour clock (`09:00`), weekday abbreviations, day-month (`Mon 12 Oct`). Wireframes assume "now" = Sun 11 Oct 2026 19:00.

**Relative time rules** (used everywhere): `<1m` → "now" / "in <1m"; `<60m` → "in 12m" / "12m ago"; `<24h` → "in 14h" / "3h ago" (minutes dropped over 3 h; "in 2h 20m" under 3 h); next calendar day → "tomorrow 09:00" / "yesterday 09:03"; within 6 days → "Mon 09:00"; otherwise "12 Oct 09:00". Absolute form: `Mon 12 Oct 09:00`.

---

## 1. Principles

Derived from tern-rss `PRODUCT.md` (headlines first, one key per action, quiet until it matters, never lose your place) plus the scheduler-specific failures in `PA §6`.

1. **Next run first.** Every list is ordered by what happens next, and the next fire is always on screen (row value, dock, status segment). A schedule is understood by its next three dates, not by its cron string. *(PA §5.2 live preview; Raycast "next run / overdue" PA §3g)*
2. **Never steal focus.** A run starts where you chose, and you stay where you were. Nothing is raised, selected, or typed into unless you press Open run or the job says "bring to front when it starts". *(PR2 test 4: host `tern new tab` leaves the shown tab and focus unchanged.)*
3. **Quiet until a run needs you.** Success is silent by default. Toasts, tab badges, and OS notifications fire for *needs you* and *failed*, not for "started" or "finished". *(PA §5.8 quiet success; Devin fail-only default PA §3e; rss "Quiet until it matters")*
4. **Every skip has a reason.** A run that did not happen (skipped, missed, blocked, caught up) is a row in history with one plain sentence saying why. Nothing disappears, nothing fails silently. *(PA §5.1, §6 "Silent stalls", "Failures that hide their own evidence")*
5. **Unattended means labelled.** What a job may do on its own (approval mode, folder, model) is visible in the list, the detail, and at the moment of saving; hands-off is never the surprise. *(PA §5.5, §5.11, §6 "Unattended + full-access")*
6. **Never lose your place.** Selection, filter, collapsed sections and half-written drafts survive tab switches, reloads and daemon restarts; deleting is two-press with undo. *(rss "Never lose your place"; LP rss two-press delete; LP swarm `new-task` `save` keeps draft)*

---

## 2. Surfaces and entry points

### 2.1 Surface map

| Surface | Scope | Half | What it is |
|---|---|---|---|
| **Palette group "Schedule"** | M1 (4 commands); M2 (rest) | window | 11 commands in total (§2.2). Pickers use `cx:pick`, one-liners `cx:prompt` (0.7.2, TP §3). |
| **Manager block** `schedule.manager` | M1 | host | The CRUD hub (§3); the only place jobs and settings are created or changed (R10). One per session by convention; "Open manager" focuses the existing one instead of opening a second. Survives window close and daemon restart (`save`). Shares the host VM with the clock and launcher, so Run now, Save & run now and Stop act directly. |
| **Status-line segment** | M1 | window | One segment, `timer` icon (§2.3). |
| **Tab titles** | M1 name; M2 badges | host / window | `⏲ name` set by the launcher; live-state prefix on run tabs is M2 (§2.4). |
| **Toasts** | M1 | window | `cx:toast`, levels `success|info|error` only (SKILL rule; TP §2.6). No buttons in toasts, so every toast names a key or points at the status segment. |
| **OS notifications** | M1 | host | The host alone sends every banner (single writer, deduped), via argv-passing `osascript` (R8), so they work with no window. Needs-you can only be noticed while a window is open (§5.3). |
| **Carly exports** | M3 | window | Natural-language list / run / pause and draft-only create (§2.5). |
| **Prompt `.md` files** | M1 | n/a | Each prompt is a markdown file `prompts/<job id>.md` opened in Tern's doc editor (§2.6). |

### 2.2 Palette commands (group `Schedule`)

Chords are suggestions bound through `tern.command{keys}`; the user can rebind (GD commands). Already taken on this machine by the user's other plugins: `ctrl+alt+shift+k` and `+n` (swarm, LP swarm), `+h` (docs fixture). Commands cannot take arguments (TP §1 #10), so each one that needs a target asks with `cx:pick`/`cx:prompt`. **Palette commands never create or change jobs by themselves** (R10): the ones that start a job open the manager with draft args via `cx:new_block`, and the rest send allowlisted intents (run now, pause/resume, pause all, stop, focus/open run).

| # | Scope | Title | Chord | What it does |
|---|---|---|---|---|
| 1 | M1 | **Schedule: Open manager** | `ctrl+alt+shift+s` | Opens (or focuses) the manager block in a new tab named "Schedule". Icon `timer`. |
| 2 | M1 | **Schedule: New job…** | `ctrl+alt+shift+j` | Opens the manager straight into the New job form as a draft: folder = focused local pane's cwd, otherwise empty and required (§4.5); role `@default`. Nothing is saved until Save. |
| 3 | M2 | **Schedule: Quick add…** | — | Two `cx:prompt`s: "When?" (placeholder `weekdays 9am, every 2h, in 30m, 0 9 * * 1-5`) then "What should the agent do?" Opens the New job form as a draft (same path as #2) focused on **Save**. Never saves by itself (PA §6 "hidden auto-created tasks"). On an unparseable "When?", re-asks with the text kept and the error as placeholder. |
| 4 | M1 | **Schedule: Run a job now…** | `ctrl+alt+shift+r` | `cx:pick` over jobs: label = name, detail = `Weekdays 12:30 · ~/Dev/app · @smol`, group = "Needs fixing / Active / Paused". Enter sends a `run_now` intent for that job id; the host starts a run with the job's stored settings exactly as a scheduled fire would (PA §6 "Run-now bypasses the real pipeline"). A job already running shows detail "Already running" and Enter instead goes to its block. While all jobs are paused the picker says "Resume all jobs to run." |
| 5 | M1 | **Schedule: Go to run that needs me** | `ctrl+alt+shift+a` | Sends a `focus_run` intent for the oldest *needs you* run's block; the host runs `tern focus <block>`. `available` only while ≥1 run needs you (4 ms upvalue check, GD commands). Same action as clicking the status segment in that state. |
| 6 | M2 | **Schedule: Recent runs…** | — | `cx:pick` over the last 30 runs: label = job, detail = outcome sentence, group = day. Enter = **Open run** (§5.6; `open_run` intent). |
| 7 | M2 | **Schedule: Pause or resume a job…** | — | `cx:pick` of jobs, current state shown with a `current` check; Enter sends `pause` or `resume`. (M1 has Pause/Resume in the manager.) |
| 8 | M2 | **Schedule: Pause all jobs** / **Resume all jobs** | — | Two commands, `available` by state (`pause_all` / `resume_all`). Global kill switch (PA §5.11 Hermes `pause`). Running runs continue. (M1 has Pause all in the manager.) |
| 9 | M2 | **Schedule: Stop a running job…** | — | `cx:pick` of running runs; Enter sends `stop_run`; the host closes the block with `tern close <block>` after the summary is saved. Outcome row: "Stopped by you". (M1 has Stop in the manager.) |
| 10 | M2 | **Schedule: Edit a job's prompt file…** | — | `cx:pick` of jobs, then opens its `.md` beside (§2.6). (M1: `p` in the manager.) |
| 11 | M2 | **Schedule: Check setup** | — | Opens the manager's Setup sheet (§6.2). (M1 reaches the sheet from the manager banner and the `setup needed` segment.) |

Not in the palette on purpose: **Delete** (destructive, lives only in the manager behind two presses) and **Edit** (needs the multi-field form).

### 2.3 Status-line segment [M1]

One segment per window (`tern.chrome.status`, GD chrome). The formatter is pure: it reads an upvalue refreshed by a timer plus `tern.chrome.refresh()` (4 ms budget, GD chrome "Refreshing"). Updates at most once a minute while counting down, immediately on any state change. Hidden while there are zero jobs (quiet; the manager's empty state and the palette are the discovery path).

Precedence, top wins; **one segment shown**:

| State | Icon / tone | Text | Click |
|---|---|---|---|
| Scheduler stalled | `warn` / `error` | `scheduler stalled · last tick 4m ago` | Check setup. Condition: active jobs exist and no heartbeat for >3 ticks (min 2 min). *(PA §6 "Silent stalls": show last-tick age)* |
| Setup problem | `warn` / `warn` | `setup needed` | Check setup (omp missing, roles unreadable, Tern too old) |
| Needs you | `bell` / `warn` | `1 needs you · deps-audit` (`2 need you` when more) | Go to run that needs me |
| Failed, unseen | `x-circle` / `error` | `nightly-tests failed` (`2 failed`) | Opens manager on that job's history. Clears when the run is opened or the manager is focused. |
| Running | `activity` / `accent` | one: `daily-review · 4m`; many: `2 running` | Opens manager |
| Paused (all), M2 | `pause` / `warn` | `paused · 4 jobs` | Opens manager with the paused banner |
| Next run | `timer` / `muted` (`accent` under 5 min) | `next: daily-review in 14h` (always one name, the soonest job) | Opens manager |

Combined case: needs-you plus running shows `1 needs you · 1 running` (tone `warn`). The narrow-width fallback is Tern's own segment truncation; the plugin supplies no second variant. Refresh follows the engine constants (≤ 1/min while counting down, immediately on any state change; `engine.md`, R15). In M1 the Paused (all) row does not exist: while all jobs are paused the Next-run row is hidden and the manager dock shows the paused banner. Setting "Show next run in the status line" (default on; M2) hides only the last row.

Status-segment clicks that open the manager use `cx:new_block`/the palette command (window half); clicks that mean "go to the run" write a focus intent (§2.2 #5). No `schedule://` route is needed.

### 2.4 Tab titles and badges (run tabs) [M1 name; M2 badges]

Run tabs are named by the host launcher right after `tern new tab` with `tern rename <block> "⏲ daily-review"` (renames the *tab*, PR2 test 4). That static name is M1. **M2:** a `tern.chrome.tab_title` formatter prefixes live state by looking the tab up in a run table kept in an upvalue [INFERENCE: tab id ↔ run mapping is available to the window half via `cx.session:tabs()`; M1 verify]. The formatter keys on the run table, not on the tab name; a tab the *user* renames afterwards drops out of the run table and is left alone (GD chrome: a formatter's title replaces even user names, so it must opt out). Run tabs live in the “Scheduled runs” session by default, so badges are seen mainly in the session switcher and the manager.

| Run state (M2) | Prefix | Tab tint (`color_tab`, semantic) |
|---|---|---|
| running | `⏲ ` | accent |
| needs you | `⚠ ` | warning |
| failed (pane kept) | `✗ ` | error |
| finished ok (pane kept) | `✓ ` | success; tint drops after the tab has been viewed |

The agent block's own title stays what omp derives from the prompt (PR Q5); only the tab name carries the job name.

### 2.5 Carly exports [M3]

Natural-language entry for free, with swarm's safety model (LP swarm pattern 16: create is draft-only, destructive is not exposed; `doc`/`sig` ≤1024 bytes each, ≤16 exports, names `[a-z][a-z0-9_]{0,23}`, TP §2.8). Carly cannot create, update or delete a job (R10: no such intents); everything it does is a read, an allowlisted intent, or opening a draft.

| Export | Signature | Behavior |
|---|---|---|
| `jobs_list` | `jobs_list()` → table of `{name, schedule, next, role, cwd, state, last}` | Read-only. Reply ≤1 MiB (0.7.2). |
| `job_add` | `job_add(name, prompt, when, cwd?, role?)` | **Creates a draft, not a job.** Opens the manager (via `cx:new_block` with draft args) in the New job form pre-filled and returns "Draft opened for review". The user presses Save. Approval mode is the default, never hands-off, and cannot be set by Carly (LP swarm "approval flags only from the user"). There is no setting to let Carly save directly. |
| `job_run` | `job_run(name)` | Sends `run_now`; returns "Queued" once the host accepts it. |
| `job_pause` | `job_pause(name, paused)` | `pause` / `resume` for one job. |
| `jobs_pause_all` | `jobs_pause_all(paused)` | `pause_all` / `resume_all`. |
| `job_remove` | — | **Not provided in v1** (no delete intent). Deleting stays in the manager. |

Names resolve case-insensitively; an ambiguous or unknown name replies with the list of matches (PA §3i Hermes "ambiguous → refuse").

`doc` for `job_add` (fits 1024 bytes):
> Draft a scheduled omp agent job. `when` accepts: `daily 09:00`, `weekdays 9am`, `mon,thu 18:30`, `every 2h`, `every 15m` (min 5m), `hourly`, `weekly on friday 4pm`, `monthly on the 1st 9am`, `in 30m`, `tomorrow 8am`, `at 2026-10-14 15:00`, `manual`, or a 5-field cron like `0 9 * * 1-5`. `cwd` must be an existing local folder (default: the focused pane's). `role` is an omp model role such as `@default` or `@smol`. The user reviews and saves the draft.

Example utterances the doc and `tern.carly.context` (≤400 chars) support: "every weekday at 9 run a dependency audit in ~/Dev/app" → `job_add("dependency-audit", "Audit dependencies…", "weekdays 9am", "~/Dev/app")`; "what jobs do I have?"; "run the nightly tests now"; "pause everything"; "why didn't daily-review run on Monday?" (answered from `jobs_list` last-run sentence). Context line: `Schedule: 4 active, 1 paused; next daily-review Mon 09:00; 1 needs you (deps-audit).`

Scheduled runs themselves get no tool to create or change jobs (PA §5.11 "no chained automations").

### 2.6 Prompt `.md` file flow [M1]

Each job's prompt is one markdown file in the plugin data dir: `<data>/prompts/<job id>.md` (managed by the plugin; never in the package folder, LP pitfall 16/22). Plain markdown, no front matter shown to the user. A user-owned prompt file (`prompt_source="file"` / `prompt_path`) is **not part of v1** (R1; arbitrary-file read, RF S3c).

| Entry | Behavior |
|---|---|
| Form, **Prompt** row: `ctrl+o` or the "Open as file" button | Opens the file beside in Tern's doc editor (`cx.docs:open(path, {how="beside"})`). For an unsaved new job the manager writes the text to a **draft file** `<data>/drafts/<draft id>.md` and opens that; on Save the host moves it to `prompts/<job id>.md`, on Cancel it is deleted. Draft args from the palette ("New job", Quick add) or a Carly `job_add` are written to a draft file the same way. (`drafts/` is a sibling of `prompts/` in the `engine.md` §2 layout.) |
| Manager: `p` on a job / palette #10 (M2) | Opens `prompts/<job id>.md` beside. |
| After saving in the doc editor | The form (if open) re-reads the file when focused again; the detail view shows "Prompt edited 2m ago". Toast, if the manager is focused: `success` "Prompt updated" / sub "Applies to the next run". For a hands-off job this edit also stales the hands-off confirmation (§6.5). |

**How the prompt reaches the agent (R1; `launch.md` §2.2-2.3).** No user text is ever put on a command line. At fire time the host copies the prompt file to the run's snapshot `runs/<job id>/<run id>/prompt.md` and starts omp with that file attached plus the fixed first message "Run the scheduled job described in the attached file." So the first user message in the run's terminal is that sentence with `prompt.md` attached, not your text (§5.6 repeats this for Open run). The snapshot also means editing mid-run is safe and the run record shows what actually ran.

Rules: the file is the only source of truth for text (the inline editor writes the same file); an empty or missing file blocks the job with "Prompt is empty" (§4.2; `prompt_empty`) or "Blocked: the prompt file is missing." (`prompt_missing`); prompts are capped at 64 KiB (`prompt_too_large`).

---

## 3. Manager block

### 3.1 Regions

Host block, `view` returns `{main, dock, layer}` (GD blocks via TP §2.6; each region wrapped in a `col`).

| Region | Content |
|---|---|
| `main` | A mode stack: **List** (default) → **Detail** (Enter) → **Form** (`n`/`e`). `esc` pops one level; the list's selection, filter and folds are kept in block `save`. |
| `dock` | Always visible: line 1 = context (next run, filter field when `/` is active, banners); line 2 = key hints (width-tiered, §8.3); right edge = clickable `badge`s for the selected row's actions (mouse parity). |
| `layer` | Overlays: delete/stop confirmation, hands-off confirmation, pickers (`picker` node, §4), Setup sheet, Settings (`prefs` in `layer` = right-docked sheet, EL work `prefs`), help (`?`), and the first-run "Run it now and watch?" prompt (§6.3). |

Because the manager is a host block it has no window `cx`; **in-block choosers are `picker`/`overlay` nodes handled in `key`** (EL lists `picker`: "draws no real text field; typing, arrows, Enter and Escape must be handled in your block's key handler"). The palette commands (window half) use `cx:pick`; both show the same rows in the same order. The manager and the launcher live in the same host VM, so Run now, Save & run now and Stop call the launcher directly; Open run calls `tern focus`/`tern new tab` from the host. **Creating and editing jobs and settings happens only inside this block** (R10): palette commands and Carly can only open it with draft args (via `cx:new_block`, an M1 gate item) or send the allowlisted intents (run now, pause/resume, pause all, stop, focus/open run). Toasts and other window chrome are driven by the window half from `snapshot.json` + kv `rev`.

### 3.2 List sections

Order is fixed. Empty sections are not drawn (except the empty state, §3.5). One flat selection moves across sections with `j`/`k`/↑/↓ (each section is a `list`; the block gives each its own `selected`, EL lists). Scope: the first four sections are M1; Recent runs is M2 (M1 shows history in Detail, §3.5).

| Section | Scope | Contains | Default |
|---|---|---|---|
| **Needs you** | M1 | **Runs** waiting on a human (`needs_input`). Row = the run + reason. | open, pinned top |
| **Needs fixing** | M1 | **Jobs** that can't start until you change something: folder missing, role gone, omp missing, hands-off review (`blocked/*`). Row = the job + the blocked sentence. Kept separate from Needs you so each header has one meaning (RP). | open, under Needs you |
| **Running** | M1 | Runs in progress (name, started, elapsed). | open |
| **Upcoming** | M1 | Active jobs by next fire ascending; manual-only jobs sort last under "no schedule". | open |
| **Paused & finished** | M1 | Paused jobs, one-shot jobs that already ran, jobs auto-paused after failures (reason in detail). | collapsed (header shows count) |
| **Recent runs** | M2 | Last 10 runs of any job, newest first, including skipped/missed/caught-up rows with reasons. `h` unfolds/focuses it. | collapsed |

A job that is running appears in **Running** *and* keeps its row in **Upcoming** (value shows its next fire) so its next run never disappears.

### 3.3 Row anatomy

A row is a Tern `item` inside a `list` (EL lists): one line, label/detail/value truncate in that order (detail first, value last; value ≤40% of the row). Tone and icon carry state; text always says it too (§8).

```
 [icon]  name  @role      schedule · last outcome · cwd                      next-run value
```

| Part | Prop | Content |
|---|---|---|
| State icon | `icon` + `tone` | See table below |
| Name | `label` (span `strong`) | Job name; filter hits marked |
| Role chip | `label` (span `muted`, after name) | `@smol` |
| Schedule | `detail` | Human text: `Weekdays 09:00`, `Every 2h`, `Once · Fri 17:00`, `Manual only` |
| Last outcome | `detail` | `✓ Fri 09:03 · $0.42` / `✗ Sat 02:00 failed` / `— never run` (glyph is part of the text so it survives without color) |
| Working folder | `detail` | Tilde path, middle-ellipsis for long: `~/Dev/app`, `~/…/deep/app` |
| Next run | `value` | `Mon 09:00 · in 14h`; narrow: `in 14h`; running: `running 4m`; needs you: `waiting 6m`; paused: `paused` |
| Hands-off flag | `label` (span `warning`) | `⚠ hands-off` after the chip, only for hands-off jobs |

State icons: running `activity`/`accent`; needs you `warn`/`warning`; scheduled `clock`/`muted`; last failed `x-circle`/`error` (row still scheduled); paused `pause`/`muted`; finished one-shot `check`/`muted`; needs fixing `shield-alert`/`warning`; auto-paused after failures `x-circle`/`error`.

Width tiers (cells of the `main` region): **≥100** everything; **80–99** drops the folder; **60–79** drops role chip and cost; **<60** name + value only (schedule/last outcome move to Detail). Same tiers in the Needs you / Recent rows.

### 3.4 Keyboard map and mouse parity

One key per action; keys are handled in the block `key` handler (EL lists: lists never receive keys). Return `false` only when nothing changed (LP pitfall 13).

**List mode** (all M1 unless tagged)

| Key | Action | Mouse equivalent |
|---|---|---|
| `j` `k` / `↓` `↑` | Move selection (`g`/`G` first/last) | click row (`select`) |
| `enter` | Open **Detail** (on a needs-you run: **Open run**) | double-click row (`activate`) |
| `n` | **New** job (form) | `+ New` badge, dock |
| `e` | **Edit** selected job | `Edit` badge |
| `r` | **Run now** (refused while all jobs are paused: "Resume all jobs to run.") | `Run now` badge |
| `space` | **Pause / resume** | `Pause`/`Resume` badge |
| `d` `d` | **Delete** (two presses; any other key disarms) | `Delete` badge → turns into `Confirm delete` (tone `error`), second click confirms |
| `h` | **History**: Detail scrolled to the job's history. M2: also unfolds/focuses Recent runs | `History` badge |
| `o` | **Open run** (live or last block for the selected job) | `Open` badge |
| `x` | **Stop** the selected running run (confirm overlay `y`/`esc`) | `Stop` badge |
| `p` | Edit the prompt **file** (`prompts/<id>.md`, §2.6) | — |
| `c` | **Duplicate** (copy opens in the form as "New job", name `daily-review copy`, Active off; a hands-off job needs its confirmation again, §6.5) | `Duplicate` badge |
| `a` | Jump to next *needs you* | status segment / "needs you" section header click |
| `/` (M2) | **Filter** (inline field in dock; matches name, folder, role, schedule text, prompt first line; `esc` clears, `enter` keeps filter and returns to list) | click filter badge |
| `P` (shift+p) | **Pause all** / Resume all | `Pause all` badge |
| `u` | **Undo** the last delete (10 s) | — |
| `,` | Settings sheet (M1 core rows, §7.7) | `Settings` badge |
| `?` | Key help overlay | `?` badge |
| `esc` | Clear filter → close overlay → leave mode | `Close` |

**Detail mode**: all of the above that apply to the job, plus `↑`/`↓` through the run history, `enter` on a run = Open run, `m` expand/collapse the run's last message, `esc` back.

**Form mode**: §4.11. **Overlays** take `y`/`enter` confirm, `esc` cancel, arrows to move.

Mouse parity: the **dock** carries a badge row for the *selected row's* actions (`Run now · Edit · Pause · History · Delete`, tones `accent`/`neutral`; `actions.click = "run=ID"` style, EL lists/GD views); rows send `select`/`activate`. Right-click (`actions.menu`) opening the same action list as an `overlay` anchored to the row is M2 [INFERENCE: menu event payload]. Section headers fold on click. Everything keyboard-reachable is click-reachable and vice versa (rss parity, LP rss).

### 3.5 Wireframes

Notation: `▌` = selection bar; `⚠ ● ◷ ✓ ✗ ⏸` stand for the Tern icons in §3.3; the box is the block's `main`+`dock`.

**List (wide, 100 cells, one job running, one waiting)**

```
┌ Schedule ─────────────────────────────────────────────────────────────────────────────────────────────┐
│  Schedule                                              4 active · 1 running · 1 needs you · next 14h    │
│                                                                                                        │
│  NEEDS YOU  1                                                                                          │
│▌ ⚠ deps-audit  @default   Waiting for approval: "Run `npm audit fix`?" · ~/Dev/app           waiting 6m │
│                                                                                                        │
│  RUNNING  1                                                                                            │
│  ● weekly-notes  @smol    Fridays 17:00 · ✓ Fri 17:04 $0.08 · ~/Dev/notes                  running 4m │
│                                                                                                        │
│  UPCOMING  3                                                                                           │
│  ◷ daily-review  @smol    Weekdays 09:00 · ✓ Fri 09:03 $0.42 · ~/Dev/app          Mon 09:00 · in 14h │
│  ✗ nightly-tests  @task   Daily 02:00 · ✗ Sat 02:00 failed · ~/Dev/api                Mon 02:00 · in 7h │
│  ◷ deps-audit  @default   Mondays 08:00 · ⚠ waiting · ~/Dev/app                        Mon 08:00 · in 13h │
│                                                                                                        │
│  ▸ PAUSED & FINISHED  2                                                                                │
│  ▸ RECENT RUNS  10                                                                                     │
│                                                                                                        │
├────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  Next: daily-review in 14h (Mon 12 Oct 09:00)           [Open run] [Edit] [Pause] [History] [Delete]   │
│  n new  e edit  ⏎ open  r run now  ␣ pause  dd delete  h history  P pause all  ? more                  │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```
(The dock badge row shows the selected row's actions; with a needs-you row selected the lead badge is `Open run`.)

**List (narrow, 56 cells)**

```
┌ Schedule ─────────────────────────────────────┐
│ NEEDS YOU  1                                    │
│▌⚠ deps-audit                         waiting 6m │
│ RUNNING  1                                      │
│ ●weekly-notes                        running 4m │
│ UPCOMING  3                                     │
│ ◷daily-review                          in 14h │
│ ✗nightly-tests                          in 7h │
│ ◷deps-audit                            in 13h │
├─────────────────────────────────────────────────┤
│ Next: daily-review in 14h                       │
│ n new · ⏎ open · r run · ␣ pause · ? keys       │
└─────────────────────────────────────────────────┘
```

**Detail / history (Enter on `daily-review`)**

```
┌ Schedule › daily-review ──────────────────────────────────────────────────────────────────────────────┐
│  ◷ daily-review                                                                  Active · next in 14h  │
│  ───────────────────────────────────────────────────────────────────────────────────────────────────  │
│  When       Weekdays at 09:00 (local, PDT) · 0 9 * * 1-5                                               │
│  If asleep  Run once when I'm back, if under 3h late                                                   │
│  Next       Mon 12 Oct 09:00 · Tue 13 Oct 09:00 · Wed 14 Oct 09:00                                    │
│  Role       @smol → Haiku 5.5 (medium thinking)                                                        │
│  Folder     ~/Dev/app  ✓ exists · git: main · 3 uncommitted files                                      │
│  Appears    Scheduled runs session, background tab · never changes what you see                        │
│  Safety     Asks before commands · stops after 30m                                                     │
│  After      Keeps the last 5 finished run panes · notifies when it needs me or fails                   │
│  Prompt     Review yesterday's commits and open PRs in this repo. Summarize what changed,         p edit│
│             flag risky changes, and list anything that needs a human decision. …                       │
│             The first message in the run is a fixed sentence; your prompt is attached to it.           │
│                                                                                                        │
│  RUNS  (last 20)                                                                                       │
│▌ ✓ Fri 09:03     4m 12s   $0.42   Haiku 5.5   "3 PRs merged, 1 risky change in auth/session.ts"        │
│  ✓ Thu 09:01     3m 58s   $0.39   Haiku 5.5   "Quiet day: 2 docs commits, nothing to flag."            │
│  ↷ Wed 09:00     skipped          The previous run was still going.                                    │
│  ✓ Tue 09:42     caught up       Missed Tue 09:00 while Tern was closed; ran once at 09:42.            │
│  ✗ Mon 09:00     timed out        Stopped at the 30m limit. Last message: "Reading src/…"              │
│                                                                                                        │
├────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  Open run: pane is closed, resumes in a new tab                  [Open run] [Run now] [Edit] [Pause]   │
│  ⏎ open run  r run now  e edit  p prompt file  m message  ␣ pause  dd delete  esc back  ? more         │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```
Run-row glyphs (R13):

| State | Glyph / icon | Notes |
|---|---|---|
| needs you | `⚠` | tone `warning` |
| ok | `✓` | |
| caught up | `✓` + "caught up" in the sentence | not a separate glyph |
| failed, timed out | `✗` | tone `error` |
| stopped (by you, or closed by you) | `■` | neutral tone, not an error |
| blocked | `shield-alert` icon | tone `warning`; the job also appears under Needs fixing |
| skipped | `↷` | |
| missed | `◌` | |
| test / manual run | text suffix only: `(test)` (M2) / `(manual)` | no glyph change |

Expanded run (`m`): last assistant message (≤12 lines, wrapped), the model that actually ran, the session id, and the cost line.

**Empty state**

```
┌ Schedule ─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                        │
│   Run an omp agent on a schedule.                                                                      │
│   Pick a time, write a prompt, point it at a folder. Runs show up here when they need you.             │
│                                                                                                        │
│   START FROM AN EXAMPLE                                                                                │
│▌ TODO sweep            Weekdays 12:30 · @smol · ~$0.10         Find and rank TODO/FIXME comments       │
│  Docs check            Fridays 13:00 · @smol · ~$0.10          Compare README and docs with the code   │
│  Dependency audit      Mondays 12:30 · @smol · asks first      Report outdated or vulnerable packages  │
│                                                                                                        │
│  Jobs run while Tern's session service is running. It keeps running after you close windows as long as │
│  a terminal or run is still open. Nothing runs while your Mac is asleep, or after a restart until you  │
│  open Tern.  Details                                                                                   │
├────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  ⏎ use example   n new job   ? how it works                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```
Examples open the form pre-filled; nothing is created until Save (PA §6). Template texts, approval modes and costs are in §6.1. **Details** opens the Setup sheet scrolled to the Keep-alive row (§6.2, §6.4). The empty state, the form and all list screens are M1.

**Optional mock (SVG, theme variables only, no background)**

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 150" font-family="var(--mono, monospace)" font-size="12">
  <text x="12" y="18" fill="var(--t3)">NEEDS YOU  1</text>
  <rect x="4" y="26" width="632" height="22" rx="5" fill="none" stroke="var(--accent)"/>
  <text x="14" y="41" fill="var(--warn)">⚠</text>
  <text x="34" y="41" fill="var(--t1)" font-weight="bold">deps-audit</text>
  <text x="112" y="41" fill="var(--t3)">@default</text>
  <text x="186" y="41" fill="var(--t2)">Waiting for approval: “Run npm audit fix?”</text>
  <text x="626" y="41" fill="var(--warn)" text-anchor="end">waiting 6m</text>
  <text x="12" y="72" fill="var(--t3)">UPCOMING  3</text>
  <text x="14" y="94" fill="var(--t3)">◷</text>
  <text x="34" y="94" fill="var(--t1)" font-weight="bold">daily-review</text>
  <text x="130" y="94" fill="var(--t3)">@smol</text>
  <text x="186" y="94" fill="var(--t2)">Weekdays 09:00 · ✓ Fri 09:03 $0.42 · ~/Dev/app</text>
  <text x="626" y="94" fill="var(--t1)" text-anchor="end">Mon 09:00 · in 14h</text>
  <text x="14" y="118" fill="var(--bad)">✗</text>
  <text x="34" y="118" fill="var(--t1)" font-weight="bold">nightly-tests</text>
  <text x="130" y="118" fill="var(--t3)">@task</text>
  <text x="186" y="118" fill="var(--t2)">Daily 02:00 · ✗ Sat 02:00 failed · ~/Dev/api</text>
  <text x="626" y="118" fill="var(--t1)" text-anchor="end">Mon 02:00 · in 7h</text>
</svg>
```

---

## 4. Create / edit job form [M1: 9 rows; M2: Advanced section]

Same screen for New and Edit (title "New job" / "Edit daily-review"). **Implementation: a `prefs` page in the block's `main`** (EL work `prefs`): it gives labelled rows with hint/warning lines, switch / choice / number / text controls, "changed from default" dots with Reset, all keyboard-driven through `editing`/`focus` props with our `key` handler (LP swarm settings page, `prefs` precedent). Text rows edit in-block with swarm's `textfield` lib (UTF-16 cursor, LP pattern 17). The M1 form is the 9-row form in §4.11 (RP P3/§4.2, decisions R23, Q6 in §9); everything else in this section is tagged M2. **M1 gate (spike first):** multi-line text editing and `prefs` inside a host block. If multi-line editing misses its time box, the Prompt row ships as a one-line field plus `ctrl+o`, which opens `prompts/<job id>.md` (or its draft, §2.6) in Tern's doc editor.

Dock during the form: hint line plus the clickable badges **Save** · **Save & run now** · **Cancel** (M2 adds **Test run**).

### 4.1 Field table

| # | Field | Scope | Control | Default | Notes |
|---|---|---|---|---|---|
| 1 | **Name** | M1 | `text` row (in-block) | none; placeholder = slug of the prompt's first words, `Tab` accepts | ≤40 chars |
| 2 | **Prompt** | M1 | row shows first 3 lines; `enter` opens the in-block **editor card** (multi-line, `enter` = newline, `ctrl+enter` = done); `ctrl+o` opens the `.md` file beside | none | Required; ≤64 KiB. Source: `prompts/<job id>.md` (§2.6) |
| 3 | **When** | M1 | `text` row (phrase / cron / date) + **Presets…** (`ctrl+p`: picker) | `weekdays 09:00` | Live preview under it (§4.3) |
| 4 | **If your Mac was asleep** | M1 | `choice` (3), in the main section (R19) | Run once when I'm back, if under 3h late | §4.1a below. Default pending Q2 (§9) |
| 5 | **Folder** | M1 | `text` row showing tilde path + **Pick…** (`enter`: picker of recent folders) | focused local pane's cwd, else empty and required | §4.5 |
| 6 | **Role** | M1 | `choice` row, menu style, opens picker | `@default` | §4.4 |
| 7 | **Approval** | M1 | `choice` (3 options in M1, 4 once Read-only is verified) with `warning` line | Ask before commands (pending Q1) | §4.7 |
| 8 | **Stop after** | M1 | `choice` menu | 30 min | §4.7 |
| 9 | **Active** | M1 | `switch` | on | Off = "Save paused". Good for a canary: "Save paused, then press r." |
| — | Where it appears · Bring to front | M2 (global in Settings in M1) | `choice` / `switch` | Scheduled runs session · off | §4.6 |
| — | When it finishes · Tell me | M2 (global in M1) | `choice` | Keep it open (limit 5) · Only when something needs me | §4.8 |
| — | If still running · Late limit · Pause after repeated failures · Tell the agent nobody is watching · Quiet when nothing to report | M2 | per §4.9 | per §4.9 | §4.9 |

**4.1a If your Mac was asleep** (R19; `catch_up` in `engine.md`): options **Run once when I'm back, if under 3h late** (default; `within`, the 3 h limit is a Settings value in M1) · **Run once, however late** (`always`) · **Skip missed runs** (`skip`). Hint: "Missed means Tern wasn't running or your Mac was asleep. Several misses count as one." For a schedule at an hour a laptop is usually asleep the preview adds: "Your Mac is often asleep at 02:00; a run more than 3h late is skipped. Pick a time you're usually awake." *(PA §5.3: single catch-up; RP P6)*

### 4.2 Per-field behavior and validation

Validation runs on every edit and again on Save; the first failing row gets the focus ring and its `warning` line. Save is disabled (badge `disabled`) while any row has an error; the dock says which.

**Name**: required; unique, case-insensitive (the stable id is separate and never shown); no leading/trailing space; ≤40. Errors: "Give the job a name." · "A job named “daily-review” already exists. Pick another name." *(PA §6 duplicate names)*

**Prompt**: required; text must be non-empty. Error: "Write what the agent should do." Hint under the row: "Say what to do if something is unclear. Nobody is watching a scheduled run." *(OC §6; swarm tells the agent too)* Counter shows only past 4,000 chars: "6,200 characters · long prompts read better as a file (ctrl+o)". The same validator runs on every payload that creates or changes a job (R10).

### 4.3 When: schedule input, presets, preview

One text field accepts all of these, parsed live by the same grammar Carly uses (§2.5):

| Kind | Examples |
|---|---|
| Preset phrases | `hourly` · `daily 9am` · `weekdays 09:00` · `weekends 10:00` · `weekly on friday 4pm` · `monthly on the 1st 9am` · `mon,thu 18:30` |
| Intervals | `every 2h` · `every 30m` (minimum 5m) |
| One-shot | `in 30m` · `tomorrow 8am` · `at 2026-10-14 15:00` · `once Fri 17:00` |
| Cron (5-field) | `0 9 * * 1-5` · `*/15 8-18 * * mon-fri` |
| Manual | `manual` (run-now only) |

**Presets…** (`ctrl+p`, in-block `picker` size `md`; palette flow uses `cx:pick`): rows with live "next" detail:
`Hourly` (at :00) · `Daily` (09:00) · `Weekdays` (09:00) · `Weekly` (Mon 09:00) · `Monthly` (1st, 09:00) · `Once` (tomorrow 09:00) · `Every N minutes/hours…` · `Manual only`. Picking one writes its canonical phrase into the field and leaves the caret on the time so typing `8` updates the preview (cheap, predictable; PA §5.2 presets-first + escape hatch). *(Claude Desktop presets PA §1a; Cowork §1d; Raycast §3g; Copilot cron preview §3b)*

**Live preview** (hint under the row, updates per keystroke; 3 lines, tone `muted`, `warning` on trouble):

```
Weekdays at 09:00 · next Mon 12 Oct 09:00 (in 14h)
then Tue 13 Oct 09:00 · Wed 14 Oct 09:00 · Thu 15 Oct 09:00
Times are in your Mac's time zone (PDT).
```
Cron input echoes the plain-English reading first: `Reads as: at 09:00, Monday to Friday`. One-shot: `Once · Fri 16 Oct 17:00 (in 5d) · runs one time, then stays here as finished`. Manual: `Manual only · runs when you press r. Never on a schedule.`

Special cases:
- Day-of-month **and** weekday both set in cron: warning line "Both a date and a weekday are set. Like cron, it runs when either one matches." *(PA §3h OpenClaw OR trap)*
- Time that does not exist or repeats at a DST change: preview line "On Sun 8 Mar 02:30 doesn't exist (clocks move forward); it runs at 03:00 that day." / "…happens twice; it runs once, the first time." *(PA §6 timezone/DST)*
- More than one job at the same minute: no stagger; runs start in order, one launch at a time. The concurrency cap is a setting (default 2 running at once); a run over the cap waits up to 10 min, then is recorded "Skipped: 2 other jobs were already running (limit 2)."
- Interval under 5m: error "Agent runs shorter than 5 minutes apart tend to overlap. Use every 5m or more."
- One-shot in the past: error "That time has already passed."
- Unparseable: error "Couldn't read “every blue moon”. Try “weekdays 9am”, “every 2h”, or a cron like 0 9 * * 1-5."

### 4.4 Role [M1]

`choice` row; opening it shows the role picker (`picker` size `md`, in-block; `cx:pick` from the palette). Roles are read **per job folder** (`omp config get modelRoles --json` run in the Folder row's cwd, since a project can override them; the list refreshes when Folder changes), cached 30 min (LP pattern 2; `roles.luau`), sorted `default, smol, task, plan, slow`, then custom roles; kind roles (`image web speech dictation judge`) and `commit memory tiny vision advisor dictation speech` are hidden (OC §2/§3, swarm `SKIP`). A role is stored bare (`default`) and always shown and passed as `@default`; **`@default` is the default for new jobs** (R16). Each row: label `@smol`, detail = the model behind it, e.g. `claude-haiku-5-5 · medium thinking`, `current` check on the selected role. The row hint under the choice: "Resolved each time the job runs, so changing what @smol points to changes this job. Runs record the model they actually used. @default is your omp default model and can cost more than @smol." *(PA §5.13)*

There is no "Other model…" row and no pinned-model chip in v1 (R16; a model id can't be entered). Preflight at fire time: if the role list was read and the role is absent, the run is **blocked** (`blocked/role_missing`), no tokens spent: "Blocked: role @research no longer exists in omp. Edit the job and pick another role." and the job moves to Needs fixing. If the role list can't be read, the run proceeds and records `role_unverified` (§5.5: "Ran without checking role @smol (couldn't read your omp roles)."). *(PA §5.11 preflight; Hermes `blocked_config` §3i)*

### 4.5 Folder [M1]

One concept: a **fixed folder** (no "wherever I am when it runs", which is unpredictable unattended).

- **Pre-fill**: the focused pane's cwd if the pane is local. Remote panes are refused with "That pane is on another machine. Pick a folder on this Mac." (LP pitfall 20, swarm `focused_cwd`). With no focused local pane the row is **empty and required**: Save is disabled and the row says "Pick a project folder." There is **no `~` or `$HOME` fallback** (R17, RP P12).
- **Pick…** opens the folder picker: groups **Open in Tern now** (cwds of `cx.session:panes()`), **Recent jobs**, **Recent agents** (cwds in `cx.agents:list()`), then **Type a path…** (one-line field with `~` expansion). Row detail = `git · main` for repos.
- **Home folder** is allowed only when picked explicitly: the job stores `allow_home = true` (the launcher passes `--allow-home`) and the row shows the omp caveat: "omp may work in a temporary folder instead of your home folder. Pick a project folder for predictable results." *(OC §0 1d)*
- **Unsafe characters**: a path containing any of `'` `"` `\` `$` `` ` `` `!` or a newline is rejected at Save with "Folders with quotes, $ or ! in the name aren't supported yet." (the host builds a shell string, so these can't be passed safely; R17).
- Display always tilde-shortened; the stored value is the absolute path.
- Checks (on edit, on Save, and at every fire):

| Check | Copy |
|---|---|
| Empty | "Pick a project folder." |
| Missing / not a directory | "~/Dev/ap doesn't exist." / "~/Dev/app.txt is a file, not a folder." |
| Unreadable | "Tern can't read ~/Dev/app. Check its permissions." |
| Unsafe characters | "Folders with quotes, $ or ! in the name aren't supported yet." |
| Home folder (explicit) | warning: "omp may work in a temporary folder instead of your home folder. Pick a project folder for predictable results." |
| Remote | "Remote folders aren't supported yet." |

- **Git hint** under the row when the folder is a repo: `git · main · 3 uncommitted files` and, if dirty and the approval allows edits: warning "The agent works in this checkout, including your uncommitted changes." The same hint is shown in Detail (RP). *(PA §6 "Running against the live checkout"; worktree isolation is M3)*
- At fire time a missing folder → run **blocked** "Blocked: ~/Dev/app doesn't exist" and the job is marked *needs fixing* (one alert, not one per tick; PA §5.11).

### 4.6 Where runs appear (placement) and focus [M1 as Settings; per job M2]

In M1 placement is a global setting (Settings › Runs), not a form row; per-job placement joins the form in M2 (R23). Every option is launched by the host with `tern new …` (`architecture.md` Decision); the tab is named `⏲ <job>`. The dedicated session's name is a setting, default **`Scheduled runs`** (R22; the palette group and manager tab stay "Schedule").

| Option | Scope | What the user gets | Launcher |
|---|---|---|---|
| **Scheduled runs session, background tab** (default) | M1 | A tab `⏲ daily-review` in the session named **Scheduled runs** (created on first use). What you see and where you type never changes; open the session to look. | `tern new tab "Scheduled runs" --json --cwd …` / `tern new session "Scheduled runs" …` (PR2 tests 4, 5); exact flags in `launch.md` |
| **Background tab in the current session** | M1 | A tab `⏲ daily-review` next to your working tabs, never shown or focused. | `tern new tab <shown session> …` |
| **Split beside a pane** | M2, listed only after V10 passes | Opens next to the focused pane at fire time. Hint: "This shrinks the pane you're working in." No focused local pane → falls back to the default option and says so in the run row. | `launch.md` V10 |
| **Picture-in-picture** | M2, listed only after V11 passes | A small floating window in a corner (`tl/tr/bl/br`, default `br`). | `launch.md` V11 |

Options whose V-item has not passed are not shown (no disabled rows).

**Bring to front when it starts** (switch, Settings, default **off**; per job M2): when on, the host runs `tern focus <block>` after launch, so the run is shown and focused. Needs-you never takes focus. Hint: "Off: the run starts quietly and you stay where you are."

**More than one Tern window (R21).** `tern` acts on one window's sessions, else the first window, and the plugin can't read which window it runs in. Expected: sessions are daemon-wide and runs appear in the shared “Scheduled runs” session whatever window you are in. **[M1 verify, gating: with two windows, are sessions daemon-wide or per window?]** If per window: runs land in the first window, and Settings › Runs shows "With several Tern windows open, scheduled runs start in the first window."

### 4.7 Approval, runtime, safety [M1]

**Approval** (choice, menu; each option has a one-line `detail`; maps to `--approval-mode`, OC §0 1c). **The default for new jobs is Ask before commands, pending the user's decision on Q1 (§9, R18).**

| Option | Detail | omp | Shown |
|---|---|---|---|
| **Read-only** | Reads and searches only. Can't edit files or run commands. | tool allowlist (`launch.md` V9) | **Hidden until V9 verifies the allowlist**; M1 lists three options |
| **Ask before commands** (default) | Edits files on its own; waits for you before running shell commands. | `write` | always |
| **Ask for everything** | Waits for you before any edit or command. | `always-ask` | always |
| **Hands-off** | Never asks. Runs commands and edits files as you. | `yolo` | always |

No example job or default prompt may need a shell under an approval mode that forbids it (R18, §6.1). A repo's own `.omp/config.yml` can't widen "Ask before commands": the run passes a config overlay (R7).

Choosing **Hands-off** shows a persistent `warning` on the row: "Hands-off runs commands and edits files as you, with your credentials, while you're away. Only use it for prompts you'd trust unattended." Saving a job with Hands-off shows a confirm overlay (§6.5) with `[Use hands-off]` / `[Keep asking]`. **The confirmation is bound to the job's prompt text, folder and role** (R10): editing any of them (including the prompt `.md` file) makes the job `blocked/hands_off_review` until it is confirmed again in the manager, and the overlay shows again on the next Save. The row in lists shows `⚠ hands-off`. Waiting-for-approval runs are *needs you*, never silently stuck while a window is open (PA §5.5, §6 "Permission stalls").

Hint under the row for Ask-before-commands: "If a run stops to ask, it shows up under Needs you. Use Save & run now to see what it asks for."

**Stop after** (menu, M1): `5 min · 15 min · 30 min (default) · 1 hour · 2 hours · 4 hours · Other…` (in-block field "e.g. 90m", max 8h). No "unlimited" (PA §6 "Process leaks"). Hint: "The run is stopped, not paused, when time is up."

### 4.8 After it runs: pane limit and notifications [M1 global; per job M2]

Every run is launched keep-open and the host alone closes run panes (R5). **M1 keeps at most 5 finished run panes** (Settings › Runs › "Finished run panes to keep", default 5): the oldest finished, unfocused run pane is closed after its summary, cost and session id are saved, and **Open run** resumes the session later (§5.6). Failed or needs-you runs are closed last. Copy under the setting: "Each finished run keeps an omp process open, roughly 100–500 MB. Tern closes the oldest beyond 5; Open run reopens any of them." (RF F9) Per-job **When it finishes** (Keep it open, subject to the limit · Close if it succeeded · Close when done) is M2.

Notifications in M1 are fixed: toast and OS notification for needs-you, failures and blocked jobs; nothing for success. The per-job **Tell me** row (Only when something needs me · Every run · Never, plus a System notification switch) is M2. The host sends every OS notification (R8).

### 4.9 More options [M2]

An "Advanced" section that starts folded (`changed` dots show "N changed"). Not in the M1 form.

| Row | Options | Hint copy |
|---|---|---|
| **Where it appears** + **Bring to front when it starts** | per-job copies of the Settings (§4.6) | |
| **When it finishes** | segmented (§4.8) | |
| **Tell me** | choice + System notification switch (§4.8) | "Quiet runs are never announced." |
| **If still running** | **Skip this run** (default) · **Run after it finishes** (at most one waits) · **Run both** | "Skipped runs are listed in history with the reason." *(PA §5.4)* |
| **Late limit** (belongs to "If your Mac was asleep") | `number` hours, default 3 | "A run later than this is recorded as missed." |
| **Pause after repeated failures** | switch + `number` (2–10, default 3) | "Stops a broken job from burning money every day." *(PA §5.12)* |
| **Tell the agent nobody is watching** | switch, default on | M1 always sends the unattended preamble (`launch.md` §3; R6). This row only lets you turn it off. |
| **Quiet when nothing to report** | switch, default off | Adds a `RESULT: [quiet]` clause to the preamble; such runs are recorded `✓ quiet` and never announced. Deferred past M1 (R6). *(PA §5.8)* |

### 4.10 Save, Save & run now, Test run [Save, Save & run now: M1; Test run: M2]

| Action | Chord | Does |
|---|---|---|
| **Save** | `ctrl+enter` / badge | Validates, writes the job, returns to the list with the row selected. Toast `success`: "Saved daily-review" / sub "next Mon 12 Oct 12:30". Edit: "Saved. Takes effect on the next run" when a run is in flight. The first-ever Save offers "Run it now and watch?" (§6.3) unless Active is off. |
| **Save & run now** | `ctrl+shift+enter` | Save, then start a run immediately, brought to front so you can watch (user-initiated; this is the watched first run). The next scheduled fire is unchanged. Copy under the badge: "Runs once right now, exactly as scheduled. It can change files." |
| **Test run** (M2) | `ctrl+t` | Runs the *current draft* once without saving it, tagged `(test)`; it doesn't count toward failure streaks or "last outcome". Deliberately not "dry run": the agent can change files. |
| **Cancel** | `esc` | If anything changed: `esc` again within 3 s confirms ("Discard changes? esc again"). Drafts persist in block `save` for reload only. |

Palette "New job…" (and, in M3, a Carly `job_add`) opens this form pre-filled as a draft; nothing is saved until Save (R10). Creating and editing jobs happens only inside this block; there are no create/update intents.

### 4.11 Form wireframe (M1: 9 rows)

```
┌ Schedule › New job ────────────────────────────────────────────────────────────────────────────────────┐
│  New job                                                                       3 changed from default  │
│  Run an omp agent on a schedule.                                                                       │
│                                                                                                        │
│  JOB                                                                                                   │
│  Name           daily-review▏                                                                          │
│  Prompt         Review yesterday's commits and open PRs in this repo. Summarize what           ⏎ edit  │
│                 changed, flag risky changes, and list what needs a human decision.            ^O file  │
│                 Say what to do if something is unclear. Nobody is watching a scheduled run.            │
│  When           weekdays 12:30                                                             ^P presets  │
│                 Weekdays at 12:30 · next Mon 12 Oct 12:30 (in 17h)                                     │
│                 then Tue 13 Oct 12:30 · Wed 14 Oct 12:30 · Thu 15 Oct 12:30 · PDT                      │
│  If your Mac was asleep   Run once when I'm back, if under 3h late ▾                                   │
│                 Missed means Tern wasn't running or your Mac was asleep. Several misses count as one.  │
│  Folder         ~/Dev/app                                                                      ⏎ pick  │
│                 git · main · 3 uncommitted files. The agent works in this checkout.                    │
│  Role           @default ▾                                                                             │
│                 claude-opus-5-5 · medium. Costs more than @smol. Resolved each time the job runs.      │
│                                                                                                        │
│  SAFETY                                                                                                │
│  Approval       Ask before commands ▾                                                                  │
│                 If a run stops to ask, it shows up under Needs you.                                    │
│  Stop after     30 min ▾                                                                               │
│                                                                                                        │
│  Active         [on]                                                                                   │
├────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│  Jobs run while Tern's session service is running. It keeps running after you close windows as long as │
│  a terminal or run is still open. Nothing runs while your Mac is asleep, or after a restart until you  │
│  open Tern.                                                                                            │
│  [ Save ^⏎ ]  [ Save & run now ^⇧⏎ ]  [ Cancel esc ]                     ↑↓ move · ←→ change · ⏎ edit  │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```
With Hands-off chosen the Approval row's hint becomes the warning from §4.7. With an invalid row, the row shows its error under the label and **Save** is dimmed with the dock reading "Fix: When". With an empty Folder the row reads "Pick a project folder." M2 adds the Advanced section (§4.9) between Stop after and Active.

**Form keys**: `↑`/`↓` and `tab`/`shift+tab` move between rows; `←`/`→` change a segmented/choice value; `space` flips a switch; `enter` edits a text row, opens a menu or picker; inside text editing `enter` commits, `esc` reverts the row; `ctrl+o` prompt file; `ctrl+p` presets; `ctrl+enter`, `ctrl+shift+enter`, `esc` as §4.10 (`ctrl+t` is M2); `/` searches rows (prefs search, M2); `R` resets the focused row to its default.

---

## 5. Run lifecycle UX

### 5.0 Labels and engine states [M1]
The engine's states are canonical (`engine.md` §7: `scheduled launching running needs_input finished failed timed_out cancelled skipped missed blocked`); the UI shows labels through this one table (R12). Reason codes are `engine.md` §7.4 / `launch.md`; the words here win. Glyphs are from §3.5.

| UI label | Engine state / reason | Glyph | Where the wording is |
|---|---|---|---|
| starting | `launching` | `activity` | "Starting…" |
| queued | `scheduled`, waiting on the concurrency cap (`waiting_cap`) or the overlap queue | `clock` | "Queued: 2 jobs are running." |
| running | `running` (no window observing: "running (not observed)") | `activity` | §5.2 |
| needs you | `needs_input` | `⚠` | §5.3 |
| ok | `finished/ok`, `ok_unobserved` | `✓` | §5.4 |
| caught up | any run with `trigger=catchup` (its outcome label stays; the row adds "caught up") | `✓` + "caught up" | §5.5 |
| failed | `failed/*` (`agent_failed`, `no_response`, `interrupted`, `exited_early`, launch errors) | `✗` | §5.5 |
| timed out | `timed_out/*` | `✗` | §5.5 |
| stopped | `cancelled/user_stop` (also `replaced`) | `■` neutral | §5.5 |
| closed by you | `cancelled/closed_by_user` (block gone without our close, no daemon gap) | `■` neutral | §5.5 |
| blocked | `blocked/*` (`cwd_missing`, `role_missing`, `omp_missing`, `hands_off_review`, …) | `shield-alert` icon | §5.5 |
| skipped | `skipped/*` (`overlap`, `cap`, `paused_all`) | `↷` | §5.5 |
| missed | `missed/*` (`asleep_or_closed`, too late) | `◌` | §5.5 |
| quiet (M2) | `finished` with `quiet=true` | `✓` | §5.4 |

Runs that never started (blocked, skipped, missed) are rows in history with a sentence, never silent (principle 4).

### 5.1 At fire time [M1 unless tagged]

| Placement / focus | What the user sees |
|---|---|
| Default (Scheduled runs session, background tab) | No toast, except the first-ever scheduled run (§6.6). A tab `⏲ daily-review` appears in the “Scheduled runs” session; the status segment becomes `daily-review · 0m` (accent), the manager row moves to Running. The view, focus and keystrokes do not change. |
| Background tab in the current session | Same, but the tab sits beside your working tabs, unfocused. |
| "Bring to front when it starts" (Settings, M1; per job M2) | The host runs `tern focus <block>`; the run is shown and focused. No toast. |
| Save & run now / first-run overlay | Always brought to front (user-initiated). |
| Several Tern windows open (R21) | Runs start in the window the `tern` CLI picks (the first window). **[M1 verify: sessions daemon-wide or per window]** If per window, scheduled runs land in the first window only, and the Settings fine print says so. |
| Picture-in-picture, Split (M2, shown only after V10/V11 pass) | PiP: a small floating block in the chosen corner. Split: a new pane beside the focused pane (focus behavior verified first). |
| "Every run" notifications (M2) | `info` toast "daily-review started" / sub "@smol · ~/Dev/app". |
| Test run (M2) | Always brought to front; toast `info` "Test run: daily-review". |
| No Tern window open at fire time | The run starts normally: the host launcher needs no window (PR2 test 5). Tab names are set by the host; badges, status segment and toasts catch up when a window opens. **Needs-you cannot be noticed without a window** (R8): a run that stops for approval waits silently until a window opens or its time limit hits. Host-visible failures (launch failure, early exit, timeout, blocked) still send the OS notification. |

### 5.2 While running [M1]

- Tab name `⏲ daily-review` (set by the launcher); manager Running row `● daily-review @smol …  running 4m` (elapsed updated per minute); status `daily-review · 4m`.
- Manager Detail shows the live `last_message` tail (from the window's observer samples, TP §2.3) when a window is observing; otherwise "Running (not observed: no Tern window open)."
- Stalled-start guard: no `working` state within 180 s of launch → the run is `failed/no_response`: "Couldn't start: the prompt wasn't delivered." It counts toward the failure streak and the pane is kept so you can look. A `delivery_error` reads "Couldn't start: omp needs updating to receive the prompt." *(LP pitfall 22, TP §2.3)*

### 5.3 Needs you [M1]

Trigger: the agent state `waiting_input` held past the engine's debounce (`engine.md` §6.5: 10 s; the host debounces raw window samples, R9), or a foreign pane opened in the run's tab (LP pattern 6).

| Where | Copy |
|---|---|
| Tab (M2) | `⚠ deps-audit`, tinted warning |
| Status segment | `1 needs you · deps-audit` (`bell`, tone `warn`); click = Go to run |
| Toast (`info`) | text "deps-audit needs you" · sub "Waiting for approval · ctrl+alt+shift+a to open" |
| OS notification | sent by the host only (R8; one writer, deduped): title "Schedule · deps-audit", body "Waiting for approval to run a command." (kind differentiated when known: "Asked a question") |
| Manager | Needs you row with the last message excerpt and wait time; `enter` = Open run; dock badge `Open run` |
| Reminder | One OS reminder after 30 min if still waiting; no further toasts |
| No window open | Nothing notifies until a window opens (§5.1, §6.4). |
| Resolution | When the agent returns to working, the badge clears; if the run then ends normally nothing else is announced |

Row hint when the reason is approval: "Waiting for approval. Set Approval to Hands-off in Edit to stop this job asking." The run ends at the time limit like any other: "Stopped at the limit while waiting for you."

### 5.4 On finish [M1]

Run record = outcome, started/finished, duration, resolved model, cost, summary, session id, and (if closed) "pane closed". The summary is the run's last `RESULT:` line (the always-on preamble asks for one, launch.md §3), else the first line of the last message (R6). `RESULT: FAILED - …` makes the run `failed/agent_failed`. Success is silent.

| Outcome | History sentence (exact) | Icon/tone |
|---|---|---|
| ok | `✓ Fri 09:03 · 4m 12s · $0.42 · "3 PRs merged, 1 risky change in auth/session.ts"` (text after `RESULT:`, else first line of the message; ≤80 chars) | `check` muted |
| ok, no window | `✓ Fri 09:03 · finished (no window was open to watch it)` | `check` muted |
| quiet (M2) | `✓ Fri 09:03 · quiet · $0.03 · nothing to report` | `check` muted |
| "Every run" toast (M2) | `success` "daily-review finished" / sub "4m 12s · $0.42" | — |

The **cost line** shows `$0.42`, `<$0.01`, or `—` when unknown, and sums turns (OC §5: Σ `usage.cost.total`); cost comes from the session JSONL read on the host and is labelled approximate (`~$0.42`) when only the last 1 MiB was read (R9). Detail view totals: "This month: 18 runs · $7.31".

Finished panes: the oldest finished, unfocused run panes beyond the global limit of 5 are closed after their facts are saved (R5); the row notes "pane closed (limit 5)" and Open run resumes the session (§5.6).

### 5.5 Failure, blocked, skipped, missed (reason copy) [M1]

Each is a row in History, never auto-archived (PA §6 "Failures that hide their own evidence"). Failures notify (toast `error` "nightly-tests failed" / sub = reason ≤120 chars; OS banner; status `x-circle`). After N consecutive failures (default 3, counting failed, timed out and config-blocked runs) the job is paused: toast `error` "nightly-tests paused after 3 failures" / sub "Fix the problem, then press space to resume."

| Row | Engine | Reason sentence |
|---|---|---|
| failed | `failed/agent_failed`, `agent_error` | "The agent stopped with an error: *<RESULT: FAILED reason, or last line of output>*." |
| failed (exited) | `failed/exited_early` | "The agent exited before finishing." |
| failed (no response) | `failed/no_response` | "Couldn't start: the prompt wasn't delivered." (counts toward the streak; pane kept) |
| failed (interrupted) | `failed/interrupted` (a daemon or heartbeat gap precedes the block's disappearance) | "Interrupted: Tern was closed while this run was in progress." |
| couldn't start | `failed/delivery_error`, `launch_error`, `launch_timeout` | "…omp needs updating to receive the prompt." · "Couldn't start: Tern couldn't open a block." · "Couldn't start: Tern didn't answer in time." |
| timed out | `timed_out/max_runtime` | "Stopped at the 30m limit. Last message: “…”." |
| timed out (waiting) | `timed_out/waiting_for_input` | "Stopped at the limit while waiting for you." |
| stopped | `cancelled/user_stop` | "Stopped by you." |
| closed by you | `cancelled/closed_by_user` | "Closed by you." |
| blocked | `blocked/cwd_missing` | "Blocked: ~/Dev/app doesn't exist." |
| blocked | `blocked/role_missing` | "Blocked: role @research no longer exists in omp." |
| blocked | `blocked/omp_missing` | "Blocked: omp wasn't found." |
| blocked | `blocked/hands_off_review` | "Blocked: the prompt, folder or role changed since you approved hands-off. Open Edit and confirm again." |
| blocked | other config blocks | "Blocked: Approval mode was changed in omp config; open Edit to review." (no tokens spent; one alert) |
| ran, role unchecked | `role_unverified` on a run that proceeded | "Ran without checking role @smol (couldn't read your omp roles)." |
| skipped (overlap) | `skipped/overlap` | "Skipped: the previous run was still going." |
| skipped (cap) | `skipped/cap` | "Skipped: 2 other jobs were already running (limit 2)." |
| skipped (paused all) | `skipped/paused_all` | "Skipped: all jobs were paused." |
| skipped (job paused) | not recorded | Paused jobs have no slots; a resume note says so (§5.7). |
| missed | `missed/asleep_or_closed` | "Missed Mon 09:00: Tern wasn't running or your Mac was asleep." |
| missed, too late | `missed` (over the catch-up limit; there is no `skipped(late)`) | "Missed Mon 09:00: 13h late, over the 3h limit." |
| caught up | any run with `trigger=catchup` | "Missed Mon 09:00 while Tern was closed; ran once at 09:42." (outcome glyph + "caught up") |

Test and manual runs carry a text suffix only: `(test)` (M2) or `(manual)`; no glyph change (R13).

### 5.6 Open run [M1]

Primary action on any run row (`enter`, `o`, badge **Open run**). Resolution order, user-visible results:

1. **Block still alive** (running, or kept open after finishing): the host runs `tern focus <block>`. The run is shown and focused (user-initiated). Liveness means a block whose command contains the run's `/runs/<job id>/<run id>/` path; a restored login shell does not count (R12).
2. **Block closed** (or the run finished and was closed by the pane limit): the host opens a new tab in the *shown* session, with the job's folder as `--cwd`, running `omp --resume` against the run's session folder. It may take focus because the user asked. Row note: "Resumed in a new tab. The original run record is unchanged." If the session file is gone: "That run's session was removed, so it can't be reopened. Its summary is below."
3. Runs that never started have no block: `enter` expands the reason instead.

What the run's terminal shows: omp's first user message is the fixed sentence "Run the scheduled job described in the attached file." with the job's prompt attached as `prompt.md` (a snapshot taken at fire time; nothing you wrote is typed into the command line, R1). Scrolling to the top therefore shows that sentence and an attachment, not your prompt text; the Detail view's **Prompt** row and the run record show what ran. Detail says this once: "The first message is a fixed sentence; your prompt is attached to it."

### 5.7 Catch-up after sleep or app closed [M1]

On wake, app/daemon start, or window open, the scheduler compares each active job's missed slots with its **If your Mac was asleep** rule (§4.1 row 4). Behavior:

- At most **one** catch-up run per job; older slots are recorded as one `missed` row (PA §5.3; Claude Desktop, Raycast, Hermes).
- Paused jobs never catch up; resuming says: "Resumed. Next run Mon 09:00 (runs missed while paused are skipped)."
- Catch-up runs start one at a time, 30 s apart, never as a burst (PA §6 "Catch-up bursts").
- Toasts: one job: `info` "Missed daily-review (Mon 09:00)" / sub "Running it once now"; several: `info` "Catching up 3 jobs" / sub "daily-review, deps-audit, +1". Over the late limit: history row only (missed, too late), plus a toast `info` "Skipped 1 missed job" / sub "13h late, over its 3h limit".
- History sentences exactly as in §5.5 (missed, missed too late, caught up). A catch-up run is tagged `caught up` in its row.

---

## 6. First run and trust

### 6.1 Onboarding empty state [M1]
Wireframe in §3.5. Three examples; each opens the form pre-filled and unsaved (PA §6 "hidden auto-created tasks"; rss starter feeds precedent, `PRODUCT.md`). Every example uses `@smol` and shows its cost, works under its stated approval mode (RP P2), and is scheduled at a time a laptop is usually awake (RP P6). The first two never need a shell, so they run unattended under the default; the third says it asks first. Hands-off is never pre-filled. *(R16, R18, R19)*

| Example | When | Approval | Role · cost | Prompt text |
|---|---|---|---|---|
| **TODO sweep** | `weekdays 12:30` | Ask before commands (it never needs one) | `@smol` · about $0.10 a run | "Search this project for TODO and FIXME comments. Group them by file, mark any that look urgent or stale, and list the five that matter most. If there are none, say so in one line. Don't change any files." |
| **Docs check** | `fri 13:00` | Ask before commands (it never needs one) | `@smol` · about $0.10 a run | "Read the README and the docs folder and compare them with the code in this project. List statements that look out of date or wrong, with the file and line. Don't change any files." |
| **Dependency audit** | `mon 12:30` | Ask before commands (asks first) | `@smol` · about $0.10 a run | "Run `npm outdated` and `npm audit` in this project. Write a short report: what to update now, what can wait. Don't change any files." |

Cost figures are estimates [INFERENCE: scaled from the sample `@smol` costs in §3.5]; replace them with measured values after the first real runs. The dependency audit runs shell commands, so under Ask before commands it stops under Needs you at the first command of every run; its row says "asks first" and the detail repeats it. (A no-ask version needs Q1 option A or hands-off.) The "Read-only" approval option stays hidden until its tool allowlist is verified (§4.7).

Folder defaults to the focused local pane's cwd; if there is none the Folder row is empty and Save asks for "Pick a project folder." (§4.5). The empty state also shows the availability text (§6.4).

### 6.2 Prerequisites check ("Setup") [M1]
Runs on first open of the manager and from the Setup sheet (palette command "Check setup" is M2; M1 reaches it from the manager banner and the `setup needed` status segment). Passing results collapse to nothing; any failure shows a banner "Schedule needs attention" and a Setup sheet (layer overlay, `size md`), each row with a fix line the user can copy (ternkit `cards.error` fixes, LP ternkit):

| Check | Pass | Fail copy → fix |
|---|---|---|
| Tern version | ≥0.7.2 | "Schedule needs Tern 0.7.2 or newer." → "Update Tern." |
| omp | Tern-managed omp, else the usual install locations, answers `--version` (launch.md §1) | "omp wasn't found. Scheduled runs can't start." → "Install omp, then check setup again." (There is no bare-`omp` fallback, R4.) |
| Roles readable | `omp config get modelRoles --json` parses in a job's folder | "Couldn't read your omp roles. Jobs still run, but role names aren't checked first." → "Run `omp config get modelRoles` in the job's folder." (info, not an error: R16 `role_unverified`) |
| Scheduler heartbeat | host tick seen within 2 min | "The scheduler isn't ticking." → "Reload plugins (palette: Reload plugins)." |
| Data folder writable | write+read a probe file | "Can't write to Tern's plugin data folder." |
| Keep-alive | `tern ls --json` lists at least one live terminal or run besides the manager | pass: "A terminal or run is open, so Tern's session service stays up after you close windows." · info: "Nothing is keeping Tern's session service alive. It may stop when you close the last window; jobs won't fire until you open Tern." → "Keep a terminal open, or leave a Tern window open." **[M1 verify: real session-service lifetime with zero windows is a gating V-item (R20); this row is the honest fallback]** |
| System notifications | `osascript` runs | "Banners are off; you'll still see toasts." (info, not an error) |

The Setup sheet always ends with the availability text (§6.4; info, never an error).

### 6.3 First run: "Run it now and watch" [M1]
After the user's **first ever Save** (job count 0→1), a `layer` overlay, unless Active is off (a job saved paused is not run against the user's intent) or the user used **Save & run now**:

> **Run it now and watch?**
> The first run shows you any permission prompts, so later runs go smoothly. It opens the run's terminal (an omp session) and takes you there; if it stops to ask, answer in that terminal.
> `[Run now  ⏎]`  `[Not now  esc]`

Verbs are collapsed to three: **Save**, **Save & run now**, **Run now** (list action, palette and this overlay). Save & run now and this overlay's Run now bring the run to front (user-initiated, so watching is the point); a Run now from the list or palette follows the job's placement. The run is a normal run (not tagged test). When that first run ends ok, one-time tip toast `info`: "Looks good. Next run Mon 12:30." / sub "Approval prompts? Edit › Approval". Shown once (flag in host `settings.json`, R11). Rationale: Claude Desktop's recommended workflow (create → Run now → approve) (PA §5.5, §1a).

### 6.4 Honest limits (always visible, four places: empty state, Setup sheet, form footer, Settings) [M1]
> **Jobs run while Tern's session service is running. It keeps running after you close windows as long as a terminal or run is still open. Nothing runs while your Mac is asleep, or after a restart until you open Tern.**

Where it is shown, **Details** (empty state and Settings) opens the Setup sheet scrolled to the Keep-alive row (§6.2). Further limits, each in the same fine print:
- **No window open (R8).** "With no Tern window open, a run that stops to ask for approval waits silently until you open a window or its time limit is reached. Launch failures, early exits, time-outs and blocked jobs still send a notification." (Needs-you can be observed only from a window; the host sees the rest.)
- **More than one window (R21, RP P4).** The `tern` CLI acts on one window's sessions, else the first window, and the plugin can't tell which window it is in. Expected: sessions are daemon-wide. **[M1 verify (gating): with two windows, are sessions daemon-wide or per window?]** If per window, the copy in Settings and Details becomes: "With several Tern windows open, scheduled runs start in the first window."
- Settings can show the last heartbeat time. "Keep Mac awake while a run is going" (`caffeinate`) is M2.

### 6.5 Unattended-permissions warning [M1]
Shown (1) on the Approval row for Hands-off (§4.7), (2) when a job is saved with Hands-off and whenever its confirmation is stale (confirm overlay), (3) as `⚠ hands-off` in every list row and in Detail "Safety: Hands-off: runs commands as you", (4) in Settings next to the default approval. Never auto-dismissed, never a toast. The confirmation is bound to the job's prompt text, folder and role (R10). Wording on the confirm overlay:

> **Use hands-off?**
> daily-review will run shell commands and edit files as you, with your credentials, whenever it fires, even when you're away. A prompt that reads web pages or issues can be tricked into doing things you didn't ask.
> This confirmation covers the prompt, folder and role as they are now. If you change any of them you'll be asked again, and until then the job won't run.
> `[Use hands-off  y]` `[Keep asking  esc]`

If the prompt (including an edit made in the `.md` file), folder or role no longer matches what was confirmed, the job becomes `blocked/hands_off_review`: row copy "Blocked: the prompt, folder or role changed since you approved hands-off. Open Edit and confirm again.", listed under Needs fixing, toast `{name} needs a hands-off review` (§7.3). Plugin data is not a security boundary against other processes running as you; the confirmation protects against accidents and against the plugin's own intent surface (R10), not against local malware.

### 6.6 First load and discovery [M1] (R25)
On the first load of the plugin, one `info` toast: "Schedule is ready." / sub "Press ctrl+alt+shift+s." (flag in host `settings.json`; never shown again). The status segment stays hidden while there are zero jobs, so the toast and the palette group are the only discovery paths. The first-ever scheduled (non-test) run also toasts once: `info` "{name} started" / sub "in the “Scheduled runs” session · later runs start quietly" (flag in host `settings.json`). No window open at that moment: the toast shows when a window next opens.

### 6.7 Install, removal, data folder [M1] (R24, RP P14)
- **README** covers: `tern plugin install github.com/OWNER/REPO` (and `tern plugin link DIR` for development); minimum Tern 0.7.2; that updating the package reloads every plugin; what removal leaves behind.
- **Removing the plugin** leaves `plugin-data/schedule` (jobs, prompts, run history, run folders) in place and does not close open run panes. Nothing is sent to anyone. To start clean, delete that folder.
- **Settings › Open data folder** reveals that folder in Finder. (Export and backup are M3.)

---

## 7. Copy deck

Strings are final unless marked `{var}`. Scope: everything is M1 unless tagged.

### 7.1 Buttons and badges
**New job** · **Edit** · **Run now** · **Open run** · **Pause** · **Resume** · **Delete** → **Confirm delete** · **Duplicate** · **History** · **Stop** · **Stop run** · **Pause all** · **Resume all** · **Settings** · **Save** · **Save & run now** · **Cancel** · **Presets…** · **Pick…** · **Open as file** · **Use example** · **Check setup** · **Details** · **Not now** · **Use hands-off** · **Keep asking** · **Undo** · **Open data folder**. M2: **Test run**.

### 7.2 Dock hint tiers (§8.3)
- **full (≥80)**: `n new  e edit  ⏎ open  r run now  ␣ pause  dd delete  h history  P pause all  ? more` (M2 adds `/ filter`)
- **short (56–79)**: `n new · e edit · ⏎ open · r run · ␣ pause · ? keys`
- **min (<56)**: `n new · ⏎ open · ? keys`
- **armed delete**: `Press d again to delete {name}, or esc to keep it.` (running: `{name} is running. d again stops it and deletes the job, or esc to keep it.`)
- **filter (M2)**: `filter: {query}  ⏎ keep · esc clear   {n} of {total}`
- **form**: `↑↓ move · ←→ change · ⏎ edit · ^⏎ save · esc cancel` (narrow: `^⏎ save · esc cancel`)
- **paused banner** (dock line 1): `All jobs are paused. Press P to resume.`

### 7.3 Toasts (`cx:toast` level · text · sub)
| Event | Level | Text | Sub |
|---|---|---|---|
| First load (R25) | info | `Schedule is ready.` | `Press ctrl+alt+shift+s.` |
| First scheduled run (R25) | info | `{name} started` | `in the “Scheduled runs” session · later runs start quietly` |
| Saved | success | `Saved {name}` | `next {Mon 12 Oct 09:00}` |
| Saved paused | success | `Saved {name} (paused)` | `press space to resume` |
| Deleted | success | `Deleted {name}` | `press u to undo` |
| Undo | success | `Restored {name}` | |
| Paused / resumed | success | `Paused {name}` / `Resumed {name}` | `next {…}` |
| All paused / resumed | info | `All jobs paused` / `All jobs resumed` | `running jobs keep going` |
| Run started (manual; every-run mode is M2) | info | `{name} started` | `{@role} · {~/path}` |
| Needs you | info | `{name} needs you` | `{reason} · {chord} to open` |
| Failed | error | `{name} failed` | `{reason ≤120 chars}` |
| Auto-paused | error | `{name} paused after {N} failures` | `fix the problem, then press space` |
| Blocked | error | `{name} is blocked` | `{reason}` |
| Hands-off review | info | `{name} needs a hands-off review` | `confirm it in Edit; nothing ran` |
| Missed, catching up | info | `Missed {name} ({Mon 09:00})` | `running it once now` |
| Several caught up | info | `Catching up {N} jobs` | `{a, b, +n}` |
| Missed, too late | info | `Skipped {N} missed job(s)` | `{13h} late, over its {3h} limit` |
| Prompt file saved | success | `Prompt updated` | `applies to the next run` |
| First run ended ok | info | `Looks good. Next run {Mon 09:00}` | `approval prompts? Edit › Approval` |
| Setup issue | error | `Schedule needs attention` | `{first failing check}` |
| Finished (every-run mode, M2) | success | `{name} finished` | `{4m 12s} · {$0.42}` |
| Test run (M2) | info | `Test run: {name}` | `it can change files` |
| Carly draft (M3) | info | `Draft ready: {name}` | `review it, then Save` |

### 7.4 Status segment
`next: {name} in {14h}` · `{name} · {4m}` · `{N} running` · `{N} needs you · {name}` · `{N} need you` · `{name} failed` · `{N} failed` · `scheduler stalled · last tick {4m} ago` · `setup needed` · (M2) `paused · {N} jobs`

### 7.5 Validation and error messages
- Name: `Give the job a name.` · `A job named “{name}” already exists. Pick another name.` · `Names can be up to 40 characters.`
- Prompt: `Write what the agent should do.`
- When: `Couldn't read “{text}”. Try “weekdays 9am”, “every 2h”, or a cron like 0 9 * * 1-5.` · `Agent runs shorter than 5 minutes apart tend to overlap. Use every 5m or more.` · `That time has already passed.` · `Cron has {n} fields; it needs 5 (minute hour day month weekday).` · `Both a date and a weekday are set. Like cron, it runs when either one matches.` · `Hour must be 0–23.`
- Folder: `Pick a project folder.` · `{path} doesn't exist.` · `{path} is a file, not a folder.` · `Tern can't read {path}. Check its permissions.` · `That pane is on another machine. Pick a folder on this Mac.` · `Folders with quotes, $ or ! in the name aren't supported yet.` · `omp may work in a temporary folder instead of your home folder. Pick a project folder for predictable results.` · `The agent works in this checkout, including your uncommitted changes.`
- Role: `Blocked: role {@x} no longer exists in omp. Edit the job and pick another role.` · `Couldn't read your omp roles. Jobs still run, but role names aren't checked first.`
- Stop after: `Use a time like 45m or 2h (up to 8h).`
- Hands-off: see §4.7 and §6.5.
- Dirty cancel: `Discard changes? esc again`
- Dock when Save is blocked: `Fix: {Name, When, …}`

### 7.6 Run-reason sentences
As the table in §5.5 plus: `Waiting for approval.` · `Asked a question.` · `Waiting for you.` · `Queued: {2} jobs are running.` · `Running (not observed: no Tern window open).` · `Resumed in a new tab. The original run record is unchanged.` · `That run's session was removed, so it can't be reopened. Its summary is below.`

### 7.7 Detail view, settings, empty, setup
- Detail field labels: `When` · `If asleep` · `Next` · `Role` · `Folder` · `Appears` · `Safety` · `After` · `Prompt` · `Runs (last 20)`.
- Settings rows (sheet, `prefs`). **M1 core rows**: **Runs** (where runs appear: Scheduled runs session / Background tab in the current session · bring to front when it starts: off · run session name: `Scheduled runs` · finished run panes to keep: 5 · jobs running at once: 2) · **Status line** (nothing in M1) · **Setup** (Check setup · last heartbeat · availability text + **Details** · **Open data folder**) · **Safety** (reset hands-off confirmations). **M2**: defaults for new jobs (role, approval, stop-after, notifications) · keep run history (last 50 runs per job for 90 days) · show next run in the status line · keep Mac awake during runs · extra PATH folders. **M3**: Carly (draft-only, nothing to relax).
- Empty state: title `Run an omp agent on a schedule.` · body `Pick a time, write a prompt, point it at a folder. Runs show up here when they need you.` · section `Start from an example` · filter empty (M2): `No jobs match “{query}”.` · all-paused empty Upcoming: `Nothing scheduled. All jobs are paused.`
- Availability text (R20, exact): `Jobs run while Tern's session service is running. It keeps running after you close windows as long as a terminal or run is still open. Nothing runs while your Mac is asleep, or after a restart until you open Tern.`
- Setup banner: `Schedule needs attention` · sheet title `Check setup`.
- Delete overlay (running job): `{name} is running. Stop it and delete the job?` `[Stop and delete  y]` `[Keep  esc]`.

---

## 8. Accessibility and theming

### 8.1 Color and tokens
No colors anywhere (tern-rss "express meaning with span tokens and tones, never colours", `PRODUCT.md`; GD views "Tones and span styles"). Tones used: `accent` (running, a next fire under 5 minutes away), `warning` (needs you, hands-off, needs fixing), `error` (failed, stalled), `muted` (scheduled, ok, paused, skipped), `success` (toasts only). Span tokens: `strong` (job names), `muted`/`dim` (role chip, detail), `num` (durations, cost), `path` (folders), `code`/`mono` (cron strings, prompts), `key` (key hints), `mark` (filter hits, via `list.filter`). Status segment tones are restricted to `accent|muted|ok|warn|error` (GD chrome). Brand: inherits Tern's theme in light and dark.

### 8.2 Redundant encoding and screen readers
Every state is **icon + word**, never color alone: `⚠ needs you`, `✗ failed`, `↷ skipped`. Rows set `aria` to a full sentence: "daily-review, weekdays at 09:00, last run succeeded Friday 09:03, next Monday 09:00, in 14 hours." Toasts are `role="alert"` for errors (EL chrome). Motion: the running pulse and shimmer stop under `.sf-still`/`prefers-reduced-motion` (EL lists/chrome); no blinking text; countdown updates once a minute, never per second.

### 8.3 Keyboard-only and narrow widths
Every action in §3.4 and §4.10 has a key; no feature is pointer-only. Overlays route `y`/`enter`/`esc`/arrows through the block's `key` handler (EL chrome: overlays never take the keyboard). Focus rings follow the selection (prefs `focus`, list `selected`) and, after returning from an overlay, the row you left (`cx:frame({{"focus", id}})`, EL input).

`hints_text(cols)` is a single function (tern-rss `hints_text`, LP rss): `cols ≥ 80` full line; `56–79` short; `<56` min (strings in §7.2). Columns drop per the row tiers in §3.3; dock badges collapse to icon + first letter under 70 cells and hide under 56 (keys still work). The form's rail nav and `prefs` hints wrap rather than truncate; chooser pickers use `size="md"` (folds to a narrow layout under 760 px, EL lists `picker`).

---

## 9. Open UX questions (decide with the user)

Final list from `decisions.md` §4 (options verbatim). Until the user answers, the spec builds the recommended option; the dependent copy is marked in §4.7 (Q1), §4.1a (Q2), §6.2/§6.4 (Q3), §4.8 (Q4), §4.6 (Q5) and §4 (Q6).

1. **Default approval for new jobs**: (A) Ask before commands + per-job "Allowed commands" list (`git`, `gh`, `npm test`…) compiled into the overlay, if omp's `bash` patterns verify — *recommended*; (B) Hands-off by default (matches your omp default `yolo` and tern-swarm); (C) Ask before commands with no allowlist (safe, but most real jobs stall on their first shell command).
2. **Catch-up window**: 3 h (*recommended*), 12 h, any age (Raycast), or skip.
3. **Keeping Tern's service alive**: (A) honest copy + Setup keep-alive row (*recommended*); (B) the plugin keeps one idle pane in the runs session so the service survives closing every window; (C) an opt-in launchd agent that starts `tern daemon` at login.
4. **Finished run panes**: keep with a cap of 5 (*recommended*), close successful runs right away (relies on `--resume`), or keep everything.
5. **Where runs live**: a dedicated "Scheduled runs" session (*recommended*) or background tabs in whatever session you're in.
6. **Form scope for M1**: 9-row in-block form (*recommended*), a palette wizard of `cx:prompt`/`cx:pick` steps, or the full Advanced form from day one.
