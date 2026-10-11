# Schedule: scheduler engine spec

> [!NOTE]
> Historical design notes, written before the build under the working name `schedule`. The shipped plugin is `tern-agent-scheduler` ("Agent Scheduler"); where these notes disagree with the code or the [README](../../README.md), the code and README win. Links to `research/`, `review/` and `engine-src/` point at internal notes that aren't published; the engine now lives in `lib/` and its tests in `test/`.

Audience: the developer implementing the engine half of the `schedule` Tern plugin (repo `tern-schedule`). UX is in `./ux.md`; this file owns the clock, the job store, the policies, the run ledger and the tests. Architecture is decided in `./architecture.md` (`AR`): host half = brain and launcher (`tern new …` CLI), window half = eyes and chrome; this spec follows it.

**Citation keys.** `PA §n` = `research/prior-art.md` §5 pattern n / §6 pitfall; `TP §x` = `research/tern-platform.md`; `PR Qn` = `research/tern-probe.md`; `PR2 T n` = `research/tern-probe2.md` test n; `AR` = `design/architecture.md`; `OC §n` = `research/omp-capabilities.md`; `LP #n` = `research/local-patterns.md` pattern n. Tern docs (under `~/.omp/agent/skills/tern-plugin/references/docs/`): `RT` = `concepts/runtime.md`, `API` = `reference/api-shared.md`, `LIM` = `reference/limits.md`, `LC` = `concepts/lifecycle.md`. `[VERIFIED]` = I ran it on this machine while writing the spec (§8, Appendix). `[INFERENCE]` = not observed.
**More keys (revision 2).** `LA` = `design/launch.md` (owns binary resolution, argv, prompt delivery, preamble text, placement realisation, tracking mechanics, V-items); `UX` = `design/ux.md` (words, widgets, copy deck); `DEC` = `design/decisions.md` (authoritative; `R<n>` = its resolutions); `RC`/`RF`/`RP` = the three reviews. Ownership of every topic is table §0 of `DEC`: this file owns the job schema, settings keys, storage layout, schedule grammar, policies, run states, reason codes, constants and the intent protocol.

**Companion code (tested).** `./engine-src/` contains `cron.luau`, `schedule.luau`, `policy.luau` and `test/` (fake America/Chicago clock, harness, 8 test scripts). Appendices A–C of this file are those three modules verbatim. §8 gives the exact commands and results.

> **Revision 2 (after review).** Conforms to `DEC` (authoritative). Changes:
> - **R1** deleted the inline "prompt after `--`" launch form and the "no shell quoting" claim (Tern joins argv into a `/bin/zsh -l -c` string, PR2 T4). The prompt reaches omp only as the attachment `@<run>/prompt.md` plus the fixed positional; argv is owned by `LA` §2 (§0.3). `prompt_source`/`prompt_path` cut from the schema (also RF S3c).
> - **R2** run directory `runs/<job id>/<run id>/{prompt.md, preamble.md, omp.yml, session/}`, `--session-dir <run>/session`; ledger moved to `ledger/<job id>.jsonl`; correlation key = the `/runs/<job id>/<run id>/` substring in the pane command (§0.3, §2, §7.1).
> - **R3** id formats restated (`j_` + 8, `r_<job8>_<slot>`, `r_<job8>_<epoch>_<rand4>`); daemon `block`/`tab`/`session` ids are **strings** extracted by pattern from `tern new --json` (§0.3, §7.1).
> - **R4** binary order is owned by `LA` §1; no bare-`omp` fallback, missing omp = `blocked/omp_missing` (§1.3, §6.4).
> - **R5** every launch passes `--keep-open`; host alone closes run panes; global cap `MAX_FINISHED_PANES = 5` (§0.3, §0.4, new §6.9); job default `after = keep` subject to the cap.
> - **R9** windows send raw samples (change + heartbeat ≤ 30 s); the host debounces and owns every transition; `last_message` ≤ 4 KiB in intents; full text and cost from an asynchronous `/usr/bin/tail -c 1048576` through `tern.process.run`, cost "approximate" when truncated (§0.3, §7.1, §7.3).
> - **R10** intent envelope `{format:1, kind, …}`, file name `<t_ms>-<win8>-<seq>.json`, allowlisted kinds only, no `create`/`update`/`delete`/`settings` intents, retry 60 s; hands-off approval bound to a hash (new `hands_off_ack`) else `blocked/hands_off_review` (§1.1, §2.3, §6.4).
> - **R11** kv holds only `hot`; first-run flags in `settings.json`, binary paths and role cache in new `cache.json` (§1.3, §2, §2.4).
> - **R12** canonical states unchanged; `skipped(late)` removed (a too-late slot is `missed`); new codes `agent_failed`, `interrupted`, `closed_by_user`, `hands_off_review`, `cwd_home`, `cwd_unsafe`, `waiting_cap`; `role_unverified` is a run note; `caught_up` and missed-too-late sentences; daemon-restart rule (RF F5) (§5.4, §7.3, §7.4).
> - **R14** one `tern ls --json` helper (`tern_state.luau`) for sessions, blocks and liveness; no `inspect` `panes[].live` (§0.3, §5.4).
> - **R15** one constants block (§0.4); host tick 15 s, observer 3 s, heartbeat 30 s; window half uses tern-swarm's staged loader.
> - **R16-R19** role stored bare / passed as `@role`, "Other model" and pinned model cut, role check per job cwd with `role_unverified`; `cwd` has no `$HOME` fallback, new `allow_home`, unsafe-character rejection; approval default `write` (pending Q1), `read_only` hidden until V9; catch-up default 3 h (pending Q2) with "If your Mac was asleep" in the main form (§1.1).
> - **R22** setting `session_name` default `Scheduled runs`. Added run fields launch.md needs: `session_file`, `placement_used`, `focus_override`, `run_dir`, `omp_path`, `omp_version`, `busy_seen`, `observed`, `close_requested`, `cancel_requested`, `pane_closed_at`, `overlay`, `notes` (§7.1). **R23** module/milestone references re-scoped (§0.2, new §0.5).
> - **Review rows:** RC C-maxruntime (`max_runtime_s` 300-28800, grace 60 s, exit-near-limit 15 s), C-catchup (min 900 s, default constant), C-pause (0 or 2-10), C-hands-off (`hands_off_ack` + reset action), C24 (Run now `slot = now`, `focus_override`, draft test runs), C31 (settings keys), C-quiet (quiet success deferred, R6); RF F3 (claim-write failure path, write caps below read caps, §2.2/§5.6), F5 (§5.4/§7.3), F6 (user-controlled paths checked through `tern.process.run`, §6.4), F9 (async tail, pane cap).

---

## 0. Decisions and architecture

### 0.1 Decision log

| # | Decision | Why (source) |
|---|---|---|
| D1 | **The clock lives in the host half** (session daemon, one VM per plugin). No window runs a timer that can fire jobs; **no leader lease**. | Host timers run with zero windows (PR2 T5); one VM = one clock (AR); window timers are late and die with the window (LP §3.1). |
| D2 | **Idempotency by cursor + deterministic run id.** Each job stores `cursor` = last slot handled; the run id of a scheduled or catch-up slot is `r_<job8>_<slot>` (manual: `r_<job8>_<epoch>_<rand4>`, R3). A slot can never produce two runs across reload, clock jump, or sleep. | kv has no CAS (API "tern.kv"); replaces locks. |
| D3 | **Local time zone only; no per-job zones.** | Luau `os` has only `clock/date/difftime/time` (RT "The VM"); no IANA database (§4.5). |
| D4 | **Vixie cron semantics**: both DOM and DOW restricted ⇒ OR; a `*`/`*/n` on either side ⇒ AND. Surfaced in the preview. | What `crontab(5)` and pasted expressions do; OpenClaw documents OR as a trap (PA §3h): show it, don't change it. |
| D5 | **Minimum recurrence 5 min; one-shot lead ≥ 1 min.** | Each fire starts an LLM agent: Carly's floor is 5 min (TP §2.8), gh-aw 5 min (PA §3c); overlap-skip is the backstop. |
| D6 | **Catch-up: ≤ 1 run per job, for the most recent missed slot, only if ≤ `catch_up_window_s` late (default `CATCHUP_DEFAULT_S` = 3 h, pending decision Q2).** Older slots → one summarised `missed` record; a slot that is itself over the window is `missed` too ("Missed Mon 09:00: 13h late, over the 3h limit."; there is no `skipped(late)`, R12). Catch-ups launch `catchup_spacing_s` apart. | PA §5.3, §6 "Catch-up bursts"; 3 h = UX default (ux §4.9). |
| D7 | **Overlap default = skip and record**; options queue-one, parallel. Global cap 2. | PA §5.4. |
| D8 | **Single writer: the host VM** (the manager block lives in it). Windows write only unique-name intent files of the allowlisted kinds in §2.3 (R10): no intent can create, edit or delete a job or a setting. | `tern.fs` has no rename/append/exclusive-create; LP #9, #21; AR. |
| D9 | **Prompts are `.md` files**, `prompts/<job id>.md`, managed by the plugin (no user-owned prompt paths, R1). Read at fire time and snapshotted to `runs/<job>/<run>/prompt.md`; the run sees that snapshot, never user text in argv. | PA §5.9; ux §2.6; RF S2/S3c. |
| D10 | **Run-now = the scheduled pipeline** (`trigger="manual"`). | PA §6 "Run-now bypasses the real pipeline". |
| D11 | **Launcher = host CLI**: `tern new tab\|session <session_name> --json --cwd … --keep-open -- <omp argv>` through `tern.process.run`; binaries, argv, prompt delivery and the preamble are owned by `LA` (R1, R4, R6). Works with zero windows, no focus steal, returns the daemon `block` id (PR2 T4, T5). Windows only **observe** (`cx.agents`, addressed by the block id as a string) and report through intent files. | `cx.agents:start` steals focus and its id is unusable (PR2 T1); window `new_tab` id unusable (PR2 T3). |
| D12 | **Honest availability.** Jobs fire only while the daemon lives. It exits when no window is attached and no program is live (PR2 T5); after a reboot nothing fires until Tern opens (TP §2.1); a sleeping Mac fires nothing and the next tick applies catch-up. | AR "Availability contract". |
| D13 | **Finish detection is tiered**: exact with a window open (windows send *raw* `cx.agents` samples; the **host** debounces and decides every transition, R9), best-effort without one (§7.3). | Host sees only `pane_exited` + `tern ls --json` (AR); an interactive omp does not exit after its answer. |

### 0.2 Module map

Pure modules (no `tern.*`; loadable in both halves and in a standalone Luau harness):

| Module | Loads in | Responsibility |
|---|---|---|
| `lib/cron.luau` | host + window | Parse 5-field cron, `next`, `upcoming`, `describe`, DST resolution, calendar math (Appendix A). |
| `lib/schedule.luau` | host + window | Text → normalized schedule record (presets, interval, one-shot, NL subset) (Appendix B). |
| `lib/policy.luau` | host | `decide(job, now)`: due slots → fire / catch-up / missed (Appendix C). |
| `lib/ledger.luau` | host | Run record shape, state machine, retention (§7). |
| `lib/const.luau` | host + window | The one constants block (§0.4). Re-exports `policy.luau`'s `ONTIME_S`, `MAX_SCAN`, `DEFAULT_WINDOW_S` rather than redefining them. |

Host-only: `store.luau` (safe read/write, §2), `tern_state.luau` (the single reader of `tern ls --json` for sessions, blocks and liveness, R14), `runner.luau` (pump, admission, run tracking, §5–7), `launcher.luau` (§0.3; argv per `LA` §2), `intents.luau`, `snapshot.luau`. Window-only, loaded with tern-swarm's staged module loader so no single load exceeds the window budget (R15, RF F7): `observer.luau` (raw agent samples → `obs` intents), `status.luau` (status segment + watchdog), palette commands (M1: Open manager, New job, Run a job now, Go to run that needs me). Carly exports are M3 and draft-only (they open the manager with draft args; R10, R23).

### 0.3 Launcher and observation

**Launch (host, `launcher.luau`).** *How* a run starts (binary resolution order R4, exact omp argv, prompt delivery R1, preamble text R6, placement realisation, tracking mechanics) is owned by `LA`; this file owns the data the launcher consumes and the state it records. `tern` and `omp` are absolute paths (host PATH is `/usr/bin:/bin:/usr/sbin:/sbin`, PR Q1), resolved per `LA` §1 and cached in `cache.json` (§2). Tern wraps the command in `/bin/zsh -l -c` and **joins argv into one string** (PR2 T4), so quoting is Tern's: the argv therefore holds only generated ASCII ids and paths, and `<data>` and `cwd` pass the unsafe-character gate (`LA` §2.3; `' " \ $ ` ! newline` are rejected, R17). **No user text ever enters argv.**

```lua
type LaunchRequest = {
  run_id: string, job_id: string, trigger: "schedule"|"catchup"|"manual"|"test",
  tab_name: string,                      -- "⏲ daily-review"
  cwd: string,                           -- absolute, preflighted (§6.4)
  allow_home: boolean,                   -- job.allow_home → --allow-home
  role: string,                          -- bare ("default"); LA passes "@"..role
  approval: string, max_runtime_s: number,
  run_dir: string,                       -- <data>/runs/<job id>/<run id>  (R2)
  placement: Placement, focus: "keep"|"front",   -- focus already folded with focus_override
}
```
Before launching, the host writes into `run_dir`: `prompt.md` (the fire-time snapshot of `prompts/<job id>.md`), `preamble.md` (text from `LA` §3) and, for every non-yolo approval, `omp.yml` (the safety overlay, R7). omp receives `@<run_dir>/prompt.md` plus the fixed positional `Run the scheduled job described in the attached file.`; omp stores its session under `<run_dir>/session` (`--session-dir`). The old "prompt as the final argv element after `--`" form is deleted.

Sequence (**one launch process in flight at a time**, FIFO, which also removes the create-session race):
1. `tern_state.snapshot()` (R14; one `tern ls --json`) → is there a session named `settings.session_name` (default **Scheduled runs**, R22)?
2. `placement.where="session"` (default): exists → `tern new tab <name> --json --cwd <cwd> --keep-open -- <omp argv>`; absent → `tern new session <name> --json --cwd <cwd> --keep-open -- <omp argv>`. With zero sessions `tern new tab` fails with "there is no session" (PR2 T5), so a session must be created first. `where="tab"`: `tern new tab --json …` (shown session; falls back to creating the run session if there is none). `split`/`float` placements are M2 (after V10/V11) and realised per `LA`. The placement actually used is stored as `placement_used` (`LA` records fallbacks such as `tab_here`).
3. Parse stdout `{"session":…,"tab":…,"block":…}` with a **pattern** (`stdout:match('"block"%s*:%s*(%d+)')`, same for `tab`, `session`) and keep all three as **strings** (R3); never decode-then-`tostring` a large double. Ids are passed to window APIs as-is. **Persist `block` into the run record before anything else.**
4. Best effort: `tern rename <block> "<tab_name>"` (renames the **tab**, PR2 T4). `focus="front"`: `tern focus <block>` (PR2 T1c). `focus="keep"` needs nothing: the CLI launch does not change the shown tab or focus (PR2 T4).
5. Stop = `tern close <block>` with `cancel_requested`/`close_requested` set first (works without a window). Open run = `tern focus <block>` or, if the pane is gone, a new tab running `omp --resume <session_file>` (`LA` §10).

**Pane lifetime (R5).** Every launch passes `--keep-open`; nothing but the host ever closes a run pane. Closing happens by the job's `after` policy and by the global finished-pane cap (§6.9), always after the run's facts are persisted.

`tern.process.run` has `timeout_ms` (`LAUNCH_TIMEOUT_MS`, 15 s) and a 16 MiB output cap (LIM). The prompt travels as a file, so `ARG_MAX` and the 64 KiB prompt cap never interact.

**Correlation key (R2).** The run directory is in `--session-dir`, so the pane's `command`/`args` in `tern ls --json` (and `agent_command` in `cx.agents:list()`) contain the substring `/runs/<job id>/<run id>/` (PR2 T4). It identifies an orphan pane after a crash (§5.4) **and** is required for liveness: a block whose command lacks the substring is not the run (RF F5, §7.3). Identity otherwise is the daemon `block` id, a **string** for every window call: `cx.session:resolve(block)` returns the window pane id, and `cx.agents:wait/transcript/stop/ask` accept the string; numbers, window ids and tab names fail (PR2 T1b). To format an id decoded from JSON use `string.format("%.0f", id)` (exact below 2^53).

**One `tern ls --json` helper (R14).** `tern_state.snapshot(cb)` runs `tern ls --json` once (`timeout_ms` 5 s), stringifies ids as above and returns `{sessions = {name → id}, blocks = {[block] = {session, tab, command, args, cwd, live, exited, focused, keep_open}}}`. Launch step 1, orphan adoption, liveness, the pane cap and the Setup keep-alive row all read this one structure. `tern inspect --json` is used only where a field exists only there; `panes[].live` does not exist in `inspect` (RF F8).

