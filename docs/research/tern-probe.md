# Tern plugin probe: timers, host process, cx.agents, single-launch lock

Tern 0.7.2, omp 18.9.1. Probe plugin `sched-probe` (host.luau + window.luau), linked, run, unlinked, deleted. Raw JSONL was written under `~/Library/Application Support/Tern/plugin-data/sched-probe/` and deleted at the end.
The run used 2 agent launches total (A = default command, B = `--model @smol`). Both were stopped and closed.
Only ONE Tern window existed, so multi-window duplicate firing was not observable (see Q2).

## Headline findings

1. **`cx.agents:start()` works** from a window timer callback. It returns a numeric pane id, opens a tab, and the prompt is delivered and answered.
2. **A numeric pane id from `start()` / `list()` is rejected by every other agent call.** `wait`, `transcript` and `stop` all raise `runtime error: pane runs no agent`. This held immediately after start, 4 s later, 12 s later, and minutes later on an idle agent.
3. **The same calls work when the target is the pane's title string** (e.g. `"Reply with pong"`, the title that `omp` sets from the prompt). `wait` resolved with `pong...`, `transcript` returned the messages, and `stop` closed the tab.
   - `cx.session:pane(<numeric id>)` returned nil, while `cx.session:pane("<title>")` returned `{pane=128849018893, kind="agent"}`.
   - Titles are not unique or stable, so this is fragile for a scheduler.
   - Untested (launches exhausted): `tostring(pane)`, `"@focused"`, or other resolve specs for a freshly started agent.
4. **`--model @smol` is honored.** `list()` shows `model = "Haiku 5.5"` for B and `"Opus 5.5"` for A (the `@default` role).
5. **Starting an agent steals focus.** The new tab becomes focused and shown immediately. There is no `focus=false` option on `start()`.
6. **The host half can run `tern` via `tern.process.run` (argv) and can create a tab with `tern new tab`.** It cannot create an agent, because `cx.agents` is window-only.
7. **`tern.timer` is one-shot**, so repeating needs re-arming. The window timer receives a fresh cx with `cx.agents`. The host timer receives none.
8. **`tern.kv` has only `get`/`set`, with no atomic operation.** A get/set-then-reread lock worked in the single-window test.
9. **Reload and edit hazards:** every edit to the package folder or `tern plugin reload` replaces the window VM. Pending timers die (`mono` is VM-local and restarts). Unfinished work is lost, and an already started agent is not stopped.

## Q1. Host half: timer, process, pane creation

Snippet (host.luau, re-armed one-shot timer; abridged):
```lua
local n = 0
local function tick(_cx)
  n += 1
  rec({ev="tick", n=n, has_cx=_cx ~= nil})
  if n == 3 then
    tern.process.run({"/Users/bfturner/.local/bin/tern","ls"},{timeout_ms=5000}, function(r) rec({ev="ls",status=r.status,stdout_len=#r.stdout,stderr=r.stderr}) end)
  end
  if n == 5 then
    tern.process.run({TERN,"new","tab","--json","--cwd","/tmp","--","sh","-c","echo probe; sleep 4"},{timeout_ms=8000}, function(r) rec({ev="new_tab",status=r.status,stdout=r.stdout}) end)
  end
  if n < 10 then tern.timer(2000, tick) end
end
tern.timer(2000, tick)
```
- Timer repeated for ~20 s with the chain re-armed each tick. Interval deltas in ms: `2003.3, 2005.2, 2004.7, 2005.8, 2006.9, 2004.1, 2004.1, 2002.5, 2002.5`. Drift is ~+3-7 ms per tick. Every host tick had `has_cx:false`.
- `tern.process.run({tern,"ls"})` worked: `{"ev":"ls","status":0,"stderr":"","stdout_len":561,"stdout_head":"Default (shown)\n  tab 1\n    17506286698532 ..."}`.
- The host env `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`, so absolute paths are needed. `TERN_WINDOW_KEY` is nil in the host, so the CLI picks the first window.
- `tern new tab --json --cwd /tmp -- sh -c 'echo probe; sleep 4'` returned `{"session": 4, "tab": 17832704212993, "block": 17832704212994}`, status 0. The probe tab closed itself after `sh` exited.
- I did not capture the pane or confirm which session it landed in.
- **Verdict: works.**
  - Timers are one-shot and must be chained.
  - Host `tern.process.run` works.
  - The host can open plain tabs and shells via the `tern` CLI, but cannot start agent blocks (no `cx.agents` in the host).

