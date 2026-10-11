# Tern probe 2: pane id forms, focus, host launch, zero-window daemon, Carly check, introspection

Tern 0.7.2 / omp 18.9.1. Throwaway plugin `sched-probe2` (host.luau + window.luau), linked, run, unlinked, deleted. Raw logs were JSONL under the plugin data dir (deleted). Agent launches used: **3 of 3** (1 via `cx.agents:start`, 1 via `cx.layout:new_tab`, 1 via host `tern new tab`), all `--model @tiny`, prompt `Reply with exactly: pong`, cwd `/tmp`. Other panes created were plain `sleep 120` shell tabs (not agent launches) used for park/focus tests.

## Headline findings (read this first)

1. **There are two pane-id namespaces in the window and only one is usable as an agent/layout target.**
   - Panes that exist in the daemon under their "CLI/daemon block id" (e.g. `17506286698538`, `17721035063303`; what `tern ls`, `tern new --json` and host `tern.process.run` see) are usable.
   - Every pane created in this window run through `cx.agents:start` or `cx.layout:new_tab`, and even the user's MERGE/SCHED panes, shows up in `cx.session:panes()`/`cx.agents:list()` with a *different* window id (`128849018887`, `128849018895`, `450971566082`, ...). Calls with that number or its string form fail: `pane runs no agent` (number), `agent not found` (string), `cx.session:pane(id)` = nil, `cx.session:resolve(str)` = nil, `cx.layout:park(id)` = `false, "unknown block, or block already parked"`, `cx.layout:close(id)` returns without closing, `cx.layout:focus(id)` does not move focus.
   - **The string form of the daemon block id (`tostring(block)` from `tern new ... --json`) works for everything**: `cx.session:pane`, `cx.session:resolve` (returns the window numeric id), `cx.agents:transcript`, `wait`, `stop`.
2. **`cx.agents:start` steals focus and focus cannot be restored from Lua; use the CLI `tern focus <block id>` (works) or avoid `start`.**
3. **`cx.layout:new_tab(launch, {focus=false})` launches without stealing focus.** It produces a live agent in `list()` (state/model/last_message), the positional prompt was auto-submitted and answered. But the returned numeric id is unusable for `wait/transcript/stop`.
4. **Host `tern new tab --json --cwd /tmp -- /opt/homebrew/bin/omp --model @tiny "<prompt>"` is the best launch path.** It does not change the shown tab or focus, returns the daemon block id, the pane is an agent in the window's `list()`, the prompt is answered, no env/PATH problem (Tern wraps the command in `/bin/zsh -l -c`), and the returned id works as a string for `wait/transcript/stop/pane/resolve`.
5. **A host clock can launch with zero windows**, but `tern new tab` fails with no session; `tern new session <name>` must be used first. The isolated daemon then exited on its own (~within 30 s) once the only block had exited and no window existed.
6. Carly `schedule` must be called from a scoped window callback (timer/command), not at load. A promptless check runs with `cx` having `agents`, `layout`, `session`, plus `tern.kv/fs/log/process/fetch/json`.

---

## Test 1. String pane ids (window `cx.agents:start`)

Baseline: `cx.session:focused()` before = `128849018887`. Snippet:
```lua
local pane = cx.agents:start({prompt="Reply with exactly: pong", cwd="/tmp", how="tab", command="omp --model @tiny"})
-- forms: pane, tostring(pane), string.format("%d", pane)
```
Raw evidence (window log, `t` = seconds since load):
```
t1_start ok pane=128849018895 (number) prev=128849018887 baseline_agents=4
t1_focus_imm        focused=128849018895        <- steal confirmed
t1_layout_focus_prev ok (no error)
t1_focus_same_call  focused=128849018895        <- layout:focus(prev) in same handler: no effect
t1_focus_after_1.5s focused=128849018895 agent={command="omp --model @tiny", model="Haiku 5.5", state="working", kind="agent", tab=128849018896, title="omp", focused=true, host=0, session=4, agent_command=..., alive=true}
t1_session_pane_{num,str,fmt}   -> nil (ok=true, no value)
t1_transcript_num  = "runtime error: pane runs no agent"
t1_transcript_str  = "runtime error: agent not found"
t1_transcript_fmt  = "runtime error: agent not found"
t1_wait_call_num   = "runtime error: pane runs no agent"
t1_wait_call_str/fmt = "runtime error: agent not found"
t1_idle (1 poll, ~4 s after start) last_message="pong\n2.1s · 8 tok · <$0.01 this turn"
t1_park_{num,str,fmt} -> false, "unknown block, or block already parked"
t1_post_park focused=128849018887 (prev; user's focus was restored by something else, see note), parked=false
t1_stop_num = "runtime error: pane runs no agent"; t1_stop_str/fmt = "runtime error: agent not found"
```
Then the tab was removed with `cx.layout:close(num)`; it did vanish from `tern ls` (verified at the end). `layout:close` with a number returned ok but in later shell-tab test did not close (see Test 1c), so the close here may have been the user or the omp exit [INFERENCE: cannot tell which].

