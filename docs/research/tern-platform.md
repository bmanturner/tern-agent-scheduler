# Tern platform research: scheduled omp agent jobs

Scope: Tern 0.7.2 (`tern --version` → `tern 0.7.2 (5d1cc64)`), plugin docs at `SKILL_DIR=/Users/bfturner/.omp/agent/skills/tern-plugin` (docs paths below are relative to `SKILL_DIR/references/docs/`), fresh types from `tern plugin types /tmp/tern-sched-types` (= `/tmp/tern-sched-types/tern.d.luau`, cited as `FRESH:line`). Nothing was installed/linked/modified; no panes were created. Tags: **[DOC]** documented, **[OBS]** observed on this machine, **[INFERENCE]** unverified.

---

## 1. Feasibility summary

1. **Feasible as a single Tern plugin (window half + optional host half), no omp extension needed.** Every required primitive exists: timers, persistent kv, `cx.agents:start` with a custom `command` (so `omp --model '@role' …`), `cwd`, placement, palette commands, block UI with forms/lists/overlays, toasts, status-line segments, Carly exports. Prior art `tern-swarm/lib/prepare.luau:41-46` already does `cx.agents:start({prompt, cwd, how="tab", command="omp --model '@role' --max-time N …"})` **[OBS]**.
2. **Biggest discovery: Tern already ships a durable scheduler for Carly: `tern.carly.schedule(spec)`** (guides/carly.md:130-185, FRESH:1655-1740). Persists across reloads/launches, has a manager UI (Settings › Carly › Scheduled / `carly_tasks` action), run history (last 10, outcomes `quiet|said|failed|missed|skipped`), pause, 50-task cap. Time grammar is limited: `in 20m`, `at 15:00`, `at 2026-10-04 09:00`, `every 30m`, `daily 09:00`, `weekdays 09:00`, `mon,thu 18:30` — **no 5-field cron** (no day-of-month, ranges, steps). Each fire starts a *Carly* LLM turn unless a `check` handles it; it runs only in the creating window and records "Missed while Tern was closed" if the app was down (binary string **[OBS]**). Whether a `check` can call `cx.agents:start` directly is untested (open question A).
3. **Own scheduler loop in the window half is the pragmatic default.** `tern.timer` is one-shot and re-armed from the callback (api-shared.md:186-222); a 15-60 s tick comparing `os.time()` (wall clock, sandbox exposes `os.time/date/clock/difftime`, concepts/runtime.md:18-20) to each job's `next_run` is robust to Mac sleep (monotonic `tern.now` is not a wall clock, guides/io.md:218-220).
4. **Window halves run once per window → duplicate firing is a real hazard.** `tern.kv` has **no CAS/lock**; docs say simultaneous sets race, last rename wins (api-shared.md:284-288). Need a leader lease (per-window kv key + `os.time()` heartbeat) and/or a `last_fired` idempotency key; residual race is tiny but non-zero (open question C).
5. **Host half cannot open panes/agents.** `tern.pane` is only `write` and `list` (api-host.md:581-624; FRESH has no additions). Host timers *do* run with zero windows (events.md:21; architecture.md:28-35, daemon keeps running), but the only ways to start something from the host are `tern.process.run({"tern","new",…})` (needs a window to target; empirical) or running `omp -p …` headless with no pane at all.
6. **The daemon is up even with no window open** **[OBS]**: pid 17086 running since Oct 06 as launchd job `so.stencil.tern.daemon` (SMAppService agent, BTM entry enabled). **But its plist has no `RunAtLoad`/`KeepAlive`** (`/Applications/Tern.app/Contents/Library/LaunchAgents/so.stencil.tern.daemon.plist`), and docs say "windows start it" (`tern --help`), so after reboot/logout it is **[INFERENCE]** not running until Tern.app is launched. Host timers therefore are not a replacement for launchd/cron for "fire while Tern was never opened".
7. **Placement without stealing focus is possible but partly manual.** `cx.layout:new_tab(launch, {focus=false})`, `split(...,{focus=false})`, `park` (hide a running pane in the session deck), `float`/`dock`, named tabs (`name_tab`), colored tabs (`color_tab`), sessions (`cx.sessions:create/switch/rename/lock`). `cx.agents:start` takes only `how = split|tab|replace_if_alone` and **no focus flag**; tern-swarm restores focus afterwards with `cx.layout:focus(prev)` (`prepare.luau:70-76`), implying it steals focus **[OBS from code, INFERENCE for behaviour]**. `cx.sessions:create` "creates and switches" (FRESH:548) → flicker unless switched back.
8. **0.7.2 added exactly what a CRUD UI wants:** `cx:prompt` (one-line native text field), `cx:pick` (searchable picker returning the chosen table), `cx.layout:park/unpark`, `tern.secrets`, `ExportCall` reply cap raised to 1 MiB (FRESH:1604-1609, 1483-1487, 1807-1815, 1705). Docs mirror and bundled types predate these.
9. **UI kit is sufficient for a CRUD manager**, with one caveat: in plugin blocks `editor`/`input` are *display-only* – the block's `key` handler must implement all text editing (elements/input.md:19-98; `edit`/`undo` events never arrive; FRESH:284-286 adds an opt-in `features` list for TSP programs, not for plugin blocks). Cheapest edit paths: `cx:prompt` for one-liners, `cx:pick` for model role/preset/cwd, `prefs` node (switch/choice/number/text/multi/action controls, elements/work.md:660-856) for the settings-page look, `el` checkbox/radio forms (guides/views.md:177-235), and opening a markdown file via `cx.docs:open` for long multi-line prompts.
10. **Commands cannot take arguments** (guides/commands.md has no args section; `CommandDef` has only `id,title,icon,group,keys,available,run`, FRESH:966-982). Use `cx:prompt`/`cx:pick`, or open a block with args (`cx:new_block(kind,args)`), or an `tern.carly.export` with positional args for natural-language control.
11. **Completion tracking:** no "agent finished" event exists. Use `cx.agents:wait(pane,{timeout})` (resolves with last assistant text when idle; rejects on timeout/exit), polling `cx.agents:list()[].state` (`idle|working|waiting_input|exited`), window event `pane_closed`, `tern events` (CLI JSON lines: `pane_exited`, `pane_closed`, `layout_changed` seen **[OBS]**), or host event `pane_exited` (fires with no window). `command_finished` does not apply to `omp` panes (no OSC 133 inside omp).
12. **OS notifications:** no plugin API. Tern turns program alerts (OSC 9/99/777) into toasts + an inbox (setting `notifications`, binary string **[OBS]**); plugins get `cx:toast` (`success|info|error` only) and can shell out (`osascript`, `terminal-notifier`) or reuse `omp-pushover`. A bell/badge on tabs is not exposed; `tern.chrome.tab_title` can prefix text (e.g. `●`) and `cx.layout:color_tab` can tint a tab.
13. **Unattended approvals matter:** agents started via `cx.agents:start` run interactively; a scheduled job that hits an approval prompt shows state `waiting_input`. Pass `--approval-mode`, `--max-time` in `command` (flags verified in `omp://cli-reference.md`, "Tools, approvals, and runtime"). Role selection = `--model @role` (`omp://cli-reference.md` "Model selection").
14. **Remote/iOS/web:** window-half scheduler = desktop only in practice (`tern.process`, `cx.agents:wait`, `cx.procs` are desktop; `tern.carly` desktop only; web has no Lua; iOS runs window halves but `tern.process` raises and agents are on remote hosts). Local-only design is right.

