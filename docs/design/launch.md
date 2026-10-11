# Launcher + run tracking: Schedule (tern-schedule)

> **Revision 2 (after review).** `design/decisions.md` is authoritative and overrides this doc where they differ. Changes made here:
> - **R1** prompt source of truth is `prompts/<job id>.md`, snapshotted to `runs/<job>/<run>/prompt.md` at fire time; `prompt_source="file"`/`prompt_path` cut (§2.3). **R2** run dir layout and correlation key by the `/runs/<job>/<run>/` substring (§2.2, §8.2). **R3** every example id is `j_xxxxxxxx` / `r_<job8>_<slot>` (manual `r_<job8>_<epoch>_<rand4>`); block/tab/session ids are strings (§2.1, §2.5).
> - **R4** no bare-`omp` fallback: missing omp is `blocked/omp_missing` (§1). **R5** `--keep-open` always, only the host closes panes, global cap of 5 finished run panes in M1 (§2.1, §9). **R6** preamble always on in M1, `RESULT:` protocol kept, quiet success deferred (§3).
> - **R7** overlay `omp.yml` for every non-yolo run pins exec-tier `tools.approval` to `prompt`; new V31 (§2.2, §7.2). **R8** host-sent, argv-safe osascript notifications with the exact argv (§8.7); **V32**.
> - **R9** windows send raw samples + 30 s heartbeat, no window-side `event`/debounce; `last_message` clipped to 4 KiB; session JSONL read async with `/usr/bin/tail -c` (§8.3, §8.4, §8.6). **R10** intent envelope `{format:1, kind}`, file name `<t_ms>-<win8>-<seq>.json`, allowlisted kinds, no create/update/delete/settings intents, hands-off hash gate (§8.4, §10); `cx:new_block` gate (**V30**).
> - **R12** engine states/reason codes are canonical (`no_response`, `interrupted`, `closed_by_user`, `user_stop`); a block whose command lacks the run marker (restored login shell) counts as gone (§8.2, §11); **V29**. **R14** one `tern ls --json` helper (§2.0). **R15** observer 3 s / heartbeat 30 s / host tick 15 s / FIFO launch queue (§2.1, §8.3). **R16** roles bare-stored, passed as `@role`, `role_unverified` vs `blocked/role_missing`, "Other model…" cut (§6). **R17** cwd rules: no `$HOME` fallback, `allow_home`, unsafe-char rejection at Save (§2.3, §5). **R18** approval default `write` pending Q1; Read-only hidden until V9 (§7.1). **R20** real-daemon lifetime gate (**V28**). **R21** two-window session scope gate (**V26**, §4). **R22** session default `Scheduled runs` (§2). **R23** split/PiP are M2 (§4); Interrupt is M2 (§10).
> - **RC C-job-names/C5**: field names are engine.md's (`max_runtime_s`, `after`, `approval` enum); `thinking`/`tools` job fields removed from v1 (§2.2). **C22** Open run uses `session_file` (§10). **C23** Stop = host `tern close` (`cancelled/user_stop`) (§10). **RF F5/F8/F9/F6/X10, S2/S4/S5**: see §8.2, §2.0, §8.6, §5, §8.3, §2.3, §7.2, §8.7. Checklist V1-V27 numbers kept for cross-references; V28-V32 added; table is ordered by gate priority (RF §6).
> - Engine-owned items (states, reason codes, thresholds, grace periods, the pane-cap value) are cited, not restated. Reason codes this doc needs that engine.md must carry: `cwd_unsafe`, `cwd_home`, `hands_off_review` (blocked), `agent_failed`, `closed_by_user`.

Status: design, 2026-10-11, revision 2. Tern 0.7.2 (`5d1cc64`), omp 18.9.1 (Tern-managed) / 18.8.6 (`~/.local/bin/omp`, see §1).
Implements the launcher half of `architecture.md`. Run states, transitions, reason codes, field names, constants and the intent protocol are owned by `design/engine.md` (decisions §0); this doc describes the mechanics that produce launcher evidence and cites engine names. Interlocks with UX: `ux.md` (labels, copy, keys).

Evidence keys: `AR` architecture.md · `PR2` research/tern-probe2.md (test numbers) · `PR1` tern-probe.md · `OC` omp-capabilities.md · `LP` local-patterns.md · `PA` prior-art.md · `UX` ux.md · `HELP` = output of `omp --help` / `tern <cmd> --help` run for this doc · `DOC:<name>` = `omp://<name>.md` or `references/docs/...`. `[INFERENCE]` = unobserved; every one has a `V#` item in §13.

Cross-cutting rule (the keystone of the quoting design): **no user-authored text (job name, prompt) ever appears in the argv that Tern turns into a `zsh -l -c` string.** Prompt and preamble travel as files; the only free-form strings in that argv are absolute paths the plugin itself generates from a validated data dir and slug ids. The job name appears only in `tern rename`, which the host runs without a shell.

---

## 1. Binary resolution

Host `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`, `HOME=/Users/bfturner` (PR2 test 7), so nothing is found by name. Panes run `/bin/zsh -l -c '<command>'` (PR2 test 4: `program=/bin/zsh args=["-l","-c","/opt/homebrew/bin/omp --model @tiny 'Reply with exactly: pong'"]`), so inside the pane the login `PATH` applies (verified: `/bin/zsh -l -c 'echo $PATH'` begins `~/.local/bin:/opt/homebrew/bin:...`). Hence: **the host must pass absolute paths for both `tern` and `omp`; the pane's login PATH only matters for what omp itself spawns** (git, node, bun, ...).

Observed on this machine (HELP/`ls -la`):

| Path | Is |
|---|---|
| `/Users/bfturner/.local/bin/tern` | symlink → `/Applications/Tern.app/Contents/MacOS/tern` (136 MB Mach-O) |
| `/Applications/Tern.app/Contents/MacOS/tern` | the real binary |
| `/opt/homebrew/bin/omp` | symlink → `~/Library/Application Support/Tern/omp/bin/omp` → `../versions/18.9.1` (Tern-managed; `state.json`: `"managed":true,"link":"/opt/homebrew/bin/omp","installed.version":"18.9.1"`) |
| `~/.local/bin/omp` | standalone 212 MB binary, **`omp/18.8.6`**; first in the login PATH, so a typed `omp` in a Tern shell is 18.8.6 while the Tern-managed one is 18.9.1 |

Resolution (host, at load and on any spawn failure; result cached in the host file `cache.json` as `bin.tern` / `bin.omp` with the detected version string (R11: `tern.kv` holds only `hot`); re-resolved when a spawn raises `tern.process.run <program>: ...` or when settings change):

**`tern`**: 1. setting `tern_path` (Settings › Scheduler › Advanced; optional) · 2. `/Applications/Tern.app/Contents/MacOS/tern` · 3. `<HOME>/Applications/Tern.app/Contents/MacOS/tern` · 4. `<HOME>/.local/bin/tern` · 5. `/opt/homebrew/bin/tern` · 6. `/usr/local/bin/tern`.
Why app bundle before the `~/.local/bin` symlink: no dangling-symlink class of failures, and it is the binary of the running daemon unless the user moved the app. Candidate validation = `tern.process.run({cand, "--version"}, {timeout_ms=3000})` with `status==0` and stdout matching `^tern %d`; a candidate that fails to start is skipped. Existence is *not* tested with `tern.fs.exists` (symlink semantics [INFERENCE] V1).

**`omp`**: 1. setting `omp_path` · 2. `link` from `<HOME>/Library/Application Support/Tern/omp/state.json` (`tern.json.decode(tern.fs.read(p, 65536)).link`, if present) · 3. `<HOME>/Library/Application Support/Tern/omp/bin/omp` · 4. `/opt/homebrew/bin/omp` · 5. login-shell lookup `tern.process.run({"/bin/zsh","-l","-c","command -v omp"}, {timeout_ms=5000})` first stdout line · 6. `<HOME>/.local/bin/omp` · 7. `/usr/local/bin/omp`.
Why Tern-managed first: it is the omp Tern itself manages and updates, the flags in this doc were verified against it (`omp --help` = v18.9.1), and PR2's verified launch used `/opt/homebrew/bin/omp`. Entry 5 and 6 pick up user-installed omp when Tern does not manage one. Validation = `<cand> --version` (prints `omp/18.9.1`) with `status==0`. Stored on each run: `omp_path`, `omp_version`.
Consequence to surface in Settings › Setup check (one row, never a blocker): "Jobs use omp 18.9.1 (Tern-managed). A terminal `omp` may be a different version (`~/.local/bin/omp` is 18.8.6)." Flags used below are all present in 18.9.1 `--help`; run-time probe `V2` checks them against the resolved binary when version ≠ 18.9.x.

A path containing a space (`~/Library/Application Support/Tern/omp/bin/omp`) is legal as argv[0]; it is used only when entries 2-4 are absent (§2.4; V1).

**No bare-`omp` fallback (R4).** If every omp candidate fails validation the run is `blocked/omp_missing` and nothing launches; a missing `tern` is `blocked/tern_missing`. engine.md §1.3's candidate order and its "bare `omp` through the login shell" fallback are superseded by this section.

---

## 2. Exact argv

All launches are `tern.process.run(argv, {timeout_ms=15000}, cb)` (direct exec, no shell; AR). `SESSION` = setting `session_name` (default **`Scheduled runs`**, R22), validated against `^[%w][%w _.-]{0,39}$` (a leading `-` would be parsed as a `tern` flag, RF S2). The palette group and manager tab stay "Schedule".

### 2.0 The `tern ls --json` helper (R14)

One host helper, `tern_state(cb)`, is the only reader of Tern state for sessions, blocks and liveness: ensure-session (§2.1), the per-tick liveness poll (§8.2), the focus guard (§4), the pane cap (§9) and the Setup-check "Keep-alive" row (R20). `tern inspect --json` is used only for a field that exists only there (none is needed today; `inspect` has no `panes[].live`, RF F8). Ids are turned into strings *before* decoding (Luau doubles lose the integer form at ≥15 digits):
```lua
local function tern_state(cb)
  tern.process.run({TERN, "ls", "--json"}, {timeout_ms = 8000}, function(r)
    if r.status ~= 0 then return cb(nil, r) end                                  -- caller classifies stderr (§11 #7)
    local s = r.stdout:gsub('("id"%s*:%s*)(%d+)', '%1"%2"')                      -- ids → strings (an escaped \"id\" inside a title cannot match)
    local ok, j = pcall(tern.json.decode, s)
    if not ok then return cb(nil, r) end
    local st = { sessions = j.sessions, blocks = {}, by_run = {} }               -- blocks[id] = block + {session, tab, tab_shown, session_shown}
    for _, se in ipairs(j.sessions) do for _, tab in ipairs(se.tabs) do for _, b in ipairs(tab.blocks) do
      b.session, b.tab, b.tab_shown, b.session_shown = se.name, tab.id, tab.shown, se.shown
      st.blocks[b.id] = b
      local job, run = (b.command or ""):match("/runs/(j_[%w]+)/(r_[%w_]+)/")    -- correlation key (R2)
      if job then st.by_run[job .. "/" .. run] = b end
    end end end
    cb(st)
  end)
end
```
`tern ls --json` shape (observed, HELP run): `{"sessions":[{"id":4,"name":"Default","shown":true,"tabs":[{"id":..,"number":1,"name":null,"shown":false,"zoomed":false,"blocks":[{"id":17506286698538,"title":"..","cwd":"..","program":"/bin/zsh","args":["-l","-c","omp"],"command":"omp","cols":84,"rows":24,"exited":null,"keep_open":false,"focused":true,"live":true}], "splits":{..}}]}]}`. A block counts as **ours** only if its `command` carries the run marker `/runs/<job>/<run>/` (R12, §8.2).