Note on focus: between `t1_focus_after_1.5s` and `t1_pre_park` focus returned to `128849018887` without any call of mine succeeding (the probe's `focus(prev)` had run 6 s earlier). [INFERENCE: the user switched tabs.] I never saw `layout:focus` take effect.

- `cx.layout:focus(prev)` right after start: **fails** (call returns, focus stays on new pane, same handler and 1.5 s later).
- `layout:park(any form)`: **fails** (`unknown block, or block already parked`), so "focus returns after park" and "state kept while parked" are **untested**; unpark was not needed.
- Forms working for `transcript/wait/stop/session:pane`: **none of number, `tostring`, `%d`**. Verdict: **fails** (confirms prior probe; adds that `tostring(pane)` and `%d` also fail, with `agent not found`).

### Test 1b. Which string works (on the host-launched pane, Test 4)
Forms tried on the same agent (window id `450971566082`, daemon block id `18043157610498`):

| form | session:pane | resolve | transcript | wait | park | stop |
|---|---|---|---|---|---|---|
| window number | nil | n/a | `pane runs no agent` | `pane runs no agent` | false `unknown block...` | `pane runs no agent` |
| `tostring(window id)` | nil | nil | `agent not found` | `agent not found` | false | `agent not found` |
| `%d` window id | nil | nil | `agent not found` | `agent not found` | false | `agent not found` |
| daemon block id (number) | nil | n/a | `pane runs no agent` | `pane runs no agent` | false | `pane runs no agent` |
| **`tostring(daemon block id)`** | `{kind="agent", pane=450971566082, title="omp"}` | **450971566082** | **works (2 msgs)** | **works, resolved `pong\n1.9s · 8 tok...`** | false (also false) | **works, agent gone** |
| exact title `"omp"` | works | works | works | works | not tried (park takes a number; passing a string title raises `error converting Lua string to i64`) | not tried |
| tab name `"Job: probe"` (from `tern rename`) | nil | nil | `agent not found` | `agent not found` | raises i64 error | not tried |

`park(daemon id)` in either form returned `false, "unknown block, or block already parked"`. Verdict for park: **fails for every form tried**; reason unknown. A plain `sleep 120` shell tab created with `cx.layout:new_tab` behaved the same (Test 1c), so it is not agent-specific.

### Test 1c. Park/focus on plain shell tabs (no agent launches)
```
s_new_nofocus  prev=128849018889 sp=128849018899 focused unchanged=128849018889   (new_tab focus=false works)
s_park_num     false, "unknown block, or block already parked"
s_close        ok, but entry still present 1.5 s later (pane did not close)
s2_new_reveal  new_tab default reveal: focused_same_call = new pane (steals focus)
s2_after_focus_prev focus(prev) -> focused still new pane, restored=false
s2_park        false, "unknown block, or block already parked"
```
Verdict: window numeric ids from this window's own `new_tab`/`start` are **not accepted by `layout:park/close/focus`** (all no-op), contradicting the doc "pass ids back exactly as received". Daemon-style ids (e.g. another plugin's block `17506286698532`) did resolve through `cx.session:pane`.

Restore used: `tern focus 17721035063305` (CLI) works (`rc=0`, shown tab changed as expected).

## Test 2. `cx.agents:wait` timeout cap
Called on a working form (daemon block id string), idle agent:
```
wait timeouts tried (all ok, no raise): 60000, 120000, 600000, 1800000, 3600000, 7200000, 86400000
```
**No `timeout is too large` error at any value up to 86 400 000 ms (24 h).** Caveat: the agent was already idle, so the awaitable resolved at once; [INFERENCE] a validation check would have occurred at call time, but that is not proven. The 30000 default is the only limit seen in docs; `cx.session:settle` is documented as capped at 120000, `wait` is not.
Verdict: **no cap observed up to 24 h**.