---

## 2. Findings by question

### 2.1 Where should the scheduler loop live? (`tern.timer`, survival matrix, daemon)

**API** (api-shared.md:186-222; FRESH:1790-1794):
```lua
tern.timer: (ms: number, fn: (cx: WindowCx?) -> ()) -> TimerHandle   -- TimerHandle:cancel()
tern.sleep: (ms) -> Awaitable<nil>
tern.now(): number  -- monotonic ms, origin = first call in process; host and window origins differ
```
- One-shot; "Timers do not repeat; reschedule from the callback". Negative ms → 0. No ceiling documented (limits.md: "Timers … have no count or size caps").
- Window: runs on UI thread, 50 ms budget, receives a **fresh window `cx`** → can call `cx.agents:start`, `cx.layout`, `cx:toast`. Host: 2 s budget, **no `cx`**; a failing host timer is toasted to every window.
- Over-budget → whole `timer` hook (all timers of that plugin/context) disabled until reload (guides/io.md:212-216). Keep the tick tiny; do kv/IO reads with small payloads.
- Raises `the plugin is gone` if armed after VM dropped.

**Do host timers run with zero windows?** Yes: host half lives in the session daemon which "keeps running" when a window quits (architecture.md:30-35; events.md:21 "Fires when no window is open: Yes (the daemon keeps running)"). Window timers die with the window.

**Survival matrix** (lifecycle.md):

| Event | Host timers | Window timers/VM | kv/files |
|---|---|---|---|
| Plugin reload (folder change ≤300 ms batch, `tern plugin reload`, palette Reload) | Dropped with VM; new entry re-registers (lifecycle.md:109-120) | Dropped; entry re-runs; `window_start` NOT re-run for already-run plugins (:122-130) | Unchanged |
| `tern plugin link/install/remove` | reload | reload | |
| Window quit | unaffected | gone | |
| Daemon restart (quit/crash/machine restart) | Plugins reload at daemon start, before pane restore (:137-144); timers re-armed by entry only | n/a | Unchanged |
| Daemon in-place upgrade (Unix) | Plugins stop, handed over (:146-151) | | |
| App quit (Cmd-Q) | Daemon survives **[OBS: daemon pid 17086 alive since Oct 06 across app restarts]** | Gone; `window_start` fires on next window creation | |
| Mac sleep | **[INFERENCE]** timers are monotonic-based (`tern.now` doc); likely paused/late across sleep, so always compare `os.time()` against `next_run` on each tick | same | |
| Mac reboot / logout | Daemon gone until Tern launches **[INFERENCE from plist: no RunAtLoad/KeepAlive]** | gone | |

**Is the daemon running with no window / after login?** Running now, started Oct 06 `tern daemon --socket …/daemon.sock --handoff` **[OBS: `ps`]**, launchd label `so.stencil.tern.daemon`, "Submitted" via SMAppService, parent bundle `so.stencil.tern`, BTM disposition `[enabled, allowed, notified]` **[OBS: `launchctl print gui/501/so.stencil.tern.daemon`, `sfltool dumpbtm`]**. Plist: `ProgramArguments=[tern daemon]`, `ProcessType=Interactive`, `AbandonProcessGroup=true`, no `RunAtLoad`/`KeepAlive` **[OBS]**. Launchd default PATH for it is `/usr/bin:/bin:/usr/sbin:/sbin` **[OBS]** (host `tern.process.run` inherits this: use absolute paths; `/Users/bfturner/.local/bin/tern` or `/Applications/Tern.app/Contents/MacOS/tern`). A window only "starts" it if absent (`tern --help`: "windows start it"; guides/debugging.md:98).

**Recommendation:** Scheduler tick in window half (needs `cx` to start agents); host half optional only as (a) an always-on clock that records `due` jobs to kv and fires a `tern.process.run` fallback, (b) the owner of a "Job Runs" block. If "fire while no window is open" is a requirement, the only real options are host half + CLI/headless omp, or an external launchd/cron job (outside the plugin brief).

### 2.2 Duplicate firing across windows; kv semantics