**Observation channels.**

| Source | Half | Gives | Available |
|---|---|---|---|
| host event `pane_exited{pane,status}` (pane = daemon block id) | host | exit + status | always, no window (TP §2.7) |
| `tern ls --json` through `tern_state` every `TICK_S` (15 s) while runs are in flight | host | liveness (`live`/`exited`, run-id substring), orphan detection, pane-cap input | always |
| session JSONL tail in `<run>/session` (`/usr/bin/tail -c 1048576` through `tern.process.run`, **asynchronous**; never a large synchronous `tern.fs.read`, RF F9) | host | full final assistant message, exact cost (approximate when the file exceeds the tail window), `RESULT:` line | always `[INFERENCE: schema per OC §4]` |
| `cx.agents:list()` joined by block string | **window** | raw `working/idle/waiting_input/exited`, `model`, `last_message` with the cost line | only while ≥1 window is open |

**Window → host: raw `obs` samples (R9).** `observer.luau` runs in every window (no election): while the snapshot lists in-flight runs it polls every `OBS_POLL_S` (3 s) (kv `rev` check, then `snapshot.json`), and for each block calls `cx.session:resolve(block)`, finds the `list()` entry with that pane, and writes one intent `{format:1, kind:"obs", block, state, model?, last_message?, delivery_error?, seen_at}` (§2.3 file name) **when `(state, model, last_message-hash)` changed for this VM, and a heartbeat sample every ≤ `OBS_HEARTBEAT_S` (30 s) while the run's state persists**. The sample carries the **raw** agent state and no interpretation: the window never debounces, never decides `needs_input`/`finished`, never sets `busy_seen`; `last_message` is truncated to `LAST_MESSAGE_MAX` (4 KiB). The **host** keeps `last_obs = {state, since, seen_at}` per run and owns every transition and threshold (§7.3). N windows ⇒ ≤ N duplicates; the host dedupes by `(block, state, hash)`. A state "holds" while the latest sample says so and `now − seen_at ≤ OBS_STALE_S`. Window budget: one `list()` + ≤ pane-cap `resolve` calls per tick, far inside 50 ms.
**Host → window:** `snapshot.json` (host-written after every state change; run block ids as strings) + kv `hot.rev` counter (§2.4).

### 0.4 Constants (one block, R15)

Every numeric constant of the engine lives in `lib/const.luau`; other sections name them, they never restate a different value. Per-job/user settings (§1) override only where stated.

```lua
-- clock and loops
PUMP_MS              = 2000    -- fast lane: intents, events, run advance (§5.1)
TICK_S               = 15      -- host tick: due check + liveness (tern ls) while runs are in flight
OBS_POLL_S           = 3       -- window observer poll while the snapshot lists in-flight runs
OBS_HEARTBEAT_S      = 30      -- window repeats an unchanged sample at least this often
OBS_STALE_S          = 45      -- a sample older than this no longer "holds" its state
STATUS_REFRESH_S     = 60      -- status segment refresh ≤ 1/min unless run state changes
-- launch
LAUNCH_QUEUE         = "single-flight FIFO"
LAUNCH_TIMEOUT_MS    = 15000
ORPHAN_WAIT_S        = 20      -- §5.4: a `launching` run without block waits this long before re-queue
NO_RESPONSE_S        = 180     -- no `working` within this ⇒ failed/no_response
-- run limits
MAXRUN_MIN_S, MAXRUN_DEFAULT_S, MAXRUN_MAX_S = 300, 1800, 28800
MAXRUN_GRACE_S       = 60      -- host forces timed_out at max_runtime + this
EXIT_NEAR_LIMIT_S    = 15      -- exit within this of max_runtime counts as timed_out
-- observation thresholds (host side)
NEEDS_INPUT_S        = 10      -- waiting_input must hold this long before `needs_input`
NEEDS_INPUT_REMIND_S = 1800    -- one reminder notification after this long still waiting
FINISH_CONFIRM_S     = 6       -- idle (after busy_seen) must hold this long
LAST_MESSAGE_MAX, SUMMARY_MAX = 4096, 200
JSONL_TAIL_BYTES     = 1048576
-- policy (ONTIME_S, MAX_SCAN, DEFAULT_WINDOW_S are defined in policy.luau and re-exported)
ONTIME_S             = 120
MAX_SCAN             = 500
CATCHUP_DEFAULT_S    = 10800   -- 3 h (pending Q2); DEFAULT_WINDOW_S in policy.luau
CATCHUP_MIN_S, CATCHUP_MAX_S = 900, 604800
MAX_CONCURRENT_DEFAULT, CAP_WAIT_S_DEFAULT, CATCHUP_SPACING_S_DEFAULT = 2, 600, 30
-- panes (R5)
MAX_FINISHED_PANES   = 5       -- global cap of finished run panes kept open
-- storage / intents
INTENT_RETRY_S       = 60      -- undecodable intent retried this long, then dropped
INTENT_MAX_BYTES     = 16384
ROLE_CACHE_S         = 1800
```
`max_concurrent`, `cap_wait_s`, `catchup_spacing_s` are user-editable settings (§1.3) whose defaults are the `*_DEFAULT` constants above.

### 0.5 Scope by milestone (R23)

The engine in this file is **M1** in full (clock, store, policies, ledger, intents, launcher with `session` and `tab` placements + *Bring to front*, minimal observer, pane cap, host OS notifications). **M2:** `split`/`float` placements (after V10/V11), Interrupt (keep pane), per-job notify / after-run / overlap options in an Advanced section, quiet success, the settings sheet beyond core rows, `keep_awake`. **M3:** Carly exports (draft-only create), worktree isolation, bundled omp reporter extension, "Allowed commands" overlay if not already shipped, export/backup. Fields reserved for later milestones are marked in §1.1.

---

## 1. Job schema

Versioned JSON, `format = 1`. A job is split across **definition** (`jobs.json`, changed only by user edits) and **runtime state** (`state.json`, changed by the engine). Splitting bounds the damage of a torn write (§2) and keeps user-edited data out of the hot path.

### 1.1 Definition fields (`jobs.json`)