### 2.1 ensure-session (once per launch, inside the launcher queue)

The launcher queue is FIFO and single-flight (one launch in progress at a time; R15) so two simultaneous fires cannot both see "no session" and create two `Scheduled runs` sessions.

```lua
-- Step 1: tern_state() (§2.0). Works with zero windows once any session exists; with none, text "no sessions".
```
Decision: `status==0` and decodable → look for `sessions[i].name == SESSION`. `status~=0` or undecodable and stdout/stderr contains `no sessions` → treat as an empty list (PR2 test 5 printed `no sessions`; whether `--json` prints `{"sessions":[]}` or text is V3). Contains `no Tern is running` → `failed/launch_error` "session service isn't reachable" (§11 #7).

```lua
-- Step 2a: session exists → a tab in it (background; PR2 test 4: view and focus unchanged)
local new_tab = {TERN, "new", "tab", SESSION, "--json", "--cwd", cwd, "--keep-open", "--", OMP, --[[omp argv §2.2]]}
-- Step 2b: session absent → create it with the first run as its first tab (PR2 test 4/5)
local new_sess = {TERN, "new", "session", SESSION, "--json", "--cwd", cwd, "--keep-open", "--", OMP, --[[same]]}
```
Flag order `new tab <SESSION> --json --cwd <d> -- <cmd>` and `new session <NAME> --json --cwd <d> -- <cmd>` is the order exercised in PR2 test 4. **`--keep-open` is passed on every launch (R5)**: it is documented (`tern new --help`: "a block whose program succeeds closes unless kept open") and is required, because when `--max-time` stops omp with status 0 the pane would otherwise vanish with the evidence. It was not exercised in PR2 (V4). **Only the host closes run panes** (`tern close`, §9); no window code closes, stops or kills a run pane. With `--keep-open` a pane never disappears on its own, so "block absent from `ls`" can only mean the user closed it, we closed it, or the daemon restarted (§8.2).

Result (PR2 test 4/5): `{"session": 4, "tab": 18043157610497, "block": 18043157610498}`. **Extract ids with a pattern and keep them as strings (R3)**: `local block = r.stdout:match('"block"%s*:%s*(%d+)')`; same for `tab`/`session`. The string is stored on the run and passed to window APIs as-is (`cx.session:resolve(block)`).
Dedicated session default is the verified no-focus-change path (PR2 test 4 "session targeting": shown session and focus unchanged). [INFERENCE, V5] a freshly created session does not become the shown one in a window.

**Multi-window (R21, RF F1).** The `tern` CLI acts on "one window's sessions… else the first window" and the plugin cannot read `TERN_WINDOW_KEY` (PR2 T7). Whether sessions are daemon-wide (expected) or per window is the gating item V26. If per window, runs land in the first window's `Scheduled runs` session and the docs say so; nothing else in this design changes.

### 2.2 The omp part (per run)

Run dir (host creates with `tern.fs.mkdir`, one level at a time; `mkdir` recursion is not documented): `<data>/runs/<job_id>/<run_id>/` with `prompt.md`, `preamble.md`, `omp.yml` and `session/` (omp creates it) (R2). `<data>` = `tern.plugin.data` = `/Users/bfturner/Library/Application Support/Tern/plugin-data/schedule` (contains a space). Ids (R3): `job_id` = `j_` + 8 `[a-z0-9]`; `run_id` = `r_<job8>_<slot>` for scheduled/catch-up slots and `r_<job8>_<epoch>_<rand4>` for manual runs, so both are `[a-z0-9_]+` slugs and the path `/runs/<job_id>/<run_id>/` is the correlation key. The ledger lives elsewhere (`ledger/<job id>.jsonl`, engine.md).

Field names are engine.md's (§1.1): `role` (bare), `approval` (`read_only|write|always_ask|yolo`), `max_runtime_s`, `after`, `allow_home`. There are **no `thinking`, `tools` or `tell_unattended` job fields in v1** (preamble is always on, R6; Read-only is hidden until V9, R18).
```lua
local APPROVAL_CLI = { read_only = "always-ask", write = "write", always_ask = "always-ask", yolo = "yolo" }   -- engine §1.1 mapping

local function omp_argv(job, run, bins, opts)
  assert(job.approval ~= "read_only", "hidden until V9: no tool allowlist is passed in v1")   -- stored value is refused → blocked/invalid_job
  local a = { bins.omp,
    "--model", "@" .. job.role,                         -- HELP: --model; "role: slow or @slow" (DOC:cli-reference "Model selection"); role charset §6
    "--approval-mode", APPROVAL_CLI[job.approval],      -- always-ask | write | yolo (HELP)
    "--max-time", tostring(job.max_runtime_s),          -- seconds; "600, 10m, 1h" (HELP, DOC:cli-reference L147)
    "--session-dir", run.dir .. "/session",             -- HELP: "Directory for session storage and lookup"
    "--append-system-prompt", run.dir .. "/preamble.md",-- always (R6); HELP: "text or file contents" (V6: file form)
    "--config", run.dir .. "/omp.yml",                  -- always (R7: approval pin for non-yolo, ask disabled for yolo); HELP: repeatable overlay
  }
  if job.allow_home then a[#a+1] = "--allow-home" end                         -- §5 (R17)
  if opts.reporter then a[#a+1] = "-e"; a[#a+1] = opts.reporter end            -- M3, §12
  a[#a+1] = "@" .. run.dir .. "/prompt.md"              -- attachment (DOC:cli-reference L57)
  a[#a+1] = "Run the scheduled job described in the attached file."   -- fixed ASCII positional
  return a
end
```
When `opts.reporter` is set the whole omp invocation is prefixed `{"/usr/bin/env", "SCHEDULE_RUN_FILE=" .. run.dir .. "/report.json", bins.omp, ...}` (`/usr/bin/env` exists; PR2 test 5 used it for `tern`). `bins.omp` stays argv[1] otherwise.

Flags verified present in `omp --help` v18.9.1 (HELP): `--model`, `--approval-mode`, `--max-time`, `--session-dir`, `--append-system-prompt`, `--config`, `--allow-home`, `-e/--extension`, `--resume`, `--cwd` (not used: Tern's `--cwd` sets the pane directory, as in PR2). Deliberately **not** used: `-p` (we want the interactive pane), `--no-session`, `--goal` (rejected with positional/@file per DOC:cli-reference L134), `--yolo`/`--auto-approve` (force yolo even when `--approval-mode` is given, DOC:approval-mode), `--profile` (isolates auth), `--thinking` and `--tools` (no job fields in v1; `--tools` returns with Read-only after V9), `--no-extensions` (R7: user-global extensions such as omp-pushover are useful for scheduled runs; project-level extension risk is documented in §7.2, not blocked).

### 2.3 How the prompt is passed (decision)

| Option | Quoting exposure | Length | Verdict |
|---|---|---|---|
| Inline positional `"<prompt>"` | `'`, `$`, backtick, newlines, leading `-`, emoji all pass through Tern's unknown quoting into `zsh -c` (only a space-containing arg was ever observed quoted: `'Reply with exactly: pong'`, PR2 test 4) | macOS argv limit ≈ 1 MiB, plus Tern's IPC | Rejected as default |
| **`@<run>/prompt.md` attachment + fixed short positional** | Path only (generated; the sole risk is the space in `<data>`, same mechanism that PR2 test 4 verified for `'Reply with exactly: pong'`) | unbounded (file) | **Chosen** |
| Positional "Read /path and do what it says" | Same path risk; costs a tool call and depends on the model obeying | unbounded | Contingency if V7 fails |

Why attachment: DOC:cli-reference L57-62: `@<path>` attaches a file to the initial message; "stdin text, text attachments, and the first positional message are combined into the initial prompt"; "Without stdin text, an argv prompt or attachment is required". Unicode and newlines are file bytes, so they cannot be mangled. **Source of truth (R1):** `prompts/<job id>.md`, managed by the plugin (created only by the host manager, R10). At fire time, after preflight, the host writes the **snapshot** `runs/<job>/<run>/prompt.md` (later edits of the job do not change the run record, and "Open run" shows what actually ran). `prompt_source="file"`/`prompt_path` are **cut from v1** (arbitrary-file read, RF S3c). The extra fixed positional makes auto-submit unambiguous even if an attachment-only launch would wait at the prompt (V7). It is plain ASCII without quotes or leading `-`; it contains spaces, so Tern will quote it exactly like PR2's `'Reply with exactly: pong'`. engine.md's earlier "prompt after `--`, no shell quoting" form is deleted (Tern joins argv into a `/bin/zsh -l -c` string, PR2 T4).
Contingency (only if V7/V8 fail): inline positional when the prompt satisfies `safe_inline(p) = #p <= 4000 and not p:find("[^%w%s%.,:;!?()/_%-]") and p:sub(1,1) ~= "-"` and newlines are replaced by spaces; otherwise the pointer form. This is documented so the implementer has the fallback ready; it is not shipped unless a V item fails.

Frontmatter-free `prompt.md` content is the job prompt verbatim (no preamble; the preamble goes to the system prompt, §3).

**Path safety gate (launcher init, Save, and every launch):** `<data>` and `cwd` MUST NOT contain `'`, `"`, `\`, `` ` ``, `$`, `!`, newline, or NUL. Spaces and non-ASCII are allowed. A violating `<data>` disables launching with a Setup-check error ("Tern's data folder path contains a character the launcher can't pass safely"). A violating `cwd` is **rejected at Save in the manager form** (R17) with the copy "Folders with quotes, $ or ! in the name aren't supported yet." and, if one slips through (edited files, moved folder), blocks the run (§11 #5 `cwd_unsafe`). (`cwd` is a Tern flag value, not shell text, so this is conservative; it also guards the `--resume` command in §10.) The same character class is rejected in role names (§6) and in `session_name` (§2).

### 2.4 Tern quoting (what is known)

PR2 test 4, `tern inspect` of a launched block: `args=["-l","-c","/opt/homebrew/bin/omp --model @tiny 'Reply with exactly: pong'"]`. Known: `argv` is joined into one string; an element with spaces is wrapped in single quotes; `@tiny` and the absolute path are bare. Unknown (V1): behavior for an embedded `'`, `$`, newline, empty string, leading `-`, non-ASCII. The design above makes none of those reachable. Paths with spaces (`~/Library/Application Support/...` as `--session-dir`, `--append-system-prompt`, `@file`, and as argv[0] in resolution fallback 3) are expected to survive by the same wrapping; `V1` runs one real launch with a spaced path and reads `tern inspect --json`'s `args[2]` to confirm.

### 2.5 Three worked examples

Common: `TERN="/Applications/Tern.app/Contents/MacOS/tern"`, `OMP="/opt/homebrew/bin/omp"`, `D="/Users/bfturner/Library/Application Support/Tern/plugin-data/schedule"`, `R = D.."/runs/<job id>/<run id>"`.

**A. Daily review (typical), session exists, ask-before-commands.** Job `j_k3x9a2bc` "daily-review", role `default` (`@default`), approval `write`, `max_runtime_s` 1800, `after` `keep`, cwd `/Users/bfturner/Dev/app`, scheduled slot 1791727200 → run `r_k3x9a2bc_1791727200`. Overlay `omp.yml` = the §7.2 approval pin.
```lua
local R = D.."/runs/j_k3x9a2bc/r_k3x9a2bc_1791727200"
{ TERN, "new", "tab", "Scheduled runs", "--json", "--cwd", "/Users/bfturner/Dev/app", "--keep-open", "--",
  OMP, "--model", "@default", "--approval-mode", "write", "--max-time", "1800",
  "--session-dir", R.."/session",
  "--append-system-prompt", R.."/preamble.md",
  "--config", R.."/omp.yml",
  "@"..R.."/prompt.md",
  "Run the scheduled job described in the attached file." }
```
Pane command (expected, [INFERENCE V1] for the exact quoting): `/opt/homebrew/bin/omp --model @default --approval-mode write --max-time 1800 --session-dir '/Users/bfturner/Library/Application Support/Tern/plugin-data/schedule/runs/j_k3x9a2bc/r_k3x9a2bc_1791727200/session' --append-system-prompt '…/preamble.md' --config '…/omp.yml' '@/Users/…/prompt.md' 'Run the scheduled job described in the attached file.'`
Follow-ups: `tern rename <block> '⏲ daily-review'` (§4). The `Scheduled runs` argument contains a space; it is a `tern` argv element (direct exec), not shell text.

**B. First run ever, no `Scheduled runs` session, hands-off, folder with a space, unicode prompt.** Job `j_q1w2e3r4` "nightly-news 🗞", role `smol` (`@smol`, cost shown on the form, R16), approval `yolo`, 900 s, cwd `/Users/bfturner/Dev/my app`, slot 1791770400 → run `r_q1w2e3r4_1791770400`. `tern ls --json` has no `Scheduled runs` → ensure-session creates it. Prompt text `Résumé les nouvelles — it's “fine”; don't ask` lives in `prompt.md` only. Hands-off ⇒ `omp.yml` = `ask: {enabled: false}` (§7.2) and the preflight verifies the hands-off confirmation hash of (prompt text, cwd, role) (R10): a mismatch is `blocked/hands_off_review` and nothing launches.
```lua
local R = D.."/runs/j_q1w2e3r4/r_q1w2e3r4_1791770400"
{ TERN, "new", "session", "Scheduled runs", "--json", "--cwd", "/Users/bfturner/Dev/my app", "--keep-open", "--",
  OMP, "--model", "@smol", "--approval-mode", "yolo", "--max-time", "900",
  "--session-dir", R.."/session",
  "--append-system-prompt", R.."/preamble.md",
  "--config", R.."/omp.yml",
  "@"..R.."/prompt.md",
  "Run the scheduled job described in the attached file." }
```
The job name, emoji, apostrophes and curly quotes never reach this argv. `cwd` has a space (Tern `--cwd` value; not shell text).

**C. Run now beside the work, project role, ask-for-everything, brought to front (M1).** Job `j_z8m4q7dd` "check-docs", role `nightly` (project role from `<cwd>/.omp/config.yml`, §6), approval `always_ask`, 300 s, placement "Background tab in the current session" + Bring to front, cwd `/Users/bfturner/Dev/personal`. Manual run → `r_z8m4q7dd_1791771000_a3f9`.
```lua
local R = D.."/runs/j_z8m4q7dd/r_z8m4q7dd_1791771000_a3f9"
{ TERN, "new", "tab", "--json", "--cwd", "/Users/bfturner/Dev/personal", "--keep-open", "--",   -- no session arg ⇒ "the session shown" (§4 b)
  OMP, "--model", "@nightly", "--approval-mode", "always-ask", "--max-time", "300",
  "--session-dir", R.."/session",
  "--append-system-prompt", R.."/preamble.md",
  "--config", R.."/omp.yml",
  "@"..R.."/prompt.md",
  "Run the scheduled job described in the attached file." }
-- then (Bring to front): { TERN, "focus", block }
```
*Shapes that are not shipped in M1* (fixed here so the argv contract is stable): split placement (M2) is `{ TERN, "split", FOCUSED, "right", "--json", "--cwd", cwd, "--keep-open", "--", <same omp argv> }` with `FOCUSED` from `tern_state()`; the M3 reporter wraps the omp argv as `"/usr/bin/env", "SCHEDULE_RUN_FILE="..R.."/report.json", OMP, ..., "-e", TPD.."/omp/reporter.ts", ...` (`TPD = tern.plugin.dir`). Read-only (hidden until V9) would add `--tools` with an allowlist validated against the tool list in `omp --help`; the user's omp lists `find`/`search`, so the names must be checked, not assumed.

---

## 3. Unattended preamble (`--append-system-prompt`)

Written to `<run>/preamble.md` per run (text below; `{…}` substituted by the host; file written with `tern.fs.write`). **Always on in M1 (R6)**: the per-job toggle (engine field `unattended_note`) is deferred, so the file is always written and `--append-system-prompt` is always passed; if V6 fails (file form not read) the host prepends this text to the `prompt.md` snapshot instead.

```
This is an unattended run of the scheduled job "{job_name}" (job {job_id}, run {run_id}).
It {how}, at {fire_local}. Nobody is watching this terminal and nobody will answer questions.

- Do the task in the user's message completely and on your own. Make reasonable assumptions and say what you assumed. Ask a question only if you truly cannot continue without the answer.
- If you are blocked (missing access, a tool keeps failing, an instruction you cannot resolve), stop and say exactly what is blocking you. Do not retry the same failing step more than twice.
- Your working directory is {cwd}. Do not change files outside it unless the task says to.
- Do not leave background processes or servers running when you finish.
- You have about {max_time_human} before this run is stopped. Finish before then.
- End your final message with one line starting `RESULT:` followed by a one-sentence summary, for example `RESULT: 3 PRs merged, 1 risky change in auth/session.ts`. If you could not complete the task, write `RESULT: FAILED - <reason>`.
```
Substitutions: `{how}` = `was started on schedule (slot {slot_local})` | `was started manually (Run now)` | `was started as a test run`; `{fire_local}` = `os.date("%a %Y-%m-%d %H:%M %Z", t)` (local, `%Z` works in both halves, PR2 test 7); `{job_name}` is stripped of control characters/newlines/backticks and capped at 80 chars; `{max_time_human}` = `30 minutes` etc. There is no quiet clause in M1: quiet success (`quiet_ok`, `[quiet]`) is **deferred past M1** (R6); engine fields for it are ignored.

Tracker parsing (host, §8.4): the last non-cost line starting `RESULT:` is the run summary (engine caps summaries at 200 chars); `RESULT: FAILED - …` ⇒ `failed/agent_failed` (reason = text) even though omp finished normally; no `RESULT:` line ⇒ `finished` with summary = first line of the last message. A literal `RESULT: [quiet]` is just a summary in M1.

Justification. The "don't ask unless truly blocked" wording follows OC §5 (the `ask` tool stalls a pane) and PA §6 "Permission stalls"; the rule "do not retry the same failing step more than twice" bounds token burn inside the time cap. The mandatory `RESULT:` line gives the tracker a deterministic summary without model-specific parsing and costs one sentence of output. PA §5.8 quiet-success (Hermes `[SILENT]`, OpenClaw `NO_REPLY`) is a later layer on top of the same `RESULT:` line (the marker would be its exact payload, honored only when the run otherwise succeeded, and the run would stay in history with its pane kept); it is not part of M1.

---

## 4. Placement & focus

Realizations, evidence per PR2. "Shown" = the session the user's window displays. Setting key `placement` (`{where, corner}` per engine §1.1); `focus` is the separate Bring-to-front switch. UI labels are ux.md's; the option set here is the realizable one: Hidden/park is dropped (park fails for every id form, PR2 test 1c) and the dedicated session is the default. **M1 ships (a), (b) and (e); split and picture-in-picture are M2 (R23).**

| # | Option (UI label) | CLI realization | Focus behavior | Status | Ships |
|---|---|---|---|---|---|
| a | **Scheduled runs session** (default): "Runs collect in a session named Scheduled runs" | `tern new tab SESSION --json --cwd D --keep-open -- …` (or `new session` if absent) | Shown session/tab and focus unchanged (PR2 test 4 "session targeting": `after: view unchanged`) | **Verified** (tab path; `new session` path verified when another session exists) | M1 |
| b | **Background tab in the current session**: "A tab in the session you're working in" | `tern new tab --json --cwd D --keep-open -- …` (no session arg ⇒ "the session shown", `tern new --help`) | PR2 test 4 ran exactly this form: "shown tab 3 and focus unchanged; new tab 4 was not shown" | **Verified** | M1 |
| c | **Split beside what I'm working on** | target block = in `tern_state()` the block with `focused==true` inside the tab with `shown==true` of the session with `shown==true` (not in `SESSION`); `tern split <block> right\|down --json --cwd D --keep-open -- …`; then if `focused` block changed: `tern focus <prev>` | Unknown whether a new split takes focus; restore with `tern focus` (works, PR2 test 1c) | **Untested** (V10) | **M2** |
| d | **Floating** (picture in picture) | after (c): `tern pip <new_block> --corner br` (`tern pip --help`: "floats a block of a split as a picture in picture over another"); undo `tern dock <block>` | Unknown | **Untested**; needs a split, so it is (c)+pip (V11) | **M2** |
| e | **Bring to front** (focus switch, any placement; always on for Test run) | after the launch result: `tern focus <block>` ("every window shows it"; PR2 test 1c: `rc=0`, shown tab changed) | Takes focus by design | **Verified** | M1 |

**Multi-window scope (R21).** Which window "the session shown" (b) and the first-window rule apply to is the open question behind V26. Expected: sessions are daemon-wide and `Scheduled runs` is visible from every window. If sessions are per window, a run created from the host lands in the first window, (b) means that window's shown session, and the manager says so in the Setup check.

Fallbacks: (c)/(d) with no focused local block (user in the runs session itself, no window, remote pane) → degrade to (b) and record `placement_used="tab_here"` + note in the run row ("No pane to split beside, opened a tab instead."). (b) with zero sessions → create session `Default`? **No**: with no windows there is no shown session, so (b) degrades to (a). Never use `layout:park` (fails), `cx.agents:start` (steals focus), `cx.layout:new_tab` (no daemon id; PR2 findings 2-3).

**Tab naming:** after a successful launch, `tern rename <block> '⏲ <job_name>'` (`tern rename --help`: "a session, or a block's tab"; PR2 test 4: renames the TAB, block title stays `omp`). Run directly (no shell), so the job name needs no quoting; the fixed `⏲ ` prefix means a name starting with `-` can never become a flag; the name is control-stripped. Names longer than 40 characters are truncated with `…`. **Only for placements a, b and e-after-a/b where the new block is alone in its new tab.** NEVER for (c)/(d): the split block shares the user's existing tab and rename would rename the user's tab. Failure is cosmetic and ignored. Tab color/badges are window-half (`cx.layout`) concerns (UX, M2), not the launcher's.
Because tab names are not agent specs (PR2 test 1b, `agent not found`), identity is always the string block id.

Focus guard rule for all placements except e: capture `focus_before` (`tern_state()`: session `shown` + tab `shown` + block `focused`) before launching; after launch, if the same query shows a different shown tab/focused block **and the launcher did not intend to bring to front**, run `tern focus <focus_before.block>`. For (a) and (b) this is expected to be a no-op (PR2) and exists as a safety net (one extra `tern ls --json`).

---

## 5. Working directory

Modes (UX "one concept: a fixed folder"; this section adds how each is produced). **There is no `$HOME` fallback (R17).** A job has a folder or it cannot be saved.

| Mode | How the value is produced | Owner |
|---|---|---|
| Fixed path | Typed or picked in the manager form; stored absolute | host manager (jobs are created/edited only there, R10) |
| Pre-filled from the focused pane | The Folder row of a **new** job is pre-filled from the focused local pane's cwd (host: the `focused` block's `cwd` from `tern_state()`, or the draft args the palette passes through `cx:new_block`); remote panes refused (UX). The user confirms it; it is stored as a fixed path | host manager |
| Empty | No focused local pane ⇒ the row is empty and required: "Pick a project folder." Save is disabled | host manager |
| Home | Explicitly picking `~` expands to `$HOME` and stores `allow_home = true` (passes `--allow-home`; the form shows omp's temp-dir caveat, §5 step 3) | host |

**`~` expansion is the host's job.** `tern.fs` documents no expansion (`reference/api-shared.md` "tern.fs"); only the host `spawn` filter's `cwd` is expanded by the daemon (`api-host.md` L557). The manager normalizes on every write and the launcher again before every launch:
```lua
local function expand(p)
  if p == "~" then return HOME end
  if p:sub(1,2) == "~/" then return HOME .. p:sub(2) end
  return p                                      -- absolute stays; relative is rejected (not starting with "/")
end                                             -- also strip a trailing "/" (except root)
```
HOME = `tern.getenv("HOME")` (present in the host VM, PR2 test 7).

**Preflight (every fire; Save runs steps 1-2 and 4; host):**
1. Safety gate §2.3: at Save the form is rejected with "Folders with quotes, $ or ! in the name aren't supported yet."; at fire `blocked/cwd_unsafe`.
2. Is a readable directory, **async and bounded** (RF F6: a synchronous `tern.fs.list` on a user path can hang on a TCC prompt or a sleeping network volume and trip the 2 s host budget, disabling every host timer): `tern.process.run({"/bin/test","-d",cwd},{timeout_ms=3000}, cb)` then, on success, `{"/bin/test","-x",cwd}`; on `-d` failure `{"/bin/test","-e",cwd}` tells missing (`cwd_missing`) from not a folder (`cwd_not_dir`, reported with code `cwd_missing` and its own sentence); a failed `-x` is "unreadable" (same code, own sentence); a timeout is treated as unreadable. No error-text parsing, so V12 becomes "exit codes of `/bin/test` for the three cases".
3. Home: `cwd == HOME` and not `allow_home` → `blocked/cwd_home` (omp otherwise "auto-switches to a temp dir unless `--allow-home`", OC §0 1d, HELP `--allow-home`); with `allow_home=true` pass `--allow-home` (UX warning stays on the form: omp may still use a temp dir, caveat from OC).
4. Git hint (host, on edit/Save only, never per fire): `/bin/test -d <cwd>/.git` first; only then `tern.process.run({"/usr/bin/git","-C",cwd,"status","--porcelain=v1","--branch"},{timeout_ms=3000})` → `git · main · 3 uncommitted files` (UX). The `.git` precheck avoids launching the `/usr/bin/git` shim in non-repos.
5. Remote folders refused at creation.

The resolved cwd is stored on the run (`run.cwd`) and goes to Tern as `--cwd` (and to `process.run` `opts.cwd` for role lookups, §6).

**Worktree isolation: deferred to M3.** `omp --help` has no worktree flag on the launch command; `omp worktree add [PATH] [COMMIT] -b <branch> -C <repo> --json -q` exists as a subcommand ("clone-first when enabled"; HELP, `omp worktree --help`), so M3 can do, host-side before launch: `omp worktree add -C <cwd> -b sched/<job>/<run_id> <run_dir>/wt HEAD --json` → run `cwd = <run_dir>/wt`; cleanup `git -C <cwd> worktree remove --force <run_dir>/wt` when the run's pane closes or at retention. Rationale for deferring: (1) PA §6 "Worktree pile-up" needs the retention/cleanup machinery that lands in M3; (2) an isolated checkout has none of the user's uncommitted state, untracked env files or `node_modules`, which breaks many jobs and needs per-job copy rules; (3) read-only and report-style jobs (the common case) don't need it; (4) UX §9 Q4 already recommends "later". M1-M2 ship the dirty-checkout warning only. Verify before M3: `omp worktree add --help` semantics for `-C`/branch creation (V13).

---

## 6. Roles

Source of truth is omp, resolved **per job cwd** so project overlays apply. Verified: `omp config get modelRoles --json` prints `{"key":"modelRoles","value":{"default":"anthropic/claude-opus-5-5:medium","slow":…,"judge":"openrouter/~typesafe/jev-latest"},"type":"record",…}`; and a project file `<cwd>/.omp/config.yml` containing `modelRoles: {nightly: anthropic/claude-haiku-5-5:low}` produced a `nightly` entry (placed first) when run with that cwd (checked in a throwaway `/tmp` dir and removed). **Verified [overlay applies by cwd].**

```lua
tern.process.run({ OMP, "config", "get", "modelRoles", "--json" }, { cwd = cwd, timeout_ms = 8000 }, cb)
-- r.stdout → tern.json.decode(...).value : { [role] = selector }
```
- **Filtering:** drop kind roles `image web speech dictation judge` (not chat models; OC §2). Chat roles known: `default smol slow plan task commit advisor tiny memory vision` (OC §2/§3). Anything else is a custom role and is kept.
- **Ordering:** `default`, `smol`, `slow`, `plan`, then remaining built-ins in the order `task commit advisor tiny memory vision`, then custom roles alphabetically (project-overlay roles are labelled "project" in the detail). Hash-table order from `decode` is unspecified, so sort explicitly.
- **Display model:** `detail = selector` shortened: strip leading `provider/`, keep `:level` (`claude-opus-5-5 · medium`); comma-fallback lists show first + `+N fallbacks`; `*` shows `= @default`. Prettier names (`Opus 5.5`) are a later nicety via `omp models --json`; PR2 `cx.agents:list()` already carries a resolved `model` string (`Haiku 5.5`) which is stored on the run once observed.
- **Cache:** per cwd, 30 min, in memory and the host file `cache.json` key `roles.<hash(cwd)>` (`{t, roles}`; R11: not `tern.kv`), invalidated by a "Refresh" action and on a `role_missing` block. A window requests roles with the allowlisted `roles_request` intent `{format:1, kind:"roles_request", cwd}` (R10); the host replies in `snapshot.json.roles[cwd]` (a window cannot depend on the host process directly; the host manager reads the cache directly). A cache miss never blocks the form: show the last cache or the built-in names with detail "checking omp…".
- **Preflight at fire time** (use the cache only if ≤ 60 s old, else re-run): **role read and absent** from the fresh map → run `blocked/role_missing`, "Blocked: role @nightly no longer exists in omp." No pane created, no tokens spent. **Role list could not be read** (omp errored, timeout, non-JSON, engine cache unknown) → **the run proceeds** and the run record notes `role_unverified` (never block on missing information, R16); a retired model behind a role surfaces only at run time (`failed/exited_early`, §8/§11 #12).
- The stored value is the bare role name (`default`); the form shows `@default` and the launcher passes `--model @<name>`. The default for new jobs is `@default` (literal requirement); example jobs explicitly use `@smol` with the cost shown. A role named with characters outside `[%w_-]` is rejected at Save (they would reach the shell string). **"Other model…" (a pinned model id) is cut from v1** because it would put free text in argv.

---

## 7. Approval & limits

### 7.1 Modes

| UX label (UX) | `approval` (engine) → `--approval-mode` | Extra argv / overlay | Prompts for (DOC:approval-mode) | Ask tool |
|---|---|---|---|---|
| Read-only | `read_only` → `always-ask` | **Hidden until V9 (M2).** Would add `--tools <allowlist>`; neither the form nor the launcher offers it in v1 (R18) | nothing is offered that could prompt | not in allowlist |
| Ask before commands | `write` → `write` | `--config omp.yml` approval pin (§7.2) | `exec` tier (shell, browser, spawn agents) | enabled |
| Ask for everything | `always_ask` → `always-ask` | `--config omp.yml` approval pin (§7.2) | `write` + `exec` | enabled |
| Hands-off | `yolo` → `yolo` | `--config omp.yml` with `ask.enabled: false` (§7.2) | nothing | disabled |

**Default for new jobs: Ask before commands (`write`), pending the user's decision (decisions Q1).** Reasons: UX recommends it; PA §5.5/§6 "Permission stalls" and "Unattended + full-access" favor narrow modes with a first-run approval flow; a stall is *visible and bounded* here (needs_input + `--max-time`, §7.3) whereas a yolo mishap is not undoable. The argument the other way is that the user's omp default is `yolo` (`omp config get tools.approvalMode` → `yolo`) and tern-swarm defaults to yolo (LP); Q1 options (a per-job "Allowed commands" list compiled into the overlay, hands-off default, or no allowlist) change only the overlay content and the default value, not the argv. The launcher **always passes `--approval-mode` explicitly** and never inherits omp's setting (a changed omp config cannot silently widen a job). Per-user default lives in Settings (`defaults.approval`, engine §1.3); Carly cannot set it. First save with Hands-off requires the confirm overlay (UX), and the confirmation is bound to a hash of (prompt text, cwd, role) (R10): editing any of them makes the next fire `blocked/hands_off_review` until re-confirmed in the manager.

Never use `--yolo`/`--auto-approve` (they override `--approval-mode`, DOC:cli-reference L137).

### 7.2 Per-run overlay `<run>/omp.yml` (R7)

Written for **every** run; precedence per DOC:approval-mode is flags > `--config` overlay > project `.omp/config.yml` > global, and `tools.approval.<tool>: allow|deny|prompt` overrides the active mode (RF S4). A repo containing `.omp/config.yml` with `tools: {approval: {bash: allow}}` would otherwise make "Ask before commands" run shell commands unprompted, so non-yolo runs pin the exec tier to `prompt`:
```yaml
# every non-yolo run (write, always_ask)
tools:
  approval:
    bash: prompt
    eval: prompt
    task: prompt      # sub-agents run headless in yolo; one approved `task` would escape every later prompt (RF S7)
    browser: prompt
```
The key names are [INFERENCE] from the exec-tier list in DOC:approval-mode and the tool list in `omp --help`; V31 verifies both the names and that the overlay beats a hostile project config. Hands-off (`yolo`) runs get the other overlay instead:
```yaml
ask:
  enabled: false
```
User-global extensions still load (e.g. omp-pushover is useful for scheduled runs); `--no-extensions` is not passed. **Documented, not blocked in v1:** a repo's `.omp/extensions/`, hooks and rules load into unattended runs, and plugin data is not a security boundary against other processes running as the user.

`ask` in a pane: in an interactive pane `ask` IS registered and opens a dialog (DOC:tools/ask Flow; OC §5). It blocks the agent until a human answers → Tern reports `waiting_input` (api-window L999-1000) → run `needs_input`. `ask.timeout` defaults to `0` (disabled; verified `omp config get ask.timeout` = 0) and, if set, **auto-selects the recommended/first option** ("auto-selected after timeout", DOC:tools/ask), which silently answers questions with guesses. Decision: **never set `ask.timeout`**; surface the stall. For Hands-off (promise: "never asks") the tool is disabled by the overlay above (`ask.enabled = true (boolean)` appears in `omp config list`, verified; honored by `--config` overlay [INFERENCE V14]; note `omp --config f config get ask.enabled` printed the unmodified `true`, so the `config` subcommand ignores the launch overlay and V14 must be tested in a real pane). In `write`/`always_ask` modes the tool stays enabled, so a question becomes `needs_input` with copy "Waiting for you." (approval vs question cannot be distinguished from `cx.agents` alone; the M3 reporter can, §12).

### 7.3 `--max-time`
Stored per job as seconds (`max_runtime_s`, 60-28800, default **1800**), always passed as a bare integer of seconds. HELP: "Stop the session after this duration (e.g., 600, 10m, 1h)"; the binary rejects other formats ("Expected a positive number of seconds or duration like …"). What happens at expiry is **not documented** in `omp://cli-reference.md` (only "bound the run"). Evidence: tern-swarm reads `exited` as "crash or `--max-time`" (LP pitfall 22), i.e. omp exits. The tracker rules that work under either behavior are engine.md §7.3's (a pane whose omp exited at ≥ `max_runtime_s` minus its margin is `timed_out`; a still-live pane past `started + max_runtime_s` plus the engine grace is host-`tern close`d and classified from the session tail). The grace and margin values are engine constants and are not restated here (the earlier +120 s / −15 s in this doc are superseded). V15 measures actual behavior (exit vs idle prompt, exit code). Wall time is used for these deadlines, so a run that overlaps a Mac sleep can be misclassified (RF §2.2); the run row is annotated by the engine's gap detection.
At a `needs_input` stall the clock keeps running; UX copy: "Stopped at the 30m limit while waiting for you."

---

## 8. Run tracking protocol

### 8.1 States (owned by engine.md)
States, transitions, reason codes and every threshold (finish confirmation, the 180 s `no_response` stall, the time-limit margin and grace, the host liveness cadence) are engine.md §7 and its constants (R12, R15); this doc does not restate them. Canonical states: `scheduled launching running needs_input finished failed timed_out cancelled skipped missed blocked`. The launcher produces three kinds of evidence, described below: **host evidence** (§8.2: the `tern new` result, `tern ls --json`, `pane_exited`, `tern capture`), **window samples** (§8.3-§8.4: raw `cx.agents` fields sent as `obs` intents, interpreted only by the host) and **end-of-run facts** (§8.6).

### 8.2 Host evidence (no window needed)

| Source | Gives | Cadence |
|---|---|---|
| `tern new` result (§2.1) | `block`, `tab`, `session` (strings) → `launching → running`, `started`, `block` stored on run | once |
| host event `pane_exited` `{pane, status}` (events.md: "fires once per pane, when the host notices the exit"; payload pane = "the host's own ids, as `tern.pane.write` takes") | exit status | push |
| `tern_state()` = `tern ls --json` (§2.0; one process per tick covering every in-flight run): block present? ours (run marker in `command`)? `live`? `exited`? `focused`? | liveness, exit, user-closed | host tick (engine constant, 15 s, same tick as the clock) while any run is `launching/running/needs_input` |
| `tern capture <block>` (text of screen) | error tail for `failed` reasons (≤ 400 bytes kept, ANSI/control stripped before storage and display) | only on abnormal exit or `no_response` |

`pane_exited.pane` vs daemon block id: events.md describes it as the host's pane id and `tern.pane.list()` entries have `pane`; **whether that number equals the `block` returned by `tern new --json` is not shown anywhere [INFERENCE] (V16)**. Design does not depend on it: `pane_exited` is only an accelerator that triggers an immediate `tern_state()` reconciliation; truth always comes from `ls`.

**Ownership by marker (R2, R12, RF F5).** After a daemon restart Tern restores panes "as login shells" and plugins load before panes restore, so a block id may survive as a live bare shell with no run in it. `inspect` exposes no daemon start time (V17 answered: no). Therefore a block belongs to a run only while its `command` contains the run marker `/runs/<job>/<run>/`; liveness requires it. A present block without the marker is treated exactly like an absent block, and the host never `tern close`s it.

Classification of a `tern_state()` observation per in-flight run (host; outcomes are engine states/codes):

| Observation | Run was | Result |
|---|---|---|
| block absent (or present without marker), `close_requested` not set by us | any non-terminal | `failed/interrupted` ("Tern was closed while this run was in progress") if a daemon/heartbeat gap precedes it (engine start-gap `down` event, or the `hot.hb` gap covers the block's last sighting); else `cancelled/closed_by_user` |
| block absent, `close_requested` set (stop / policy / cap) | — | keep whichever terminal state we recorded |
| `exited != null`, run already terminal | finished etc. | no change (omp quit after finishing, e.g. user typed /exit) |
| `exited != null`, elapsed ≥ `max_runtime_s` − engine margin | running/needs_input | `timed_out/max_runtime` (or `waiting_for_input`) |
| `exited != null`, status 0, no `working` ever seen, elapsed < 60 s | launching/running | `failed/exited_early` (reason from the `tern capture` tail) |
| `exited != null`, status ≠ 0 | running/needs_input | `failed/agent_error` "omp exited with status N" + capture tail |
| `live`, ours, and now > `started + max_runtime_s` + engine grace | running/needs_input | host `tern close` (sets `close_requested`), classify per engine §7.3, `timed_out` |
| `live`, ours, now − `started` > 180 s and no sample ever showed `working` | launching/running | `failed/no_response` (counts toward the streak; **pane kept**, §9) |

`exited`'s JSON type for a dead block (number vs object) is [INFERENCE] (V18); `tern ls` text showed `exited 0` (PR2 test 5).

### 8.3 Window evidence (observer; raw samples through intents)

Window half loads through tern-swarm's staged module loader (one `require` per `tern.timer(0)` step, RF F7). **Windows send raw samples; the host owns debouncing and every transition (R9).** While the last `snapshot.json` lists in-flight runs, each window ticks every 3 s (engine constant; background throttling of 40-90 s is accepted, LP pitfall 3; host liveness covers the gap) and for each run in `launching/running/needs_input`:
```lua
local win = cx.session:resolve(run.block)                        -- PR2 test 1b: only the string daemon id resolves; returns the window pane id
local a = nil
if win then for _, e in ipairs(cx.agents:list()) do if e.pane == win then a = e; break end end end

local function clip(m)                                            -- RF F4: ≤ 4 KiB per sample; RESULT:/cost lines are at the end, the fallback summary at the start
  if m == nil or #m <= 4096 then return m, false end
  return m:sub(1, 1024) .. "\n…\n" .. m:sub(-3072), true
end

local sample = a and { resolved = true, state = a.state, model = a.model, alive = a.alive,
                       delivery_error = a.delivery_error, last_message = (clip(a.last_message)),
                       truncated = select(2, clip(a.last_message)) }
                 or  { resolved = false }
```
Fields used (PR2 tests 1/3/4, TP): `state` (`working|idle|waiting_input|exited`), `model`, `last_message`, `delivery_error`, `alive`. Never use ids from `list()`/`start()` for addressing (PR2 headline 1). The window keeps **no** `busy_seen`, idle timer or finish debounce, and derives **no `event`**; its only memory is the hash of its last sent sample and the time it was sent.

**When a window writes (R9):** an `obs` intent when `(state, model, hash(last_message), delivery_error, resolved)` changes against its own memory, **and a heartbeat every ≤ 30 s while the run's state persists** (the host needs a fresh sample to confirm "still idle" or "still waiting"). A window stops writing while `hot.hb` is stale for > 2 min (the host is not draining, RF X10) and remembers its own pending file names, capped at 20.

The `last_message` clip is 4 KiB because `cx.agents:list()` ships every agent's message through a 50 ms window call every 3 s and an oversized intent can exceed the intent cap and be dropped (RF F4); full text and cost come from the session file (§8.6).

### 8.4 Observation intent files and host derivation

Window → host, `<data>/intents/<t_ms>-<win8>-<seq>.json` (`win8` = random 8-char window id created at window start, `seq` monotonic per window; applied in name order, swarm pattern LP 9). Envelope `{format:1, kind, ...}` (R10; engine.md owns the protocol). Written in a single `tern.fs.write` (no rename API exists; write is "non-atomic replace", TP §2.2), so the host retries an undecodable file for 60 s and then drops it; applied files are deleted.
```json
{"format":1,"kind":"obs","run":"r_k3x9a2bc_1791727200","block":"18043157610498","win":"w3a9f2b1","seq":12,"t":1791727260,
 "agent":{"resolved":true,"state":"idle","model":"Haiku 5.5","alive":true,"last_message":"RESULT: 3 PRs merged\n2.1s · 308 tok · $0.01 this turn","delivery_error":null},
 "truncated":false}
```
**Allowlisted kinds only (R10):** `obs`, `run_now`, `pause`, `resume`, `pause_all`, `resume_all`, `stop_run`, `focus_run`, `open_run`, `roles_request`, `ack_failed`. There are **no `create`/`update`/`delete`/`settings` intents**: jobs and settings are written only by the host manager block, and a palette "New job" opens it with draft args through `cx:new_block` (V30). Payloads pass the same validator as the form (run/job ids must exist, `block` must equal the run's block, sizes capped). The launcher-relevant kinds execute as: `run_now` (existing job id, stored settings; §10), `stop_run` (host `tern close`, §10), `focus_run`/`open_run` (§10), `roles_request` (§6).

**Dedupe / idempotency (host).** Many windows see the same pane, so duplicates are normal. The host applies `obs` keyed by run id: a sample that changes nothing is a no-op; a terminal run ignores later `obs` except to fill missing `summary`/`model`. Stale files (run unknown or terminal > 1 h) are dropped. Applied `(run, win, seq)` pairs for the last 200 intents are kept in memory to skip re-processing after a partial drain.

**Host derivation from raw samples** (engine §7.3 owns the rules, thresholds and confirmations; this is how samples feed them):
| Sample | Host effect |
|---|---|
| `state=="working"` | set `busy_seen`, `first_work_at`, `model`; `launching → running`; `needs_input → running` |
| `state=="waiting_input"` | `→ needs_input` after the engine's hold; toast once per entry (window-side from `snapshot.json`); OS notification via §8.7 only for host-visible events |
| `state=="idle"` with `busy_seen` (or non-empty `last_message`) | finish candidate (initial idle is not "finished", LP pitfall 23); confirmed on the engine's consecutive observations, waiting the engine's late-message grace if `last_message` is absent; then parse `last_message` (§3, `split_msg` below) and start §8.6 |
| `state=="exited"` or `resolved==false` after earlier samples | no state change by itself; triggers an immediate `tern_state()` reconciliation (§8.2) |
| `delivery_error ~= nil` | `failed/delivery_error` with the error text |

Cost line parse (the pane's `last_message` ends with a per-turn line: `pong\n2.1s · 8 tok · <$0.01 this turn`, PR2 test 1/3; task text: `2.1s · 308 tok · $0.01 this turn`), run on the host over the clipped message:
```lua
local function split_msg(m)                      -- → body, cost = {seconds_text, tokens, usd_text}
  local body, line = m:match("^(.*)\n([^\n]*this turn)%s*$")
  if not line then return m, nil end
  local dur, tok, usd = line:match("^(.-) · ([%d%.,kKM]+) tok · (<?%$[%d%.]+) this turn$")
  return body:gsub("%s+$", ""), dur and { dur = dur, tok = tok, usd = usd } or nil
end
```
`last_turn_cost` is informational only (final turn). **Authoritative cost is the session JSONL** (§8.6).

**No window attached.** The host alone can establish launch, liveness, exit and timeout (§8.2) but not working/idle/`last_message` (those exist only in `cx.agents`). While no window observes, a run stays `running` with `observed=false`; the manager shows "Running (not observed: no Tern window open)" and the engine's overlap rule still counts it. **A run that stops for approval while no window is open waits silently** until a window opens (the first tick reports the current sample) or its time limit hits; only host-visible events (launch failure, early exit, timeout, blocked, `interrupted`) notify (R8). On the next window start the run becomes `finished` with `ended = first idle observation` and `ok_unobserved` per engine. Optional host-only fallback: `tern wait <block> --until idle=20000 --timeout N` (HELP: "exits with the program's status; 124: out of time") as a hint [INFERENCE: idle=MS semantic on a TUI with a spinner is unproven, V19]. The proper fix is the M3 reporter (§12).

### 8.5 Sequence of one run

```mermaid
sequenceDiagram
  autonumber
  participant C as Host clock (15 s tick)
  participant L as Launcher (host, FIFO single-flight)
  participant T as tern CLI
  participant D as Tern daemon
  participant P as Run pane (zsh -l -c omp ...)
  participant W as Window half (3 s tick)
  participant S as Store/ledger + snapshot.json
  C->>L: slot due → run r1 (state launching)
  L->>L: preflight: cwd, role (omp config get), path gate, hands-off hash; write prompt.md snapshot / preamble.md / omp.yml
  alt preflight fails
    L->>S: run r1 = blocked (reason, no pane)
  else ok
    L->>T: tern ls --json (tern_state)
    T->>D: list sessions
    D-->>L: sessions (Scheduled runs present?)
    L->>T: tern new tab|session "Scheduled runs" --json --cwd D --keep-open -- omp ... --config omp.yml
    T->>D: create block
    D->>P: spawn omp, prompt @prompt.md auto-submitted
    T-->>L: {"session","tab","block":N}
    L->>T: tern rename N '⏲ name'
    L->>S: r1 = running (block N, started); snapshot rev++
  end
  loop every window tick (3 s) while runs are in flight
    W->>S: read snapshot (kv rev changed?)
    W->>W: cx.session:resolve(N) → cx.agents:list() entry
    W->>S: intent obs(raw sample) on change + heartbeat ≤ 30 s
  end
  loop every host tick
    C->>T: tern ls --json (all in-flight runs, marker check)
    T-->>C: block live / exited / absent
    C->>S: apply intents (idempotent, host derives), stall + max-time rules
  end
  P-->>W: state working → idle, last_message "RESULT: … 2.1s · 308 tok · $0.01 this turn"
  W->>S: obs samples (idle, then heartbeats)
  S->>S: host confirms finish; r1 = finished; parse RESULT; async tail of session JSONL → cost, session_file
  C->>T: pane cap check → tern close oldest finished unfocused run pane (§9)
  W->>W: toast / badge / status segment from snapshot; host sends OS notification (§8.7)
```

### 8.6 End-of-run facts from the session file
At `finished`, `failed`, `timed_out`, `cancelled` (any run that had a `block`), the host reads omp's session JSONL **asynchronously** (RF F9: never a large synchronous `tern.fs.read` in the host VM; a budget trip disables every host timer):
- **Locate.** `--session-dir` is the *root* for omp's storage; its inner layout is `[INFERENCE V20]` (default root layout is `<root>/<encoded-cwd>/<ts>_<id>.jsonl`, DOC:session). Walk at most 3 levels of our own small run directory with `tern.fs.list(dir)` collecting names ending `.jsonl`; choose the newest by name (timestamp prefix). Store **`session_file`** (absolute path; Open run uses it, §10) and `session_id` (`<id>` after the `_` in the file name without extension; confirm against the header's `id`).
- **Read.** `tern.process.run({"/usr/bin/tail", "-c", "1048576", file}, {timeout_ms = 8000}, cb)`: the last 1 MiB, argv-passed (the path has a space; no shell). The partial first line is discarded; so is the 256-byte fixed-width title slot (a line beginning `{"type":"title"`). V21 checks that `process.run` returns 1 MiB of stdout intact.
- **Cost.** For each remaining line that contains the substring `"cost"` (cheap prefilter), `pcall(tern.json.decode, line)`; if `m.type=="message"` (field names [INFERENCE] V22: assistant messages carry `usage.cost.total`, OC §4) add `m.message.usage.cost.total`; decode at most ~2000 lines per timer step. Cost = sum, displayed per UX (`$0.42`, `<$0.01`, `—`). **When the file is larger than 1 MiB the sum covers only the tail: the figure is stored with `cost_approx=true` and labeled approximate.** Sub-agent (task tool) sessions are separate files and are likely **not** in the sum (V22); label the figure "main session" in Detail until verified. The same tail supplies the last assistant message when the window sample was clipped or absent (summary, `RESULT:` line; engine §7.3 T2 evidence).
- A run whose file is missing or unreadable records `cost=nil` ("—").
- Retention of `<run>/` is M3 (UX Settings "keep run history").

### 8.7 Host OS notifications (R8)

The **host** sends every OS notification (single writer, deduped by `(run id, transition)` stored on the run record, so several windows or reloads never double-notify). Windows only show toasts. The only mechanism is an argv-passing `osascript`; text and title are **never** interpolated into script source (RF S5: `"` & `do shell script` injection from a job name, a `last_message` or a forged intent):
```lua
local function clean(s)
  s = (s:gsub("%c", " "):gsub("%s+", " "):gsub("^[%s%-]+", ""))   -- control chars out; leading "-" out so osascript cannot read it as an option
  local cut = utf8.offset(s, 201)                                -- ≤ 200 characters
  return cut and s:sub(1, cut - 1) or s
end
local function notify(text, title)
  tern.process.run({"/usr/bin/osascript",
    "-e", "on run argv",
    "-e", "display notification (item 1 of argv) with title (item 2 of argv)",
    "-e", "end run",
    clean(text), clean(title)}, {timeout_ms = 5000}, function() end)    -- failure is cosmetic (§11 #26)
end
```
Which transitions notify, and the notify-once incident rule, are engine.md's (`system_notification`, §6.5). Copy (ux.md owns the words) must state: with no Tern window open, a run that stops for approval waits silently until a window opens or its time limit hits; host-visible failures (launch failure, early exit, timeout, blocked, interrupted) still notify. `tern rename` and `tern capture` tails follow the same rule: no shell, control characters stripped, fixed `⏲ ` prefix. V32 checks the argv form with a hostile string.

---

## 9. End-of-run pane policy and pane cap

Every run pane is launched `--keep-open` (R5), so a pane never goes away on its own and **only the host closes run panes**, always after the terminal state and the §8.6 facts are persisted (facts first, close second). No window code calls close/stop/kill on a run pane.

**Per-job `after` (engine §1.1; UX labels):**

| Policy | UX label | Action | Never applies to |
|---|---|---|---|
| `keep` (default) | Keep it open | nothing by itself; omp stays interactive so the user can reply; subject to the cap below | — |
| `close_ok` | Close if it succeeded | `finished` only → wait `CLOSE_DELAY_S = 5` → `tern close <block>` | failed, timed_out, blocked, needs_input, cancelled; test runs; runs the user focused/opened (`focused==true` in the latest `ls`) |
| `close` | Close when done | any terminal state with a block → same close | test runs; `failed/no_response` (keep evidence); runs the user is currently looking at |

**M1 pane cap (R5, RF F9, RP P8).** An idle interactive omp costs 113-525 MB, so the host keeps at most **5 finished run panes** globally (engine constant `finished_pane_cap`; decisions R5 fixes the value). After a run's facts are persisted, and on every host tick, the host counts blocks that are ours (run marker), in a terminal state and still present in `tern_state()`; while the count exceeds the cap it closes the **oldest finished, unfocused** one (`ended` ascending; skip any block with `focused==true`; never `launching/running/needs_input` panes; never a block whose run has `needs_input` or no persisted facts). Closing sets `close_requested` first so §8.2 does not classify the vanishing block as `cancelled`, then records `pane_closed_at`. The run record, summary, cost and `session_file` stay; Open run resumes the session (§10).

Implementation: `tern.process.run({TERN, "close", block}, {timeout_ms=8000}, cb)`; `tern close` failing with "no such block" is success. Closing a block that is alone in its tab removes the tab (PR2: `stop` closed the tab); in a split it removes only the split (M2). A kept finished pane remains a normal agent (state `idle`), so the tracker must not re-open the run when the user later chats in it: runs in a terminal state are never re-evaluated. Kept panes are what keep Tern's session service alive with no window open (V28); the cap bounds that too, so the copy must not promise more than R20 says.

## 10. Open run / Stop / Run now

**Open run** (UX; window intent `open_run`, executed by the host; RC C22):
1. Block alive and ours (latest `tern_state()` says `live`, or `exited` but present, with the run marker): `tern focus <block>`. Verified form (PR2 test 1c).
2. Block absent / closed (cap, user, daemon restart): new tab in the **shown** session (user-initiated, may take focus), run cwd, resuming omp's session by the stored **`session_file`**:
```lua
{ TERN, "new", "tab", "--json", "--cwd", run.cwd, "--keep-open", "--",
  bins.omp, "--session-dir", run.dir .. "/session", "--resume", run.session_file,
  "--approval-mode", APPROVAL_CLI[run.approval],     -- explicit again, from the run's snapshot (the job may have changed)
  "--config", run.dir .. "/omp.yml" }               -- the same overlay as the run had (R7); plus --allow-home if the run had it
```
`--resume <value>` accepts "ID prefix or path, or the picker if omitted" (HELP, DOC:cli-reference); the path form needs no lookup assumptions, while `--session-dir` keeps new turns in the run's folder. `--model` is not passed (session restores its model [INFERENCE V23]); the preamble is not re-sent. `--resume` cannot combine with `--no-session` or a positional prompt-less goal; we pass no prompt. The resumed pane carries no run marker for scheduling purposes (it is a user session, never a tracked run). Row note per UX: "Resumed in a new tab. The original run record is unchanged." If `session_file` is nil/missing: "That run's session was removed, so it can't be reopened."
3. Run never launched (`blocked`, no block): no pane; UI shows the reason.

**Stop** (run in `running/needs_input`): Stop = `cancelled/user_stop` ("Stopped by you."), RC C23. **One Stop = host `tern close`** (works everywhere, no window, verified close semantics): the window sends `stop_run` (or the manager block calls the host directly); the host sets `close_requested=true` and `cancel_requested=true`, runs `tern close <block>`, records `cancelled/user_stop`. **Interrupt is M2**: `cx.agents:interrupt(block)` (window API; PR2 verified `stop(tostring(block))` closes the tab, so `stop` is never used) stops the turn but keeps the pane, with `cancel_requested` recorded **first** so the resulting `idle` is classified `cancelled`, not `finished`; it is a separate action beside Stop, not a renaming of Stop (V24: `interrupt` against a `working` omp).

**Run now** = the exact scheduled pipeline (preflight → ensure-session → launch → rename → track) with `trigger="manual"`; run id `r_<job8>_<epoch>_<rand4>`; `slot` per engine (`now`, RC C24). The window's `run_now` intent names an **existing job id** and runs with its stored settings (R10); a Test run of an unsaved draft is started from the host manager block (no intent can carry a draft). Differences from a scheduled run are only data: `how` text in the preamble, overlap/paused-all handling is the engine's decision (refused while all jobs are paused), placement/focus from the job unless **Test run** (forces Bring to front and `after=keep`, tagged `(test)`, text suffix only). A hands-off job's Run now never skips preflight or the hands-off hash gate. It uses the same launcher queue; two clicks queue, they do not race.

---

## 11. Failure table

`hint` = who is told; every row is a persisted run (never silent, PA §6). Codes are engine.md §7.4's (R12); user copy is ux.md's, shown here only to fix intent. Retry policy applies only inside `launching`; terminal states do not retry (engine's failure-streak pause handles repeated failures).

| # | Failure | Detection | Run state / reason code | User copy | Retry |
|---|---|---|---|---|---|
| 1 | `tern` binary not found | all §1 candidates fail `--version` | `blocked/tern_missing` | "Couldn't start: Tern's command-line tool wasn't found. Set its path in Settings." | none; re-resolve next fire |
| 2 | `omp` not found (no bare-`omp` fallback, R4) | all candidates fail `--version` | `blocked/omp_missing` | "Couldn't start: omp wasn't found." | none |
| 3 | `process.run` raises (`tern.process.run <program>: …`) | `pcall` | `failed/launch_error` | "Couldn't start: the tern tool couldn't run." | re-resolve binary once, retry once |
| 4 | Data dir unsafe chars / run dir not writable | gate §2.3 / `pcall(tern.fs.mkdir/write)` | `blocked/data_unwritable` | "Couldn't start: Schedule can't write its files." | none |
| 5 | cwd missing / not a folder / unreadable / unsafe / home not allowed | §5 preflight | `blocked/cwd_missing` (also not-a-folder, unreadable, own sentences), `cwd_unsafe`, `cwd_home` | "Blocked: ~/Dev/app doesn't exist." | none; job → needs fixing, one alert |
| 6 | Role absent from a role list that was read | §6 | `blocked/role_missing` | "Blocked: role @research no longer exists in omp." | none |
| 6b | Role list could not be read | §6 | **not a failure**: the run proceeds, `role_unverified` noted on the run | note on the run row | n/a |
| 6c | Hands-off confirmation hash (prompt, cwd, role) no longer matches | §7.1 | `blocked/hands_off_review` | "Blocked: this hands-off job changed. Review and confirm it in the manager." | none until re-confirmed |
| 7 | Daemon unreachable from CLI | `ls`/`new` stderr contains `no Tern is running` or `status ≠ 0` with that text | `failed/launch_error` | "Couldn't start: Tern's session service isn't reachable." | 2 retries, 15 s apart |
| 8 | `tern new tab` says `there is no session` | stderr (PR2 test 5) | not a failure: fall through to `new session` | — | immediate |
| 9 | `new session` fails because the name exists (race with user) | status ≠ 0 and a following `ls` shows the session | not a failure: redo as `new tab` | — | once |
| 10 | `tern new` timeout/non-zero, unknown cause | status ≠ 0 / `timed_out` | `launching` kept; before any retry run `tern_state()` and look for a block whose `command` contains the run marker (`/runs/<job>/<run>/`) | – | up to 2 retries 15 s apart; if the marker block exists adopt it (idempotent), never launch a duplicate; then `failed/launch_error` (`launch_timeout` if Tern never answered) "Couldn't start: Tern couldn't open a block." |
| 11 | stdout has no `"block"` | pattern fails | same as #10 | same | same |
| 12 | omp exits within seconds (bad flag, auth, role model retired, `--resume` conflict, version without a flag) | `exited != null`, elapsed < 60 s, never `working` | `failed/exited_early` | "Couldn't start: omp stopped right away: *<last line of screen>*" (`tern capture`, stripped, ≤120 chars); if text matches `unknown option\|unrecognized` → "…omp needs updating to receive the prompt."; if it matches `login\|sign in\|auth\|expired\|401\|403` → "…omp isn't signed in." (RF X8) | none |
| 13 | Prompt never delivered | no `working` within 180 s (`launching`/`running`) | `failed/no_response`, counts toward the streak, **pane kept**; with `delivery_error` → `failed/delivery_error` | "Couldn't start: the prompt wasn't delivered to omp." (capture tail classified as in #12) | none |
| 14 | Agent needs a human | `waiting_input` samples | `needs_input` (not failure) | "Waiting for you." (approval vs question needs M3) | n/a; continues until the user acts or the time limit; with no window open it waits silently (§8.4) |
| 15 | Time limit hit | omp exit near the limit, or host deadline + engine grace | `timed_out/max_runtime` (`waiting_for_input` if it was stalled) | "Stopped at the 30m limit. Last message: “…”." | none |
| 16 | Agent ended with an error | `exited` status ≠ 0, or `RESULT: FAILED - …` | `failed/agent_error` / `failed/agent_failed` | "The agent stopped with an error: *…*." | none |
| 17 | User closed the pane | block absent, no `close_requested`, no gap before it | `cancelled/closed_by_user` | "Closed by you." | none |
| 18 | Tern/daemon restarted mid-run | on host load: run in-flight and block absent **or present without the run marker** (restored login shell, RF F5), with a daemon/heartbeat gap | `failed/interrupted` | "Interrupted: Tern was closed while this run was in progress." | none; engine's catch-up policy decides about re-fire |
| 19 | Host plugin reload mid-run | VM reload | none: on load reconcile every in-flight run from the ledger + `tern_state()` (PR1 headline 9) | — | n/a |
| 20 | No window ever observes | no `obs`, block live | stays `running`, `observed=false` | "Running (not observed: no Tern window open)." | resolved by first window tick or §12 |
| 21 | Session JSONL missing/unreadable | §8.6 | run keeps its state; `cost=nil` | "—" cost | none |
| 22 | `tern rename` / `tern focus` fails | status ≠ 0 | cosmetic: ignored / for Open run falls to resume path | – | none |
| 23 | Placement degraded (M2) | no focused block (c/d) | run proceeds with fallback placement | "No pane to split beside, opened a tab instead." | n/a |
| 24 | Focus moved unexpectedly | post-launch `tern_state()` differs and not Bring-to-front | restore with `tern focus <prev>` | none | once |
| 25 | Finished pane closed by the cap (§9) | host-initiated, `close_requested` set | no state change; `pane_closed_at` recorded | none (Open run resumes) | n/a |
| 26 | OS notification fails | `osascript` status ≠ 0 | cosmetic; the in-app toast/segment still show it | – | none |
| 24 | Focus moved unexpectedly | post-launch `inspect` differs and not Bring-to-front | restore with `tern focus <prev>` | none | once |

---

## 12. Optional M3: omp run-reporter extension

**Why.** `cx.agents` observation needs an open window, cannot tell an approval prompt from a question, has only the per-turn cost line, and cannot report the omp session id/path directly (§8.4 "No window", §7.2, §8.6). An in-omp reporter writes lifecycle facts to a file the host reads on its own tick, independent of windows. Not required for v1 (AR "omp is used as-is").

**Loading.** Per run, zero install: `-e <tern.plugin.dir>/omp/reporter.ts` (HELP `-e, --extension`; explicit paths load even with `--no-extensions`, OC §1; `tern.plugin.dir` is the absolute, symlink-resolved package folder, PR2 test 7, so it may be `/private/tmp/...` for linked plugins). Run identity through env, because the plugin-flag mechanism is unproven: `/usr/bin/env SCHEDULE_RUN_FILE=<run>/report.json <omp> …` (§2.5 C). Events (DOC:extensions L483, L459, L548; used the same way by omp-pushover `src/index.ts:192-203`): `agent_start`, `agent_end` (`event.willContinue`, `event.isTerminal`, `event.messages[].stopReason`), `tool_approval_requested`/`tool_approval_resolved`, `tool_execution_start` (`toolName=="ask"`), `session_shutdown` (2 s budget). **Guards:** return immediately if `process.env.OMPCODE === "1"` (nested/sub omp, pushover `index.ts:19`) or `ctx.agent.kind !== "main"` or `!process.env.SCHEDULE_RUN_FILE`.

```ts
// <plugin>/omp/reporter.ts — sketch (types per omp://extensions.md)
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { writeFileSync } from "node:fs";
export default function (pi: ExtensionAPI) {
  const file = process.env.SCHEDULE_RUN_FILE;
  if (!file || process.env.OMPCODE === "1") return;
  const st: Record<string, unknown> = { v: 1, state: "starting", turns: 0 };
  const put = (patch: Record<string, unknown>, ctx: any) => {
    if (ctx?.agent?.kind && ctx.agent.kind !== "main") return;
    Object.assign(st, patch, { t: Date.now(), session_id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd });
    try { writeFileSync(file, JSON.stringify(st)); } catch {}      // never throw into omp
  };
  pi.on("agent_start", (_e, ctx) => put({ state: "working", turns: (st.turns as number) + 1 }, ctx));
  pi.on("tool_approval_requested", (e: any, ctx) => put({ state: "needs_input", wait: "approval", tool: e?.toolName }, ctx));
  pi.on("tool_execution_start", (e: any, ctx) => { if (e?.toolName === "ask") put({ state: "needs_input", wait: "question" }, ctx); });
  pi.on("tool_approval_resolved", (_e, ctx) => put({ state: "working", wait: null }, ctx));
  pi.on("agent_end", (e: any, ctx) => {
    if (e?.willContinue === true || e?.isTerminal === false) return;
    const last = e?.messages?.at?.(-1);
    put({ state: last?.stopReason === "error" ? "failed" : last?.stopReason === "aborted" ? "aborted" : "idle_done" }, ctx);
  });
  pi.on("session_shutdown", (_e, ctx) => put({ state: st.state === "idle_done" ? "exited_ok" : "exited" }, ctx));
}
```
Host consumption: each tick `tern.fs.read(report.json, 65536)` (write is non-atomic: decode errors are ignored until next tick) → authoritative `state`, `wait`, `session_id` (no §8.6 file hunting), and exact cost can be added with `ctx.sessionManager` cost fields once confirmed [INFERENCE V25]. `cx.agents` observation remains for `last_message` and as the fallback when the reporter fails to load (omp prints an extension error; `report.json` simply never appears ⇒ tracker falls back automatically, no new failure class). Risk: extensions run in-process; uncaught throws in raw timers kill the session, so the sketch uses no timers (OC note extensions.md L416).

---

## 13. M1 verification checklist

Run each once on the dev machine (they create ≤3 throwaway panes in a `SchedProbe` session, cleaned up with `tern kill session`; **isolated daemon** = `TERN_CONFIG_DIR` + `TERN_DAEMON_SOCKET`, as PR2 test 5). `[R]` = read-only. Ordered by **gate priority** (RF §6); V-numbers are stable cross-reference ids (V1-V27 kept, V28-V32 new), so the table is not in numeric order. "If false" = what breaks.

| Gate | V | Verify ([INFERENCE] source) | One-line experiment | If false |
|---|---|---|---|---|
| **G1** one half-day, isolated daemon, decides F1/F2/F5 | V26 (R21) | **Two-window session scope**: with two windows, are sessions daemon-wide? Does `tern new tab <SESSION>` accept a name as well as an id? | open windows A and B; `tern new session SchedProbe -- sleep 300` from A's pane, then `tern ls --json` and `tern new tab SchedProbe --json …` from B's pane; compare `shown`/visibility in both windows | per-window sessions: runs land in the first window; docs/Setup check say so (§4) |
| G1 | V28 (R20) | **Real-daemon lifetime with zero windows and kept panes**: does the daemon (and the plugin's host timer, `hot.hb`) survive after the last window closes while a `--keep-open` pane is (a) a live idle program, (b) an exited kept shell, (c) absent? | one window; `tern new session SchedProbe --keep-open -- sleep 3600`; close every window; wait 90 s; `tern ls --json` + `ps` + `hot.hb` advancing; repeat with `-- sh -c 'exit 0'` and with no pane | R20 copy ("keeps running as long as a terminal or run is still open") must change; Setup keep-alive row decides |
| G1 | V29 (R12, RF F5) | **Daemon restart restores panes as login shells**: block id and `command` after restart; does the run-marker check classify it as gone? | start a `sleep` pane via `tern new … -- /bin/sh -c 'sleep 600 # /runs/j_x/r_y/'`; restart the daemon; `tern ls --json` → `live`, `command`, `args` | marker rule (§8.2) needs another liveness signal |
| **G2** launch mechanics, decides S2 and §2.3 | V1 | Tern quoting: spaced paths survive; embedded `'`/`$`/newline/leading `-`/non-ASCII behavior (§2.4) | `tern new tab SchedProbe --json -- /bin/echo 'a b' "it's" '$HOME' '-x' 'é'` then `tern inspect --json` → `args[2]`; and `tern new … -- "<omp>" --session-dir "<D>/x y"` with spaced path; also `tern.fs.exists` on a dangling symlink | §2.3 contingency / stricter gate |
| G2 | V4 | `--keep-open` keeps the pane after omp exits 0; `tern close` closes it | `tern new tab SchedProbe --json --keep-open -- sh -c 'exit 0'` → `tern ls --json` shows block with `exited` set; `tern close` | pane vanishes with the evidence; R5 cap and classification break |
| G2 | V7 | `@file` + fixed positional auto-submits and the model sees the file content (and how it's inlined) | tiny run (`--model @tiny`) with `prompt.md` = "Reply with exactly: pong"; read session JSONL first user message | pointer-form contingency (§2.3) |
| G2 | V8 | `@<path with spaces>` attachment works | same with `prompt.md` under `…/Application Support/…` | needs a space-free run dir |
| G2 | V30 (R10/R23) | **`cx:new_block` from a palette command opens the host manager with draft args** (spike first); also multi-line `textfield` and `prefs` inside a host block (architecture.md owns those two; run in the same sitting) | palette command → `cx:new_block{block="schedule.manager", args={draft={name="x"}}}`; read the args in the block's `init(cx,args,saved)` | no "New job" from the palette; one-line prompt field + `ctrl+o` fallback (decisions R23) |
| **G3** tiny role, < $0.05 total | V6 | `--append-system-prompt <path>` reads the file | tiny run: preamble file says "reply with exactly ZETA"; prompt "what is your instruction?"; or `--export` the session and grep | prepend the preamble to `prompt.md` (§3) |
| G3 | V2 | All §2.2 flags accepted by the resolved omp (18.8.6 vs 18.9.1) | `<omp> --help \| grep -E -- '--(model\|approval-mode\|max-time\|session-dir\|append-system-prompt\|config\|allow-home\|extension\|resume)'` for each candidate binary [R] | the §1 version check blocks the run |
| G3 | V14 | `--config` overlay with `ask.enabled:false` unregisters `ask` | tiny run with overlay asking the agent to call `ask`; expect no such tool | Hands-off stays "may ask"; copy changes |
| G3 | V5 | A newly created session does not become the shown one | `tern ls --json` shown flags before/after `tern new session SchedProbe2 …` | focus guard (§4) fires |
| G3 | V15 | `--max-time` expiry: exit vs idle, status, message | `omp --model @tiny --max-time 5 …` with a prompt that sleeps via bash (`sleep 60`) in a SchedProbe pane; read `tern ls --json` `exited` | engine O3 rule |
| G3 | V16 | Host `pane_exited.pane` equals the `block` id from `tern new` | host log of `ev.pane` vs `block` for a `sh -c 'sleep 3'` block | accelerator only; none |
| G3 | V17 | Daemon start time exposed (to tell restart from user close) | **Answered (RF F5): `tern inspect --json` has no start time.** Use the heartbeat gap + run marker (§8.2) | n/a |
| G3 | V18 | JSON of `exited` for a finished block | `tern ls --json` after V4 | §8.2 `exited` tests |
| G3 | V3 | `tern ls --json` with no sessions | isolated daemon: `tern ls --json; echo $?` [R] | §2.1 text fallback |
| G3 | V12 | `/bin/test -d/-x/-e` exit codes for missing / file / permission cases (§5 step 2) | host-plugin test log of the three cases | classification text |
| G3 | V20 | Layout under `--session-dir` | run tiny omp with `--session-dir /tmp/sd`; `find /tmp/sd` | §8.6 locate step |
| G3 | V21 | `tern.process.run({"/usr/bin/tail","-c","1048576",f})` returns the full 1 MiB of stdout | host test on a 2 MB file | cost needs chunked reads |
| G3 | V22 | JSONL field names for cost; sub-agent cost location | `grep -m3 '"cost"' <session>.jsonl`; run a prompt that uses the `task` tool and compare | cost `—` |
| G3 | V23 | `--resume <path>` restores model/cwd, accepts `--session-dir` and `--config` | `<omp> --session-dir /tmp/sd --resume <file> --approval-mode write --config <omp.yml>` in a SchedProbe pane | Open run copy changes |
| G3 | V27 | End-to-end happy path | one tiny scheduled run: launch → `running` → `finished` with summary `RESULT:` and cost within 60 s, with zero windows closed and with one open | M1 not shippable |
| **G4** in `/tmp`, S4/S5 | V31 (R7) | **Overlay beats project config**: with a repo `.omp/config.yml` containing `tools: {approval: {bash: allow}}`, an `omp --approval-mode write --config <omp.yml>` run still prompts for a shell command; the exec-tier key names are right | `/tmp/ov/.omp/config.yml` hostile; run tiny omp with the §7.2 overlay, prompt "run `echo hi`"; expect an approval prompt (`waiting_input`); repeat without the overlay to see it run | "Ask before commands" can be widened by a repo; the setting must carry a warning or the mode must change |
| G4 | V32 (R8) | The argv-form `osascript` shows hostile text literally and runs nothing | `notify('x" & (do shell script "touch /tmp/pwn") & "', '-t')`; expect a banner with that text and no `/tmp/pwn` | notifications disabled |
| **M2** | V9 | Allowed `--tools` names and read-only effect (Read-only stays hidden until this passes) | `<omp> --tools read,grep,glob,web_search,todo --mode json -p "list your tools" --model @tiny`; compare with the tool list in `omp --help` | Read-only never ships |
| M2 | V10 | `tern split` focus behavior | `tern split <sleep-pane> right --json -- sleep 30` then compare `tern_state()` focus before/after | split placement (R23) |
| M2 | V11 | `tern pip` on a fresh split | `tern pip <new-block> --corner br` on a two-block tab | PiP placement |
| M2 | V24 | `cx.agents:interrupt(block)` stops the turn, pane stays, state → idle | window probe on a tiny run | Interrupt action |
| M2 | V19 | `tern wait --until idle=20000` on an omp pane | `tern wait <omp-block> --until idle=20000 --timeout 60` after the reply is done | window-less finish hint |
| **M3** | V13 | `omp worktree add -C … -b … --json` semantics | `omp worktree add --help`; dry run in a temp repo | worktree isolation |
| M3 | V25 | Cost/id accessors in extension ctx | read `omp://extensions.md` `ctx.sessionManager` and log in a probe extension | reporter cost |

Decisions that depend on engine.md (now written): the run-record field names this doc uses (`started`, `ended`, `busy_seen`, `observed`, `close_requested`, `cancel_requested`, `session_file`, `pane_closed_at`, `cost_approx`) and the reason codes listed in the Revision 2 note. engine.md owns them; this doc cites them.