- One window VM per plugin per window (architecture.md:105-107; api-window.md:3-5). Each window runs the entry → each arms its own timer → each would fire. Window events "heard once per window" (events.md:29).
- **`tern.kv`**: `get(key)`/`set(key,value)` only (FRESH:1800-1805). No CAS, no lock, no delete-if, no TTL, no watch. Shared by both halves and all windows via one file `<state>/plugin-data/<id>/kv.json`; each VM re-reads on mtime/length change, so gets see others' sets; set rewrites whole file via temp+rename; "Simultaneous sets from two VMs race; the last rename wins" (api-shared.md:284-288; guides/io.md:71-77). Raises on unreadable/invalid JSON (retains cache). **No documented size/key-count limit** ("meant for small state: every set serializes all of it", io.md:77; limits.md "kv keys … no count or size caps"). JSON-only values; empty table → `{}` unless `tern.json.array`; `decode` drops null members.
- Other shared primitives: `tern.fs.write` (non-atomic replace; no exclusive-create/`O_EXCL`), so no lockfile primitive either **[INFERENCE: no API for exclusive create]**. `tern.process.run({"mkdir", lockdir})` gives an atomic POSIX lock though (mkdir fails if exists), at the cost of a process spawn; `({"ln","-s",…})` likewise. **[INFERENCE]** works; untested.
- **Mitigations (design, [INFERENCE]):**
  1. *Leader lease:* each window VM generates a random id at load, writes `lease.<id> = os.time()` every tick (distinct keys → merges survive; whole-file rewrite uses current merged map), and only the window with the lexicographically-smallest id among leases `< 2×tick` old fires. Window closure drops it from contention within ≤2 ticks.
  2. *Idempotency:* before firing, re-read kv; skip if `job.last_fire_at >= scheduled_slot`; write `last_fire_at` first (claim-then-act), then `get` again after ~200 ms and abort if `claimed_by ~= me`.
  3. *Or avoid the problem:* run the scheduler only in the host half (single worker VM per plugin per host) and have it call `tern.process.run({"tern","new","tab",…})`; the daemon CLI target needs checking (open question B).
  4. *Or* use Carly tasks, which are "created in and run only in their creating window" (guides/carly.md:134-135): exactly one firing window by construction, but tasks are lost to that window; `tern.carly.tasks()` lists all windows' tasks.
- Window identity helper: `TaskInfo.window: string` exists for Carly tasks (FRESH:1691); no documented per-window id for plugins besides generating one. `TERN_WINDOW_KEY` is in pane env **[OBS]**; whether `tern.getenv` in window VM sees it is unknown (window reads "the Tern app's" env, api-shared.md:181-184).

### 2.3 `cx.agents` (0.7.2 ground truth, FRESH:599-638; docs api-window.md:976-1007)