| Field | Type | Default | Validation | Why |
|---|---|---|---|---|
| `id` | string | generated `j_` + 8 × `[a-z0-9]`, collision-checked | `^j_[a-z0-9]{8}$`, immutable | Stable addressing; names are not unique and renames must not move files (PA §6 "Duplicate names"; Hermes ambiguity). Safe in paths and in run ids. |
| `name` | string | none (UX proposes a slug of the prompt) | 1–40 chars, trimmed, no control chars; case-insensitive unique among jobs | Display + CLI/Carly addressing; uniqueness enforced via slug (Claude requires unique names, PA §1a). UX limit ux §4.1. |
| `slug` | derived | — | `lower(name)` → `[a-z0-9]+` joined by `-`, ≤40; **not stored**, recomputed | Tab titles, Carly arguments, duplicate check. Not used in paths. |
| *(prompt)* | — | — | **No prompt field.** The prompt is `prompts/<id>.md`, owned by the plugin, edited only through the manager (or Tern's doc editor via `ctrl+o`); ≤ 64 KiB. `prompt_source="file"` / `prompt_path` are **cut from v1** (arbitrary-file read, RF S3c; R1). | Prompt text never enters argv: at fire time it is snapshotted to `runs/<job>/<run>/prompt.md` (§0.3). |
| `schedule` | table | `{kind="cron", input="weekdays at 09:00", expr="0 9 * * 1-5"}` | see §1.2 | The one thing every product has (PA §5.2). |
| `role` | string | `"default"` (shown and passed as `@default`; example jobs set `smol` explicitly and show its cost) | `^[%w_%-]+$` (swarm `schema.luau:503`), stored **bare**; no pinned model id ("Other model…" is cut, R16) | Becomes `--model '@role'` (OC §1a). Roles are read **per job cwd** (`omp config get modelRoles --json` run in that folder, cached in `cache.json` for `ROLE_CACHE_S`): readable and absent ⇒ `blocked/role_missing` at preflight, warn at save; **unreadable ⇒ the run proceeds** and records the note `role_unverified` (§6.4). Resolved model recorded per run (PA §5.13). |
| `cwd` | string | pre-filled by the New-job form from the focused local pane's cwd; otherwise **empty and required** ("Pick a project folder."). **No `$HOME` fallback** (R17) | absolute, `~` expanded at save; ≤1024 chars; must not contain `' " \ $ ` ! newline` (rejected at save: "Folders with quotes, $ or ! in the name aren't supported yet."); directory must exist at preflight | `tern new … --cwd`; remote panes refused by UX (ux §4.5). |
| `allow_home` | boolean | `false` | `true` only when the user explicitly picked `~`/`$HOME` as the folder; `cwd == $HOME` with `allow_home=false` is invalid (`blocked/cwd_home`) | Passes `--allow-home` (`LA`); the form carries omp's temp-dir caveat (R17). |
| `placement` | table | `{where="session"}` | `where ∈ session\|tab` in M1; `split\|float` are M2 (after V10/V11); `corner ∈ tl\|tr\|bl\|br` (default `br`, only `float`) | `session` = the dedicated run session named `settings.session_name` (default **Scheduled runs**, R22; default; keeps the shown tab and focus, PR2 T4); `tab` = background tab in the current session. Realisation and fallbacks: `LA`. **`hidden` is dropped:** `layout:park` fails for every id form (AR issue 3), and the run session keeps runs out of view. |
| `focus` | `"keep"\|"front"` | `"keep"` | enum | `keep` = the CLI launch touches nothing; `front` = `tern focus <block>` after launch (the form's *Bring to front* switch). A one-off *Run now and watch* uses the run's `focus_override`, not this field (§6.8). |
| `approval` | `"read_only"\|"write"\|"always_ask"\|"yolo"` | `"write"` (*Ask before commands*; **pending the user's decision, Q1**, R18) | enum; `read_only` is **hidden from the form until its tool allowlist is verified (V9)**; example jobs must work under their stated mode | UI → `--approval-mode`: `write`→`write`, `always_ask`→`always-ask`, `yolo`→`yolo` (Hands-off), `read_only`→`always-ask` + read-only allowlist `[INFERENCE: V9]`. Exact argv and the exec-tier overlay `omp.yml` for every non-yolo run (R7): `LA`. Default `write`: edits proceed, commands surface as *needs you* (PA §5.5). |
| `hands_off_ack` | string? | nil | present and equal to the current hash whenever `approval="yolo"` | Written **only** by the host manager when the user confirms Hands-off: `"ho1:"` + FNV-1a-64 (two 32-bit lanes, `bit32`) of `prompt text ␀ cwd ␀ role` (R10). Preflight recomputes it from the stored prompt, `cwd`, `role`; a mismatch ⇒ `blocked/hands_off_review` until re-confirmed in the manager. Settings action *Reset hands-off confirmations* clears every `hands_off_ack`. This guards against accidental or foreign edits; plugin data is **not** a security boundary against processes running as the user. |
| `max_runtime_s` | number | `1800` (`MAXRUN_DEFAULT_S`) | integer 300–28800 (UI hint "5m or more", up to 8 h; RC C-maxruntime) | Passed as `--max-time`; the host forces `timed_out` at +`MAXRUN_GRACE_S` (60 s); a pane exit within `EXIT_NEAR_LIMIT_S` (15 s) of the limit counts as the limit (§7.3). No "unlimited" (PA §6 "Process leaks"). |
| `overlap` | `"skip"\|"queue"\|"parallel"` | `"skip"` | enum | D7. `queue` keeps at most one waiting slot (latest wins). Form option is **M2**; M1 stores the default. |
| `catch_up` | `"within"\|"always"\|"skip"` | `"within"` | enum | D6. The form shows it as the main-section row **If your Mac was asleep** (R19). |
| `catch_up_window_s` | number? | nil (= `CATCHUP_DEFAULT_S`, 10800 = 3 h, pending Q2) | integer 900–604800 when set (the form says "15m or more"); used only for `within` | D6. |
| `notify` | `"issues"\|"all"\|"off"` | `"issues"` | enum | `issues` = needs-you, failed, timed-out, blocked; `all` adds success (no "started" toast except for manual runs); `off` = history only. Devin's default is failures-only (PA §3e). Per-job option is **M2**. |
| `system_notification` | boolean | `true` | | The **host** sends the OS banner (single writer, deduped, R8) in addition to the window-side toast. Per-job option is **M2**. |
| `after` | `"keep"\|"close_ok"\|"close"` | `"keep"` | enum | Pane policy: never closes failed / needs-you runs (PA §6). `keep` is **subject to the global cap** `MAX_FINISHED_PANES` (§6.9, R5). Per-job option is **M2**. |
| `pause_after_failures` | number | `3` | **0 or an integer 2–10**; 0 = never auto-pause (the form switch maps off→0; RC C-pause) | Streak → auto-pause (PA §5.12, Devin Error state). |
| `unattended_note` | boolean | `true` | | Whether the preamble (`LA` §3) is appended. **Always on in M1**; the per-job toggle is deferred (R6). |
| `quiet_ok` | boolean | `false` | | **Deferred past M1** (R6): not shown, not written. The summary is the last `RESULT:` line, else the first line of the last message (§7.1). |
| `enabled` | boolean | `true` | | `false` = no scheduling. Auto-pause also sets it `false` and records `paused_reason` in state. |
| `created_at`, `updated_at` | number | now | unix seconds | History, sort. |
| `tz` | table | `{iana=<readlink /etc/localtime>, abbr=os.date("%Z")}` at creation | informational | Detect "created in CDT, now in PST" (§4.5). Not used for computation. |

Deliberately **not** fields (speculative or unsafe): `prompt_source`/`prompt_path` (arbitrary-file read, R1), a pinned model id (R16), `thinking`, `tools`, per-job extra argv (arbitrary flags from a data file), worktree isolation (M3), per-job time zone, jitter/stagger (PA §5.10 low value for one user), "continue previous session" (the *Open run* resume covers it), tags/description, retries.

`schedule` record:

| Field | Type | Meaning / validation |
|---|---|---|
| `kind` | `"manual"\|"cron"\|"interval"\|"once"` | `manual` = never fires, only Run now. |
| `input` | string ≤200 | What the user typed (shown back in the editor). |
| `expr` | string | Canonical machine form: for `cron`, the 5-field expression after macro/NL expansion (`cron.parse(...).src`); for `interval`, seconds as text; empty otherwise. **Human text is not stored**; `cron.describe(spec)` regenerates it so it can't go stale. |
| `secs` | number? | `interval` only: 300 ≤ secs ≤ 86400. |
| `anchor_at` | number? | `interval` only: unix seconds, floor to minute of save/enable/resume. Slots = `anchor_at + k*secs` (§3.3). |
| `run_at` | number? | `once` only: unix seconds, ≥ now+60 at save. |

### 1.2 Runtime state fields (`state.json`, key = job id)

| Field | Type | Why |
|---|---|---|
| `cursor` | number | Last slot handled (fired, skipped, or recorded missed), or the arming time. Never decreases except on an explicit re-arm (D2). |
| `armed_at` | number | When scheduling last started (create / enable / resume / schedule edit / zone change). `cursor` is initialised to it. |
| `next_run` | number? | Cached next slot after `cursor`; nil for `manual`, disabled, or finished `once`. Recomputed on every change. |
| `pending` | `{slot:number, run_id:string}?` | The single queued slot for `overlap="queue"`, and runs waiting on cap / window. Persisted so a reload does not lose it. |
| `last_run` | table? | `{run_id, slot, started, ended, state, reason_code, summary}`; `summary` ≤ 200 chars (first line of last message). Display source for lists. |
| `failure_streak` | number | Consecutive failed/timed_out/config-blocked non-test runs (§6.5). |
| `paused_reason` | `nil\|"user"\|"failures"\|"blocked"` | Why `enabled=false`; UI wording. |
| `incident` | `{since:number, run_id:string, notified:boolean}?` | Open failure incident; one notification per incident (§6.5). |
| `runs_total` | number | Informational count. |

### 1.3 Global settings (`settings.json`)

Host-written. Also holds the host-owned first-run flags (R11, R25). Binary paths, detected versions and the role cache are **not** here: they live in `cache.json` (§2).

| Setting | Default | Notes |
|---|---|---|
| `paused_all` | `false` | Kill switch, §6.7. |
| `max_concurrent` | `2` (`MAX_CONCURRENT_DEFAULT`) | ux §4.1 note (cap default 2). |
| `cap_wait_s` | `600` | A due run waiting on the cap is skipped (`cap`) after this long (ux). |
| `catchup_spacing_s` | `30` | Min gap between *catch-up* launches (ux §5.7). |
| `retain_runs` / `retain_days` | `50` / `90` | Per-job ledger retention (ux §7.7). |
| `defaults.*` | role `default`, placement `session`, focus `keep`, approval `write` (pending Q1), `max_runtime_s` 1800, notify `issues`, after `keep`, catch_up `within`, system_notification `true` | Applied by the New-job form only; stored jobs are always fully materialised. |
| `omp_path`, `tern_path` | nil | Explicit absolute paths. **Resolution order, validation (`--version`) and the no-bare-`omp` rule are owned by `LA` §1 (R4)**: Tern-managed omp first; missing omp ⇒ `blocked/omp_missing`. |
| `bin_dirs` | `{}` | Extra dirs the launcher tries (UX "Extra PATH folders"; use per `LA` §1). |
| `session_name` | `"Scheduled runs"` | The dedicated run session (R22). Validated `[%w _.-]{1,40}`. Palette group and manager tab stay "Schedule". |
| `show_next_in_status` | `true` | Status segment shows the next run (RC C31). |
| `keep_awake` | `false` | M2: `caffeinate` while a run is active (ux §6.4). |
| `watchdog` | `"notify"` | `notify \| reload`, §5.5. |
| `welcomed`, `first_scheduled_toast_done` | `false` | R25 flags: the one-time "Schedule is ready. Press ctrl+alt+shift+s." toast and the first-ever scheduled-run toast. |
| `max_jobs` | `50` | Carly/Claude cap 50 (PA §1b); bounds file sizes. |

The tick (`TICK_S`) and every other loop constant are in §0.4, not settings. Carly keys (save without review, delete) belong to M3 and are not defined here.

The prompt preamble (unattended note, final `RESULT:` line request) is **owned by `LA` §3**; the engine only writes it to `<run>/preamble.md` so *Run now* and scheduled runs send identical text.

### 1.4 Example

`jobs.json`:
```json
{
  "format": 1,
  "seq": 7,
  "jobs": [
    {
      "id": "j_k3m9x2ab", "name": "daily-review",
      "schedule": { "kind": "cron", "input": "weekdays at 9am", "expr": "0 9 * * 1-5" },
      "role": "default", "cwd": "/Users/me/Dev/app", "allow_home": false,
      "placement": { "where": "tab" }, "focus": "keep",
      "approval": "write", "max_runtime_s": 1800,
      "overlap": "skip", "catch_up": "within",
      "notify": "issues", "system_notification": true, "after": "keep",
      "pause_after_failures": 3, "unattended_note": true,
      "enabled": true, "created_at": 1760000000, "updated_at": 1760000000,
      "tz": { "iana": "America/Chicago", "abbr": "CDT" }
    }
  ]
}
```
`state.json`:
```json
{
  "format": 1, "saved_at": 1760191215,
  "jobs": { "j_k3m9x2ab": {
      "cursor": 1760191200, "armed_at": 1760000100, "next_run": 1760277600,
      "last_run": { "run_id": "r_k3m9x2ab_1760191200", "slot": 1760191200, "started": 1760191203, "ended": 1760191520, "state": "finished", "reason_code": "ok", "summary": "No new issues since Friday." },
      "failure_streak": 0, "runs_total": 12 } },
  "inflight": ["r_k3m9x2ab_1760191200"]
}
```

---

## 2. Storage layout

Everything lives under `tern.plugin.data` (`<state>/plugin-data/schedule`, created before the entry runs; API "tern.plugin"). **Never write in the package directory**: any change there reloads every plugin (LC "Watching"; LP #22). The data path contains a space on macOS (`Application Support`). Tern joins argv into one `/bin/zsh -l -c` string (PR2 T4) and quotes elements itself, so the launcher passes plain argv elements and applies the unsafe-character gate of `LA` §2.3 (`' " \ $ ` ! newline` rejected in `<data>` and `cwd`) instead of hand-quoting; any command string the plugin does build itself (not planned in M1) must be POSIX single-quoted (swarm `lib/sh.luau`).

```
<data>/
  kv.json                         Tern-owned. Host writes ONE key, "hot" (≤ 1 KB, includes `rev`). §2.4
  snapshot.json                   host → window read model (jobs, in-flight runs with block ids as strings, recent runs); cap 128 KiB
  settings.json  (+ .bak)         global settings + first-run flags §1.3  cap 64 KiB
  cache.json                      host-written, regenerable: resolved binary paths + versions (LA §1), role lists per cwd (ROLE_CACHE_S); cap 64 KiB; damaged ⇒ deleted and rebuilt, never pauses jobs
  jobs.json      (+ .bak)         { format, seq, jobs[] } definitions    cap 256 KiB
  state.json     (+ .bak)         runtime state + in-flight run ids      cap 256 KiB
  prompts/<job id>.md             managed prompt text (source of truth)  cap 64 KiB
  drafts/<draft id>.md            unsaved New-job prompt drafts (manager-written); discarded on cancel, pruned at load when older than 7 days  cap 64 KiB
  ledger/<job id>.jsonl (+ .bak)  run ledger, one record per line        cap 128 KiB   (R2)
  ledger/_drafts.jsonl            test runs of unsaved drafts (job id `_draft`), pruned like any ledger (§6.8)
  runs/<job id>/<run id>/         per-run directory (R2):
      prompt.md                     fire-time snapshot of the prompt (passed as `@<run>/prompt.md`)
      preamble.md                   `--append-system-prompt` file (text: LA §3)
      omp.yml                       safety overlay for every non-yolo run (R7)
      session/                      `--session-dir`: omp's own JSONL + artifacts
  events.jsonl   (+ .bak)         engine events: gaps, reloads, zone change, pause/resume; last 200 lines
  trash/<job id>.md               copy of a deleted job's prompt, pruned after 30 days
  intents/<t_ms>-<win8>-<seq>.json  window → host, allowlisted kinds only (§2.3), write-once, deleted by host once applied   cap 16 KiB
```

### 2.1 What `tern.fs` can and cannot do

From `API` "tern.fs": `read(path, max_bytes?)`, `write(path,text)` (**creates or truncates, then writes**), `list`, `exists`, `mkdir` (with parents), `remove` (file, symlink, or directory with contents). **There is no rename, append, stat, or exclusive create**, and relative paths resolve against the plugin dir (always use absolute paths from `tern.plugin.data`). A bounded `read` rejects an oversized file before allocating (useful as a damage guard); an unbounded read does not. `tern.kv.set` is atomic (temp+rename) but is one shared file whose concurrent writers race, last rename wins (`API` "tern.kv").

Consequences and how the engine lives with them:

| Limit | Consequence | Mitigation |
|---|---|---|
| `write` truncates before writing | A crash mid-write loses the file | **Backup-then-write** (§2.2). |
| No rename/exclusive create | No lock files, no atomic swap | **Single writer** (§2.3); unique-name write-once files for cross-VM messages. |
| No append | A JSONL "append" is read-modify-write of the whole file | Ledger files are small (≤128 KiB) and rewritten only on state transitions (a few times per run). |
| No stat/mtime | Can't detect external edits cheaply | Prompt files are read at fire time only; the UI re-reads on focus. |
| Reads are synchronous on the VM thread | 2 s host / 50 ms window budgets; one blocking call on a slow volume can pass the 2 s budget and disable **all** host timers until reload (RF F6) | Bounded reads of plugin-owned files only (small, local); **user-controlled paths (`cwd`, role reads, `tail` of session files) go through `tern.process.run` with `timeout_ms`** (§6.4, §0.3); windows never read files > a few KB. |
| JSON decode drops `null` members; empty tables encode as `{}` | Round-trip surprises | Never use `null` as data; tag arrays with `tern.json.array()`; use explicit `false`/missing. `encode(v, true)` sorts keys: diff-friendly. |

### 2.2 Damage protection (LP #21, extended)

All structured files go through one `store` module:

1. **Read cap.** `tern.fs.read(path, CAP)`; a file over its cap is *damaged*, not truncated.
2. **Format guard.** Every file has `format = 1`. A file with `format > 1` is **never written**; the engine enters *read-only mode* ("Data written by a newer Schedule; update the plugin") and does not launch anything.
3. **Backup-then-write.** Keep the last successfully loaded/written text in memory (`known_good[path]`). `safe_write(path, text)`: if `text == known_good[path]` → no-op (also avoids rewriting every tick); else write `path..".bak"` with `known_good`, then write `path`, then set `known_good`. Crash during the `.bak` write leaves the main intact; crash during the main write leaves a good `.bak`.
4. **Load order.** main → `.bak` → *damaged*. A parse error, wrong type, or cap overflow on the main file falls back to `.bak` and logs `warn`. If both fail: copy whatever bytes exist to `<name>.corrupt-<unix>` (so nothing is destroyed), **set `paused_all=true` in memory**, show "Schedule data is damaged, jobs are paused" with *Start fresh* / *Open data folder*, and do not overwrite anything until the user chooses.
5. **Schema validation on load.** Per-job validation (§1.1); a job that fails is moved to `invalid` in memory, shown in the list with its error, kept on disk verbatim, and never fired. One bad job never blocks the others.
6. **Cross-file consistency.** `state.json` entries for unknown job ids are dropped; jobs with no state entry get a fresh one (`cursor = armed_at = now`, so a restored job never "catches up" on history it has no cursor for).
7. **Ledger tail repair.** An unparsable last line is dropped; other bad lines are kept as raw text and re-emitted (never silently lost).
8. **Self-inflicted overflow can never be "damaged" (RF F3).** Each file has a *write* cap below its read cap (90 %). Before `safe_write`, the store prunes in this order until the text fits: oldest terminal ledger records (§7.5), then `events.jsonl` lines, then `snapshot.json` recent-run entries. If it still doesn't fit the write is refused and the engine enters the `data_unwritable` health state (§5.6); the file on disk is untouched.
9. **Write failure.** `tern.fs.write` raising (disk full, EPERM, quota) is caught per file; the in-memory state stays authoritative, the file is marked dirty and retried every tick. `hot.health = "data_unwritable"` while any write fails (§2.4); launching stops (§5.6).

### 2.3 Single-writer rule

The host VM is the only writer of `settings.json`, `cache.json`, `jobs.json`, `state.json`, `ledger/*`, `runs/<job>/<run>/*`, `prompts/*`, `events.jsonl`, `snapshot.json` and the `hot` kv key. Windows never write kv (R11). Everything else:

| Writer | May write | Never |
|---|---|---|
| Window palette commands, status segment | `intents/<t_ms>-<win8>-<seq>.json` (unique name, written once), allowlisted kinds only | any registry file, kv |
| Manager block (host-side) | calls the engine in-process (same VM): the **only** place jobs and settings are created, edited or deleted, and where hands-off is confirmed | direct file writes outside `store` |
| Window observer (every window) | `obs` intents only | `ledger/`, `runs/`, `jobs.json`, `snapshot.json` |
| The user | `prompts/<id>.md` in Tern's doc editor (`ctrl+o`); the engine only *reads* it, at fire time | n/a |

**Intent protocol (R10).** Envelope `{format:1, kind, …}`; file name `<t_ms>-<win8>-<seq>.json` (`t_ms` = 13-digit unix ms, `win8` = 8 chars of the window id, `seq` = per-window counter, zero-padded to 4), so names are unique and sort in write order. The host pump (every `PUMP_MS`, §5.1) lists `intents/`, applies in **file-name order** within a 300 ms budget, and removes each file after applying. An undecodable intent is retried for `INTENT_RETRY_S` (60 s) then dropped and logged (swarm, LP #9); an unknown `kind`, a wrong `format` or a file over `INTENT_MAX_BYTES` is dropped at once. **Allowlisted kinds only:**

| `kind` | Payload | Host action |
|---|---|---|
| `obs` | `block` (string), `state` (raw agent state), `model?`, `last_message?` (≤ 4 KiB), `delivery_error?`, `seen_at` | Record a raw sample for the in-flight run owning `block`; unknown blocks are dropped. §0.3, §7.3. |
| `run_now` | `job_id` of an **existing** job | `runner.fire(job, {trigger="manual"})` with the job's *stored* settings (no overrides, no `focus_override`); refused under `paused_all` (§6.8). |
| `pause` / `resume` | `job_id` | `enabled` false/true with `paused_reason="user"` / re-arm (§6.7). |
| `pause_all` / `resume_all` | — | `paused_all` (§6.7). |
| `stop_run` | `run_id` | `tern close` + `cancelled/user_stop` (§7.3). |
| `focus_run` / `open_run` | `run_id` | `tern focus <block>` / `LA` §10 Open run. |
| `roles_request` | `cwd` of an existing job | Refresh the role list for that cwd asynchronously into `cache.json` (§6.4); republish snapshot. |
| `ack_failed` | `run_id` | Clear the unseen-failure flag (`hot.failed_unseen`). |

**There are no `create`, `update`, `delete` or `settings` intents.** Creating and editing jobs and settings happens only inside the host manager block; palette *New job* and any future Carly `job_add` open the manager with draft args through `cx:new_block` (an M1 gate V-item, §9). Every payload field is validated by the same validator as the form (ids must exist, strings are length-clipped, enums checked). Plugin data is **not** a security boundary against processes running as the user: any such process can write `intents/` or the data files. The allowlist and the hands-off hash (§1.1 `hands_off_ack`) limit what a *plugin-side* caller can do, not what the OS user can. Cross-half wake-up when latency matters: `cx:open("schedule://wake")` → window `tern.route.link` → touch a new intent (LP #10); otherwise the 2 s pump is the latency.

### 2.4 `tern.kv` is hot state only

One key, rewritten by the host at most every `TICK_S` (15 s) and on state changes, and **only if changed or the heartbeat is due**. It is the **only** kv key and **only the host writes it** (R11); first-run flags live in `settings.json`, binary paths and the role cache in `cache.json`.

```json
"hot": { "v":1, "rev":42, "hb":1760191215, "paused_all":false, "running":1, "needs_input":0,
         "failed_unseen":0, "setup_ok":true, "scheduler":"ok", "health":"ok",
         "next":{"id":"j_k3m9x2ab","name":"daily-review","at":1760277600} }
```
`health` ∈ `ok | data_unwritable | readonly | damaged` (§2.2). `rev` increments whenever the host republishes `snapshot.json`; windows compare it (one kv read) before reading the file. The window status segment reads this key (4 ms formatter budget, `RT` "Budgets"), refreshing at most every `STATUS_REFRESH_S` unless run state changes: no file reads in formatters. A lost write is self-healing: the host republishes within one tick. kv is **never** used for claims or the job list: simultaneous sets race and the last rename wins (`API`), and `set` raises when `kv.json` is unreadable (always `pcall`).

### 2.5 Retention and cleanup

- Ledger: keep the newest `retain_runs` (50) *terminal* records per job and drop records older than `retain_days` (90); in-flight records are never pruned. A pruned record's `runs/<job>/<run>/` directory (snapshot, preamble, overlay, session) is removed with `tern.fs.remove` (recursive).
- On job delete: write `trash/<id>.md` (prompt copy), remove `ledger/<id>.*`, `runs/<id>/`, `prompts/<id>.md`; prune `trash/` older than 30 days at load. Delete is two-press in the UI with undo (ux §3.4).
- `events.jsonl`: last 200 lines. `drafts/*.md` older than 7 days are removed at load. Undecodable intents older than `INTENT_RETRY_S` are removed at load.
- Housekeeping runs at load and once per hour on the tick (`TICK_S`), under a time slice (≤200 ms per tick).

---

## 3. Schedule grammar

Input → `schedule.parse(text, now)` → `{kind, expr, input, secs?, run_at?}` or `nil, hint`. The UI always shows the **normalized form** and the next 3 fire times returned by `cron.upcoming` (PA §5.2: Copilot's English preview, Raycast's next-run). Raw cron is validated by the same code that runs it, so preview and behaviour cannot diverge.

### 3.1 Cron (kind `cron`)

Five fields: `minute hour day-of-month month day-of-week`.

| Field | Range | Names | Notes |
|---|---|---|---|
| minute | 0–59 | | |
| hour | 0–23 | | |
| day of month | 1–31 | | |
| month | 1–12 | `JAN`…`DEC` (case-insensitive) | |
| day of week | 0–7 | `SUN`…`SAT` | 0 and 7 are Sunday; `5-7` = Fri,Sat,Sun |

Syntax per field: `*`, `a`, `a-b`, `a,b,c`, `*/n`, `a-b/n`, and `a/n` (read as `a-max/n`, Vixie). Rejected with an exact message: backward ranges (`FRI-MON`), step 0, empty set, out-of-range values, `L W # ?`, 6-field/seconds expressions, full names inside cron fields (the NL layer accepts them).

Macros: `@hourly` `0 * * * *`, `@daily`/`@midnight` `0 0 * * *`, `@weekly` `0 0 * * 0`, `@monthly` `0 0 1 * *`, `@yearly`/`@annually` `0 0 1 1 *`. **`@reboot` is rejected**: a "run when Tern starts" trigger is a different feature (event-driven), not in scope.

**DOM/DOW semantics (D4).** A field is "star" if its text starts with `*` (so `*/2` is star, as in Vixie).

| DOM | DOW | Day matches when |
|---|---|---|
| star | star | always |
| star | restricted | DOW matches |
| restricted | star | DOM matches |
| restricted | restricted | **DOM matches OR DOW matches** |
| star (`*/2`) | restricted | DOM **and** DOW (the `*/n` quirk) |

*Why OR:* it is what every cron reference and pasted expression does; AND would silently change the meaning of expressions copied from elsewhere. *Cost:* "first Monday of the month" (`0 9 1-7 * MON`) is not expressible; the preview says so. *Surfacing:* `cron.describe` appends `(day-of-month OR day-of-week)` and the form shows a `warning` line: "Runs on day 1 **or** on Mondays. Both conditions together isn't supported."

**Statically impossible** (`0 0 30 2 *`, `0 0 31 4,6,9,11 *`): rejected at parse with "never fires: that day does not exist in the chosen month(s)". Rare-but-possible (`0 0 29 2 *`) is accepted; the preview shows the next date (`Tue 29 Feb 2028`) and a note "runs rarely" when next > 366 days.

**Minimum recurrence (D5).** `cron.min_gap(spec, now)` = smallest gap between the next 6 slots; must be ≥ 300 s, else "Agent runs shorter than 5 minutes apart tend to overlap. Use every 5m or more." (ux §4.3). Checked at save and when the schedule is edited.

### 3.2 Presets (what the form's *Presets…* picker produces)

| Preset | Input fields | `expr` produced |
|---|---|---|
| Manual (run now only) | — | kind `manual` |
| Hourly at :MM | MM 0–59 | `MM * * * *` |
| Daily at HH:MM | time | `MM HH * * *` |
| Weekdays at HH:MM | time | `MM HH * * 1-5` |
| Weekly on days at HH:MM | days ⊆ Mon..Sun, time | `MM HH * * MON,THU` (days sorted Sun-first by number) |
| Monthly on day N at HH:MM | N 1–31, time | `MM HH N * *` (N>28: warning "skips shorter months") |
| Every N minutes/hours | N≥5 min, ≤24 h | kind `interval` (§3.3) |
| Once at date + time | datetime in the future | kind `once` (§3.4) |
| Custom cron | text | the typed expression, validated |

### 3.3 Interval (kind `interval`): `every 30m`, `every 2h`, `every hour`

Units `m`, `min`, `minutes`, `h`, `hr`, `hours`. Range 5 min ≤ interval ≤ 24 h; longer periods must use a daily/weekly preset, because instants-based intervals drift against the wall clock across DST (a 24 h interval would move from 09:00 to 10:00 after fall-back). **Anchoring rule:** slots are `anchor_at + k·secs`, where `anchor_at` = the minute the job was saved/enabled/resumed (or its schedule edited). The first run is at `anchor_at + secs`, not immediately ("Save & run now" covers that). The grid is fixed; late or missed runs do **not** shift later slots. Preview line: "every 2 h, starting now (next 16:07). For clock times use 'hourly at :00' or cron." Plugin reload does not re-anchor (persisted).

### 3.4 One-shot (kind `once`): `in 20m`, `at 15:00`, `tomorrow 9am`, `2026-10-12 09:00`

`run_at` is an instant, resolved in the local zone with the same DST rules as cron (`cron.resolve`). Forms: `in <n><unit>` (units m/h/d/w; minimum 1 min; result rounded **up** to the minute), `at <time>` (next occurrence, today if still in the future else tomorrow), `today|tomorrow [at] <time>`, `YYYY-MM-DD <time>` (date validated: `2026-02-30` → "That date does not exist"), past times → "That time has already passed". After the run is handled the job gets `enabled=false`, `paused_reason=nil`, `last_run` kept, and the UI shows `done` (Claude Desktop one-shots disable themselves, PA §1a; OpenClaw deletes on success: we keep the record because the history is the user's evidence, PA §5.1). A one-shot missed by more than its catch-up window is recorded `missed` and disabled.

### 3.5 Natural-language subset → normalized

The subset is Hermes' (PA §3i), case-insensitive, whitespace-collapsed, `and` ≡ `,`. **Anything else is refused with a hint; the parser never guesses.** Every success shows `normalized` = `cron.describe` plus the machine form (`Weekdays at 09:00 · cron 0 9 * * 1-5`).

| Input | Result |
|---|---|
| `manual`, `never`, `off` | `manual` |
| `0 9 * * 1-5`, `@weekly` | cron (validated) |
| `daily at 7am`, `every day at noon`, `daily 07:00` | `0 7 * * *` |
| `weekdays at 9am`, `every weekday 9:00` | `0 9 * * 1-5` |
| `weekends 10:00` | `0 10 * * 0,6` |
| `every monday 9am`, `mon,thu 18:30`, `monday and wednesday at 9am`, `every friday at 5:30pm` | `0 9 * * MON`, `30 18 * * MON,THU`, `0 9 * * MON,WED`, `30 17 * * FRI` |
| `hourly`, `hourly at :15`, `every hour at :15` | `0 * * * *`, `15 * * * *` |
| `monthly on the 15th at 8:30`, `monthly on day 1 9am`, `monthly 9am` | `30 8 15 * *`, `0 9 1 * *` |
| `every 30m`, `every 2 hours`, `every hour` | interval 1800 / 7200 / 3600 |
| `in 20m`, `in 2 hours`, `in 1 day` | once |
| `at 15:00`, `tomorrow 9am`, `today 5pm`, `2026-10-12 09:00` | once |

Time forms: `9am`, `9:30pm`, `09:00`, `noon`, `midnight`; a bare `9` means 09:00 on the 24 h clock; `13am`/`25:00` → "I can't read the time". Every NL result that is cron is re-run through `cron.parse`, so `monthly on the 40th` fails with the cron error. Implementation: Appendix B (tested: 26 inputs, `final_t3.txt`).

---

## 4. Next-fire algorithm

### 4.1 Contract

```lua
cron.parse(expr)                     -> spec | nil, err
cron.next(spec, after, budget?)      -> t, kind, nominal | nil, "never"|"budget"
   -- smallest slot strictly > after (unix seconds). kind: "exact"|"gap"|"overlap"|"real".
   -- nominal = the wall time the expression named, so the UI can say "02:30 doesn't exist; runs at 03:00".
cron.upcoming(spec, n, after, budget?) -> { t1, t2, ... }
cron.describe(spec)                  -> "Weekdays at 09:00" | "Mon, Thu at 18:30" | "Every hour at :15" | ...
cron.min_gap(spec, after)  cron.period_at(spec, slot)  cron.next_interval(anchor, secs, after)
cron.resolve(y,mo,d,h,mi) -> t, kind ; cron.add_days(y,m,d,n) ; cron.utc_offset(t) ; cron.clock (injectable)
```
Time is unix seconds; local zone only; `cron.clock = {time, date}` defaults to `os` and is injectable for tests (§8). Only `os.time` and `os.date` (local and `!` UTC) are used, the functions the sandbox exposes (`RT` "The VM"). Full source: Appendix A.

### 4.2 Search structure and iteration bounds

Field-wise enumeration, not minute stepping: years `sy…sy+9` × selected months (sorted list) × days of that month × selected hours × selected minutes, skipping everything before the start key `(wall of after) + 1 min`. The first candidate whose resolved instant is `> after` wins.

| Bound | Value | Why |
|---|---|---|
| Horizon | 9 years (`HORIZON_YEARS`) | Feb 29 gaps up to 8 years across 2100 (verified: `0 0 29 2 *` after 2096-03-01 → 2104-02-29). |
| Iteration budget | default 8000 day-checks, caller-overridable | Worst case is ~10·12·31 = 3720 day checks + ≤1440 hour/minute candidates for the starting day. Host call passes 8000, window previews 3000. On exhaustion → `nil,"budget"`. |
| Cost | ~0.1 ms for the worst (Feb 29) search | `[VERIFIED]` 200 worst-case calls in 19 ms under luau-web (WASM, interpreted) on this machine; far inside host 2 s / window 50 ms (`RT` "Budgets"). |
| `upcoming(n)` | n ≤ 10 in UI | n × next. |
| Policy slot scan | `MAX_SCAN = 500` slots per decision | `*/5` over 24 h = 288 slots. Interval jobs count missed slots arithmetically (O(1)). |

All loops are bounded by constants; no loop depends on unbounded input, so the budget trip described in `RT` "A tripped budget" (which disables the whole `timer` hook until reload) cannot come from the engine's own search.

### 4.3 DST rules (concrete)

Facts established on this machine with `TZ=America/Chicago` and libc `mktime` (Python `time.mktime` → same libc) `[VERIFIED]`:

| Input (2026) | `mktime` result | Meaning |
|---|---|---|
| 2026-03-08 02:30, isdst=-1 | **03:30 CDT** | nonexistent time is pushed forward by the gap |
| 2026-03-08 02:00 | 03:00 CDT | |
| 2026-11-01 01:30, isdst=-1 | 01:30 **CDT** (first) | ambiguous time → first occurrence; isdst=0 gives CST |
| 2026-03-32 09:00 | 2026-04-01 09:00 | out-of-range days normalise (not relied on) |

US transitions in 2026: **Sun 8 Mar 02:00→03:00** (spring forward), **Sun 1 Nov 02:00→01:00** (fall back). Other platforms' `mktime` differ for gaps [INFERENCE: glibc], so the engine does **not** rely on `mktime` behaviour: it calls `os.time{...}` and *round-trips* through `os.date("*t")`; if the fields don't come back, the wall time is a gap.

Two job classes (Vixie, `crontab(5)` "DST"): **wildcard** jobs (minute or hour field starts with `*`, e.g. `*/15 * * * *`, `0 */6 * * *`, `@hourly`) follow real elapsed time; **fixed-time** jobs (`30 2 * * *`) follow the wall clock.

| Situation | Fixed-time job | Wildcard job | Preview line |
|---|---|---|---|
| **Gap** (spring forward; wall time doesn't exist) | Fires **once at the first instant after the gap** (`30 2 * * *` on 8 Mar → 03:00 CDT; `kind="gap"`) | The nonexistent slot is **skipped** (no spurious extra run: `30 * * * *` → 01:30 CST, 03:30 CDT) | "On Sun 8 Mar 02:30 doesn't exist (clocks move forward); it runs at 03:00 that day." |
| **Overlap** (fall back; wall time happens twice) | Fires **once, the first occurrence** (`30 1 * * *` on 1 Nov → 01:30 CDT only; `kind="overlap"`) | Fires on **real time**, including the repeated hour (`0 * * * *` → 01:00 CDT, 01:00 CST, 02:00 CST) | "On Sun 1 Nov 01:30 happens twice; it runs once, the first time." |
| Interval | Instants, unaffected | | |
| One-shot | Same `resolve` rule as fixed-time | | |

Implementation points (Appendix A): `resolve(y,mo,d,h,mi)` = `os.time` → `os.date` round-trip; on mismatch, `gap_end` binary-searches (≈15 `os.date` calls over ±4 h) for the first instant whose wall clock is ≥ the target; on match, one-step-away probes (`t±3600`, `t±1800`) detect a repeated wall time and return the first occurrence. For wildcard jobs, when `utc_offset(after+3h) < utc_offset(after-3h)` (a fall-back is within ±3 h), a ≤180-step minute scan over real instants returns repeated-hour matches. `utc_offset(t)` is computed from civil arithmetic over `os.date("*t")` vs `os.date("!*t")`, with no `mktime`. `[VERIFIED]` against a brute-force minute-scan oracle over 120 days spanning 1 Nov 2026 for 11 expressions (`final_t6.txt`: all OK).

### 4.4 Impossible, rare, and over-budget

| Expression | Result |
|---|---|
| `0 0 30 2 *`, `0 0 31 4,6,9,11 *` | parse error "never fires…" (static check when DOW is star) |
| `0 9 31 * *` | valid: skips short months; preview notes it |
| `0 0 29 2 *` | valid: next 2028-02-29, 2032-02-29 …; across 2100 → 2104-02-29 |
| Exotic combination the static check can't see (`0 0 31 */2 * 1` with AND quirk) | `cron.next` → `nil,"never"` after the horizon; the form shows "never fires within 9 years" and refuses to save |
| Budget exhausted | `nil,"budget"`: treated as "unknown": the host keeps the previous `next_run` and logs `warn`; never blocks the tick |

### 4.5 Time zones: not available per job

**The Luau sandbox has `os.clock`, `os.date`, `os.difftime`, `os.time` and nothing else from `os`** (`RT` "The VM" table). `os.date` formats in the process's local zone (or UTC with `!`); there is no IANA database, no `TZ`-parameter, and no way to ask "what time is it in Europe/Paris". `tern.getenv("TZ")` reads the half's environment but cannot compute offsets. **Therefore v1 has no per-job time zone**, and the UX must say so:

- Header of the schedule input: "Times are in your Mac's time zone (CDT, UTC−5)" (matches ux §4.3), from `os.date("%Z")`/`%z` and `cron.utc_offset(now)`. `os.date("*t")`, `os.date("!*t")`, `os.time{…}` with local tables and the `%z %Z` formats work in both halves, e.g. `"2026-10-14 12:46:40 -0500 CDT Wed"` `[VERIFIED: PR2 T7]`.
- **Do not use `os.time(os.date("!*t"))`**: PR2 T7 saw it return `now` exactly (it treats the table as UTC) while `os.time{…}` of a local table is local: the two conventions conflict. The engine never uses that round trip: `utc_offset` is civil arithmetic over `os.date("*t")` vs `os.date("!*t")` fields, and `resolve` uses only local-table `os.time{}` plus a field round-trip check.
- **Zone name (display only)**: host runs `/usr/bin/readlink /etc/localtime` (absolute path; host PATH is minimal, PR Q1) once at load and every 10 min. On this Mac it returns `/var/db/timezone/zoneinfo/America/Chicago` `[VERIFIED]` → IANA name `America/Chicago`.
- **Zone-change handling.** If the IANA name differs from the last recorded one (DST changes alter `abbr` but not the IANA name): log `zone_changed`, toast "Time zone changed America/Chicago → America/Denver. Schedules follow your Mac's time zone.", **re-arm every job** (`cursor = armed_at = now`, recompute `next_run`) so no catch-up burst is triggered by the offset change, and set `tz` on edit. An unchanged-name DST shift needs nothing: slots are recomputed from wall fields each time.
- The daemon and the app are processes of the same user on the same Mac; a host reload picks up zone changes. A zone change while the daemon runs is detected by the 10-min readlink; whether libc itself re-reads `/etc/localtime` without a restart is `[INFERENCE]` (macOS usually does); the re-arm covers both outcomes.
- Possible later feature, **not designed**: per-job IANA zones by parsing TZif files from `/var/db/timezone/zoneinfo/<name>` with `tern.fs.read` + `string.byte`/`buffer` `[INFERENCE: feasible, ~150 lines]`.

---

## 5. Tick loop

### 5.1 Host timer chain

```lua
local PUMP_MS, TICK_S = 2000, 15                -- = const.PUMP_MS, const.TICK_S (§0.4)
local last_wall, last_mono, last_slow = os.time(), tern.now(), 0

local function pump()
  pcall(tern.timer, PUMP_MS, pump)             -- ARM FIRST: a body error must not end the chain
  local t0 = tern.now()
  local now, mono = os.time(), tern.now()
  local gap = detect_gap(now, mono)            -- §5.3
  last_wall, last_mono = now, mono

  local ok, err = pcall(function()
    drain_intents(t0 + 300)                    -- ms deadlines inside each stage
    ingest_events(t0 + 500)                    -- queued pane_exited events, finished tern.process callbacks
    if gap or now - last_slow >= TICK_S then
      last_slow = now
      due_scan(now, gap, t0 + 900)             -- policy.decide per enabled job, admission, launch
      publish_hot(now)                         -- heartbeat
    end
    advance_runs(now)                          -- timeouts, raw-sample debounce, finish confirmation; `tern ls` liveness poll once per TICK_S while runs are in flight
    flush_dirty()                              -- store.safe_write for changed files
  end)
  if not ok then tern.log.error("pump", err) end
  local dt = tern.now() - t0
  if dt > 500 then tern.log.warn("slow pump ms", dt) end
end
tern.timer(1000, pump)                         -- first tick 1 s after load; load itself stays tiny
```

| Choice | Value | Rationale |
|---|---|---|
| Fast lane (intents, launcher ingest, run tracking) | 2 s | Edits and "Run now" feel immediate; `fs.list` of a tiny dir costs microseconds. |
| Tick (`TICK_S`: due scan, liveness `tern ls`, heartbeat, kv publish) | 15 s | Cron granularity is 1 min; worst on-time lateness 15 s ≪ `ONTIME_S` = 120 s. Claude Desktop checks every minute (PA §1a). Host drift is +2–7 ms per tick (PR Q1: 2 s chain deltas 2002.5–2006.9 ms) so the chain is stable. Window timers were 40–90 s late in the background for tern-swarm (LP §3.1 "Limits swarm accepted"), which is why the clock is on the host. |
| Why not 1 s / 60 s | | 1 s buys nothing (cron minute granularity) and writes more; 60 s makes lateness up to a minute and widens the double-count window around Mac sleep. |
| Arm-first | | If the body raises, the chain survives. If the body *trips the 2 s budget*, `RT` "A tripped budget" disables the whole `timer` hook until reload, and nothing in the VM can catch it. Therefore every stage has a soft deadline (`t0+300/500/900 ms`) and defers remaining work to the next tick; the watchdog (§5.5) covers the residual risk. |
| `tern.timer` raises `the plugin is gone` after reload | | Wrapped in `pcall`. |

State in memory is rebuilt at load from files; the tick never reads a file except the `intents/` listing (and the intents it applies). `tern.on("pane_exited", …)` is registered once at load and only enqueues the event. `next_run` is cached per job and recomputed only when the job changes or a slot is handled, so a quiet tick costs O(jobs) comparisons.

### 5.2 Wall-clock comparison

All scheduling compares **`os.time()` (wall clock)** with cached slot instants. `tern.now()` is monotonic and "only differences mean anything" (`API` "tern.now"); it is used only to measure tick duration and to detect clock jumps. A late timer therefore costs nothing: the next tick sees `now ≥ next_run` and `policy.decide` classifies lateness (§6.1).

### 5.3 Sleep and clock-jump detection

Per fast tick: `dw = now − last_wall`, `dm = (mono − last_mono)/1000`.

| Condition | Class | Action |
|---|---|---|
| `dw > 30` (a fast tick is 2 s) | **gap**: Mac sleep, VM stall, or forward clock jump (`dm` smaller than `dw` when the monotonic clock excludes sleep, `[INFERENCE]`) | `events.jsonl` `{ev:"gap", from, to}`; force an immediate `due_scan(gap=true)` (§6.1 handles catch-up through lateness); reconcile in-flight runs against fresh observations. |
| `dw < −5` | **clock moved back** | `events` `{ev:"clock_back"}`; recompute every `next_run` from `cursor`; **no slot already handled can refire** because `cursor` is persisted and only advances (D2). |
| `|dw − dm| > 20` with `0 ≤ dw ≤ 30` | clock stepped (NTP) | recompute `next_run`s; log only. |
| first tick after load | **start gap** | `from = hot.hb` (persisted heartbeat) → `{ev:"down", from, to}`; downtime is handled by the same cursor-based path as sleep. This is the **normal** case after quitting Tern: the daemon exits when no window is attached and no program is live (PR2 T5), and after a reboot nothing runs until Tern opens (TP §2.1). |

There is no separate "wake" hook: the plugin has no system-woke event (TP §2.10); the gap test is the wake detector.

### 5.4 Reload safety and reconcile at load

Reload (a package file change, `tern plugin reload`) drops timers and pending callbacks but keeps files, kv, and **running panes** (`LC` "What survives a reload"; PR1 Headline 9). `load` must therefore be idempotent:

1. Read `settings`, `cache`, `jobs`, `state`, ledger heads (§2.2). Enter read-only mode on a format-guard hit.
2. Take one `tern_state.snapshot()` (async; one `tern ls --json`, R14). For every id in `state.inflight`:

| Record at load | Evidence | Result |
|---|---|---|
| `scheduled` (no launch started) | none | continue admission; if its slot is now beyond the catch-up window it is recorded `missed` (reason `late`, §6.1) and never launched |
| `launching`, **no `block` stored** | blocks whose `command`/`args` contain `/runs/<job id>/<run id>/` | found → adopt its `block` (string), state `running`; not found and age ≥ `ORPHAN_WAIT_S` (20 s) → the launch never happened: re-queue (safe, the pane provably doesn't exist); age < 20 s → wait (the `tern new` may still be returning) |
| `running` / `needs_input`, `block` stored | the `ls` entry for the block, **and** its `command`/`args` contain `/runs/<job id>/<run id>/` (RF F5), and `live` | all true → continue tracking (fresh `obs` samples arrive when a window is open). Block missing, **or present without the marker** (a daemon restart can restore a pane as a bare login shell) → the run's pane is gone: `failed/interrupted` if a heartbeat/daemon gap precedes it (an `events.jsonl` `gap`/`down` entry overlapping the run, §5.3), else `cancelled/closed_by_user`; a restored bare shell is left alone (we never `tern close` a block that lacks the marker). Present with marker but `exited` → exit rules (§7.3) using the asynchronous session tail |

3. Drop undecodable intents older than `INTENT_RETRY_S`. Then `due_scan(gap=true)` once and arm the chain. Slots missed while the plugin was reloading are an ordinary gap.

Because the block id is persisted before any follow-up step and the run id is in the process argv, a crash at any point leaves either a recorded run or a recognisable orphan: never an invisible agent.

### 5.5 Heartbeat and watchdog

- Host publishes `hot.hb = now` and `hot.scheduler="ok"` every slow tick. UI conditions come from ux §2.3: *"Condition: active jobs exist and no heartbeat for >3 ticks (min 2 min)"* → status segment `scheduler stalled · last tick 4m ago` (tone `error`) and the Setup check "tick < 2 min ago" (ux §6.2).
- The window half (`status.luau`) evaluates `now − hot.hb` in its **formatter-free** timer (formatters only read an upvalue: 4 ms budget); on stall it toasts once per stall and offers the palette command *Reload plugins* (`cx:command("reload_plugins")`, as swarm's watchdog does, LP #13).
- **No auto-reload by default**: a reload orphans in-flight agents (§5.4 reconciles them, but needlessly interrupts tracking). A setting `watchdog = notify | reload` (default `notify`) mirrors swarm: `reload` only when no run is in-flight and the user has been idle 30 s, at most once per 10 min.
- A stalled host (hook disabled by budget trip) shows a stale `hb`; a window-less host with no windows has nobody to tell, and the next window that opens shows the banner immediately ("last tick 3 h ago").

### 5.6 Admission (what a due slot goes through)

Order, per `fire` request from `policy.decide` (or Run now), sorted by slot:

```
1. paused_all?          → record skipped(paused_all); cursor advances           (§6.7)
2. health != "ok"?      → data_unwritable / readonly / damaged: do NOT claim; cursor and next_run untouched; the slot stays due (see "Claim-write failure")
3. create run record    → state=scheduled, run_id deterministic; cursor = slot; flush state+ledger   (CLAIM)
4. preflight(job)       → async, no tokens spent; blocked(reason_code)           (§6.4)
5. overlap(job)         → skip | queue | parallel                               (§6.2)
6. cap                  → wait ≤ cap_wait_s (stay `scheduled`, reason `waiting_cap`), then skipped(cap)
7. catch-up spacing     → if trigger=catchup and now − last_catchup_launch < catchup_spacing_s: wait
8. launch queue         → one `tern` launch process at a time (FIFO)
9. state=launching; write prompt.md/preamble.md/omp.yml into the run dir; launcher runs steps 1–5 of §0.3   (ACT)
```
Claim-then-act: step 3 persists the run *before* step 9 acts; §5.4 repairs a crash between them. Waiting runs sit in `state.pending` and `inflight`. A run is never waiting for a window: there is none to wait for.

**Claim-write failure (RF F3).** Never launch with an unpersisted claim: after a reload the slot would fire again. If either flush of step 3 (`state.json` or the ledger file) raises or is refused for size (§2.2 items 8-9), the engine (a) does **not** launch; (b) rolls `cursor`/`next_run` back in memory so the slot is not consumed; (c) records the attempt only in memory as `blocked/data_unwritable` (environmental, no streak) and sets `hot.health="data_unwritable"` (banner: "Schedule can't write its data, so nothing is launched."); (d) stops claiming new slots (step 2) and retries the dirty files each tick. When writes work again the still-due slot is decided afresh by `policy.decide`, so catch-up rules apply (a slot now older than its window becomes `missed`). A claim that persisted but whose *launch* record write fails after the pane exists is covered by the orphan rule of §5.4: the run id is in the pane's command.

### 5.7 Window observation and the rejected alternative

Window halves take no part in firing. The only window duty is `observer.luau` (§0.3), which is idempotent and leaderless, forwards **raw** samples and decides nothing (R9). If it is not running (no window), the run is tracked at tier 2/3 (§7.3).
The earlier design, a window-side launcher (`cx.agents:start`) with a leader lease and claim protocol, is rejected (AR): it steals focus and returns unusable ids. It is kept as a short appendix (Appendix E) in case Stencil fixes those issues.

---

## 6. Policies

### 6.1 Missed runs and lateness (`policy.decide`)

`decide(job, now)` (Appendix C, tested) returns `{fire?, missed?, next_run, done}`:

1. `next_run = job.next_run or next(cursor)`. If `now < next_run` → nothing.
2. Collect due slots up to `now` (≤ 500 for cron; arithmetic for intervals): `first`, `latest`, `n`.
3. `late = now − latest`.
4. If `n == 1` and `late ≤ ONTIME_S (120 s)` → **fire** (normal).
5. Apply catch-up to the `latest` slot: `within` → fire iff `late ≤ catch_up_window_s` (default `CATCHUP_DEFAULT_S` = 10800); `always` → fire; `skip` → no fire. The catch-up run is tagged `trigger="catchup"` only if `late > ONTIME_S` (120 s). A fired catch-up displays the derived `caught_up` sentence (§7.4).
6. All other due slots (`n − (fired?1:0)`) become **one** `missed` record `{count, first, last}` (not N records), reason `asleep_or_closed`. If `latest` itself was *not* fired because it is over the window (`within`) the record's `last` is that slot and its reason is `late`: "Missed Mon 09:00: 13h late, over the 3h limit." There is **no `skipped(late)`** (R12): a too-late slot is always `missed`.
7. `cursor = latest`; `next_run = next(max(latest, now))` (never re-schedules into the past); one-shots set `done`.

`[VERIFIED]` cases (`final_t5.txt`): on-time 15 s late → fire; Fri-night→Mon 10:00 → catch-up fire; Fri→Mon 22:00 (13 h late) → `missed`; Fri→Wed with 3 slots → catch up Wed, `missed=2`; `*/15` after 3 h sleep → 1 fire + `missed=11`; `every 30m` after 2 h 40 → 1 catch-up + `missed=4`; `catch_up=skip` → missed; one-shot 5 h late → missed (default) or run (`always`).

| Policy | Default | Per-job override | Justification |
|---|---|---|---|
| Missed-run catch-up | `within`, 3 h | `catch_up`, `catch_up_window_s` | PA §5.3: single catch-up convergent across Claude (7 d), Raycast (any age), Hermes (≤2 h); per-job toggle fixes Hermes' global-only limit. |
| Catch-up spacing | 30 s between catch-up *launches* | global `catchup_spacing_s` | PA §6 "Catch-up bursts" (#44128, #55631); ux §5.7. |
| Paused jobs never catch up | — | — | PA §3i (Hermes). |
| Jitter/stagger | none | — | PA §5.10 low value for one user. Two jobs at one minute start in slot order, bounded by the cap. |

### 6.2 Overlap

| Mode | Behaviour when the previous run of the same job is non-terminal |
|---|---|
| `skip` (default) | New run recorded `skipped`, `reason_code=overlap`, "Skipped: the previous run was still going." Cursor advances. |
| `queue` | New run stays `scheduled` in `pending`; **at most one** waits (a newer slot replaces the waiting one and the replaced one is recorded `skipped(overlap_replaced)`); starts when the previous run turns terminal, if still inside its catch-up window. |
| `parallel` | Launches regardless (still subject to the global cap); distinct `--session-dir`s. |

PA §5.4: Claude skips + records; Raycast folds into one; Devin queues with depth; Hermes refuses. `skip` is the cheapest to reason about; the record makes it legible (PA §5.1).

### 6.3 Global concurrency cap

`max_concurrent = 2` non-terminal runs (counting `launching`, `running`, `needs_input`; **not** `scheduled`). A due run over the cap stays `scheduled` (reason `waiting_cap`) for up to `cap_wait_s = 600` s and then becomes `skipped(cap)`: "Skipped: 2 other jobs were already running (limit 2)." Claude Desktop skips "other scheduled tasks were already running" (PA §1a); Hermes `max_parallel_jobs` (PA §3i). `needs_input` runs count: a stalled approval must not let ten more agents pile up behind it.

### 6.4 Preflight (no tokens spent)

Runs at step 4 of admission for *every* trigger including Run now, **asynchronously**. User-controlled paths are never touched with a synchronous `tern.fs` call in the host VM: a TCC prompt, a sleeping network volume or an iCloud placeholder can block past the 2 s budget and disable every host timer until reload (RF F6). They are checked through `tern.process.run` with `timeout_ms` = 3000 (`/bin/test`). The run stays `scheduled` until preflight returns. Each failed check produces `blocked` with a `reason_code` and a one-sentence reason; none launches anything (PA §5.11; Hermes `blocked_config`).

| Check | How | Fails as |
|---|---|---|
| Job valid | schema validation passed at load (§1.1) | `invalid_job`; `cwd_unsafe` if a hand-edited `cwd` contains one of `' " \ $ ` ! newline` |
| Hands-off review | `approval="yolo"`: recompute the `hands_off_ack` hash from the stored prompt text, `cwd`, `role`; it must equal the stored value | `hands_off_review` ("Blocked: this hands-off job changed since you confirmed it. Open it in Schedule to review.") until re-confirmed in the manager |
| `cwd` | `/bin/test -d <cwd>` through `process.run`; `cwd == $HOME` requires `allow_home=true` | `cwd_missing` ("~/Dev/app doesn't exist"); `cwd_home` |
| Prompt | `prompts/<id>.md` is plugin-owned and local: one bounded `tern.fs.read(path, 64 KiB)`; non-empty. A symlinked or missing file reads as missing (bounded reads reject symlinks): re-save the prompt in the manager | `prompt_missing` / `prompt_empty` / `prompt_too_large` |
| Role | Per job cwd (R16): fresh `cache.json` entry for that cwd (`ROLE_CACHE_S`) → check membership; otherwise `tern.process.run` of `omp config get modelRoles --json` with the job cwd as working directory (`timeout_ms` 5000 `[INFERENCE: process.run takes a cwd, O11]`) and cache the result. **List read and role absent ⇒ blocked. List unreadable (error, timeout, undecodable) ⇒ the run proceeds** and gets the note `role_unverified` (§7.1); never block on missing information | `role_missing` ("role @research no longer exists in omp") |
| `tern` and `omp` | Resolved per `LA` §1 and cached in `cache.json` (candidate validated with `--version`). **No bare-`omp` fallback (R4)** | `tern_missing` (environment); `omp_missing` |
| Run dir | `fs.mkdir` of `runs/<job>/<run>` and the writes of `prompt.md`, `preamble.md` (and `omp.yml`) succeeded | `data_unwritable` |

`blocked` kinds: `cwd_missing`, `cwd_home`, `cwd_unsafe`, `prompt_*`, `role_missing`, `invalid_job`, `omp_missing`, `hands_off_review` are **config** blocks (count toward the failure streak and trigger auto-pause); `data_unwritable` and `tern_missing` are environmental (no streak). Auto-pause of a config-blocked job at the threshold sets `paused_reason="blocked"`.

### 6.5 Failure streak, auto-pause, notify-once

| Item | Rule |
|---|---|
| Counts toward `failure_streak` | `failed` (including `agent_failed` and `no_response`), `timed_out`, config-`blocked`; **not** `failed/interrupted` (Tern was restarted, not the job's fault), `skipped`, `missed`, `cancelled` (`user_stop`, `closed_by_user`), env-blocked, nor any run with `trigger="test"` (ux §4.10). |
| Resets | on any `finished` non-test run. Resume from a pause also resets. |
| Auto-pause | when `pause_after_failures ≠ 0` and `failure_streak ≥ pause_after_failures` (default 3; valid values 0 or 2–10): `enabled=false`, `paused_reason="failures"` (or `"blocked"`), one toast "paused after N failures". PA §5.12 (OpenClaw alert after 2, Hermes streak, Devin Error status). |
| Automatic retry | **None.** Providers/network errors can't be told apart from real failures reliably, and a retry spends tokens unseen (PA §5.12 "modest but real"). The UI offers *Run again*. |
| Incident | Opens on the first failure of a streak (`incident={since, run_id, notified=true}`) and fires the notification **once**. Further failures in the same incident are silent (counted only). Closes on success. OpenClaw/Hermes alert cooldown + incident grouping (PA §3h/3i); we don't need a cooldown timer because auto-pause bounds the incident. |
| `needs_input` | Notifies **once per run** when `waiting_input` has held ≥ `NEEDS_INPUT_S` (10 s); leaving and re-entering within the same run does not re-notify. **One reminder** notification after `NEEDS_INPUT_REMIND_S` (1800 s) of still waiting. If the run is still waiting at `max_runtime` it ends `timed_out(waiting_for_input)`. |
| `notify="issues"` | Notify on: needs_input, failed, timed_out, blocked (config), auto-pause. `"all"` adds `finished` (but not quiet success). `"off"`: ledger and status segment only. |

### 6.6 One-shot handling

Fires via `policy.decide` like any slot (kind `once`; `next_run = run_at`). Catch-up applies (`within`/`always`/`skip`). After the slot is handled, the job becomes `enabled=false`, state `done`. Editing the schedule of a done one-shot re-arms it. Run-now on a one-shot does not consume it.

### 6.7 Pause all / kill switch

`paused_all` (settings + `hot`) is absolute:
- The pump keeps running (heartbeat continues); `due_scan` consumes slots and records **one `skipped(paused_all)` record per job per tick** (count merged), advancing cursors. **No catch-up on resume**: the slots are already consumed ("Skipped: all jobs were paused.", ux §5.5).
- In-flight runs continue (ux §2.2: "Running runs continue"); *Stop all running* is a separate explicit action that closes (`tern close <block>`) every non-terminal run (`cancelled`, `reason_code=user_stop`).
- **Run now is refused while paused-all** ("Resume all jobs to run"), even for a manually paused job: the kill switch must be absolute (Hermes `hermes pause`, PA §5.11).
- A job paused individually (`enabled=false`): no slots, nothing recorded; on resume `armed_at = cursor = now`, so "runs missed while paused are skipped" (ux §5.7; Hermes: paused jobs never catch up).
- Damage mode (§2.2) forces `paused_all=true` in memory until the user decides.

### 6.8 Run now (D10)

`runner.fire(job, {trigger="manual", slot=now, focus_override?})`: identical admission pipeline (§5.6). Differences, all intentional: the run id is `r_<job8>_<now>_<rand4>` and **`slot = now`** (RC C24); `cursor`/`next_run` are not touched (a manual run does not consume a scheduled slot); overlap `skip` still applies and says so ("A run is already in progress"); allowed for a paused job; refused under paused-all. The `run_now` **intent** (§2.3) names an existing job and runs it with its stored settings only; just the in-process manager call may pass `focus_override="front"` (*Run now and watch*, the first-run overlay), which is recorded on the run (`focus_override`, §7.1) and folded into `focus` before the launch. `Test run` = the same with `trigger="test"`, placement `session` (or `tab`) and `focus_override="front"`, excluded from streaks and `last_outcome`. **Unsaved drafts** (RC C24): a test run of a form draft has no job, so `job_id = "_draft"`, run id `r_draft_<epoch>_<rand4>`, ledger `ledger/_drafts.jsonl` (same retention), the draft's `role`/`cwd`/`approval`/`max_runtime_s` copied into the record, run directory `runs/_draft/<run id>/`; it never touches `jobs.json` or `state.json` and can only be started from the manager block.

### 6.9 Finished-pane cap (R5)

Every run pane is launched with `--keep-open`, and an idle interactive omp holds 113–525 MB (RF F9). The host therefore keeps **at most `MAX_FINISHED_PANES` (5) finished run panes open, globally across jobs**. After a run reaches a terminal state and its record is persisted, and again each `TICK_S` while the count is over: take the run panes (blocks whose command contains a `/runs/` marker of a terminal run) from `tern_state.snapshot()`; while more than 5, close the **oldest finished, unfocused** one (`focused == false`, never an in-flight or `needs_input` run) with `close_requested = true` set first, then `tern close <block>`, then record `pane_closed_at`. If all remaining panes are focused the cap waits. The facts (record, summary, cost, `session_file`) are already persisted, so *Open run* still works by `--resume`. `after = close_ok`/`close` close earlier per job (§7.3); `after = keep` means "keep, subject to this cap".

---

## 7. Run ledger and state machine

### 7.1 Record

One record per run, in `ledger/<job id>.jsonl` (one JSON object per line, oldest first; a transition rewrites that record's line, §2.1). `last_message` ≤ `LAST_MESSAGE_MAX` (4 KiB), `summary` ≤ `SUMMARY_MAX` (200). launch.md uses these field names verbatim.

| Field | Type | Notes |
|---|---|---|
| `run_id` | string | slot runs (scheduled and catch-up): `r_<job8>_<slot>`; manual/test: `r_<job8>_<epoch>_<rand4>`; draft test runs: `r_draft_<epoch>_<rand4>`; `missed`/`skipped` summaries: `r_<job8>_<first slot>` with `count`. Idempotent claim key (D2, R3). |
| `job_id`, `job_name` | string | Name snapshot (the job can be renamed or deleted later). `_draft` for draft test runs. |
| `trigger` | `schedule\|catchup\|manual\|test` | |
| `slot` | number | The scheduled instant this run answers (manual: `now`). |
| `state` | enum (§7.2) | |
| `reason_code`, `reason` | string | Machine code + one sentence (§7.4). |
| `notes` | string[]? | Annotations that are not states, e.g. `"role_unverified"` (§6.4). |
| `count`, `first`, `last` | number? | For merged `missed`/`skipped` records. |
| `created`, `started`, `ended` | number | `started` = launch time (`tern new` returned); `ended` set on terminal. |
| `lateness_s` | number | `started_or_created − slot`. |
| `block`, `tab`, `session` | string? | Daemon ids from `tern new --json`, kept as **strings** (R3). `block` is persisted first and passed to window calls as-is (§0.3). |
| `run_dir` | string | `runs/<job id>/<run id>` (relative to `<data>`); holds `prompt.md`, `preamble.md`, `omp.yml`, `session/` (R2). |
| `session_file` | string? | Path of omp's session JSONL under `<run_dir>/session`, discovered asynchronously after launch by the walk in `LA` §8; nil until found. *Open run* resumes with `omp --resume <session_file> --session-dir <run_dir>/session` (`LA` §10). |
| `session_id` | string? | Id part of `<ISO>_<id>.jsonl` (OC §4). |
| `placement_used` | string? | Placement actually realised (`session`, `tab`, `tab_here`, …, `LA` §4); differs from `job.placement` after a fallback. |
| `focus_override` | `"front"?` | One-off *Run now and watch* / test run (§6.8); the effective focus for this run. |
| `role`, `model` | string | `role` bare as configured; `model` = `cx.agents:list()` display name seen later (`"Opus 5.5"`, PR Q6): shows role drift (PA §5.13). |
| `cwd`, `allow_home` | | Snapshot. |
| `approval`, `max_runtime_s` | | Snapshot, to explain the run. |
| `omp_path`, `omp_version` | string | The binary that ran (`LA` §1). |
| `overlay` | boolean | `omp.yml` was passed (every non-yolo run, R7). |
| `prompt_head` | string ≤ 200 | First chars of the snapshot `prompt.md` that was actually sent. |
| `busy_seen` | boolean | The host has seen a `working` sample (or a non-empty `last_message` differing from the empty baseline). Set only by the host (§7.3). |
| `observed` | boolean | At least one window sample arrived. `false` ⇒ tier 2/3 run, shown "not observed"; replaces the earlier `unobserved` field. |
| `close_requested`, `cancel_requested` | boolean? | Set **before** the host calls `tern close` (stop, policy, cap) so the vanishing block is not misread as `closed_by_user` (§7.3). |
| `pane_closed_at` | number? | When the host closed the pane (§6.9, `after`). |
| `last_message` | string? | Last assistant message ≤ 4 KiB: from a window sample (tier 1, truncated by the window) or from the asynchronous session tail (tier 2); includes Tern's cost line, e.g. `"pong\n2.1s · 308 tok · $0.01 this turn"` (PR Q4). |
| `summary` | string ≤ 200 | The last `RESULT:` line of the final message (text after the prefix), else the first line of the final message (R6). |
| `cost_line` | string? | Last line of `last_message` matching `·` and `tok`, for display only. Exact cost (`usage.cost.total`, OC §4) comes from the session JSONL read **asynchronously** with `/usr/bin/tail -c 1048576` through `tern.process.run` (never a large synchronous `tern.fs.read`, RF F9) `[INFERENCE: schema]`. |
| `cost_approx` | boolean? | The tail window was smaller than the file, so cost covers only the tail and is labeled approximate. |

### 7.2 States

`scheduled → launching → running ⇄ needs_input → finished | failed | timed_out | cancelled`; without launching: `skipped | missed | blocked`.

```
 scheduled ──(admit ok)──▶ launching ──(tern new ok)──▶ running ⇄ needs_input
     │ │                       │                     │  │        │
     │ └─ blocked (preflight)  └─ failed             │  │        └─▶ timed_out | cancelled | failed
     └─ skipped (cap/overlap/paused_all)             │  └─▶ failed (exited early / delivery_error / no_response)
 (no run) ─▶ missed                                  └─▶ finished | timed_out | cancelled
```
Terminal: `finished failed timed_out cancelled skipped missed blocked`. In-flight (listed in `state.inflight`): `scheduled launching running needs_input`.

### 7.3 Transitions and evidence

Evidence tiers (D13): **T1** window raw samples (`working|idle|waiting_input|exited`, model, last message; interpreted only by the host, R9), **T2** host `pane_exited{pane,status}` + `tern ls --json` liveness (with the run-id marker) + the asynchronous session-tail read, **T3** timers (`--max-time`, deadline). The host keeps per run `last_obs = {state, since, seen_at}`; a state *holds* while the latest sample reports it and `now − seen_at ≤ OBS_STALE_S`. Windows write a sample on change and every `OBS_HEARTBEAT_S`, so a persisting state stays fresh.

| From → To | Evidence / rule | Debounce / timeout |
|---|---|---|
| `scheduled` → `launching` | admission steps 4–8 pass | — |
| `scheduled` → `blocked` / `skipped` | preflight failure / `overlap`, `cap` (> `cap_wait_s`), `paused_all` | immediate |
| `launching` → `running` | `tern new` exited 0 and stdout parsed to `{session,tab,block}` (strings); block persisted first | `LAUNCH_TIMEOUT_MS` |
| `launching` → `failed` | non-zero status (`launch_error`, first stderr line); unparsable stdout; timeout with no orphan in `tern ls` (`launch_timeout`) | — |
| `running` → `needs_input` | **T1**: raw `waiting_input` held ≥ `NEEDS_INPUT_S` (10 s since `last_obs.since`). Unobservable without a window. | 10 s |
| `needs_input` → `running` | **T1**: a `working` sample | immediate |
| `running` → `finished` | **T1**: raw `idle` and the **`busy_seen` rule** (a `working` sample was seen at least once, or `last_message` is non-empty and differs from the empty baseline; the host sets `busy_seen`) holding ≥ `FINISH_CONFIRM_S` (6 s) (swarm `steps.luau:83-184`, LP #5). Then the host reads the session tail asynchronously for the `RESULT:` line and cost; `RESULT: FAILED - …` ⇒ `failed/agent_failed` instead. **T2** (no window): `pane_exited` status 0 with finish evidence; or the tail shows a completed assistant turn and no growth for 15 s `[INFERENCE: schema OC §4, verify]` → `finished`, `observed=false`, reason `ok_unobserved`. | 6 s / 15 s |
| `running` → `failed` | **`no_response`**: no `working` sample and an empty `last_message` `NO_RESPONSE_S` (180 s) after `started` ("Prompt not delivered"; counts toward the streak; pane kept). `delivery_error` set (`delivery_error`). **T2**: `pane_exited` non-zero (`agent_error`), or exit before finish evidence with elapsed < `max_runtime − EXIT_NEAR_LIMIT_S` (`exited_early`). | 180 s |
| `running`/`needs_input` → `timed_out` | pane exit with elapsed ≥ `max_runtime − EXIT_NEAR_LIMIT_S` (15 s; omp's `--max-time`; exit status undocumented, OC §6); or `now ≥ started + max_runtime + MAXRUN_GRACE_S` while alive: classify from the session tail (completed assistant turn ⇒ `finished`, `observed=false`, `reason_code=ok_unobserved`; else `timed_out`), then close the pane | `max_runtime` + 60 s |
| any in-flight → `cancelled` | user *Stop run*/*Stop all*: set `cancel_requested`+`close_requested`, `tern close <block>` (works without a window); `reason_code=user_stop` (or `replaced`) | immediate |
| any in-flight → pane gone | block absent from `tern ls`, or present **without the `/runs/<job>/<run>/` marker** (restored login shell, RF F5), and `close_requested` not set: `failed/interrupted` if a daemon/heartbeat gap precedes it (§5.3, §5.4), else `cancelled/closed_by_user`. With `close_requested` set, keep the state already recorded | next tick |
| `finished` + `after=close_ok`/`close` | set `close_requested`, `tern close <block>` after the record is saved (summary, cost and `session_file` are kept; *Open run* resumes the session); `close_ok` never closes failed / needs-you / focused runs | `CLOSE_DELAY_S` per `LA` §9 |
| any terminal | the global finished-pane cap (§6.9) | — |

A run with no sample for `OBS_STALE_S` while a window is open stays in its state and the UI shows "not observed". Without any window, **needs-you cannot be detected** (state `waiting_input` lives only in `cx.agents`): the availability text must say so, and the run ends at its deadline. Quiet success (`[quiet]`) is deferred past M1 (R6).

### 7.4 Reason codes

| `reason_code` | State | Sentence (ux §5.5; UI labels: `ux.md`) |
|---|---|---|
| `ok` | finished | (none) |
| `ok_unobserved` | finished | "Finished (no window was open to watch it)." |
| `agent_failed` | failed | "The agent reported it couldn't finish: *<text after `FAILED -`>*." (final `RESULT: FAILED - …`, R6) |
| `agent_error` | failed | "The agent stopped with an error: *<last line>*." (omp exit ≠ 0) |
| `exited_early` | failed | "The agent exited before finishing." |
| `no_response` | failed | "Couldn't start: the prompt wasn't delivered." (no `working` within 180 s; counts toward the streak; pane kept) |
| `delivery_error` | failed | "Couldn't start: omp needs updating to receive the prompt." |
| `launch_error` | failed | "Couldn't start: Tern couldn't open a block." |
| `launch_timeout` | failed | "Couldn't start: Tern didn't answer in time." |
| `interrupted` | failed | "Interrupted: Tern was closed while this run was in progress." (pane gone after a daemon/heartbeat gap; not counted in the streak) |
| `max_runtime` | timed_out | "Stopped at the 30m limit. Last message: “…”." |
| `waiting_for_input` | timed_out | "Stopped at the limit while waiting for you." |
| `user_stop` | cancelled | "Stopped by you." |
| `closed_by_user` | cancelled | "Closed by you." (pane gone, no gap before it, not closed by us) |
| `replaced` | cancelled | "Replaced by a newer run." |
| `cwd_missing`, `cwd_home`, `cwd_unsafe`, `prompt_missing`, `prompt_empty`, `prompt_too_large`, `role_missing`, `invalid_job`, `omp_missing` | blocked | "Blocked: ~/Dev/app doesn't exist." etc.; `cwd_home`: "Blocked: the folder is your home folder; pick a project folder or allow home in the job."; `cwd_unsafe`: "Blocked: the folder name has characters Schedule can't pass safely." |
| `hands_off_review` | blocked | "Blocked: this hands-off job changed since you confirmed it. Open it to review." |
| `data_unwritable` | blocked | "Blocked: couldn't write run data." |
| `tern_missing` | blocked | "Blocked: the tern command wasn't found." |
| `overlap`, `overlap_replaced` | skipped | "Skipped: the previous run was still going." |
| `cap` | skipped | "Skipped: 2 other jobs were already running (limit 2)." |
| `paused_all` | skipped | "Skipped: all jobs were paused." |
| `waiting_cap` | scheduled | "Waiting: 2 other jobs are running (limit 2)." (queued label; ends as a launch or `skipped/cap`) |
| `late` | missed | "Missed Mon 09:00: 13h late, over the 3h limit." (replaces the removed `skipped(late)`, R12) |
| `asleep_or_closed` | missed | "Missed Mon 09:00: Tern wasn't running or your Mac was asleep." |
| `caught_up` *(derived, not stored)* | any run with `trigger="catchup"` | "Missed Mon 09:00 while Tern was closed; ran once at 09:42." built from `slot`, `started`; shown as a suffix next to the run's own outcome |
| `role_unverified` *(note, not a state)* | any | "Couldn't check that role @research exists; ran anyway." stored in `notes` (§6.4) |
| `quiet` | finished | **Deferred past M1** (R6): "Nothing to report." |

### 7.5 Retention

Per job: newest `retain_runs` (50) terminal records and ≤ `retain_days` (90). Pruned at load and hourly (§2.5). A merged `missed`/`skipped` record counts as one. Failed records are pruned like any other by count/age; never auto-archived on failure (PA §6 "Failures that hide their own evidence").

---

## 8. Testing strategy

### 8.1 Tooling on this machine

| Check | Result |
|---|---|
| `which luau luau-lsp luau-analyze` | none found; nothing in `~/.local/bin` or `/opt/homebrew/bin` |
| `brew info luau` | formula available (stable 0.741), **not installed**. `brew install luau` provides `luau` and `luau-analyze` (real libc, honours `TZ`). I did not install it. |
| `bun` | present (`~/.bun/bin/bun`) |
| `luau-web` (npm, Luau compiled to WASM) | `bun add luau-web` works; `LuauState.createAsync()` then `loadstring(src)` returns a callable function `[VERIFIED]`. Its libc is **not** timezone-aware: `os.date("%Z")` returned `UTC-0600` and `os.time{…02:30}` round-tripped to the wrong hour. Therefore the DST tests **must use an injected clock**, not `os`. |

Hence the design rule: `cron.clock = {time, date}` is a parameter (default `os`). `test/fake_chicago.luau` implements `date("*t"|"!*t", t)` and `time(tbl)` from civil arithmetic and the US DST rule (2nd Sun March 02:00, 1st Sun November 02:00), with `mode="bsd"` (gap pushes forward, like macOS) and `mode="alt"` (the other `mktime` convention) so `resolve`'s round-trip logic is exercised for both. Tests run with no network and no Tern.

### 8.2 How to run

```
cd tern-schedule && bun add -d luau-web
bun test/run.ts test/t1.luau      # runs the Luau script; prints its output
# real libc cross-check (after `brew install luau`):
TZ=America/Chicago luau test/conformance.luau   # same cases vs os.time/os.date, expect identical to fake clock
luau-analyze lib/*.luau                          # type check
```
`test/run.ts` inlines the modules into one chunk and provides a `require("./x")` shim (the tested sources use `require("./cron")` unchanged, as in Tern).

### 8.3 Must-have cases and status

| # | Case | Expectation | Status |
|---|---|---|---|
| 1 | Spring forward, fixed-time `30 2 * * *`, 8 Mar 2026 America/Chicago | one run at 03:00 CDT; 9 Mar at 02:30 | `[VERIFIED]` t1/t2 (both fake modes) |
| 2 | Spring forward, wildcard `30 * * * *` | 01:30 CST, 03:30 CDT (no spurious 03:00) | `[VERIFIED]` t1 |
| 3 | Fall back, fixed-time `30 1 * * *`, 1 Nov 2026 | once, 01:30 CDT; next day 01:30 CST | `[VERIFIED]` t1/t2 |
| 4 | Fall back, wildcard `0 * * * *`, `*/20 * * * *` | repeated hour runs (01:00 CDT, 01:00 CST, 02:00 CST); `after` inside the second pass still yields 01:20, 01:40 CST | `[VERIFIED]` t1/t2 |
| 5 | `after` inside the repeated hour for fixed-time job | next day, no double fire | `[VERIFIED]` t2 |
| 6 | Feb 29: `0 0 29 2 *` from 2026 → 2028, 2032; from 2096-03-01 → 2104 | | `[VERIFIED]` t1 |
| 7 | Impossible: `0 0 30 2 *`, `0 0 31 4,6 *` | parse error "never fires" | `[VERIFIED]` t1 |
| 8 | DOM/DOW OR: `0 9 1 * MON`; star-AND `5 4 */2 * *` | Mondays **or** the 1st; odd days | `[VERIFIED]` t1 |
| 9 | Steps/ranges/names: `*/20 9-10 * * 1-5`, `0 9 * * 5-7`, `FRI-MON` rejected, `@daily` | | `[VERIFIED]` t1 |
| 10 | Oracle: 11 expressions vs brute-force minute scan across 1 Nov | identical prefix of 60 slots | `[VERIFIED]` t6 |
| 11 | Catch-up: on-time, `asleep Fri→Mon`, 3-slot gap, `*/15` after 3 h, interval after 2 h 40, one-shot late, `skip`, `always`, window edge 2 h 50 / 3 h 10 | table in §6.1 | `[VERIFIED]` t5 |
| 12 | NL grammar: 26 inputs incl. errors (`every 2m`, `25:00`, `2026-02-30`, `every 25h`, `monthly on the 40th`) | §3.5 | `[VERIFIED]` t3, t8 |
| 13 | `describe`: 12 expressions | "Weekdays at 09:00", "Mon, Thu at 18:30", … | `[VERIFIED]` t4 |
| 14 | `next` kind/nominal: gap → `("gap", 02:30)`, overlap → `"overlap"` | | `[VERIFIED]` t7 |
| 15 | **Not yet written**: clock-jump (`dw<−5`) keeps cursor and does not refire; reload with `launching` and no block (orphan adopted from a fake `tern ls` by the `/runs/<job>/<run>/` marker); a present block without the marker after a restart ⇒ `failed/interrupted`, not tracked, not closed (F5); launch queue serialisation and the session-exists branch with a fake `tern.process.run` (`there is no session` → `new session`); `obs` dedupe and host-side debounce (needs-input 10 s, finish 6 s, stale sample 45 s, reminder 30 min); intent envelope: file-name order, allowlist rejects `create`/`update`/`delete`/`settings`, undecodable retried 60 s; claim-write failure (fake `fs.write` raises ⇒ no launch, cursor rolled back, `data_unwritable`) and write-cap pruning (F3); `store.safe_write` torn-write recovery with a fault-injecting fake `tern.fs`; format guard refuses write; ledger retention prune; `hands_off_ack` mismatch ⇒ `blocked/hands_off_review`; role unreadable ⇒ `role_unverified` note, role read and absent ⇒ `blocked/role_missing`; finished-pane cap closes the oldest unfocused beyond 5; 15-digit block ids stay exact strings; preflight matrix | | to implement with the runner |
| 16 | **Not yet written**: real-libc conformance (`conformance.luau`) comparing `cron.upcoming` under the fake clock vs `TZ=America/Chicago luau` for 2026 | identical | needs `brew install luau` |

Add a property check: for random valid specs, `next(t) > t`, `upcoming` strictly increasing, and `next(next(t)−1) == next(t)` (no skipped slot).
Test the runner with an **injected `tern`** (fake `fs`, `timer`, `kv`, `now`, `process`) so `pump()` is driven deterministically (advance `os.time` stub by 2 s per call; sleep = jump 3 h; reload = new `runner.load()` on the same fake fs).

---

## 9. Open items

| # | Item | Needed for |
|---|---|---|
| O1 | **M1 gate (spike first, R10/R23):** palette → `cx:new_block` opens the host manager with draft args; multi-line text editing in a host block (swarm `textfield`); `prefs` inside a host block. If multi-line editing misses its time box: one-line prompt field + `ctrl+o` to open `prompts/<id>.md` in Tern's doc editor. (Prompt delivery, `@file` + positional and quoting of spaced paths are `LA` V-items, not engine items.) | §2.3 |
| O2 | Does `--session-dir` + `--resume <session_file>` work from a Tern pane, and do these sessions stay out of `omp --resume`'s picker (OC open items; `LA` §10)? The run-dir marker in the pane command makes correlation independent of it. | §7.1 |
| O3 | omp exit status at `--max-time` expiry and on approval failure (OC §6). | §7.3 |
| O4 | **T2 finish evidence without a window**: session JSONL schema for "assistant turn complete" and file-growth quiescence, via the asynchronous tail. If it cannot be made reliable, no-window runs end at the deadline classified by the tail, or the optional bundled omp reporter extension (M3, AR) writes a `done` marker. | §7.3 |
| O5 | `tern new session <session_name>` behaviour when a session with that name exists but was renamed/locked; `tern rename` of the tab; `tern pip/move` flags for the M2 `split`/`float` placements. | §0.3 |
| O6 | libc re-reading `/etc/localtime` in a long-lived daemon. | §4.5 |
| O7 | Host timer behaviour across a real Mac sleep (engine is correct either way). Tune §5.3 classes after a logged sleep test. | §5.3 |
| O8 | `tern close <block>` on an already-exited block; whether it also removes the tab. | §7.3 |
| O9 | **Two windows (R21, gating V-item):** are Tern sessions daemon-wide or per window? The `tern` CLI acts on "one window's sessions… else the first window" and the plugin can't read `TERN_WINDOW_KEY` (PR2 T7). If per window, runs land in the first window; the docs say so. | §0.3 |
| O10 | **Real daemon lifetime with zero windows** while a kept pane or run is open (R20, gating V-item; availability copy and Setup keep-alive row are architecture/ux-owned). | §5.3 |
| O11 | Does `tern.process.run` accept a working directory (needed for the per-cwd role read, §6.4)? Fallback: run the read through `/bin/zsh -l -c` with the unsafe-character gate already enforced on `cwd`. | §6.4 |

## Appendix A: `lib/cron.luau` (tested)

See `./engine-src/cron.luau`; reproduced below.

```lua
-- lib/cron.luau : pure, no tern.* calls. Local time zone only.
local cron = {}
cron.clock = { time = os.time, date = os.date } -- injectable for tests

local HORIZON_YEARS = 9 -- covers the 8-year Feb-29 gap across 2100
local MIN_INTERVAL_S = 300

local MONTH_NAMES = { JAN=1, FEB=2, MAR=3, APR=4, MAY=5, JUN=6, JUL=7, AUG=8, SEP=9, OCT=10, NOV=11, DEC=12 }
local DOW_NAMES = { SUN=0, MON=1, TUE=2, WED=3, THU=4, FRI=5, SAT=6 }
local MACROS = {
  ["@hourly"] = "0 * * * *", ["@daily"] = "0 0 * * *", ["@midnight"] = "0 0 * * *",
  ["@weekly"] = "0 0 * * 0", ["@monthly"] = "0 0 1 * *",
  ["@yearly"] = "0 0 1 1 *", ["@annually"] = "0 0 1 1 *",
}

-- ---------- pure civil-calendar arithmetic (no os.*) ----------
local function days_from_civil(y: number, m: number, d: number): number
  y -= m <= 2 and 1 or 0
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end
local function civil_from_days(z: number): (number, number, number)
  z += 719468
  local era = (z >= 0 and z or z - 146096) // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp + (mp < 10 and 3 or -9)
  return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end
function cron.add_days(y: number, m: number, d: number, n: number): (number, number, number)
  return civil_from_days(days_from_civil(y, m, d) + n)
end
local function is_leap(y: number): boolean return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end
local DIM = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function dim(y: number, m: number): number return (m == 2 and is_leap(y)) and 29 or DIM[m] end
local function dow_of(y: number, m: number, d: number): number return (days_from_civil(y, m, d) + 4) % 7 end
local function wkey(y, m, d, h, mi, s) -- monotone over wall-clock fields
  return ((((y * 12 + m) * 31 + d) * 24 + h) * 60 + mi) * 60 + (s or 0)
end
local function civil_secs(w) return days_from_civil(w.year, w.month, w.day) * 86400 + w.hour * 3600 + w.min * 60 + w.sec end
local function utc_offset(t: number): number -- seconds east of UTC at instant t; no mktime involved
  return civil_secs(cron.clock.date("*t", t)) - civil_secs(cron.clock.date("!*t", t))
end
cron.utc_offset = utc_offset

-- ---------- parse ----------
local function parse_field(src: string, lo: number, hi: number, names: { [string]: number }?, dow: boolean?)
  local set, list = {}, {}
  local star = src:sub(1, 1) == "*"
  local top = dow and 7 or hi
  local function val(tok: string): number?
    local n = tonumber(tok)
    if n == nil and names then n = names[tok:upper()] end
    if n == nil or n % 1 ~= 0 or n < lo or n > top then return nil end
    return n
  end
  for part in src:gmatch("[^,]+") do
    local range, step = part, 1
    local r, s = part:match("^(.-)/(.*)$")
    if r then
      range = r
      step = tonumber(s) :: any
      if step == nil or step % 1 ~= 0 or step < 1 then return nil, "bad step in '" .. part .. "'" end
    end
    local a, b
    if range == "*" then a, b = lo, hi
    else
      local x, y = range:match("^([%w]+)%-([%w]+)$")
      if x then a, b = val(x), val(y) else
        a = val(range); b = (r ~= nil) and top or a  -- 'a/n' reads as 'a-max/n' (Vixie)
      end
      if a == nil or b == nil then return nil, "bad value '" .. part .. "'" end
      if a > b then return nil, "range goes backwards '" .. part .. "'" end
    end
    for v = a, b, step do
      local k = (dow and v == 7) and 0 or v
      set[k] = true
    end
  end
  for v = lo, hi do if set[v] then table.insert(list, v) end end
  if #list == 0 then return nil, "empty field '" .. src .. "'" end
  return { set = set, list = list, star = star }
end

function cron.parse(expr: string)
  local src = expr:gsub("^%s+", ""):gsub("%s+$", "")
  local macro = MACROS[src:lower()]
  if src:sub(1, 1) == "@" and not macro then return nil, "unsupported macro " .. src .. " (use @hourly @daily @weekly @monthly @yearly)" end
  local canon = macro or src
  local f = {}
  for w in canon:gmatch("%S+") do table.insert(f, w) end
  if #f ~= 5 then return nil, "need 5 fields: minute hour day-of-month month day-of-week" end
  if canon:find("[LW#?]") and not canon:find("%a%a%a") then return nil, "L, W, # and ? are not supported" end
  local mi, e1 = parse_field(f[1], 0, 59);               if not mi then return nil, "minute: " .. e1 end
  local hr, e2 = parse_field(f[2], 0, 23);               if not hr then return nil, "hour: " .. e2 end
  local dm, e3 = parse_field(f[3], 1, 31);               if not dm then return nil, "day of month: " .. e3 end
  local mo, e4 = parse_field(f[4], 1, 12, MONTH_NAMES);  if not mo then return nil, "month: " .. e4 end
  local dw, e5 = parse_field(f[5], 0, 6, DOW_NAMES, true); if not dw then return nil, "day of week: " .. e5 end
  local spec = {
    minute = mi.set, hour = hr.set, dom = dm.set, month = mo.set, dow = dw.set,
    minutes = mi.list, hours = hr.list, months = mo.list,
    dom_star = dm.star, dow_star = dw.star,
    wild = f[1]:sub(1, 1) == "*" or f[2]:sub(1, 1) == "*", -- Vixie: wildcard jobs follow real elapsed time
    src = table.concat(f, " "),
  }
  -- Statically impossible: day-of-month only (AND case) that no selected month has (e.g. 30 Feb).
  if spec.dow_star and not spec.dom_star then
    local ok = false
    for _, m in ipairs(spec.months) do
      for d in pairs(spec.dom) do if d <= dim(2000, m) or (m == 2 and d == 29) then ok = true end end
    end
    if not ok then return nil, "never fires: that day does not exist in the chosen month(s)" end
  end
  return spec
end

-- ---------- matching / resolving ----------
local function day_ok(spec, y, m, d): boolean
  local a, b = spec.dom[d] == true, spec.dow[dow_of(y, m, d)] == true
  if spec.dom_star or spec.dow_star then return a and b end -- Vixie: a '*' on either side means AND
  return a or b                                              -- both restricted: OR
end
local function matches(spec, w): boolean
  return spec.minute[w.min] == true and spec.hour[w.hour] == true and spec.month[w.month] == true
    and day_ok(spec, w.year, w.month, w.day)
end

-- first instant whose wall clock is >= target (DST gap end)
local function gap_end(target: number, guess: number): number
  local clock = cron.clock
  local function k(t) local w = clock.date("*t", t) return wkey(w.year, w.month, w.day, w.hour, w.min, w.sec) end
  local lo, hi = guess - 4 * 3600, guess + 4 * 3600
  while lo + 1 < hi do
    local mid = (lo + hi) // 2
    if k(mid) >= target then hi = mid else lo = mid end
  end
  return hi
end

-- wall time -> instant. kind: "exact" | "gap" (wall time does not exist: first instant after the gap)
-- | "overlap" (wall time happens twice: the first occurrence). Powers the form's DST preview line.
local function resolve(y, mo, d, h, mi)
  local clock = cron.clock
  local t = clock.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })
  local w = clock.date("*t", t)
  if w.year == y and w.month == mo and w.day == d and w.hour == h and w.min == mi then
    for _, delta in ipairs({ -3600, -1800, 3600, 1800 }) do -- same wall time one step away => repeated hour
      local w2 = clock.date("*t", t + delta)
      if w2.day == d and w2.hour == h and w2.min == mi then return (delta < 0) and (t + delta) or t, "overlap" end
    end
    return t, "exact"
  end
  return gap_end(wkey(y, mo, d, h, mi, 0), t), "gap"
end

cron.resolve = resolve -- (y, mo, d, h, mi) -> instant, kind
cron.dim = dim

-- ---------- next ----------
-- Smallest slot strictly after `after` (unix seconds). Returns t, kind, nominal where kind is
-- "exact"|"gap"|"overlap"|"real" and nominal = the wall time the expression named; or nil, "never"|"budget".
function cron.next(spec, after: number, budget: number?)
  local clock = cron.clock
  local left = budget or 8000
  local w0 = clock.date("*t", after)
  local sy, sm, sd, sh = w0.year, w0.month, w0.day, w0.hour
  local startkey = wkey(sy, sm, sd, w0.hour, w0.min + 1, 0)
  local found: number? = nil
  local fkind, fnom = "exact", nil
  for y = sy, sy + HORIZON_YEARS do
    for _, mo in ipairs(spec.months) do
      if y == sy and mo < sm then continue end
      for d = 1, dim(y, mo) do
        left -= 1
        if left <= 0 then return nil, "budget" end
        if y == sy and mo == sm and d < sd then continue end
        if not day_ok(spec, y, mo, d) then continue end
        for _, h in ipairs(spec.hours) do
          if y == sy and mo == sm and d == sd and h < sh then continue end
          for _, mi in ipairs(spec.minutes) do
            if wkey(y, mo, d, h, mi, 0) >= startkey then
              local t, kind = resolve(y, mo, d, h, mi)
              if t > after and not (kind == "gap" and spec.wild) then
                found, fkind, fnom = t, kind, { year = y, month = mo, day = d, hour = h, min = mi }
                break
              end
            end
          end
          if found then break end
        end
        if found then break end
      end
      if found then break end
    end
    if found then break end
  end
  if spec.wild then
    -- Real-time rule across a fall-back: the repeated hour runs again for wildcard jobs.
    if utc_offset(after + 3 * 3600) < utc_offset(after - 3 * 3600) then
      local limit = found and math.min(found, after + 3 * 3600) or after + 3 * 3600
      local t = (after // 60 + 1) * 60
      while t < limit do
        if matches(spec, clock.date("*t", t)) then return t, "real", nil end
        t += 60
      end
    end
  end
  if found then return found, fkind, fnom end
  return nil, "never"
end

function cron.upcoming(spec, n: number, after: number, budget: number?)
  local out, t = {}, after
  for _ = 1, n do
    local nt = cron.next(spec, t, budget)
    if not nt then break end
    table.insert(out, nt)
    t = nt
  end
  return out
end

-- interval + once
function cron.next_interval(anchor: number, secs: number, after: number): number
  if after < anchor then return anchor end
  return anchor + ((after - anchor) // secs + 1) * secs
end

-- gap between the slot after `slot` and `slot` (the job's local "period" for catch-up windows)
function cron.period_at(spec, slot: number): number
  local nxt = cron.next(spec, slot, 4000)
  return nxt and (nxt - slot) or 86400
end

-- min spacing over the next 6 slots (validation: >= MIN_INTERVAL_S)
function cron.min_gap(spec, after: number): number
  local ups = cron.upcoming(spec, 6, after, 4000)
  local g = math.huge
  for i = 2, #ups do g = math.min(g, ups[i] - ups[i - 1]) end
  return g
end
cron.MIN_INTERVAL_S = MIN_INTERVAL_S

-- ---------- describe ----------
local DOWN = { [0]="Sun","Mon","Tue","Wed","Thu","Fri","Sat" }
local function hhmm(h, m) return string.format("%02d:%02d", h, m) end
local function ranges(list: { number }, name: (number) -> string): string
  local out, i = {}, 1
  while i <= #list do
    local j = i
    while j < #list and list[j + 1] == list[j] + 1 do j += 1 end
    if j - i >= 2 then table.insert(out, name(list[i]) .. "-" .. name(list[j]))
    else for k = i, j do table.insert(out, name(list[k])) end end
    i = j + 1
  end
  return table.concat(out, ", ")
end
local MON = { "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec" }
function cron.describe(spec): string
  local dows, doms = {}, {}
  for v = 0, 6 do if spec.dow[v] then table.insert(dows, v) end end
  for v = 1, 31 do if spec.dom[v] then table.insert(doms, v) end end
  local nm, nh = #spec.minutes, #spec.hours
  -- times phrase
  local every: string? = nil
  local when: string
  if nm == 1 and nh == 24 then every = "Every hour at :" .. string.format("%02d", spec.minutes[1]); when = every
  elseif nm >= 2 and 60 % nm == 0 and spec.minutes[1] == 0 and spec.minutes[2] == 60 // nm then
    every = "Every " .. (60 // nm) .. " minutes" .. (nh < 24 and (" during hours " .. ranges(spec.hours, tostring)) or ""); when = every
  elseif nh * nm <= 6 then
    local ts = {}
    for _, h in ipairs(spec.hours) do for _, m in ipairs(spec.minutes) do table.insert(ts, hhmm(h, m)) end end
    when = "at " .. table.concat(ts, ", ")
  else when = "at minutes " .. ranges(spec.minutes, tostring) .. " of hours " .. ranges(spec.hours, tostring) end
  -- day phrase
  local day: string? = nil
  local dom_all, dow_all = #doms == 31, #dows == 7
  local dnames = function(v) return DOWN[v] end
  if dom_all and dow_all then day = nil
  elseif dom_all or spec.dom_star then
    if #dows == 5 and dows[1] == 1 and dows[5] == 5 then day = "Weekdays"
    elseif #dows == 2 and dows[1] == 0 and dows[2] == 6 then day = "Weekends"
    else day = ranges(dows, dnames) end
  elseif dow_all or spec.dow_star then day = "Monthly on day " .. ranges(doms, tostring)
  else day = "Day " .. ranges(doms, tostring) .. " or " .. ranges(dows, dnames) end
  local s
  if every then s = every .. ((day and ", " .. day:lower()) or "")
  else s = (day or "Daily") .. " " .. when end
  if #spec.months < 12 then s ..= ", in " .. ranges(spec.months, function(v) return MON[v] end) end
  if not spec.dom_star and not spec.dow_star and not dom_all and not dow_all then s ..= " (day-of-month OR day-of-week)" end
  return s
end

return cron
```

## Appendix B: `lib/schedule.luau` (tested)

```lua
-- lib/schedule.luau : text -> normalized schedule record (pure). Requires lib/cron.
local cron = require("./cron") -- (in the plugin: require("./cron"))
local M = {}

local DOW = { sun=0, sunday=0, mon=1, monday=1, tue=2, tues=2, tuesday=2, wed=3, wednesday=3,
              thu=4, thur=4, thurs=4, thursday=4, fri=5, friday=5, sat=6, saturday=6 }
local UNIT = { m=60, min=60, mins=60, minute=60, minutes=60, h=3600, hr=3600, hrs=3600, hour=3600, hours=3600,
               d=86400, day=86400, days=86400, w=604800, week=604800, weeks=604800 }
local DOW_CRON = { [0]="SUN","MON","TUE","WED","THU","FRI","SAT" }

local function time_of_day(s: string): (number?, number?)       -- "9am" "9:30pm" "09:00" "noon" ":15"(minute only handled elsewhere)
  if s == "noon" then return 12, 0 elseif s == "midnight" then return 0, 0 end
  local h, m, ap = s:match("^(%d%d?):(%d%d)%s*([ap]m)$")
  if not h then h, m, ap = s:match("^(%d%d?):(%d%d)()$") ap = nil end
  if not h then h, ap = s:match("^(%d%d?)%s*([ap]m)$") m = "0" end
  if not h then h = s:match("^(%d%d?)$") m = "0" end            -- bare "9" = 09:00 (24 h clock)
  if not h then return nil, nil end
  local raw, Mi = tonumber(h) or 0, tonumber(m) or 0
  if ap and (raw < 1 or raw > 12) then return nil, nil end
  local H = raw
  if ap == "pm" and H < 12 then H += 12 elseif ap == "am" and H == 12 then H = 0 end
  if H > 23 or Mi > 59 then return nil, nil end
  return H, Mi
end

local function dow_list(s: string): string?                       -- "mon,thu" "monday and wednesday" "weekdays"
  if s == "weekdays" or s == "every weekday" then return "1-5" end
  if s == "weekends" then return "0,6" end
  local out = {}
  for tok in s:gsub(" and ", ","):gsub("^every%s+", ""):gmatch("[^,%s]+") do
    local d = DOW[tok] or DOW[tok:gsub("s$", "")]
    if d == nil then return nil end
    table.insert(out, DOW_CRON[d])
  end
  return #out > 0 and table.concat(out, ",") or nil
end

-- returns { kind="cron"|"interval"|"once"|"manual", expr=..., input=..., run_at?=..., secs?=... } | nil, hint
function M.parse(input: string, now: number)
  local s = input:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  local rec = function(kind, expr) return { kind = kind, expr = expr, input = input } end
  local function cronrec(expr: string) -- every NL result is re-validated by the cron parser
    local spec, err = cron.parse(expr)
    if not spec then return nil, err end
    return rec("cron", spec.src)
  end
  if s == "" then return nil, "Enter a schedule, e.g. 'weekdays at 9am' or '0 9 * * 1-5'" end
  if s == "manual" or s == "never" or s == "off" then return rec("manual", "") end

  -- (a) raw cron / macro
  local nf = 0 for _ in s:gmatch("%S+") do nf += 1 end
  if s:sub(1, 1) == "@" or (nf == 5 and s:match("^[%d%*]")) then
    local spec, err = cron.parse(s)
    if not spec then return nil, err end
    return rec("cron", spec.src)
  end

  -- (d) relative one-shot: in 20m / in 2 hours
  local n, u = s:match("^in (%d+)%s*(%a+)$")
  if n and UNIT[u] then
    local secs = tonumber(n) * UNIT[u]
    if secs < 60 then return nil, "Minimum is 1 minute" end
    local r = rec("once", "") r.run_at = -((-(now + secs)) // 60) * 60 return r
  end

  -- (c) interval: every 30m / every 2 hours / every hour
  local n2, u2 = s:match("^every (%d*)%s*(%a+)$")
  if n2 and UNIT[u2] then
    local secs = (n2 == "" and 1 or tonumber(n2)) * UNIT[u2]
    if secs < cron.MIN_INTERVAL_S then return nil, "Minimum interval is 5 minutes" end
    if secs > 86400 then return nil, "Maximum interval is 24 hours; for longer periods use 'daily at 09:00', 'weekly' or a cron expression" end
    local r = rec("interval", tostring(secs)) r.secs = secs return r
  end

  -- one-shot "at 15:00": next occurrence of that time, today or tomorrow
  local at = s:match("^at (.+)$")
  if at then
    local H, Mi = time_of_day(at)
    if H then
      local w = cron.clock.date("*t", now)
      local t = cron.resolve(w.year, w.month, w.day, H, Mi)
      if t <= now then
        local y2, m2, d2 = cron.add_days(w.year, w.month, w.day, 1)
        t = cron.resolve(y2, m2, d2, H, Mi)
      end
      local r = rec("once", "") r.run_at = t return r
    end
  end

  -- hourly [at :15]
  local mm = s:match("^hourly at :(%d%d)$") or s:match("^every hour at :(%d%d)$") or s:match("^hourly$") and "00"
  if mm then return cronrec(tonumber(mm) .. " * * * *") end

  -- strip a leading "at"/"on" in "weekdays at 9am", "mon,thu at 18:30", "every monday 9am"
  local days, tod = s:match("^(.-) at ([%w:]+ ?[ap]?m?)$")
  if not days then days, tod = s:match("^(.-) ([%d:]+ ?[ap]?m?)$") end
  if not days then days, tod = s:match("^(%a[%a%s,]-) (noon)$") end
  if days and tod then
    local H, Mi = time_of_day(tod)
    if not H then return nil, "I can't read the time '" .. tod .. "' (try 9am, 09:30, noon)" end
    local hm = Mi .. " " .. H
    if days == "daily" or days == "every day" then return cronrec(hm .. " * * *") end
    local dl = dow_list(days)
    if dl then return cronrec(hm .. " * * " .. dl) end
    local dom = days:match("^monthly on the (%d+)%a*$") or days:match("^monthly on day (%d+)$") or days:match("^monthly$") and "1"
    if dom then return cronrec(hm .. " " .. tonumber(dom) .. " * *") end
    -- (d) dated one-shot: "tomorrow 9am", "today 17:00", "2026-10-12 09:00"
    local base: number? = nil
    local ys, ms, ds = days:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if ys then
      local y, mo, d = tonumber(ys) or 0, tonumber(ms) or 0, tonumber(ds) or 0
      if mo < 1 or mo > 12 or d < 1 or d > cron.dim(y, mo) then return nil, "That date does not exist" end
      base = cron.resolve(y, mo, d, H, Mi)
    elseif days == "tomorrow" or days == "today" then
      local w = cron.clock.date("*t", now)
      local y2, m2, d2 = cron.add_days(w.year, w.month, w.day, days == "tomorrow" and 1 or 0)
      base = cron.resolve(y2, m2, d2, H, Mi)
    end
    if base then
      if base <= now then return nil, "That time has already passed" end
      local r = rec("once", "") r.run_at = base return r
    end
  end
  return nil, "Not understood. Try: 'weekdays at 9am', 'every monday 9am', 'mon,thu 18:30', 'every 2h', 'in 20m', 'tomorrow 9am', or cron '0 9 * * 1-5'"
end
return M
```

## Appendix C: `lib/policy.luau` (tested)

```lua
-- lib/policy.luau : pure decisions. No tern.*, no I/O, `now` is passed in.
local cron = require("./cron")
local P = {}
P.ONTIME_S, P.MAX_SCAN, P.DEFAULT_WINDOW_S = 120, 500, 3 * 3600

-- job.sched = { kind, spec?(parsed cron), secs?, anchor?, run_at? }; job.cursor = last handled slot (or armed_at)
local function next_after(job, t: number): number?
  local s = job.sched
  if s.kind == "cron" then return (cron.next(s.spec, t, 3000))
  elseif s.kind == "interval" then return cron.next_interval(s.anchor, s.secs, t)
  elseif s.kind == "once" then return (s.run_at > t) and s.run_at or nil end
  return nil -- manual
end
P.next_after = next_after

-- Returns { fire = {slot, catchup}?, missed = {count, first, last}?, next_run = number?, done = bool }
function P.decide(job, now: number)
  local out = { done = false }
  local nxt = job.next_run or next_after(job, job.cursor)
  if nxt == nil then out.done = job.sched.kind == "once"; return out end
  if now < nxt then out.next_run = nxt; return out end
  -- collect due slots (bounded)
  local first, latest, n = nxt, nxt, 1
  if job.sched.kind == "interval" then
    n = (now - nxt) // job.sched.secs + 1
    latest = nxt + (n - 1) * job.sched.secs
  else
    while n < P.MAX_SCAN do
      local s = next_after(job, latest)
      if s == nil or s > now then break end
      latest, n = s, n + 1
    end
  end
  local late = now - latest
  local fire_it, catchup = false, false
  if n == 1 and late <= P.ONTIME_S then fire_it = true
  else
    local mode = job.catch_up or "within"             -- "within" | "always" | "skip"
    local window = job.catch_up_window_s or P.DEFAULT_WINDOW_S
    if mode == "always" or (mode == "within" and late <= window) then fire_it, catchup = true, late > P.ONTIME_S end
  end
  local older = n - (fire_it and 1 or 0)
  if older > 0 then out.missed = { count = older, first = first, last = fire_it and (latest - 1) or latest } end
  if fire_it then out.fire = { slot = latest, catchup = catchup } end
  out.next_run = next_after(job, math.max(latest, now))
  out.done = out.next_run == nil and job.sched.kind == "once"
  return out
end
return P
```

## Appendix E: window-side launcher (rejected, kept in case Stencil fixes the id/focus issues)

If `cx.agents:start` ever returns a usable id and stops stealing focus, a window launcher needs: per-window VM id; a lease file per VM (`bridge/lease/<vm>`, own file, no shared-file race; TTL 10 s, leader = smallest fresh id confirmed on 2 consecutive ticks); and **claim-then-act per run id**: (1) skip if `acks/<run>` exists, (2) write unique `claims/<run>.<vm>`, (3) settle ≥ 1 pump (2 s), (4) winner = smallest vm among visible claims (re-publish once if mine vanished), (5) write `acks/<run>` `{state:"starting"}` immediately before `start`, (6) never retry `start` for that run id. `tern.kv` is not used for leases or claims: concurrent sets race and the last rename wins (`API` "tern.kv"). The host's deterministic run id and cursor already make slot handling idempotent, so only "who executes request R once" is left to the window.

## Appendix D: test clock and harness

`test/fake_chicago.luau` (fake zone, two `mktime` conventions) and `test/run.ts` (inlines modules, `require` shim) are in `./engine-src/test/`; scripts `t1`–`t8` produce the outputs quoted in §8.3.