## Test 3. Window launch without focus steal
```lua
local p = cx.layout:new_tab({cwd="/tmp", command="omp --model @tiny 'Reply with exactly: pong'"}, {focus=false})
```
Signature (fresh types): `new_tab(self, launch: Launch?, reveal: Reveal?): number?`, `Launch = {cwd, command, block, args}`, `Reveal = {focus: boolean?}`.
```
t3_new_tab ok pane=128849018897 (number) prev=128849018887 focused_now=128849018887   <- NOT stolen
t3_poll n=1 (+1.5s) agent={command="omp --model @tiny 'Reply with exactly: pong'", model="Haiku 5.5", state="working", kind="agent", cwd="/tmp", program="omp", tab=128849018898}
t3_poll n=2 state="idle" alert=true (no last_message yet)
t3_poll n=3 (+5s) state="idle" last_message="pong\n2.0s · 8 tok · <$0.01 this turn"
t3_transcript_str / wait_call_str / stop_str (tostring(window id)) = "agent not found";  transcript_num / wait_num = "pane runs no agent"
```
Focus: unchanged (`128849018887`) through the launch. A later poll showed `focused=128849018889` [INFERENCE: the user switched tabs; not me].
The tab disappeared after the probe's failed stop; I did not close it. [INFERENCE] the user or omp exit closed it; unresolved. `tern ls` at the end shows no probe panes.
Verdict: **partial**. Launches without focus steal; agent appears in `list()` with `state`, `model`, and (after the turn) `last_message`; positional prompt is auto-submitted and answered; `wait/transcript/stop` **do not work** with the numeric id or its string form (daemon id is not returned by `new_tab`).

## Test 4. Host launch via CLI
Host half:
```lua
tern.process.run({"/Users/bfturner/.local/bin/tern","new","tab","--json","--cwd","/tmp","--",
  "/opt/homebrew/bin/omp","--model","@tiny","Reply with exactly: pong"}, {timeout_ms=15000}, cb)
```
Both omp binaries exist: `/opt/homebrew/bin/omp` and `~/Library/Application Support/Tern/omp/bin/omp`.
```
t4_new_tab status=0 stdout={"session": 4, "tab": 18043157610497, "block": 18043157610498}
```
- `tern inspect --json` before: session `Default` shown, shown tab 3, focused block `17721035063305`. After: same shown tab 3 and focus; new tab 4 was **not shown**. **No focus steal, view unchanged.**
- Inspect of the block: `program="/bin/zsh" args=["-l","-c","/opt/homebrew/bin/omp --model @tiny 'Reply with exactly: pong'"] command=... cols 80 rows 24 keep_open=false focused(in its tab)=true live=true`. The `-l -c` wrapper means the login-shell PATH/env was available; omp started fine (`tern capture <block>` showed the omp banner `v18.9.1`, the user line, `pong`, `1.9s · 8 tok · <$0.01 this turn`).
- It is an agent in window `cx.agents:list()`: `{pane=450971566082, kind="agent", agent_command="/opt/homebrew/bin/omp --model @tiny 'Reply with exactly: pong'", command=<same>, model="Haiku 5.5", state="idle", last_message="pong\n1.9s...", tab=450971566081, session=4, title="omp", cwd="/tmp", alive=true, host=0}`.
- `tern rename 18043157610498 "Job: probe"` returned rc 0 but **renames the tab** (`tern ls`: `tab 4 "Job: probe"`), not the block/pane. `tern rename --help` says "a session, or a block's tab". The block title stays `omp`. The tab name is not a valid agent spec (`agent not found`).
- Block `18043157610498` as a **string** works with `cx.agents:wait/transcript/stop` and `cx.session:pane/resolve` (see Test 1b). `stop(...)` closed the tab.
- Prompt answered: yes.