```lua
type AgentBlock = { pane: number, command: string?, model: string?, cwd: string,
  state: "idle"|"working"|"waiting_input"|"exited", last_message: string?, delivery_error: string? }
type AgentMessage = { role: "user"|"assistant", text: string, tools: { {[string]: any} } }
agents:list(): {AgentBlock}                         -- sync; ALL sessions; includes shells that run omp typed at prompt (command = json null)
agents:start({prompt: string, cwd: string, command: string?, how: "split"|"tab"|"replace_if_alone"?}): number  -- sync; returns pane id
agents:ask(agent: number|string, text): ()          -- sync; queues until composer sendable=true; blank/concurrent pending prompt errors
agents:wait(agent, {timeout: number?}): Awaitable<string?>   -- DESKTOP; resolves last assistant text when idle; default 30000 ms
agents:transcript(agent, {last: number?}): {AgentMessage}    -- default 50, max 1000, last=0 → {}; omp.session TSP chat only; non-omp → {}
agents:interrupt(agent): ()                         -- Ctrl-C, block stays
agents:stop(agent): ()                              -- closes block + program, no confirmation
```
- `command`: a **shell command line** for the pane's program; omitted → setting `agent_command` (default `omp`, binary string `DEFAULT_AGENT: &str = "omp"` **[OBS]**). Panes are actually spawned as `/bin/zsh -l -c omp` (args seen in `tern inspect --json` **[OBS]**), so PATH comes from the login shell (good for `omp`). tern-swarm passes `"omp --model '@role' --max-time 3600 <approval args>"` **[OBS: prepare.luau:41]**. "Native omp requires TSP send" – the prompt is delivered by one atomic TSP `send` event once the composer reports `sendable=true`; if omp is too old, `delivery_error` is set ("omp needs updating"). `cwd` `~`/`~/…` expands on the launch host.
- `how`: `split|tab|replace_if_alone`; omitted → setting `agent_placement` (binary: enum `AgentPlacement{split, replace_if_alone, new_tab}`, default `replace_if_alone` **[OBS: strings; settings.json has no override]**). Note the setting spells `new_tab` vs API `tab` **[INFERENCE: same thing]**. Settings keys: `agent_command`, `agent_placement` (read/write via `cx.settings:get/set`, FRESH:759-783; do not mutate user's settings from a scheduler).
- **Targeting:** `start` has no window/session/tab/workspace argument. It opens "like New agent block" relative to the **calling window's focused/current context** **[INFERENCE]**. To place elsewhere, move afterwards: `cx.layout:move_to_tab`, `move_to_new_tab(pane, session?)`, `park`, `float`, or use `cx.sessions:switch` around the call. Reads (`list`, `transcript`, `wait`, `ask`) accept pane ids or resolve specs (`"@focused"`, title) across sessions.
- **Availability in callbacks:** `cx` in timer/process/fetch callbacks in the window half is a fresh full `WindowCx` (architecture.md:109-111; api-window.md:602-607) → `cx.agents` present. Host halves have no `cx` → no agents. Queued prompts survive VM reset: "the window retains prompt until its composer reports sendable=true… queued prompts survive a Carly/plugin VM reset" (FRESH:616-617; api-window.md:986-987).
- **`wait`:** default 30000 ms; an explicit larger value is accepted (doc example uses 120000, api-window.md:1005); there is a "timeout is too large" error (binary string **[OBS]**) so a hard cap exists but its value is undocumented → test (open question D). Timeout, gone/exited agents and delivery errors **reject** (err string in `:next`). Queued/just-submitted input is not considered idle. For hour-long jobs don't use one `wait`; poll `agents:list()` every tick or chain `wait`s.
- **State exposure:** `state` derived from progress OSC 9;4 (working/idle); paused progress or an ask overlay → `waiting_input` (api-window.md:999-1000). `exited` when the program ended. `model` is available per agent.
- **Events for agent finished:** none documented. Use `wait`, `list` polling, `pane_closed` (window), `pane_exited` (host), CLI `tern events`/`tern wait`.
- **Focus:** no `focus` option on `start`; tern-swarm saves `cx.session:focused()` and restores with `cx.layout:focus(prev)` after `start` (`prepare.luau:48,70-76`) → treat `start` as focus-taking unless proven otherwise.

### 2.4 Can the host half start agents/panes?

- `tern.pane` = `write(pane, text)` + `list()` only (api-host.md:581-624; FRESH diff shows no host-pane additions). `write` types into an existing pty (queued, applies after handler returns). It cannot create panes. `cx.agents`, `cx.layout`, `cx.sessions`, `cx.hosts:terminal` are window-only.
- Host `spawn` filter modifies shells the host starts; not a launcher.
- Host `tern.process.run` can exec anything as the daemon's user: (a) **`tern new tab|session … -- omp …`** CLI → creates a pane through the control socket; env of the daemon lacks `TERN_WINDOW_KEY` so it targets "the first window" (`tern new --help`: "--window KEY's, else the window of the pane it runs in, else the first window"); behaviour with no window attached is untested. (b) **`omp -p --model @role --cwd DIR "prompt"`** headless, no pane, no window, no focus; `process.run` with no `timeout_ms` waits indefinitely (limits.md), stdout ≤16 MiB. Its output could be shown in a plugin block / resumed later with `omp --resume`.

### 2.5 Placement options

From `tern` CLI help (all `--help` captured; LAUNCH = `[--cwd DIR] [--keep-open] [-- COMMAND...]`; "as in a window, a block whose program succeeds closes unless kept open"; every command picks a window by `--window KEY` → `$TERN_WINDOW_KEY` → first window):

| Command | Usage | Scheduling relevance |
|---|---|---|
| `tern new session NAME [LAUNCH]` | session with one tab | Possible named "Scheduled" session; shown/hidden behaviour untested |
| `tern new tab [SESSION] [LAUNCH]` | tab in session (default: shown session) | Spawn agent tab: `tern new tab Scheduled --cwd D --keep-open -- omp --model '@smol' "prompt"` **[INFERENCE: prompt as positional per omp CLI]** |
| `tern split BLOCK right\|down [LAUNCH]` | block beside BLOCK | |
| `tern run BLOCK COMMAND...` | types COMMAND+Enter | |
| `tern move BLOCK below\|above\|left-of\|right-of BLOCK` / `tab N\|new-tab` | regroup | move into a Scheduled session/tab afterwards |
| `tern pip BLOCK [--over BLOCK] [--corner tl\|tr\|bl\|br]` / `tern dock BLOCK [side]` | float/dock | picture-in-picture agent monitor |
| `tern keep-open BLOCK on\|off` | keep pane after success | essential for `omp -p` style jobs |
| `tern rename SESSION\|BLOCK NAME` | session or a block's tab name | name tab "Job: daily-review" |
| `tern focus BLOCK` | "every window shows it" (explicit focus) | **do not call** for background jobs |
| `tern close BLOCK`, `tern kill session SESSION` | cleanup | |
| `tern wait BLOCK [--until exit\|prompt\|idle=MS] [--timeout S]` | exit code = program status, 124 timeout | job completion from a host process |
| `tern events [--filter KIND,...]` | JSON lines: saw `pane_exited{pane,status}`, `pane_closed{pane,by}`, `layout_changed{by}` **[OBS]** | live completion feed (host `tern.process.run` can't stream; window can't either; an external watcher can) |
| `tern capture BLOCK [--ansi\|--html\|--scrollback\|--surfaces]`, `tern send BLOCK keys\|text\|paste`, `tern process BLOCK`, `tern ls/inspect [--json]` | read/drive | `inspect --json` exposes `sessions[].shown`, a top-level `detached: []` list, `panes[].keep_open/followed`, `clients[].kind (window|cli)` **[OBS]** |
| `tern help dev` | headless `serve`, `ctl`, `shot`, scenarios; **not** a spawn mechanism for end users | |

`new`/`split` expose **no name or focus flag**; naming is a follow-up `rename`; whether `new tab` steals focus is untested (open question E). `tern inspect --json` having a `detached` session list suggests daemon sessions can exist with no window showing them **[INFERENCE]** (the "background session not shown" idea).

From the plugin API (window): 
- `cx.layout:new_tab(launch, reveal)`, `split(target, dir, launch, reveal)` where `Reveal = { focus: boolean? }` (FRESH:902-903, 1462-1464) → **`{focus=false}` opens without stealing focus**. `Launch = {cwd?, command?, block?, args?}` (FRESH:1028-1037). Note: a plain `layout:new_tab({command="omp …"})` is a terminal pane running omp, not an `agent`-kind block started through `cx.agents` (agent kind reporting for typed-at-prompt omp exists: `list()` includes "shells running omp" though). Whether prompt-delivery/`wait`/`transcript` work on such a pane: [INFERENCE] yes via `list()`+`ask`, untested.
- `cx.layout:tab(spec, reveal)` builds + names a workspace tree (`TabSpec{cwd,name,split,ratio,launch,[1],[2]}`); `name_tab`, `color_tab`, `order_tab`, `move_to_tab`, `move_to_new_tab(pane, session?)`, `float/dock`, **`park/unpark` (new in 0.7.2: "Parks pane in its session's deck, its program still running; its split collapses, or its tab closes when it was the only pane"; `unpark` deals it back, FRESH:1483-1487)** → a "hidden but running" agent pane, perfect for background jobs; `snapshot/restore`, `arrange`.
- `cx.sessions:{list,current,create,switch,rename,close,lock,unlock}` (FRESH:543-561): `create` "Creates and switches to a session"; so a "Scheduled" session is creatable, then `switch` back (flicker). `lock` prevents interactive close.
- `cx.hosts:terminal(host, {cwd, command})` opens and **focuses** a shell tab (FRESH:588-590).
- Keep-open: CLI `--keep-open`/`tern keep-open`; window API has no equivalent documented; default Tern closes a pane whose program succeeds (CLI help). An interactive `omp` stays alive until quit, so only relevant for `omp -p`.
- **Opening without stealing focus:** yes for `layout:new_tab/split` (`{focus=false}`), `move*`, `park`; **unknown/probably no for `agents:start`** (see 2.3).
- Window tab-title formatter `tern.chrome.tab_title(fn(TabInfo{id,name,cwd,program,title,panes,busy}))` can prefix/badge scheduled-job tabs (api-window.md:352-382); `tern.chrome.refresh()` after state change.

### 2.6 UI kit for a CRUD job manager

**Block lifecycle** (api-host.md:41-113, guides/blocks.md): host-defined `tern.block.define(id, {init(cx,args,saved), view, title, key, event, resize, save})`; manifest `[[blocks]]` required; view returns `{main=col(...), dock=…, layer=…}` (region roots are not drawn; always wrap in a `col`). `save` returns JSON that is restored after reload/daemon restart (blocks.md; lifecycle.md:114,137-144). Blocks are host-side: **a block's host VM has timers and `tern.process` but no window `cx`**; to start agents the block must hand off to the window half. Mechanisms: shared `kv` (queue), `cx:open("jobs://run/ID")` handled by `tern.route.link` in the window half, or window half `tern.on("canvas_action")`. [INFERENCE: route.link scheme is the cleanest host→window RPC; `cx:open(target)` on Block cx forwards to windows showing the pane (api-host.md:304,500-501).] Alternatively build the manager as a **window-half canvas** (`cx.canvas:open`, owner-tagged panels, `canvas_action` events deliver clicks to the plugin, api-window.md:679-754): no host entry, direct `cx`. Canvas limits: no `input`/`editor`/images, no keys (canvases take no keys), 256 KiB/change, 2000 nodes.
**Controls:** 
- Buttons/actions: `p.actions = {click="run=ID"}` → `event{ev="action", act="run", value="ID"}` (views.md:132-170); `menu` for right-click.
- Lists: `ui.list(items)` / `item` rows with icon/label/detail/value/key hint; selection is yours; `select`/`activate` events (elements/lists.md). `picker` node: modal searchable sheet with scopes/tabs/actions (lists.md:312-470). `tabs` node.
- Text: `editor` (multi-line) and `input` (one-line) display state you own; keys arrive at `key`; plugin blocks advertise no `edit` feature, so you implement insert/backspace/cursor yourself; set focus with `cx:frame({{"focus","main.field"}})` (elements/input.md:19-98).
- **`cx:prompt({value,placeholder,icon,action}) → Awaitable<string?>`** and **`cx:pick({items=[{label,detail,group,icon,current,…}],placeholder,icon,action}) → Awaitable<PickItem?>`** (0.7.2, FRESH:1604-1609, 1616-1653), available on any window `cx` (palette command, timer…). They remove most text-editing work for name, cron/preset, directory, model-role and prompt one-liners. Prompt is one line only → multi-line prompt via `cx.docs:open(path,{how="beside"})`/`cx.docs:read(path)` on a `~/…/jobs/<id>.md` file the user edits, or paste (a `paste` key arrives with the text, api-host.md:181-183).
- Checkbox/radio/forms: `ui.el("input",{type="checkbox"|"radio",…})` + form `values` on events (views.md:177-235).
- Settings-page look: `prefs` node (elements/work.md:660-856): pages/sections/rows with controls `switch|choice|number|text|multi|action|keys`, `changed` markers, search, keyboard `editing` state you drive. Good for global settings (default role, default cwd, default placement), also could be rows-as-jobs with `action` buttons.
- Modal dialogs: `overlay` node in `layer` (`modal`, anchor/size, children incl. lists; keys still go to your `key` handler, elements/chrome.md:237-304).
- Dock: `dock` region strip below main (api-host.md:54-58) – buttons (`badge`/`el button` with actions) for New/Run/Pause; `checklist` dock pill exists (elements/work.md:428-556).
- Toasts: `cx:toast(level,text,sub?)` **window levels only `"success"|"info"|"error"`** (anything else raises, SKILL.md:147; api-window.md:599); host Effect cx toasts accept `success`, `error|warn|warning` (→error), other → info (api-host.md:497-503). Node `toast` in a block view: `text,sub,tone,ttl` (elements/chrome.md:161-185). One toast at a time window-wide; 2.2 s success / 5.2 s info/error.
- Palette commands: `tern.command({id,title,icon,group,keys,available,run})` → palette row + action `plugin.<plugin>.<id>`; bindable via `tern.bind`/settings; `available(cx)` 4 ms gate (api-window.md:108-155). **No arguments**; use `cx:prompt/pick`. Several commands per plugin ("Scheduled jobs: New…", "Run now", "Pause all", "Open manager"). `cx:action("plugin.<id>.<cmd>")` from another plugin fails on 0.4.5 (SKILL.md:153-156) but docs for 0.7.2 say it works (guides/carly.md:126-128) [verify].
- Status line / chrome: `tern.chrome.status(fn(StatusPaneInfo) → {{text,icon,tone,command}})`; pure function, 4 ms, cached per input, so a "next job in 12m" segment must read an upvalue/ kv value and call `tern.chrome.refresh()` from the timer; clicking runs any action (e.g. `plugin.sched.open`) (api-window.md:403-464). Also `tab_title`, `window_title` formatters. Status segment is per *focused pane* input but formatter can ignore the pane.
- Bell/badge on tabs: no API; emulate with `tab_title` prefix + `color_tab`.
- OS-level notification: no plugin API; options: `tern.process.run({"osascript","-e",'display notification …'})`, `terminal-notifier`, omp-pushover prior art (`/Users/bfturner/Dev/personal/omp-pushover`). In-app: Tern setting `notifications` converts OSC 9/99/777 from programs to toast + inbox (**[OBS: binary string, "Programs' alerts (OSC 9, 99 and 777) show as toasts and in the inbox"; `notification_filters` in settings.json]**) – omp itself may already emit such alerts (not verified).
- Secrets: `tern.secrets.get/set` (window-only, keychain, 0.7.2).
- Carly integration: see 2.8.

**Budgets that shape code:** window 50 ms/call, formatter 4 ms, host 2 s (limits.md). Do JSON/kv of the whole job list only on edit and tick (small), and no loops over unbounded input.

### 2.7 Events useful for completion tracking

| Source | Event | Payload | Notes |
|---|---|---|---|
| Host | `pane_exited` | `{pane,status}` | fires with no window; any pane incl. agents (events.md:36-39) |
| Host | `command_started/finished`, `cwd`, `title` | see docs | `title` changes on omp panes could signal progress **[INFERENCE]** |
| Window | `pane_created/pane_closed` `{pane}`, `tab_created/closed`, `focus`, `window_start`, `title`, `cwd`, `command_*` | events.md:177-188 | `pane_closed` only for panes **this window** closes, not other windows' or daemon-side exits (events.md:220-231) |
| Window | `canvas_action` | `{pane,owner,act,node,…}` | clicks from `cx.canvas` panels |
| Agent | none; `cx.agents:wait/list/transcript` | | state from OSC 9;4 |
| CLI | `tern events` JSON lines `pane_exited`,`pane_closed`,`layout_changed` **[OBS]**; `tern wait BLOCK --until exit` | | external watcher possible |

Events caused while the window half isn't loaded are dropped, not queued (events.md:265-266): a window that was closed misses completions → on `window_start` reconcile by scanning `cx.agents:list()`.

### 2.8 Carly: exports, heartbeat, scheduling

- **`tern.carly.export(name, {sig,doc}, fn(...args, cx, call))`** (guides/carly.md:32-94; FRESH:1722-1741): window half, desktop only; name `[a-z][a-z0-9_]{0,23}`, ≤16 per plugin; `sig`/`doc` ≤1024 bytes each; args positional JSON-safe; return value or `call:wait(ms)` (default 30000, max 120000) + `call:reply/fail`; **reply cap 1 MiB in 0.7.2 (docs/ bundled types say 16 KiB)**. Carly calls `await(plugins["<id>"].<name>(...))`. Loaded plugins' exports and `tern.carly.context(fn)` (≤400 chars each, 1600 total, 4 ms) are visible to Carly automatically → "list my jobs", "add a job: weekdays 09:00 …" via exports `jobs_list()`, `job_add(spec)`, `job_run(id)`, `job_pause(id, bool)`, `job_remove(id)`.
- **`tern.carly.schedule(spec: TaskSpec) → id`, `tasks()`, `cancel(id)`** (FRESH:1655-1740; guides/carly.md:130-185): "Desktop window only: durable Carly task. Exactly one of when/on is required." Fields: `title ≤60`, `when` (`in 20m`, `at 15:00`, `at 2026-10-04 09:00`, `every 30m`, `daily 09:00`, `weekdays 09:00`, `mon,thu 18:30`), `on` (window event watch), `check` (Luau source string returning `function(ev, cx, state)`; nil=quiet, false=end, string/table escalates; runs synchronously in its own VM, 50 ms; receives `dry_run` on creation and `resume` after a window reopens), `prompt` (turn instructions), `pane`, `once`, `expires` (event watch ≤7d, default 12h), `id` (replace). Min recurrence 5 min when a model turn can start; 1 min for promptless checks. Max 50 tasks. Recorded `by = "plugin:<id>"`, persisted across reloads and launches, run **only in the creating window**; manage in Settings › Carly › Scheduled (action `carly_tasks`, actions.md:138). Run log: `at`,`outcome(quiet|said|failed|missed|skipped)`,`text`, last ten. Binary strings: "Missed while Tern was closed", "recording missed Carly task", "tasks: at most 50 scheduled tasks", "id: heartbeat cannot be removed" **[OBS]**.
  *Implication:* it is a ready-made persistent, UI-managed scheduler, but every fire is shaped as a **Carly turn** (Carly's model, `carly.model` can be a role like `"@smol"`, FRESH:766 example), not an omp job. If a `check` is allowed to call `cx.agents:start(...)` (its `cx` is described as `cx` in the signature; capabilities not documented) the loop could be: `schedule({title=…, when=…, check=[[return function(ev,cx,state) cx.agents:start({prompt=…,cwd=…,command=…}) return nil end]]})` → zero LLM cost, durable, with history and "missed" accounting. **Unverified; highest-value experiment (open question A).** Downsides: no true cron, 5-min lower bound is irrelevant (≥1 min), per-window ownership, prompt/cwd/role must be embedded in the Lua source string (JSON-escape carefully), model-turn escalation path may spend Carly tokens if misused.
- **Heartbeat:** built-in task 0 "heartbeat", managed by an interval setting, "every 30 minutes by default, Settings › Carly" (`~/Library/Application Support/Tern/carly/HEARTBEAT.md` **[OBS]**: "Carly reads this checklist on every heartbeat… speaks up only when something needs you. While it holds nothing but headings and comments, no heartbeat runs."). It can't be deleted/replaced (FRESH:1678,1737). Not a general job scheduler (a checklist prompt run by Carly), though a one-line checklist entry such as "every morning start an omp review in X" is the zero-code way for a user to get a vague version of this.
- `cx:ask_carly(text)` opens Carly with a shown question (guides/carly.md:111-124).
- Carly also has built-in tools (`inspect`, `configure`, `session`, `arrange`, `actions`, `run_command`, `send_input`, `lua`) and the full window `cx` including `agents` (guides/carly.md:8-30), so a user can already say "start an omp agent in ~/x with this prompt" interactively.

### 2.9 Support matrix (concepts/support-matrix.md, architecture.md:47-91)

| Capability | macOS/Linux/Windows desktop | iOS | Web tab |
|---|---|---|---|
| Host half (timers, blocks, pane events) | Yes, in daemon | No | No |
| Window half (commands, cx.agents, cx.layout, canvas) | Yes | Yes (interpreted); `tern.process` raises; agents/panes belong to attached remote hosts | **No Lua** |
| `tern.fetch` | Yes | Yes | n/a |
| `tern.carly.*` | Desktop windows only (carly.md:3-6, api-window.md:52) | no | no |
| `cx.agents:wait`, `cx.procs`, `cx.db/git/docs` | desktop | desktop only | n/a |
| Remote hosts | A remote daemon runs *its own* host halves from *its* plugins folder; your window half is local but drives remote panes; a remote host's plugin can't run code on your machine (security.md:60-85). `cx.agents:start` on a remote-session focus would target that host's launch **[INFERENCE]**; `cx.hosts:terminal(host,{cwd,command})` explicit remote tab. | | |
| Plugin blocks/lens views shown | Yes | Yes | Yes (from serving host) |

Scheduled jobs are therefore a **local desktop** feature; the block UI the host half defines is also visible on iOS/web (read-only mirror, but input via keys works on web? [INFERENCE: yes, blocks accept keys from any replica]).

### 2.10 Existing scheduling features (grep of docs for schedule/cron/interval/every/at/launchd/wake)

- `grep -rn -i "heartbeat\|schedule\|cron\|launchd\|wake\|TaskSpec" docs` → hits only: guides/carly.md:130-185 (Carly schedule), reference/actions.md:138 (`carly_tasks` action: "Carly: Scheduled tasks · Opens Settings › Carly › Scheduled"), guides/blocks.md:202 ("change state from a timer"), examples/longrun.md (a 1 s self-rearming `schedule()` render tick), reference/api-window.md:474-486 (same pattern), examples/review-queue.md:69 (launchd's short PATH note), concepts/architecture.md:62 ("when they wake it", event loop). No cron/launchd/wake/sleep API; no plugin hook for "system woke".
- Note: bundled doc mirror and bundled `tern.d.luau` are **both** older than 0.7.2 (no `cx:pick`/`cx:prompt`/park); the SKILL's `tern.d.luau` already contains `tern.carly.schedule` (diff shows no change there).

---

## 3. API drift 0.7.2 vs bundled types

`diff /tmp/tern-sched-types/tern.d.luau SKILL_DIR/references/tern.d.luau` (fresh file 90,656 bytes). Relevant adds/changes in **fresh (0.7.2)**; use these as ground truth:

| Area | Change in 0.7.2 | FRESH line | Relevance |
|---|---|---|---|
| Forms | **`WindowCx:pick(PickOptions) → Awaitable<PickItem?>`** (searchable picker; `PickItem{label,detail,group,icon,current,…}`; nil on dismiss) | 1604-1606, 1616-1641 | Role/preset/directory/job chooser without writing a list view |
| Forms | **`WindowCx:prompt(PromptOptions?) → Awaitable<string?>`** (one-line native field over focused pane; `value,placeholder,icon,action`) | 1607-1609, 1643-1653 | Name/cron/path/prompt input from palette commands |
| Layout | **`LayoutCx:park(pane)` / `unpark(pane, reveal)`**; `PaneInfo.parked`; `session:panes()` "parked ones included"; `snapshot/restore/arrange` include parked panes; `TabGroup.blocks` may deal parked blocks | 1483-1487, 373-377, 1444, 912-915, 1498 | Hide a running agent pane without closing it |
| Secrets | **`tern.secrets.get/set`** (window-only keychain, per plugin) | 1807-1815 | Not needed unless storing tokens |
| Carly | `ExportCall:reply` cap **1 MiB** (was 16 KiB); `ExportCall:wait` returns typed `ExportWait`; | 1698-1711 | Larger job lists via Carly |
| Whiteboard | `cx.whiteboard` (WhiteboardCx) + `PaneKind` adds `"canvas"`, `"carly"`; canvas docs say `tern.canvas` ≠ whiteboards | 355-357, 1293-1420, 1564-1567 | Irrelevant to scheduling |
| Canvas | `cx.session:event` can fire canvas action clicks; unknown fields raise | 1283-1285, 1441 | Minor |
| Surface | `BlockCx`/surface hello `features: {"edit"|"undo"}` opt-in | 284-286 | TSP programs only; plugin blocks still send none |
| Env | spawn env also sets `TERN_BLOB_DIR` | 350 | Minor |
| Hosts | `ManagedHost.state` adds `"stalled"` | 567 | Minor |
| Misc | `tern.base64.encode/decode`; `tern.runtime.jit` doc tweak | 1775-1783, 37 | Minor |

**Unchanged between the two (already in bundled types):** `AgentsCx` (start/ask/wait/transcript/interrupt/stop, `AgentBlock`, `delivery_error`), `tern.carly.schedule/tasks/cancel`, `tern.timer/sleep`, `tern.kv`, `LayoutCx` (except park), `SessionsCx`, `HostsCx`, `Reveal`, `Launch`, `TabSpec`, `ToastLevel`, `tern.on` event lists (host: `spawn,command_started,command_finished,cwd,title,pane_exited`; window: `window_start,focus,pane_created,pane_closed,tab_created,tab_closed,command_started,command_finished,cwd,title,canvas_action`).

**Doc-vs-type discrepancies noted:** docs say "window `cx:toast` only success/info/error" (consistent); doc `Carly export` cap 16 KiB (docs) vs 1 MiB (fresh types); docs mirror `api-window.md` Window cx table lacks `pick`/`prompt`/`whiteboard`.

---

## 4. Open questions needing an empirical test

A. **Can a Carly `check` call `cx.agents:start` (or any `cx` method) directly with no model turn?** (Would make `tern.carly.schedule` the durable scheduler.) Test: `schedule({title="probe", when="in 1m", check=[[return function(ev,cx,state) cx:toast("info","check ran") cx.agents:start({prompt="hi",cwd="/tmp"}) return nil end]]})`; also does `ev` for a `when` task carry fields (`ev.ev`?), and what do outcomes `quiet/said` record? Does `tasks()` `next` survive reload? What happens to a missed fire (window closed) on reopen (`resume` call, catch-up or skip)?
B. **Host `tern.process.run({"tern","new","tab","--cwd",D,"--",...})` from the daemon with zero windows open:** does it fail, queue, or create a detached session? Which window/session does it use with no `TERN_WINDOW_KEY`? Does a pane appear in `tern inspect --json` `detached`?
C. **Duplicate-fire protocol:** two windows, kv leases; measure the race window of simultaneous `kv.set` (loop-set from two windows) and whether distinct keys are lost.
D. **`cx.agents:wait` maximum timeout** (the "timeout is too large" error value) and behaviour on 1-hour waits; does an unfocused/parked/hidden pane report `idle/working` correctly (progress OSC 9;4 from omp)?
E. **Focus and placement of `cx.agents:start`:** does `how="tab"` steal focus/switch tab/session? Does passing `cx.sessions:switch` first target another session? Can you start in a parked/hidden state (`start` then `layout:park(pane)` in the same handler)? What does `replace_if_alone` do for a scheduled start in an otherwise empty window?
F. **`cx.layout:new_tab({command="omp --model '@x' \"prompt\"", cwd}, {focus=false})` vs `cx.agents:start`:** does the former show up in `cx.agents:list()` with `state`, support `wait`/`transcript`? Is a positional-argument prompt (omp CLI) simpler than TSP send? Handling of quoting.
G. **Sleep/wake:** do `tern.timer`s catch up immediately after Mac wake, pause, or drift? Add `os.time()` delta logging to a timer test and sleep the machine. Does the daemon survive lid-close? Does Tern close/reopen windows → `window_start` re-run?
H. **After reboot** does `so.stencil.tern.daemon` start at login without opening Tern? (Check `launchctl print` after login; BTM says enabled, plist has no RunAtLoad.)
I. **Approval prompts in unattended agents:** with `--approval-mode yolo|write`, do scheduled agents ever block on `waiting_input`; how does that surface (`state`), and can the plugin auto-interrupt/stop after `--max-time`?
J. **`cx:action("plugin.<id>.<cmd>")` cross-plugin** in 0.7.2 (SKILL says "Unknown action" on 0.4.5, guides/carly.md:126-128 says it works now) – matters for status-segment click → manager open (same plugin, so should work).
K. **Host→window handoff for a host-defined manager block:** does `cx:open("sched://…")` from Block cx reach `tern.route.link` in the window half? Alternatively skip the block and build the manager as a window-half canvas/`prefs`-style canvas? (Canvas forbids input fields but has `cx:prompt`.)
L. **`cx:prompt` multi-line?** One line only per docs; check paste behavior and length limits. Check `cx:pick` item count limit and whether `PickItem` extra fields round-trip.
M. **omp OSC alerts → Tern notifications/inbox:** does omp emit OSC 9/777 on turn completion so that scheduled jobs produce toasts/inbox entries for free? Setting `notifications` / `notification_filters`.
N. **Do omp panes started from `cx.agents:start` run under launchd's env?** Observed args `/bin/zsh -l -c omp` mean login-shell PATH; confirm `OMP_*` env and `--profile` selection work through `command`.
O. **Reload behaviour of an in-flight job:** after plugin reload during a job's `wait`, are `wait` callbacks lost (VM dropped)? Design: persist `{job_id → pane}` in kv and re-attach by polling `cx.agents:list()` at `window_start` / after load.
P. **Per-window leader election and window id:** is any stable window identifier readable by plugins (`tern.getenv("TERN_WINDOW_KEY")` in window VM; `TaskInfo.window` for Carly tasks)?

---

## 5. Raw evidence index

- Daemon: `ps` → `/Applications/Tern.app/Contents/MacOS/tern daemon --socket …/daemon.sock --handoff` (started Oct 06); `launchctl print gui/501/so.stencil.tern.daemon` (Submitted, managed_by ServiceManagement, default PATH `/usr/bin:/bin:/usr/sbin:/sbin`); plist at `/Applications/Tern.app/Contents/Library/LaunchAgents/so.stencil.tern.daemon.plist`; `tern inspect --json` → `{sessions[{id,name,shown,tabs}], detached, panes, clients[{kind: window|cli}]}`; agent panes show `program=/bin/zsh args=["-l","-c","omp"] command="omp"`.
- Settings keys found in binary strings: `agent_command` (default `omp`), `agent_placement` (`split|replace_if_alone|new_tab`, default `replace_if_alone`), `notifications`, `notification_filters`, `confirm_close`, `new_blocks`, `share_sessions`, `desktop_integration`.
- Tern state: `~/Library/Application Support/Tern/{settings.json,plugins/*.path,plugin-data/<id>/kv.json,carly/HEARTBEAT.md,daemon.sock,daemon.state}`; a `sched-probe` plugin link and data dir already exist there (not mine; presumably another investigation's probe).
- Prior art: `/Users/bfturner/Dev/personal/tern-swarm/lib/prepare.luau:26-76` (agent start with role, max-time, approval args, focus restore).
- omp flags verified in `omp://cli-reference.md`: `--model <id-or-role>` (`@slow`), `--cwd`, `--approval-mode always-ask|write|yolo`, `--yolo`, `--max-time`, `-p/--print`, `--mode json|rpc`, `--no-session`, `--profile`.