## Q2. Window half: VM ids, ticks, `cx.agents`

Snippet: `local vm = string.format("W%x%x", os.time(), math.random(0,0xFFFFFF))`, then a chained `tern.timer(2000, tick)` recording `cx ~= nil` and `cx.agents ~= nil`.
- Each load or reload creates a new VM with a new id. Exactly one VM was live per window and tick, and old VMs stopped (their `mono` clocks do not continue). Six VM ids were created across reloads, never concurrently.
- Window ticks: `has_cx:true, has_agents:true` on every tick. Deltas ≈ 2016 ms (about 14 ms drift per tick), 14 ticks.
- `cx.agents:list()` is JSON-encodable. Entry shape: `{pane, command, model, cwd, state, last_message, delivery_error?}`.
  - It lists all agents across sessions, including the user's panes (state `idle`/`working`).
  - `command` is omitted (null) for agents not started as agent blocks.
- **Duplicate-firing risk across multiple windows: NOT measured**, because only one window was open. [INFERENCE] each window loads its own VM, so N windows give N timers. A lock or a window-key guard is therefore needed. The docs say each window loads its own window half (`SKILL.md` table).
- **Verdict: works** for single window; multi-window unverified.

## Q3. Single-launch lock via `tern.kv`

```lua
local cur = tern.kv.get("lock")
if cur == nil or (os.time() - (cur.ts or 0)) > 30 then tern.kv.set("lock", {vm=vm, ts=os.time()}) end
-- 2 s later:
local cur2 = tern.kv.get("lock"); owner = cur2 ~= nil and cur2.vm == vm
```
- The VM that set the lock re-read its own id and believed `owner:true`. Later VMs saw `believes_owner:false` while the lock was fresh, and took it once it was stale (after reloads).
- Two VMs never both believed they owned the lock, but there was never real concurrency (one window).
- kv API (`tern.d.luau`): `get(key)` and `set(key, value)` only, plus a "VM re-reads kv.json when it changed on disk" note. **No compare-and-set.** Set-then-reread narrows a race but does not make it atomic.
- **Verdict: partial.** It works for a single window. True atomicity is not available (race window between two windows' set/get). [INFERENCE] a safer design uses per-job `lastRun` keys plus a deterministic window election.

## Q4. Agent launch A (default command)

```lua
local pane = cx.agents:start({prompt="Reply with exactly: pong", cwd="/tmp", how="tab"})
cx.agents:wait(pane, {timeout=180000}):next(function(msg, err, c) ... end)
```
Evidence:
- `pre_start focused = {pane=128849018887 "MERGE: Assess merging upstream..."}` -> `start ok=true pane=128849018891` -> `post_start focused = {pane=128849018891, title="omp", kind="agent"}`.
- **Focus did move to the new tab immediately.**
- `post_start` list: `{command:"omp", cwd:"/tmp", state:"working"}`.
- `wait(pane,...)` called synchronously after start **raised** and was logged by Tern: `plugin handler failed plugin="sched-probe" hook="timer" error=runtime error: pane runs no agent` at `window.luau:62` (the `wait` line).
- The same error on a later retry, with the agent idle for minutes and `list()` showing `state="idle"` and `last_message="pong\n2.1s · 308 tok · $0.01 this turn"`: `wait_registered ok=false err="runtime error: pane runs no agent"`.
- Agent state progression (`list()` polled every 1.5 s): `working` (no model) -> `working` (model "Opus 5.5") -> `idle` with `last_message "pong\n2.1s · 308 tok · $0.01 this turn"`, about 5 s after start.
- Prompt was delivered and answered correctly ("pong").
- The `start()` prompt delivery works, but the numeric id cannot be used for `wait`/`transcript`/`stop` (see headline 2).
- Note: after the failed `stop(pane)` in the forced-stop handler, tab 4 stayed open (`tern ls`: `17721035063307 omp /tmp`). It closed only when I later stopped it by title.
- **Verdict for numeric-id flow: fails** (`pane runs no agent`). **Title-spec flow: works** (see Q5).

## Q5. Agent launch B (role) and title-spec retest

`command = "'/Users/bfturner/Library/Application Support/Tern/omp/bin/omp' --model @smol"` (omp docs: `--model <id-or-role>`, role `slow` or `@slow`, `omp://cli-reference.md` line 103). The command with spaces in the path, single-quoted, launched fine.
- `start ok=true pane=128849018893`. `post_start list`: `{"command":"'/Users/bfturner/Library/Application Support/Tern/omp/bin/omp' --model @smol","cwd":"/tmp","state":"working"}`.
- Within 2 s, `list()` showed `model:"Haiku 5.5"` (role `smol` = `anthropic/claude-haiku-5-5:medium` in config.yml) and `state:"idle"`. Later `last_message:"pong\n1.8s · 14K tok · <$0.01 this turn"`. **The role was honored.**
- Agent tab title became `Reply with pong` (derived from the prompt).
- `wait(128849018893)` at 2 s, 6 s and 12 s, `transcript(...)` at 6 s and 12 s, and `stop(...)` at 20 s all raised `pane runs no agent`.
- Title spec retest on the same still-open pane (no new launch):
  - `cx.session:pane(128849018893)` -> nil. `cx.session:pane("Reply with pong")` -> `{kind:"agent", pane:128849018893, title:"Reply with pong"}`.
  - `cx.agents:transcript("Reply with pong",{last=4})` -> `[{"role":"user","text":"Reply with exactly: pong","tools":[]},{"role":"assistant","text":"pong\n1.8s · 14K tok · <$0.01 this turn","tools":[]}]`.
  - `cx.agents:wait("Reply with pong",{timeout=5000})` resolved with `pong\n1.8s · 14K tok · <$0.01 this turn`.
  - `cx.agents:stop("Reply with pong")` closed the tab. `tern ls` afterwards shows no tab 4.
- After B's `start`, focus was the new tab. In the failed run, `after_stop` shows focus back on a user pane only after the user (or window) switched tabs. The probe did not restore focus itself.
- **Verdict: works** for role selection (`--model @smol`), and for `wait`/`transcript`/`stop` **by title spec**. Numeric id usage fails with `pane runs no agent`.

## Q6. `list()` fields while working and idle

| moment | command | model | state | cwd | last_message |
|---|---|---|---|---|---|
| right after A start | `omp` | absent | working | /tmp | absent |
| ~2 s later | `omp` | Opus 5.5 | working | /tmp | absent |
| ~5 s later | `omp` | Opus 5.5 | idle | /tmp | `pong\n2.1s · 308 tok · $0.01 this turn` |
| B ~2 s | full quoted omp cmd | Haiku 5.5 | idle | /tmp | (appears after the turn) |
| user's agents | `omp` or absent | Opus 5.5 | idle/working | their cwd | their last text |

- `model` is the display name (`"Opus 5.5"`, `"Haiku 5.5"`), not the id.
- Default agent command is plain `omp`; user panes started elsewhere lack `command`.
- No `delivery_error` was ever set.

## Implications for the design [INFERENCE]

- A window-half timer chain (re-armed `tern.timer`) is a workable scheduler tick. `cx.agents:start()` from it works.
- Use a title (or other string spec) for `wait`/`transcript`/`stop`, or rely on `list()` polling for `state`/`last_message`. Do not depend on the numeric `start()` return.
- `start()` steals focus. Provide a note in the UI, or look for a `focus` option.
- Reloads kill pending timers and orphan started agents. Persist job state in kv or files and reconcile on load.
- Guard against multiple windows with an election or per-job `lastRun` keys. kv has no atomic primitive.
- Role selection works via `command` with `--model @role` (use `list().model` to verify).
- The host half can run `tern` via argv but not launch agents.

## Cleanup done

`tern plugin unlink sched-probe` -> `unlinked sched-probe (…/plugins/sched-probe.path)`.

`tern plugin list` after cleanup:
```
ternkit 0.1.0 Ternkit — 5 blocks, 0 lenses, window  ready
omp-pushover 0.1.0 Phone push (omp) — 0 blocks, 0 lenses, window  ready
swarm 0.1.0 Swarm — 2 blocks, 0 lenses, window  disabled
tern-rss 0.1.0 Tern RSS — 1 blocks, 0 lenses, window  ready
```
`tern ls` after cleanup:
```
Default (shown)
  tab 1
    17506286698532  <plugin block>  /tmp  84×50
    17506286698538  <agent pane>  ~/Dev/<project>  84×24  focused
    17506286698540  <agent pane>  ~/Dev/<project>  84×24
  tab 2 (shown)
    17721035063303  <agent pane>  ~/Dev/<project>  171×50  focused
  tab 3
    17721035063305  SCHED: Design Tern scheduled prompt jobs …  focused
```
No probe panes remain. `/tmp/tern-sched-probe`, `/tmp/tern-sched-types` and the probe data dir were deleted.
