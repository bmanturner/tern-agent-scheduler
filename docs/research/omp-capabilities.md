# omp capabilities for a Tern "scheduled agent jobs" plugin

Environment: omp v18.9.1 (`omp --version` → `omp/18.9.1`), Tern-managed. Research only; nothing was run beyond `--help`, `omp config get`, `omp models --help`, read-only `ps`/`lsof`.
`omp --help` = output of `omp --help` (v18.9.1). Doc refs are `omp://<file>.md`.

## 0. Key answers

| # | Question | Answer | Citation |
|---|---|---|---|
| 1a | Role selection flag | `--model @role` (also bare `--model slow`). `--model` takes a model id/fuzzy match OR a configured role. No `--role` flag. Roles expand through `modelRoles`; `:thinking` suffix lives in the role value. | `omp://cli-reference.md` L103 ("Model or configured role… `slow` or `@slow`"); `omp://models.md` L645; `omp --help` (no `--role`). Prior art: tern-swarm `prepare.luau:41` `omp --model '@<role>' --max-time …` |
| 1b | Thinking | `--thinking off\|minimal\|low\|medium\|high\|xhigh\|max\|auto` (overrides role's `:level`) | `omp --help` |
| 1c | Approval | `--approval-mode always-ask\|write\|yolo`; `--auto-approve`/`--yolo` force yolo. **Default is already `yolo`** (schema default; `omp config get tools.approvalMode` → `yolo` on this machine). | `omp://approval-mode.md` "Modes"; cli-reference L136ff |
| 1d | cwd | `--cwd <dir>`; plus `--add-dir`. In Tern, `cx.agents:start({cwd})` sets the pane cwd. Starting in `~` auto-switches to a temp dir unless `--allow-home`. | `omp --help`; `api-window.md` L984 |
| 1e | Session naming | **No CLI flag to name a session.** Titles auto-generate (disable `--no-title` / `PI_NO_TITLE`); an extension can `pi.setSessionName()`. | `omp://cli-reference.md` L210; `omp://extensions.md` L129 |
| 1f | Continue/resume | `-c/--continue`, `-r/--resume [id-prefix\|path]` (alias `--session`), `--fork <id\|path>`, `--no-session`, `--session-dir <dir>` | `omp://cli-reference.md` "Session history" |
| 1g | Output / limits | `-p/--print` (text, answer after turn); `--mode json` = JSONL events; `--mode rpc`. `--max-time <600\|10m\|1h>`. **No max-turns, no cost cap flag** found. | cli-reference L147, L173-216 |
| 1h | Exit codes | Only documented: "Terminal turn failures produce a nonzero exit status in both text and JSON modes"; RPC stdout failure → exit 1. Specific codes not documented → `[INFERENCE]` treat 0 = ok, non-0 = failed. | cli-reference L216; rpc.md L77 |
| 2 | Roles | This machine: `default, slow, plan, smol, commit, advisor, vision, tiny, memory, task, judge`. Built-ins: chat roles `default smol slow vision plan commit tiny memory task advisor`; kind roles `image web speech dictation judge`; custom names allowed. **Enumerate at runtime with `omp config get modelRoles --json`** (verified: returns a JSON object role→selector). | `~/.omp/agent/config.yml:1-12`; `omp://models.md` L634-651; tern-swarm `roles.luau:16` |
| 3 | How Tern launches omp | Agent block = `cx.agents:start({prompt,cwd,command?,how?})`; omitted `command` uses Tern settings (no agent command key present in `settings.json`; default is plain `omp`). Tern manages omp binary (`manager.json`: `{"manager":"tern"}`; `state.json`: managed, installed 18.9.1, link `/opt/homebrew/bin/omp` → `~/Library/Application Support/Tern/omp/bin/omp`). | `api-window.md` L984-987; files in `~/Library/Application Support/Tern/omp/` |
| 4 | Sessions | `~/.omp/agent/sessions/<encoded-cwd>/<ISO-timestamp>_<sessionId>.jsonl` (JSONL, header line `{"type":"session","id","cwd","title"}`; assistant messages carry `usage.cost.total`, `stopReason`). Resume: `omp --resume <id-prefix>` in Tern (`command=` param). | `omp://session.md` L42-45; observed file `-Dev-local/2026-05-24T16-40-05-237Z_019e5adb-…jsonl` |
| 5 | Unattended | `ask` tool is **not even registered** without a prompt-capable UI; if called anyway it throws "Ask tool requires interactive mode". Approval prompts that cannot be shown **fail the call** (no silent allow). In yolo nothing prompts. Subagents always run yolo. | `omp://tools/ask.md` Flow 1-2; `omp://approval-mode.md` ("a call that still requires a prompt fails…", "Subagents") |
| 6 | Extensions | Yes: `pi.registerCommand("schedule", …)` + `pi.registerTool({name:"schedule_job", parameters: pi.zod…})` + events `agent_start/agent_end/session_start/session_shutdown/turn_end/session_stop`. Load via `~/.omp/agent/config.yml` `extensions:` list (user already has `~/Dev/personal/omp-pushover` there), `-e <path>`, `~/.omp/agent/extensions/`, or `omp install`/`omp plugin`. | `omp://extensions.md`; `omp://extension-loading.md`; omp-pushover `src/index.ts` |
| 7 | Built-in scheduling | **None found** (no cron/schedule feature). Exists only: extension `ctx.setInterval/setTimeout` (in-process, dies with session), `/loop` (mentioned only as "reset-style /loop actions" in vibe-mode doc, undocumented elsewhere), `omp ps` daemon-supervised background processes (not schedules), Tern's Carly heartbeat (every 30 min). | greps over `omp://` (see §7) |
| 8 | RPC | Possible (`omp --mode rpc`: `get_state`, `get_session_stats`, events, `agent_end`), but a Tern **Luau plugin cannot easily hold a stdio child** open as a long-lived RPC client `[INFERENCE]`; for unattended runs TSP agent block + session JSONL / a tiny extension is simpler. Not worth it for v1. | `omp://rpc.md` |

## 1. Recommended command lines

**Interactive, in a Tern agent block** (what Tern's `cx.agents:start` should be given as `command`, prompt passed separately as `prompt`; same shape tern-swarm uses at `prepare.luau:41-46`):

```sh
omp --model @default --approval-mode yolo --max-time 45m
```
```lua
cx.agents:start({ prompt = job.prompt, cwd = job.cwd, how = "tab" --[[split|tab|replace_if_alone]],
  command = "omp --model '@default' --approval-mode yolo --max-time 45m" })
```
- Prompt is submitted by Tern once input is ready (`api-window.md` L986). Alternative is positional: `omp --model @default --approval-mode yolo "<prompt>"` (cli-reference "Launch": positional = initial prompt), but then shell quoting is on you; prefer `prompt=`.
- `--approval-mode` choice: `yolo` = nothing prompts (safe for unattended, dangerous for what it can do); `write` = file edits ok, shell/exec prompt (agent sits at "waiting_input" in the block until a human answers); `always-ask` = everything but reads prompts.
- Add `--thinking <lvl>` only to override the role's own `:level`.

**Headless (no pane, results to a log/JSON)**:

```sh
omp -p --mode json --model @default --approval-mode yolo --max-time 45m --cwd /abs/project -- "<prompt>"
```
- Run through `tern.exec`-style background command (swarm uses `run.exec{"omp","-p","--model","@tiny","--no-session","--no-title",…}`, `names.luau:179`). Use `--no-session` only if no history is wanted (it also kills "Open run" and usage lookup); otherwise leave sessions on and add `--no-title` to skip the title-generation call.
- Text mode (`-p` without `--mode json`) prints only the last assistant message to stdout (cli-reference L173-182) = the final message with zero parsing; JSON mode gives the event stream incl. usage.
- `omp` may not be on a minimal PATH of a Tern background exec: swarm searches `~/.local/bin`, `/opt/homebrew/bin`, … (`configuration.md` L24-27). Use absolute `/opt/homebrew/bin/omp` (symlink to Tern-managed binary).

## 2. Launch forms (Q1)

- Interactive with prompt: `omp "prompt"` / `omp @file.md "prompt"` (`omp --help` examples). `--goal "<objective>"` starts interactive goal mode (needs `goal.enabled`, no positional prompt).
- Non-interactive: `-p/--print` (`omp://cli-reference.md` L162-182). Piped stdin / non-TTY stdin selects print automatically (L58-61). `--mode json` also headless; `-p` optional.
- Unattended planning+implementation: `--plan-yolo [--plan-yolo-into <role>]` (cli-reference L132; `plan.defaultOnStartup` ignored in print mode L218).
- Role-ish flags: `--smol/--slow/--plan <id>` override those role models for the run (and env `PI_SMOL_MODEL` etc.); `--model` with `@role` is the way to *pick* a role; `--models a,b` limits Ctrl+P cycling.
- Per-run config overlay: `--config <file>` (repeatable), e.g. to set `tools.approval.<tool>: deny` for scheduled runs (`omp://approval-mode.md` "User overrides").
- Tool restriction: `--tools a,b,c` (allowlist), `--no-tools`. Tool deny: `tools.approval.<name>: deny` in config/overlay (absolute). `bash.patterns` allow/deny/prompt rules exist but are "not containment" (approval-mode.md "Safety overrides").
- Other: `--no-extensions`, `--no-skills`, `--no-rules`, `--no-lsp`, `--no-pty`, `--append-system-prompt <text|file>` (good place to say "nobody is watching; don't ask questions" like swarm does), `--profile <name>` isolated auth/sessions.
- Limits: only `--max-time`. No `--max-turns`/budget flag in `omp --help`. Cost can be bounded only by post-hoc reading or an extension enforcing it `[INFERENCE]`.
- Exit codes: see table row 1h. `--max-time` expiry behaviour (exit status) not documented `[unverified]`.

## 3. Roles (Q2)

- `~/.omp/agent/config.yml:1-12` modelRoles (selectors only): default=`anthropic/claude-opus-5-5:medium`, slow=`…opus-5-5:xhigh`, plan=`…opus-5-5:high`, smol=`anthropic/claude-haiku-5-5:medium`, commit=`…sonnet-5-5:low`, advisor=`…opus-5-5:low`, vision=`openai-codex/gpt-6-astra:medium`, tiny=`…haiku-5-5:low`, memory=`…haiku-5-5:medium`, task=`…sonnet-5-5:auto`, judge=`openrouter/~typesafe/jev-latest`.
- Semantics: `*` selects `@default`; values may be comma-separated fallbacks (first available), `:level` thinking suffix; unset `smol`/`slow` inherit `default`; `tiny` falls to `smol`, `memory` to `tiny` (`omp://models.md` L641-654). Kind roles (`image web speech dictation judge`) aren't chat models → don't offer them as job roles; offer chat roles + any custom role found in config.
- Runtime enumeration: **`omp config get modelRoles --json`** (verified output is a flat JSON object). tern-swarm already does exactly this: `tern-swarm/lib/roles.luau:16`. Project-level overrides exist (`<cwd>/.omp/config.yml`), and `omp config get` run with `cwd = job.cwd` presumably resolves layered config `[INFERENCE]`. Model-id list: `omp models [--json]` / `omp models find <s>` (`omp models --help`). Presets: `/modelpreset` snapshots whole role sets (models.md L660).

## 4. How Tern launches omp (Q3) — read-only observation

- `ps` shows user omp processes as bare `omp` with parent `/bin/zsh -l` (pids 19008←17195, 19751←19333): i.e. in the panes I observed, omp is typed at the shell prompt, not exec'd by Tern with special argv. Daemon helper: `…/Tern/omp/versions/18.9.1 __omp_worker_daemon_broker`, `__omp_worker_text_predict` (Tern-managed binary path). One omp (pid 61902) hangs off `/Applications/Tern.app/Contents/MacOS/tern daemon --socket …/daemon.sock --handoff …`.
- Tern docs: `cx.agents:list()` returns "agent blocks, and shells running omp (typed at the prompt; their `command` is `tern.json.null`)" (`api-window.md` L978-981). So agent identity comes from the program/TSP, not a launch flag.
- Env that Tern sets in pane processes (visible in this subagent's own env, inherited from its pane): `TERN_PANE`, `TERN_PANE_SOCKET` (daemon.sock), `TERN_WINDOW_SOCKET`, `TERN_WINDOW_KEY` (secret-ish, don't log), `TERN_BLOB_DIR`, `TERN_IDENTITY`, `TERN_LENSES=1`, `TERN_COMPLETE=1`, `TERN_ACP`. No `PI_*`/`OMP_*` observed except `OMPCODE=1` (set for nested/sub-agent omp; omp-pushover uses it to skip, `src/index.ts:19`). Working/idle state reaches Tern through progress OSC 9;4; `waiting_input` when paused or ask overlay (`api-window.md` L999-1000). `cx.agents:wait(pane,{timeout})` returns last assistant text; `transcript(pane,{last})` reads the omp TSP chat (L989-994).
- `~/Library/Application Support/Tern/omp/manager.json` = `{"manager":"tern","name":"Tern"}`; `state.json` = `{managed:true, checked, installed:{version:"18.9.1", sha256, via:{how:"patch"}}, link:"/opt/homebrew/bin/omp", offered:true}`; dir has `bin/ versions/ check.lock state.lock`. Implication: Tern owns installs/updates (version dirs 18.8.7 and 18.9.1 coexist); always invoke `omp` via PATH/symlink, never a version-pinned path. `omp update` may fight the manager `[INFERENCE]`.
- Tern settings.json has no agent-launch command key (grep for agent/omp/command keys: only prompt/composer keys). "New agent block" uses settings default when `command` omitted — exact default `[unverified]`; always pass `command` explicitly.

## 5. Sessions (Q4)

- Path: `~/.omp/agent/sessions/<encoded-cwd>/<timestamp>_<sessionId>.jsonl`; `<encoded-cwd>` = `-<rel-to-home>` for dirs under `$HOME` (e.g. `-Dev-local`), `--<abs-with-dashes>--` otherwise, `-tmp-…` under tmp (`omp://session.md` L45). Observed: `~/.omp/agent/sessions/-Dev-local/2026-05-24T16-40-05-237Z_019e5adb-a775-7000-a9f1-9693fd302e84.jsonl` with sibling dir for subagent transcripts/artifacts (`<session>/<AgentId>.jsonl`, export doc L59). Sessions are lazy: the file may not exist until first write (session.md L58).
- File format (v3): line 1 `{"type":"session","version":3,"id","timestamp","cwd","title","titleSource"}`; then entries `thinking_level_change`, `service_tier_change`, `message` (user/assistant with `parentId` tree), etc. Assistant messages include `provider`, `model`, `stopReason` (`stop|toolUse|error|aborted|length`) and `usage:{input,output,cacheRead,cacheWrite,totalTokens,cost:{input,output,cacheRead,cacheWrite,total}}` (observed in a real file). **Run cost = Σ `message.usage.cost.total` over assistant messages; final message = last assistant `message` with `stopReason:"stop"` text blocks.** Subagent costs live in child transcripts `[INFERENCE]`.
- Finding the session for a run (no CLI flag sets the id):
  1. **Deterministic (recommended):** start the job with `--session-dir <state>/runs/<jobId>/<runId>` → exactly one jsonl (+artifacts) in a dir the plugin owns; `--resume <prefix>`/`--continue` with the same `--session-dir` resumes (cli-reference "Session and workspace"; session.md L604 "Explicit sessionDir disables global fallback"). Caveat: `--session-dir` also scopes `--resume` lookup, so reopening needs the same flag.
  2. Scan `sessions/<encoded-cwd>/` for the newest file whose header `timestamp` ≥ run start (racy if user has another omp in that cwd).
  3. Extension writes `ctx.sessionManager`'s file/id to the shared run record on `session_start` (robust, needs the extension).
  4. RPC `get_state` returns `sessionFile`/`sessionId` (rpc.md L473-475).
- Reopen interactively ("Open run"): Tern `cx.agents:start({cwd=job.cwd, prompt="", command="omp --resume <sessionId-prefix>"})` — resume accepts id prefix, filename prefix, or id suffix (session.md L604); note it needs a prompt param shape that tolerates empty prompt `[unverified]`. Resume restores the recorded model and fails closed if the model is gone (session-operations doc L502). `--fork <id>` instead opens a copy (safer if the original is still live). Session ownership lease: a second live process writing the same session is moved to a sibling file (session.md L539-540).
- Export: `omp --export <session.jsonl> [out.html]`; `/export`. `omp stats -j`/`-s` gives aggregate usage JSON; `omp usage -j` = provider quota windows (for a "budget remaining" hint).
- Reading status from JSON mode: `--mode json` prints a header then JSONL events; `message_end` has completed messages (with usage); `agent_end` events carry `messages`, `willContinue`, `yielded` (omp-pushover reads `event.messages`, `willContinue`, `isTerminal`, `last.stopReason` at `src/index.ts:192-203`).

## 6. Unattended behaviour & safety (Q5)

- Approval modes: `always-ask` (auto: read), `write` (auto: read,write; prompts exec), `yolo` (default, no prompts). Tiers: read / write / exec; MCP tools = write; unknown custom tools = exec (`approval-mode.md`).
- Headless + approval needed: "a call that still requires a prompt fails rather than silently allowing it when no interactive UI is available" (approval-mode.md L"Approval is resolved again…"). So `-p --approval-mode write` + a shell call = tool failure the model sees; agent may work around or end. Subagents likewise reject prompts.
- Headless + `ask`: tool needs `session.canPromptUser ?? session.hasUI` to even register (`omp://tools/ask.md` Flow 1); if invoked, aborts with `ToolAbortError("Ask tool requires interactive mode")` (Flow 2). In a **Tern agent block** the TUI exists so `ask` *does* prompt and the run stalls (`waiting_input`) until a human answers. `ask.timeout` default 0 = never auto-answer (this machine: `omp config get ask.timeout` → 0; set >0 to auto-pick the recommended option). `ask.enabled` can disable the tool. Plan mode disables the timeout.
- Therefore for scheduled interactive blocks: either accept waiting_input (and surface it in the history UI via `cx.agents:list()` state) or set `--config overlay` with `ask.enabled: false` / `ask.timeout: N` `[settings keys per ask.md; overlay mechanism per cli-reference --config]`, and tell the agent in `--append-system-prompt` that nobody is watching (swarm does this in its prompt, `how-it-works.md` L22-25).
- Hard risk: yolo = shell + file writes as the user with all credentials, scheduled while the user is away. tern-swarm's own README warns the same (`README.md` L14-17,105-110). Mitigations: `write` mode + `tools.approval.bash: deny` overlay for read-only jobs; `--tools read,grep,find,…` allowlist (tool names `[verify via omp --tools]`); per-job `--max-time`; run in a dedicated worktree/dir; show a clear "unattended yolo" badge. Safety overrides: bash critical patterns (`rm -rf /`, curl|sh, …) force a prompt but are ignored in yolo unless explicit policy (approval-mode "Safety overrides") → in yolo + headless these still fail only if an explicit `prompt`/`deny` is configured.
- Prompt-injection note: scheduled prompts that read the web/mail run with those privileges.

## 7. Extensions (Q6)

- Shape: TS module, `export default function (pi: ExtensionAPI)`; `pi.zod` for schemas (`omp://extensions.md` L69-110). omp-pushover is a real example: `omp-pushover/package.json` `"omp":{"extensions":["./src/index.ts"]}`, `src/index.ts:17` factory, `pi.registerCommand("push", {description, handler:async(args,ctx)=>…})` (`:205`), events at `:139-203`, shared JSON state file `~/.config/omp-pushover/state.json` written via tmp-file + `rename` (`src/state.ts:65-75`) and read by its Tern plugin.
- (a) `/schedule` slash command: `pi.registerCommand("schedule", {description, handler(args, ctx)})`; `ctx.ui.notify/select/input` available in TUI; headless ctx is no-op (`ctx.hasUI`). Name collisions with built-ins are skipped (extensions.md L1258).
- (b) LLM-callable tool: `pi.registerTool({name:"schedule_job", label, description, parameters: pi.zod.object({...}), execute(toolCallId, params, signal, onUpdate, ctx)})` returning `{content:[{type:"text",text}], details}` (L74-100, L597-615). Approval tier for custom tools defaults to **exec** (approval-mode.md L"Tools without an approval declaration…"), so declare `approval: "write"` (or object with `policy`) if you want it not to prompt outside yolo; consider an explicit `prompt` policy so the user confirms agent-created jobs. Subagents: extension tools are not admitted in restricted children (L612-ish) — fine.
- Status reporting back: events `session_start`, `agent_start`, `turn_start/turn_end`, `agent_end` (`event.messages`, `willContinue`, `yielded`/`isTerminal` as used by pushover `:192-203`), `session_stop` (main-session stop hook), `session_shutdown` (handler budget 2 s, concurrent; extensions.md L1257), `tool_approval_requested/resolved`, `tool_execution_start/end` (pushover uses them to detect `ask`/approval = "needs input"), `auto_retry_start`. Use `ctx.agent.kind==="main"` to ignore subagents (pushover `isMain`, `:28`); skip when `process.env.OMPCODE==="1"`.
- To know which run it is: Tern could pass a job id through an env var or `--append-system-prompt`, or via `pi.registerFlag`/`pi.getFlag` (registerFlag exists in API list L119) e.g. `omp -e ext --sched-run <runId>` `[INFERENCE: flag passing mechanism, check types.ts]`; or env `SCHEDULER_RUN_ID` read by the extension from `process.env` (works in-process, trivial).
- Install/load: (1) `extensions:` list in `~/.omp/agent/config.yml` (user has `~/Dev/personal/omp-pushover` at config.yml:152-153; directory with `package.json#omp.extensions` works, extension-loading L"Explicitly configured paths"); (2) drop file in `~/.omp/agent/extensions/` or `<repo>/.omp/extensions/`; (3) `-e <file>` per launch (explicit paths load even with `--no-extensions`); (4) `omp install <path|npm|name@marketplace>` / `omp plugin link|install|enable|disable|doctor`; (5) `--trusted-extension <abs>` allowlist. `omp --no-extensions` for headless jobs skips all, so pass `-e` explicitly if the reporter is needed. Live-source changes to the list apply to hooks/commands/tools but newly enabled modules need a restart (extension-loading L"Live source changes").
- Caveat: extensions run in-process, unsandboxed; uncaught throws in raw timers kill the session → use `ctx.setInterval/setTimeout` (extensions.md L395-416).
- What an extension buys vs plugin-only: (i) in-chat creation (`/schedule`, `schedule_job`), (ii) precise run lifecycle (start/end/cost/needs-input/final message, session file path) written to a shared JSON store instead of polling jsonl/OSC state, (iii) per-run policy (`tool_call` hook can block/limit tools). Plugin alone can already: create/list/edit jobs, fire `cx.agents:start`, watch via `list()/wait()/transcript()`. **Real value of the extension = (i)+(ii).** It's optional; a plugin-only v1 is viable. This matches the user's omp-pushover split (Tern plugin + omp extension sharing a state file).

## 8. Built-in scheduling? (Q7)

Greps of `omp://` for cron/schedule/recurring/heartbeat/interval/loop:
- No cron/scheduler/recurring-task feature. Hits are unrelated (advisor `reviewInterval`, compaction, MCP reconnect backoff, memory consolidation lease heartbeat, native-task cancellation heartbeat).
- `/loop` only appears as "Reset-style `/loop` actions are also blocked" (`omp://vibe-mode.md` L19); no `/loop` doc found → exists but undocumented here `[unverified semantics]`.
- Extension timers: `ctx.setInterval/setTimeout` — in-process, `unref`'d, cleared on `session_shutdown` (extensions.md L395-416) → cannot fire when no omp is running.
- `omp ps` = list/stop/kill/restart "daemon-supervised background processes" (`omp ps --help`), and async background jobs (auto-backgrounded bash/task/eval; `ctx.getAsyncJobSnapshot()`); `session_stop` defers until bg jobs idle. Not schedule features.
- Collab `busy` flag (collab.md L85) could signal live work but is for share sessions.
- `omp --goal` / goal mode = run-until-objective, not time-based.
- Tern-side prior art: Carly heartbeat (`~/Library/Application Support/Tern/carly/HEARTBEAT.md`, every 30 min default per task brief). Scheduling must therefore be done by the Tern plugin (a Luau timer / `tern` event loop; Tern windows must be open) or by launchd/cron calling headless `omp -p`. A plugin-only scheduler runs only while the Tern window runs `[INFERENCE]`; check Tern plugin docs for `tern.timer`/background capability (another agent's area).

## 9. RPC / SDK (Q8)

- `omp --mode rpc` (newline-delimited JSON over stdio; ready frame, commands `prompt`, `get_state` (incl. `sessionFile`, `sessionId`, `sessionName`), `get_session_stats` (tokens/cost), `get_messages`, `abort`, `goal`, etc.; events forwarded from `AgentSession`; `agent_end` with `willContinue`/`yielded`; "session is done only when no run/queue/background job can wake it", rpc.md L345-352). `--no-ui` makes extensions headless; `rpc-ui` surfaces `ask` as `extension_ui_request` the host can answer (so a host could answer/auto-answer `ask`), `set_ask_dialog` opts in (rpc.md L680).
- SDK (`omp://sdk.md`) is for embedding in JS/TS (Bun) — not usable from Luau directly.
- Verdict `[INFERENCE]`: not worth it for v1. A Luau plugin would need to own a long-lived child with stdin/stdout (tern exec APIs are oriented to finite commands; swarm uses `run.exec` with timeouts), and RPC output isn't visible in a pane, losing the "agent block appears in Tern" requirement. Richer status is available cheaper via: (a) `cx.agents:list()` → `{pane, state, last_message, model, cwd}` and `wait()`; (b) a tiny omp extension appending run status (cost from `ctx`/session usage) to the shared JSON; (c) parsing the session JSONL post-run. Use RPC/JSON mode only for the *headless* variant if per-event progress is wanted; plain `-p --mode json` already gives events + usage with no RPC.

## 10. Design implications (summary)

1. Interactive scheduled run = `cx.agents:start{prompt,cwd,how,command="omp --model '@role' --approval-mode <mode> --max-time <dur> [--session-dir …]"}`; shell-quote the role (`@` is safe unquoted in sh, but swarm quotes it).
2. Role picker populated by `omp config get modelRoles --json` (cache per cwd; filter out kind roles `image web speech dictation judge`).
3. Headless variant for "silent" jobs: `omp -p --mode json … --no-title`, capture stdout; final text via `-p` text mode.
4. History/"Open run": store `{runId, jobId, startedAt, cwd, role, pane?, sessionDir, sessionId, status, costTotal, finalMessage}`; reopen with `omp --resume <id>` (or `--fork`).
5. Warn loudly: default approval is yolo; unattended yolo agents can run arbitrary commands.

## 11. Open questions

- Exact exit codes of `omp -p` incl. `--max-time` expiry and approval-failure; whether `--max-time` kills the process or ends gracefully (not documented in cli-reference).
- Whether `omp config get modelRoles --json` honours project `.omp/config.yml` layering and `--config` overlays (docs say layered settings; the CLI command's scope not verified).
- Whether Tern's `agents:start` accepts an empty prompt/`command`-only (for "Open run"), and what the default `command` is when omitted (not in settings.json).
- Exact name/mechanism of passing a run id into an extension (`registerFlag`/`getFlag` vs env) — check `types.ts`; env var read from `process.env` is the safe assumption.
- Does `--session-dir` change where `--resume` by id works from Tern's panes (needs same flag) and does it interact with title index/`omp --resume` picker.
- Can the scheduler wake while no Tern window is open (Tern daemon keeps panes alive but plugin VMs run per window `[INFERENCE]`) → need launchd for true background; separate research area.
- `ask.enabled`/`ask.timeout` overlay semantics for scheduled runs (settings keys from ask.md; `--config` overlay verified in CLI ref but not tested).
- Cost of sub-agent spend: whether parent session usage includes child transcripts' cost.
- Whether `/loop` has user-facing recurring semantics worth reusing.