Session targeting (`tern new --help`): `tern new session NAME [LAUNCH]`, `tern new tab [SESSION] [LAUNCH]` (default: the session shown), `LAUNCH = [--cwd DIR] [--keep-open] [-- COMMAND...]`.
```
before: sessions=[Default SHOWN] focus tab3 17721035063305
tern new session SchedProbe --json --cwd /tmp -- sh -c 'sleep 40'  -> {"session":18124761989121,"tab":...22,"block":...23}
after : sessions=[Default SHOWN, SchedProbe]   focus unchanged
tern new tab SchedProbe --json --cwd /tmp -- sh -c 'sleep 40'      -> {"session":18124761989121,"tab":18133351923713,"block":18133351923714}
after : view unchanged (Default shown, same focus)
tern kill session SchedProbe -> rc 0, session gone
```
Verdict: **works**. A dedicated "Schedule" session keeps scheduled runs out of the user's view and focus. [INFERENCE: the user would see the session in the session switcher; and a cx.agents:list() window entry for it (the list covers all sessions, as in the earlier probe).]

## Test 5. Zero-window daemon (isolated)
Env: `TERN_CONFIG_DIR=/tmp/tsp2/cfg TERN_DAEMON_SOCKET=/tmp/tsp2/d.sock`; `tern daemon --socket /tmp/tsp2/d.sock` backgrounded. (`tern daemon --help` is not supported: `unknown argument --help`, usage is `tern daemon [--socket PATH]`.)
```
tern ls                    -> "no sessions"           (daemon with zero sessions/windows)
tern new tab --json --cwd /tmp -- sh -c 'date > ran.txt; sleep 3'
                           -> "tern new: there is no session", rc 1, ran.txt not created
tern new session Jobs --json --cwd /tmp -- sh -c 'date > /tmp/tsp2/ran.txt; sleep 3'
                           -> {"session":17179869185,"tab":...,"block":17179869187}; ran.txt created (Sun Oct 11 09:12:21 CDT 2026)
tern new tab --json ...    -> works once a session exists (ran2.txt written)
```
After the blocks exited the isolated daemon exited by itself (`tern ls`: "no Tern is running (no session daemon on ...)", `tern plugin link` said "no daemon running") [INFERENCE: daemon shuts down when no window is attached and no program is live].

Host-only plugin (`hostonly`, host.luau only), linked into the isolated config, daemon restarted:
```
{"ev":"loaded","sock":"/tmp/tsp2/d.sock","cfg":"/tmp/tsp2/cfg"}      <- host env DOES contain TERN_DAEMON_SOCKET/TERN_CONFIG_DIR here
{"ev":"ls","status":0,"stdout":"no sessions\n"}
{"ev":"chosen","sub":["new","session","Jobs","--json",...]}
{"ev":"new","status":0,"stdout":"{\"session\": 4294967297, \"tab\": 4294967298, \"block\": 4294967299}"}
host_ran.txt = Sun Oct 11 09:12:59 CDT 2026
tern ls -> Jobs (shown) / tab 1 / 4294967299 sh -c 'date > /tmp/tsp2/host_ran.txt; sleep 3' ... exited 0
```
The plugin passed the socket through `/usr/bin/env TERN_DAEMON_SOCKET=... TERN_CONFIG_DIR=... /Users/bfturner/.local/bin/tern ...`; whether the CLI would find the daemon without them is not tested here (the user's real daemon in test 4 had no `TERN_DAEMON_SOCKET` env and the CLI found it).
Verdict: **works**: the host clock launches programs with ZERO windows. Must create a session when none exists. The daemon exits when idle with no windows, so the clock does not outlive an idle daemon.

## Test 6. Carly scheduled check
First attempt at load: `tern.carly: needs a scoped window callback` (must call from a timer/command callback). From a `tern.timer(1000, function(cx) ... end)`:
```lua
local id = tern.carly.schedule({title="sched probe", when="in 1m", once=true, check=[[ return function(ev, cx, state) ... return false end ]]})
```
Returned `2` (id 1 was the earlier failed-load run? No: first reload scheduled id 1; each window reload added one more task). Dry-run on schedule: executes the check (the file existed already ~0 s after scheduling). Real fire at +60 s, with these results (from the check's own `tern.fs.write` and `tern.log.warn`, both worked):
```
{"agents":true,"at":1791727720,"cx_keys":{},"cx_nil":false,"ev_keys":["ev:string"],"ev_type":"table",
 "has_await":false,"has_fetch":true,"has_fs":true,"has_json":true,"has_kv":true,"has_log":true,
 "has_os_time":true,"has_plugins_global":false,"has_process":true,"layout":true,"session":true,
 "state_type":"table","tern_global":true}
```
- `ev` is a table with one key `ev` (string). `cx ~= nil`, `cx.agents`, `cx.layout`, `cx.session` exist. `cx` iterates with no pairs() keys (userdata). `tern.kv`, `tern.fs`, `tern.log`, `tern.process`, `tern.fetch`, `tern.json` are all present; `await` is nil; `state` is a table. `tern.log.warn` lines show `plugin="schedule-4294967295"` in `~/Library/Logs/Tern/tern.log`.
- `tern.carly.tasks()` at +80 s listed only the heartbeat (id 0, `by="heartbeat"`, runs all `skipped`, `when="heartbeat"`, `window=""`). The probe task was **gone** (returning `false` ended it); `tern.carly.cancel(id)` returned `false`. So there is no `history/outcome` entry to read for an ended once-task.
- Dry-run also executes the check and writes (side effects fire at schedule time).
- Each plugin reload that re-ran `schedule` created a new task; all fired once and ended.
Verdict: **works**. The check VM can use tern.* IO and `cx.agents:start` is available [INFERENCE for calling it; not exercised, per rules].

## Test 7. Introspection
Window half: `tern.plugin = {id="sched-probe2", name="Sched Probe2", dir="/private/tmp/tern-sched-probe2", data="/Users/bfturner/Library/Application Support/Tern/plugin-data/sched-probe2"}`; `tern.runtime = {os="macos", jit=true}`; `tern.context="window"`.
Host half: same `plugin` shape, `runtime` same, `tern.context="host"`.
**`tern.plugin.dir` is an absolute package folder path (resolved symlink for linked plugins: `/private/tmp/...`)**, usable to pass a bundled file to omp `-e <dir>/omp-ext.ts` (not exercised with omp; [INFERENCE]).
`tern.getenv("TERN_WINDOW_KEY") ~= nil`: **false** in the window half and false in the host half (host also `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME=/Users/bfturner`, `SHELL=/bin/zsh`, `USER=bfturner`, no `TERN_DAEMON_SOCKET` in the real daemon). `tern.getenv("TZ")` = nil.
Date/time in **both halves** (identical results):
```
os.date("*t")   -> {year=2026,month=10,day=11,hour=9,min=5,sec=37,wday=1,yday=284,isdst=true}   (local = CDT)
os.date("!*t")  -> {... hour=14, min=5, sec=37, isdst=false}
os.time{year=2026,month=10,day=11,hour=9,min=0} -> 1791709200   (works; 9:00 CDT = 14:00 UTC)
os.time(os.date("!*t", now)) - now = 0   (see caveat below)
os.date("%Y-%m-%d %H:%M:%S %z %Z %a", 1792000000) -> "2026-10-14 12:46:40 -0500 CDT Wed"
os.clock() works (float seconds)
```
Caveat: `os.time(os.date("!*t", now)) - now` returned `0`, i.e. `os.time` treats the table as UTC-style, while `os.time{...hour=9}` returned 1791709200 which is 14:00 UTC, i.e. as LOCAL (CDT). These two readings conflict for `!*t`; I did not isolate it further. Use `os.date("*t")`, `os.time{}` with local tables, and cross-check with `os.date("%z")` rather than assuming the UTC round trip works.
Verdict: **works**: `os.date` (`*t`, `!*t`, format strings incl. `%z %Z`) and `os.time{...}` are available in both halves (enough for a cron engine; DST handling must be verified by the engine, `isdst` is reported).

## Design implications

1. **Primary launch path: host half runs `tern new tab|session ... -- <abs omp> --model <role> "<prompt>"`** and stores the returned daemon `block` id with the run record. It does not steal focus or switch the shown tab, needs no window, and works with absolute binary paths (login-shell wrapper resolves env). Pass `--cwd` for the job's working directory.
2. **Always address runs by `tostring(blockId)`** (string) in `cx.agents:wait/transcript/stop/ask`, `cx.session:pane/resolve`. Never use numeric ids or window ids from `list()`/`start()`/`new_tab()`. To join a `list()` entry to a run, call `cx.session:resolve(tostring(blockId))` (returns the window pane id) and match `list()[i].pane`; or match on `agent_command`.
3. **Do not use `cx.agents:start` for scheduled runs** (steals focus; returned id unusable; no daemon id). `cx.layout:new_tab(launch, {focus=false})` is a workable no-steal fallback for window-only launches but gives no usable handle, so run tracking needs `list()` matching on `agent_command`/cwd, and `stop` has no handle other than closing the tab via CLI.
4. **Focus restore:** `cx.layout:focus` did not work in this build for window-created panes; use `tern focus <blockId>` from the host (works) if any step must restore focus. Avoid needing it.
5. **Dedicated session ("Schedule") for runs**: `tern new session Schedule --json ...` then `tern new tab Schedule ...` keeps view and focus unchanged. A run in a non-shown session is still listed by `cx.agents:list()`.
6. **Block rename is not available via CLI**: `tern rename` renames a tab. Use it to label a run's tab (`Job: <name>`); do not use it as an agent spec.
7. **Park is unusable** in this build (`unknown block...`); do not design around park/unpark. Use a dedicated session or background tab instead.
8. **Zero-window clock:** host timer works with no window; `tern new tab` needs an existing session, so the host must create one (`tern new session Schedule`) when `tern ls` says `no sessions`. The daemon exits when idle with no windows, so scheduled runs only fire while a Tern daemon lives; missed-run policy must be explicit (catch up / skip) on next start.
9. **`cx.agents:wait` accepted timeouts up to 86 400 000 ms** with no cap error (agent was idle, so not fully proven). Still prefer polling `list()`/`wait` in chunks and persisting run state, because reload kills VM timers/pending awaitables.
10. **Carly `schedule` check** can serve as an in-window timer that survives window VM resets (durable) and has `cx.agents/layout/session` + `tern.kv/fs/process`; it must be scheduled from a callback. Each dry-run executes the check once; ended tasks vanish from `tasks()` (no history). It is optional and not needed if the host clock owns scheduling.
11. **Cron engine:** `os.date("*t")`, `os.time{}` and `%z` exist in both halves; local time is CDT here. Verify UTC round-trip behaviour (`os.time(os.date("!*t"))`) before relying on it; prefer local-table math with `isdst` handling.
12. **Bundled omp extension:** `tern.plugin.dir` gives the absolute package path, so `omp -e <dir>/ext.ts` is possible [INFERENCE; the path is `/private/...` for linked plugins].
13. Plugin reload replaces the window VM and kills its timers (same as prior probe); every reload re-ran load-time code, including `tern.carly.schedule` (duplicate tasks). Make load-time code idempotent (reconcile Carly tasks by id stored in kv).

## Cleanup done

- `tern plugin unlink sched-probe2` -> `unlinked sched-probe2 (/Users/bfturner/Library/Application Support/Tern/plugins/sched-probe2.path)`; deleted `/tmp/tern-sched-probe2`, the plugin data dir under `~/Library/Application Support/Tern/plugin-data/sched-probe2`, and `/tmp/tsp2` (the isolated daemon had already exited; `ps` shows 0 `tern daemon` processes for `/tmp/tsp2`). Raw JSONL kept briefly in `/tmp/probe2-evidence` and removed after this report.
- Probe sessions: `SchedProbe` session killed; the four `sleep 120` tabs closed by `tern close`.
- `tern plugin list`:
```
ternkit 0.1.0 Ternkit — 5 blocks, 0 lenses, window  ready
omp-pushover 0.1.0 Phone push (omp) — 0 blocks, 0 lenses, window  ready
swarm 0.1.0 Swarm — 2 blocks, 0 lenses, window  disabled
tern-rss 0.1.0 Tern RSS — 1 blocks, 0 lenses, window  ready
```
- `tern ls` at the end:
```
Default (shown)
  tab 1
    17506286698532  <plugin block>  /tmp  84×50
    17506286698538  <agent pane>  ~/Dev/<project>  84×24  focused
    17506286698540  <agent pane>  ~/Dev/<project>  84×24
  tab 2 (shown)
    17721035063303  <agent pane>  ~/Dev/<project>  171×50  focused
  tab 3
    17721035063305  SCHED: Design Tern scheduled prompt jobs  ~/Dev/personal  171×50  focused
```
- Focus: at start the shown tab was 2 (MERGE `17721035063303`); at the end it is again tab 2. During the run the shown tab moved (my window `new_tab` default-reveal test and the earlier `start` stole focus; the user also appeared to switch). I restored once with `tern focus 17721035063305` (the SCHED tab) after the shell-tab reveal test; the user's later switch back to tab 2 is theirs. No probe panes remain.
- Safety: I never sent keys to, closed, moved or captured a pane I did not create. `cx.session:pane`/`resolve`/`panes()` read metadata of user panes only (ids and titles; no capture).
