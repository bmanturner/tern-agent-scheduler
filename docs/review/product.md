# Product review: Schedule (tern-schedule) design dossier

Reviewer: ReviewProduct. Read-only. Docs reviewed: architecture.md (AR), ux.md (UX), engine.md (EN), launch.md (LA), research/*. Severity: **blocker** = cannot ship v1 as specified / contradicts a user requirement; **major** = user-visible failure or large rework if found late; **minor** = polish/consistency.

`tern plugin install SRC` / `tern new --help` were read (read-only) for two findings below.

---

## 0. Findings index

| ID | Sev | One line |
|---|---|---|
| P1 | blocker | Headline availability copy ("even with every window closed") contradicts AR's own contract that the daemon exits when no window and no live program remain |
| P2 | blocker | Flagship "Morning repo digest" example is Read-only, which launches omp with a tool allowlist that has no shell, so it cannot run `git log`/`gh` |
| P3 | blocker | M1 as written ships no run observation (M2), so after "Run now" or the first fire the user cannot tell if it finished, failed, or needs them; "last outcome", history, and needs-you are all M2 |
| P4 | major | `tern` commands act on **one window's** sessions (first window by default); design assumes sessions are daemon-wide (LA V26 unverified) so "Schedule session" and "tab in the current session" can land in the wrong window |
| P5 | major | Needs-you / OS notification promised with no window open (UX §5.1) is impossible per EN §7.3 line 688 |
| P6 | major | Onboarding example "Nightly test sweep Daily 02:00" can never run on a laptop under the 3 h catch-up default |
| P7 | major | Name collision: palette group, manager tab and run session are all "Schedule"; the run session is invisible unless the user finds the session switcher |
| P8 | major | Interactive `omp` panes never exit; "Keep it open" default + retention cap only in M3 means live agent processes accumulate from day one |
| P9 | major | Role contract is inconsistent across UX/EN/LA (pinned model field missing; roles-unreadable behavior opposite; role ordering and hidden-role lists differ) |
| P10 | major | Form implementation (hand-rolled text/multiline editing in a host `prefs` block, 17 fields) is the largest unverified M1 item; opening a host block from a window command is unverified (TP open question K) |
| P11 | major | Default approval `write` stalls most real jobs under "Needs you"; the only escape the UX copy points to is Hands-off; omp has no remember-approval path in the design |
| P12 | major | Default cwd fallback `$HOME` (EN §1.1) creates a job that LA §5 then blocks at every fire (`cwd_home`), with no `allow_home` field in the schema |
| P13 | minor | UX/EN/LA disagree on defaults and states in several smaller places (placement example JSON, Q&A on run states, prompt delivery, `[quiet]` vs `RESULT:`) |
| P14 | minor | No install/distribution/uninstall story; no "what happens to my jobs if I remove the plugin" |
| P15 | minor | Copy gaps: `cwd_unsafe`, `allow_home`, "not observed", "caught up" burst, Carly/draft first-use |

Detail follows. Sections 1-5 are the five requested deliverables; findings are inline under the section that exposes them.

---

## 1. Requirement trace

| Req | Where satisfied | Verdict / gaps |
|---|---|---|
| (a) menu to CRUD scheduled prompts | UX §2.2 palette group (11 cmds), §3 manager block (list/detail/form), §3.4 keys: `n` new, `e` edit, `d d` delete + `u` undo, `c` duplicate, `space` pause. EN §1 schema, §2 store. | Complete on paper. **Gap P10**: opening the host-side manager from a window palette command via `cx:new_block` is not probed (TP open question K; AR line 55 asserts it). No M1 spike item for it in LA §13. |
| (b) time via cron-style input | UX §4.3 one field accepts presets / intervals / one-shot / 5-field cron / `manual`; live preview with next 3 dates and plain-English reading; DST + DOM/DOW-OR warnings. EN §3 + tested `cron.luau`/`schedule.luau`. | Strongest part of the dossier. Minor: an `every 2h` job's first fire is at save + 2h (EN §3.3), but the UX preview (§4.3) shows only "Every 2h" generic copy; the preview must print the first fire time or users will think it runs now. Also UX examples in `job_add` doc (§2.5) use `every 15m (min 5m)` consistent with EN D5. |
| (c) set the prompt | UX §4.1 row 2 (inline multi-line editor card or `ctrl+o` `.md` file), §2.6; EN D9, `prompts/<id>.md`. LA §2.3: delivered as `@prompt.md` attachment + fixed positional. | Satisfied. **P13**: AR/EN §0.3 say the prompt is the final argv element after `--`; LA §2.3 rejects that and uses a file attachment with the fixed sentence "Run the scheduled job described in the attached file." EN §0.3 needs to adopt LA (this also resolves EN O1). Risk: the fixed positional is visible as the first user message in every run pane; users reading a run see that sentence, not their prompt; the TUI shows the attachment, which is acceptable, but add to UX §5.6 so Open run explains it. |
| (d) omp role, default `@default` | UX §4.1 row 5 default `@default`; §4.4 picker from `omp config get modelRoles`; EN §1.1 stores `"default"`, emits `--model @default` (EN line 53, LA line 118). | **Literally `@default` everywhere user-visible and in argv: yes.** Stored value is bare `default` (EN), prefix added at launch (LA §6). Not a bug but must be one rule: store bare, display/emit with `@` (UX line 69, 247, 344 already comply). **Gaps (P9)**: (1) UX §4.4 "Other model…" pinned model has no schema field: EN `role` regex `^[%w_%-]+$` rejects `anthropic/claude-sonnet-5-5:low` and LA §6 says "stored value is the bare role name". Either cut "Other model…" from v1 or add `model` field. (2) Roles unreadable: UX §6.2/§7.5 "Jobs will use @default" vs LA §6/§11 `omp_error` → blocked, nothing launches. Pick blocked (honest) and fix UX copy. (3) Ordering: UX `smol, default, task, plan, slow`; LA `default, smol, slow, plan, …`. (4) Hidden roles: UX hides `commit memory tiny vision advisor`; LA keeps them. (5) Roles are per-cwd in LA (project overlay) but UX/EN cache one global list for 30 min; the form's role list must key on the Folder row. (6) On this machine `@default` = `claude-opus-5-5:medium` (LA §6), the most expensive role, as the default for unattended recurring jobs. The role row hint shows the model; add a cost-aware nudge ("`@smol` is usually enough for digests") on the examples (set examples to `@smol`). |
| (e) configurable cwd | UX §4.5 (fixed folder, picker over open panes / recent / typed path, git hint, remote refused); LA §5 preflight (exists/dir/readable/home/unsafe chars). | Satisfied with gaps **P12**/**P15**: EN §1.1 default falls back to `$HOME`, which LA §5.3 blocks unless `allow_home`; `allow_home` is not in the EN schema or the form. Folder paths containing `' " \ ` $ !` are refused at fire time (`cwd_unsafe`, LA §2.3) but UX has no validation copy for them; a user with `~/Bob's Projects` gets a blocked run at 09:00 instead of a form error at save. Validate at save with copy: "Folders with quotes or $ in the name aren't supported yet." Worktree isolation is deferred (UX Q5); acceptable, the git-dirty warning exists. |
| (f) configurable placement of the agent's block | UX §4.6 four options + bring-to-front switch; EN `placement`/`focus`; LA §4 realization table. | Partially real. Verified: Schedule session (a), background tab here (b), bring-to-front (e). **Unverified**: split (c, LA V10), pip (d, LA V11). UX §4.6 lists all four in the M1 form while LA ships (c) in M2 and (d) in M3. Ship M1 with the two verified options + front switch; show split/pip only when their V-items pass (do not show disabled options with explanations). Also **P4**: placement (b) means "the session shown" in *which window*? See P4. |
| (g) anything else good for UX | UX: empty-state examples, first-run "Run it now and watch?", Test run, status segment, tab badges, quiet success, catch-up, auto-pause after failures, Carly draft-for-review, setup check, undo delete. | Rich, arguably too rich for v1 (§4 of this review). Missing high-value items: see §3 table (per-job missed-run toggle is in; worktree, "continue previous session", share/export are out). |
| (h) Tern-native, polished, end-user friendly, single plugin | AR "One Tern plugin, both halves, no omp extension"; UX uses `prefs`, `list`, `picker`, `overlay`, chrome status segment, Carly exports; voice rules from tern-rss. | Single plugin: yes. Tern-native: yes in surface. Weak points: **P1** (honest availability), **P4** (multi-window correctness), **P14** (no install story), and the run pane is a plain omp terminal, so "results" are scrollback in a tab nobody opens (see §2). |

---

## 2. First-hour walkthrough (new user, install → first fire → reviewing the result)

Assumes Tern 0.7.2, plugin not yet installed, user knows only "there's a Schedule plugin".

| # | Step | What the spec says | Friction / gap |
|---|---|---|---|
| 1 | **Install** | Nothing. UX/AR have no install section. `tern plugin install github.com/OWNER/REPO` exists (read from `tern plugin --help`); `tern plugin link DIR` for dev. | **P14 (minor)**: add README/Setup text with the one-line install, minimum Tern version, and a plugin manifest `description` shown by `tern plugin list`. Setup check row "Tern version ≥0.7.2" cannot run on an older Tern that rejects the plugin first. |
| 2 | **Discover** | Palette group "Schedule" (11 commands), chord `ctrl+alt+shift+s`. Status segment is **hidden while there are zero jobs** (UX §2.3). | New user has no cue a plugin exists. Recommend: on first plugin load, a single `info` toast "Schedule is ready. Press ctrl+alt+shift+s" (once, kv flag). Palette titles are good ("Schedule: Open manager"). Chord collisions: user's other plugins already use `+k/+n/+h`; the dossier checked that, good. |
| 3 | **Open manager** | Opens "in a new tab named Schedule". Empty state with 3 examples, disclosure line, `⏎ use example`. | **P7**: the tab is called "Schedule" and the *run session* is also "Schedule" (UX §4.6, EN `session_name`). In the session switcher the user sees a session "Schedule" that contains run tabs but not the manager (unless they happen to open the manager there). Decide one home: **manager = tab 1 of the "Scheduled runs" session** (recommended, §5 D3) so the user has one place to go for everything, or rename the run session to something that cannot be confused with the manager ("Scheduled runs"). |
| 4 | **Disclosure** | "Jobs run while Tern is running, even with every window closed. Nothing runs while your Mac is asleep or after a restart until you open Tern…" | **P1**: AR "Availability contract" says the daemon "exits when no window is attached and no program is live". So quitting/closing Tern's last window ends the clock unless a live program (a kept-open run pane, an idle shell) exists. The copy tells the user closing windows is safe; it usually is not. Replace with: "Jobs run while Tern is open. Closing every window may stop them unless a terminal or run is still open." Add a Setup row "Keep Tern running" (and an `inspect` probe at load that warns "no live program: the scheduler will stop when the last window closes"). LA §13 needs a V item: close all windows on the real SMAppService daemon (PR2 test 5 used an **isolated** daemon, not the production one) and check the clock survives. |
| 5 | **Pick an example** | "Morning repo digest: weekdays 09:00, reads only" opens the form pre-filled; folder = focused pane cwd. | **P2 (blocker)**: Read-only = `--approval-mode always-ask --tools read,grep,glob,web_search,todo` (LA §7.1). No shell tool, so "merged PRs, new commits, open PRs" (prompt text UX §6.1) cannot be produced (`git log`, `gh pr list`). The first example would "succeed" with an apology message. Fix: example approval `Ask before commands` (and honest label "asks first"), or define Read-only as write-mode + `tools.approval.bash: allow-readonly` if omp supports it (OC §6 lists `bash.patterns` allow/deny/prompt; unverified), or drop the git/PR wording from the prompt. Also unverified tool names (LA V9). |
| 6 | **Fill the form** | Single `prefs` page, 5 sections, 17 fields, 4 advanced folded. Prompt via in-block multiline editor or `ctrl+o` file. | The visible fields are reasonable (Name, Prompt, When, Folder, Role, Where, Approval, Stop after, After, Tell me, Active) but still **11 decisions** for a first job; a new user needs ~4 (prompt, when, folder, approval). Fold Where/Stop after/After/Tell me into "More options" with sensible defaults for v1. **P10**: multiline editing in a host block is hand-written (TP point 9: `editor`/`input` display-only; UX relies on swarm's `textfield`, UTF-16 cursor). That is days of work and the main M1 risk. See §4 for a cheaper M1. Name: placeholder = slug of the prompt, Tab accepts; fine. |
| 7 | **When field** | Live 3-line preview, presets picker `ctrl+p`. | Good. Missing: say first-fire time for intervals (see §1b). `ctrl+p` may collide with Tern/terminal bindings in a block; unverified. |
| 8 | **Save** | `ctrl+enter`; toast "Saved daily-review / next Mon 12 Oct 09:00". Then **the "Run it now and watch?" overlay** (UX §6.3). | Good flow. Copy bug: the overlay says "You'll be taken to the run." Taking focus away from the manager the moment the user saved is a legitimate user-initiated action; fine. But the first run in `write` mode will stall on the first shell command (P11): the user sees an omp approval prompt in a pane they have never seen before; nothing tells them what the pane is or how to get back to the manager. Add a one-line banner in the manager Detail while a test run is going: "Watching test run. Press ctrl+alt+shift+s to come back." |
| 9 | **First approval stall** | Needs-you detection requires a window observer (EN §7.3). Test run is brought to front so the user sees it. Toast "Looks good. Next run Mon 09:00 / Approval prompts? Edit › Approval". | **P11**: the only remedy surfaced is changing Approval. The Claude Desktop recommended path (PA §5.5: run once, approve, "always allow") is absent: omp has no persistent per-job allowlist in the design. Users will conclude "to make this stop asking I must pick Hands-off", i.e. the design funnels them into the unsafe mode. Mitigation for v1 without new omp features: Approval mode `Ask before commands` + per-job `--config` overlay `tools.approval.bash: allow` for patterns user lists (e.g. `git`, `gh`, `npm test`); or at minimum tell them in the empty state that unattended jobs that run shell commands should use Hands-off on a trusted folder, with the consequences, instead of implying the stall is a one-off. Decide in §5 D1. |
| 10 | **Leave** | Switch to other work. Default placement: Schedule session, background; nothing visible. | The user can now close the Tern window. See P1. If the laptop sleeps overnight, see P6. |
| 11 | **First scheduled fire (09:00 next day)** | Tab `⏲ daily-review` appears in the Schedule session; status segment `daily-review · 4m`; no toast (quiet). | Intentional quietness, but a new user gets **no signal at all** that something ran. First-ever scheduled (non-test) run should toast once: "daily-review started in session Schedule" (kv flag, never again). |
| 12 | **Needs-you while elsewhere** | Toast + `⚠` tab badge + status segment `1 needs you · deps-audit` + OS banner; `ctrl+alt+shift+a` jumps there. | OK **only if a window is open** (P5). With no window: nothing detects `waiting_input` (EN §7.3 line 688) yet UX §5.1 last row promises OS notification. Either (a) have the host poll `tern capture` for the omp approval-prompt marker (unverified) or (b) say plainly in the copy that approvals can only be noticed while a Tern window is open, or (c) default no-window runs to a mode that never asks. Also a toast has no buttons (UX §2.1); a 5 s toast at 09:00 while the user is in another app is invisible; the OS banner is the only real signal and is a default-on switch dependent on `osascript` (unverified from the host; the window half sends it?). Say which half sends it. |
| 13 | **Overnight: reviewing the result next morning** | Manager list shows `✓ Fri 09:03 · $0.42` plus first-line summary; Detail has run history with last message (≤12 lines on `m`); Open run focuses the kept pane or resumes the session. | This is the weakest part of the product experience. Results exist only as (1) a ≤80-char line in the list and (2) the live omp pane. Gaps: (i) with no window open at fire time the run is "running, not observed" until a window opens, then flips to `finished late=true` (LA §8.3). A user opening Tern at 08:30 after a 09:00 slot the previous day sees "running 23h" or a late flip; copy for this state is missing. (ii) The summary depends on omp obeying a `RESULT:` line (LA §3) or the session JSONL schema (V22, unverified); fallback is "first line of last message", usually a preamble sentence, not a summary. (iii) There is no "unread results" concept (ChatGPT/Codex inbox) so a result the user has already seen is indistinguishable from one they have not. Add: `✓ ●` unread dot cleared when the run is opened; status segment `2 new results` (muted) instead of silence when `notify=issues`. (iv) No way to read the full final message without opening the pane (≤12 lines expand). Allow "Copy last message" and "Open prompt/transcript file". |
| 14 | **Open run the day after** | Pane kept alive (default) → `tern focus`; else new tab with `omp --resume`. | **P8**: day-after, panes are alive only if never closed; with the default Keep-open, M1 has no cap (cap 30 in LA §9 is M3), so 5 daily jobs = 35 live omp processes after a week, each holding memory and keeping the daemon alive indefinitely. Default `After = Close if it succeeded` (summary + session id are saved first, Open run can `--resume`) or implement the keep-last-N cap in M1 (it is ~20 lines). Also `omp --resume` against `--session-dir` is unverified (LA V23). |
| 15 | **Mac sleeps** | Catch-up: once if <3 h late. | **P6**. Also "Missed" rows say "Tern wasn't running or your Mac was asleep": OK. |
| 16 | **Something breaks** | Failures toast + OS banner; auto-pause after 3 failures; Setup check; scheduler-stalled segment. | Good. Add a "Copy diagnostics" action in Setup sheet (versions, resolved paths, last 20 events) so a user can report problems. |

### Dead ends and confusing copy found in the walkthrough

1. "Schedule" ×3 naming (P7).
2. The disclosure sentence (P1) and "Details" link goes where? UX §3.5 shows `Details` with no target.
3. UX §6.3 overlay says "Run it now and watch?" for jobs saved as paused/manual too; for a `manual` job, the first Save → overlay is right; for a job saved with Active off, running it contradicts the user's intent: skip the overlay when Active is off.
4. "Test run" vs "Save & run now" vs overlay "Run now and watch": three near-identical verbs. Collapse to two: **Save** and **Save & run now** (which is always the watched first run), and keep "Test run" out of M1 (see §4).
5. Status segment label "failed" vs History "✗"; vocabulary list (UX §0) says use "needs you", but the Needs-you section also holds "needs fixing" jobs (UX §3.2), two meanings in one header.
6. `hands-off` is jargon: "Never asks" in the picker, with `yolo` hidden. UX does this correctly in §4.7; keep it.
7. `P1`-class: "Tern's background service exits when no window is attached…" appears in UX §6.4 as Settings fine print, but the primary disclosure contradicts it.

---

## 3. Prior-art gap check

### 3.1 §5 ranked patterns

| PA §5 | Covered? | Where / notes |
|---|---|---|
| 1 Fresh session per run + inbox with skipped runs and reasons | **Covered** (history incl. skip/missed with sentence; fresh pane per run) | UX §3.2/§5.5, EN §7. **Missing: the inbox half**: no unread state (see §2 step 13). New pane per run = fresh session: yes. |
| 2 Presets-first + cron escape + NL + one-shot + live preview | **Covered, strongest** | UX §4.3, EN §3, tested. |
| 3 Explicit single catch-up policy, per job | **Covered** | EN D6, UX §4.9. Default window 3 h is the issue (P6). |
| 4 Overlap skip/fold + global cap | **Covered** | EN D7, §6.2-6.3, cap 2. |
| 5 Per-job approval + Run now → approve → remember + loud stalls | **Partly**: approval per job, needs-you, first-run overlay; **"remember" missing** (P11); stalls loud only with a window (P5) |
| 6 Worktree isolation toggle | **Deliberately excluded** (UX Q5, EN §1.1 "not fields", LA §5 → M3). | **Justified** for v1 (needs retention machinery; breaks node_modules/.env). But PA §6 "running against live checkout" mitigation is only a hint line; make sure the dirty-checkout hint is shown on the **detail** view and at Save, not only on the form (UX has it only at §4.5). |
| 7 Delivery target / placement first-class | **Covered** (placement + bring-to-front); "continue previous session" **excluded** (EN "not fields"). Justified: Open run `--resume` covers it; revisit if users ask. 2 of 4 placements unverified (see §1f). |
| 8 Quiet-success mode | **Covered** (`quiet_ok`, notify=issues default). Marker disagreement: UX/EN use bare `[quiet]`, LA uses `RESULT: [quiet]` (P13). Cut `quiet_ok` from M1 (advanced, off by default). |
| 9 Job = file on disk | **Partly**: prompts are `.md` files in plugin data; EN `prompt_source="file"` for repo-owned prompt is in schema but UX §2.6 has no UI for it. Cut `prompt_source=file` from v1 or add a "Use a file in the repo" entry. |
| 10 Stagger/jitter | **Excluded** (EN "not fields"): justified (single user, local). Note the top-of-hour 09:00 collision is handled by cap + 30 s catch-up spacing only for catch-ups; two jobs at 09:00 both start at once under the cap of 2: acceptable. |
| 11 Safety rails: no chained automations, preflight, create-paused canary, pause-all | **Covered** (Carly no self-edit, preflight blocks, Active switch, Pause all). |
| 12 Failure handling modest: streak → auto-pause, notify once | **Covered** (EN §6.5). Retry-once for provider errors is excluded; justified. |
| 13 Resolve role at fire time, record resolved model | **Covered** (UX §4.4 hint; EN ledger `model`). Needs `cx.agents` model (window-only) so unobserved runs lack the model; note in "not observed" copy. |

### 3.2 §6 pitfalls

| PA §6 pitfall | Status |
|---|---|
| Silent stalls / dead scheduler | Covered: heartbeat + "scheduler stalled · last tick 4m ago". |
| Catch-up bursts | Covered: ≤1 per job, 30 s spacing. |
| Permission stalls | Partly: needs-you needs a window (P5); no approval timeout (UX: run ends at max-time). |
| Failures hiding evidence | Covered: never auto-archive; `--keep-open`. Weakness: Close-when-done option closes failed `blocked` rows? LA keeps evidence; fine. |
| Green ≠ success | Covered: `RESULT:` line + `RESULT: FAILED`. Depends on the agent obeying a system-prompt suffix; document as best-effort. |
| Process leaks | **Partly**: `--max-time` + host deadline; but kept interactive panes after a **finished** run never exit (P8). |
| Pile-up | **Missing in M1** (retention M3; P8). |
| Running against live checkout | Hint only. |
| Timezone/DST | Covered (local zone only, preview warnings, tz recorded). IANA per job excluded (no Luau API): justified. |
| Unattended + full access | Covered: Hands-off confirm, badge, Carly can't set it. |
| Run-now bypasses pipeline | Covered (EN D10). |
| Duplicate names | Covered (stable ids, unique slug). |
| Edit-not-supported / hidden auto-created tasks | Covered (edit always; Carly = draft). |
| Model drift/retirement | Partly: role resolved at fire; resolved model recorded **only when observed**. Preflight blocks missing roles but not retired models (LA §6 admits). |
| Hard-coded app-must-be-open | **Contradicted by copy** (P1). |
| Jitter surprising users | N/A (none). |

### 3.3 Missing from the design (not in PA §5 ranking but common in the products surveyed)

- **Unread/inbox** (ChatGPT/Codex Scheduled view). Add `unread` flag per run; cheap.
- **Per-job cost cap / monthly spend visibility**: UX shows `$0.42` and a monthly total in Detail; there is no limit (omp has only `--max-time`). State plainly in Settings: "No spend limit; use Stop after". Fine, but an expensive `@default` Opus job every 5 minutes (`every 5m`) is allowed; either raise the interval floor for non-`@smol` roles or show estimated cost per day when the schedule is `<1h`. Optional v1.1.
- **First-class "why didn't it run?"** answer: covered by history sentences and Carly; good.
- **Export/backup**: jobs live only in `plugin-data`; EN has `.bak`. A "Show data folder / Export jobs" button is missing; cheap and matters for plugin removal (P14).
- **Count limit**: EN `max_jobs 50`; fine.

---

## 4. Scope sanity

### 4.1 Is M1 shippable and small?

AR M1 = "cron/schedule module with tests; store + ledger; host clock; CLI launcher with dedicated session; manager block (list, detail, form); palette Open manager/New job." Problems:

1. **P3 (blocker)**: M2 holds "window run tracking (state, needs-you, finished, last message, cost line), status segment, tab badges, toasts, Open run, run history with skip/missed reasons". The M1 manager list and detail wireframes, however, are built around last outcome, history, running/needs-you sections. Without M2 the list shows "never run" forever (ledger only records launched/failed-to-launch), and a user cannot learn that a run finished or stalled. M1 is "fires panes into a session nobody watches". It is not lovable and arguably not shippable.
2. The M1 form is the single biggest block of unverified UI work (P10): hand-rolled multiline editing, 17 rows, pickers in a host block with no `cx`, advanced section, validation, dirty-cancel, draft persistence. LA §13 lists 27 verification items (V1-V27) tied to M1; many (V1 quoting, V4 `--keep-open`, V7 attachment auto-submit, V15 `--max-time` exit) gate the launcher itself.
3. The engine spec has ~1,300 lines with tested pure modules: this part is in good shape and is the right M1 foundation.

### 4.2 Proposed tighter M1 ("minimum lovable v1")

Goal: one fully working loop: **create → it fires → I can see it ran / needs me / failed → I can open the result**.

**Keep in M1 (all required to close that loop):**
- Engine as specified: cron/schedule/policy, store, ledger, host clock, preflight, overlap skip, cap, single catch-up, pause-all, auto-pause.
- Launcher with two placements (Schedule session, background tab here) + Bring-to-front switch, `@file` prompt delivery, absolute-path resolution, `--keep-open`.
- Window observer for **needs you / finished / failed + last message** (the minimal slice of M2), the status segment (needs-you, failed, running, next), toasts for needs-you and failed, OS banner for needs-you/failed, Open run (focus or resume), and run history with reasons in Detail.
- Manager: List (Needs you, Running, Upcoming, Paused), Detail with history, and a **form with 8 rows**: Name, Prompt (one-line field + `ctrl+o` opens the `.md`), When (with live preview), Folder (picker over open panes + typed path), Role (picker), Approval (3 options: Read-only deleted until its tool list is verified: Ask before commands default, Ask for everything, Hands-off), Stop after, Active. Everything else is a default in Settings (not per-job).
- Actions: Run now, Pause/Resume, Delete (two-press + undo), Duplicate (cheap, reuses form), Pause all.
- Palette: Open manager, New job, Run a job now, Go to run that needs me.
- Setup check (omp found, roles readable, scheduler heartbeat, availability note).
- Empty state with examples (fixed per P2/P6).
- First-run "Run now and watch" overlay (cheap, valuable).

**Defer (post-M1):**
- Split + PiP placements (unverified, lowest value, user-visible only as an option).
- Test run (use Save & run now), "Tell the agent nobody is watching" and "Quiet when nothing to report" toggles (keep unattended preamble always on; drop `[quiet]`/quiet success), `If still running` options (ship skip only), `If missed` per-job choice (ship the global 3 h default as a Settings value), per-job notify levels (ship `issues` only), per-job After-run policy (ship global default + retention cap), `prompt_source=file`.
- Carly exports (all of §2.5; ship only `jobs_list` if anything), Quick add, "Edit a job's prompt file" palette command, Recent runs palette picker, Stop-a-running-job picker (the manager has Stop), tab-title badges / `color_tab` (needs run-table↔tab mapping, marked INFERENCE in UX §2.4), `caffeinate` setting, extra PATH folders setting, settings sheet beyond 6 rows, right-click context menu, filter `/`, width tiers beyond 2.
- Optional omp reporter extension (already M3).
- Worktree isolation.

This trims roughly half the UX surface while keeping every user requirement (a-h) satisfied at the base level (placement is configurable among the two verified options + bring-to-front).

### 4.3 Over-engineering to cut or defer (specific)

| Item | Where | Recommendation |
|---|---|---|
| Intent-file protocol for window→host (create/update/delete/…) | EN §2.3 | Needed for palette commands and `obs`; but the manager block lives in the host VM, so only palette (run-now, focus, pause-all) and obs need it. Keep kinds `obs`, `run_now`, `focus`, `pause_all`, `settings` only; the form needs none. |
| 15 s tick + 2 s pump + 3 s observer poll + 10 s `tern ls` + 5 s window poll | EN §0.3, §5; LA §8 | Four overlapping cadences. Collapse: one 15 s host tick (due + liveness), one 3 s observer poll only while runs are in flight. |
| `snapshot.json` + kv `hot.rev` + file polling | EN §2.4 | If the window needs state for the status segment, kv `hot` alone (≤1 KB) is enough for M1; `snapshot.json` only when a window-side list is needed (Carly, palette pickers). Palette pickers can read `snapshot.json` lazily on invocation instead of a rev poll. |
| Four-level DOM/DOW + DST test matrix | EN §4, tests | Already built and tested; keep. |
| `.bak` + `.corrupt` + format guard on 4 files | EN §2.2 | Reasonable for the scheduler's state. Fewer files: merge `jobs.json`+`state.json`? The split is justified by torn-write blast radius; keep. |
| 11 palette commands + 11 form actions + 17 key bindings | UX §2.2, §3.4 | Trim per §4.2. |
| 8 status-segment states | UX §2.3 | Keep 5: stalled/setup, needs you, failed, running, next. |
| Tab badges `⏲ ⚠ ✗ ✓` with run-table↔tab mapping [INFERENCE] | UX §2.4 | Defer; status segment + manager suffice. |
| `tern.carly.context` + 6 Carly exports with allowlist settings | UX §2.5 | Defer; nice-to-have, with its own security surface. |
| Width tiers 4 levels + dock badge collapsing + hint tiers | UX §3.3, §8.3 | Two tiers (≥80, <80). |
| Settings: "Keep Mac awake", "extra PATH folders", "reset hands-off confirmations", "Carly" group | UX §7.7 | Defer all but extra PATH folders (setup-fix). |
| Reporter extension, worktrees, `float`/`split` | M3 | Already deferred; keep. |

---

## 5. Decisions for the user (≤6)

**D1. How should unattended jobs be allowed to run shell commands by default?** (P2, P11)
Options: (A) Default *Ask before commands*; users who want unattended shell choose Hands-off per job (spec today); (B) default Hands-off with strong labeling (matches the user's own omp default `yolo` and tern-swarm; jobs just work); (C) default Ask, plus a per-job "Allowed commands" list (e.g. `git`, `gh`, `npm test`) compiled into a `--config` overlay (`tools.approval.bash` patterns), so scheduled jobs run unattended with a narrow allowlist.
Tradeoffs: A is safe but most real jobs stall and users end up in Hands-off anyway; B is smooth but a prompt-injection / bad-prompt corridor; C is the best product but needs verification that `bash.patterns` overlays work (OC §6 "not containment").
**Recommend A for v1 plus verify C as a follow-up** (and fix the Read-only example per P2).

**D2. What does "Tern must be running" really mean, and do we help?** (P1, P6)
Options: (A) honest copy only ("Jobs run while Tern is open"); (B) Setup row explaining Login Items + warn at load when no live program keeps the daemon alive; (C) plugin keeps a hidden keep-alive pane, (D) plugin writes a launchd agent.
**Recommend A+B** (UX Q3 option b, and correct the "even with every window closed" sentence first). Revisit C/D only after the production daemon behavior is probed (add V-item).

**D3. One home for everything: where does the manager live and what is the run session called?** (P7)
Options: (A) manager opens as a tab in the current session, runs go to a session "Schedule" (spec today, collision); (B) run session is renamed "Scheduled runs" and the manager is also tab 1 of that session ("Open manager" switches there); (C) no dedicated session: runs are background tabs in the current session.
Tradeoffs: A is confusing; B gives one destination but "Open manager" changes the user's view (user-initiated, acceptable); C is simplest and avoids P4 but clutters the working session.
**Recommend B.**

**D4. Result review model: panes or inbox?** (§2 step 13, P8)
Options: (A) keep every run pane open by default (spec today); (B) close successful runs after N minutes and rely on a stored last-message + `--resume`; (C) A with a keep-last-N cap (default 10 panes total).
Tradeoffs: A leaks processes; B depends on unverified `--resume --session-dir` (V23) and the JSONL schema (V22); C is cheap and keeps evidence.
**Recommend C in M1, with a "Read result" view in Detail (last message, full text copy) so users rarely need the pane.**

**D5. M1 scope cut: palette-wizard create (cx:prompt/cx:pick) vs full in-block form?** (P10, §4)
Options: (A) full `prefs` form with hand-rolled multi-line editor (spec today); (B) M1 form with 8 rows and one-line prompt + `ctrl+o` file for long prompts (§4.2); (C) window-only wizard: New job = a sequence of `cx:prompt`/`cx:pick` (name → when → prompt → folder → role → approval) and Edit = same sequence prefilled, manager list read-only plus actions.
Tradeoffs: A is highest polish, highest risk; B is the recommended middle; C is fastest and robust, but weaker "menu to CRUD" feel and cannot show the live schedule preview alongside the field.
**Recommend B**, with C as the fallback if the spike for host-block text editing misses a one-week box.

**D6. Which model role should new jobs and examples default to?** (§1d)
Literal ask is `@default`; on this machine that is `claude-opus-5-5:medium`. Options: (A) `@default` everywhere (matches the request; costly for recurring jobs); (B) `@default` for new jobs, examples explicitly `@smol` with cost line shown; (C) `@smol`.
**Recommend B**: keeps the stated requirement and shows cost-awareness where users are most likely to copy-and-forget (the three examples).

---

## 6. Detailed findings

### P1 [blocker] Availability copy contradicts the architecture contract
- Location: UX §3.5 empty state, §4.11 form footer, §6.2 Setup, §6.4, §7.7 disclosure; AR "Availability contract" lines 61-65.
- Problem: UX says "Jobs run while Tern is running, even with every window closed." AR line 62-63 says the daemon "exits when no window is attached and no program is live". The only evidence that the daemon survives with zero windows is PR2 test 5 on an **isolated** `tern daemon` with a hand-made socket, not the SMAppService production daemon (TP point 6: plist has no `RunAtLoad`/`KeepAlive`). A user who quits Tern.app loses their jobs and is told the opposite. A normal user reads "even with every window closed" as "Tern can be closed".
- Evidence: AR lines 61-65; PR2 test 5 environment line 133; TP §2.1 point 6.
- Resolution: (1) Add a V-item: on the real daemon, close/quit all windows with and without a live pane, observe whether the daemon and a host timer survive. (2) Rewrite the disclosure to what is verified: "Jobs run while Tern is open." (3) Setup check row "Daemon keep-alive" using `tern inspect --json` clients/panes; warn when no live program would keep it alive.

### P2 [blocker] "Read-only" has no shell; flagship example needs one
- Location: UX §6.1 table (Morning repo digest = Read-only), §4.7; LA §7.1 (`--tools read,grep,glob,web_search,todo`).
- Problem: The prompt asks for commits and PRs; `git log`/`gh pr list` require a shell tool excluded by the allowlist. Tool names are unverified (LA V9; the user's omp also lists `find`/`search`). First-run experience of the headline example would be a polite failure to do the task.
- Resolution: Change the example to Ask-before-commands with a prompt that says which commands to use, or define Read-only as `write` + deny edit tools (verify) and keep bash allowed read-only; or rewrite the example prompt to use only `read/grep` (e.g. "Read CHANGELOG/TODO..."). Verify V9 in M1 before shipping Read-only at all; hide the option until verified.

### P3 [blocker] M1 lacks run observation
- Location: AR Milestones (line 78-80); UX §3.2/§3.3 list built on last-outcome/history.
- Problem: see §4.1.
- Resolution: Move the minimal observer (needs you / finished / failed / last message), status segment, needs-you+failed toasts/OS banner, Open run and run history rows into M1 (§4.2); defer badges/Carly/polish to M2/M3.

### P4 [major] `tern` CLI acts on one window's sessions
- Location: AR Decision line 12-13 ("never changes the user's shown tab"), LA §2.1/§4 (placement b "session shown"), LA V26 (unverified); `tern new --help` output: "Every command works on one window's sessions: --window KEY's, else the window of the pane it runs in, else the first window."
- Problem: The host has no pane and no `$TERN_WINDOW_KEY`, so every launch targets "the first window". Consequences: (1) `Schedule` session is created in window 1 even if the user works in window 2; (2) placement "background tab here" opens in window 1's shown session, which may not be the one the user is in; (3) `tern focus` raises a block in window 1; (4) `tern ls --json` sees only window 1's sessions: with two windows, a Schedule session in window 2 is invisible and the next launch creates a second "Schedule" session.
- Resolution: Add to LA §13 an immediate V-item (two windows). Design response: window half records its `TERN_WINDOW_KEY` (`tern.getenv`) in an intent whenever a window gains focus; the host passes `--window KEY` (last-active key) on every `tern` call; store `schedule_window_key` and re-resolve when the window disappears (`tern inspect --json` `clients`). If sessions are per-window, document "Runs appear in the window you used most recently."

### P5 [major] Needs-you/OS notification promised where it cannot be detected
- Location: UX §5.1 last row; EN §7.3 line 688; LA §8.3 "No window attached".
- Problem: UX: "needs-you and failures still send the OS notification if enabled" with no window. EN: without any window needs-you cannot be detected. Also the OS banner sender (host `osascript`? window?) is unspecified.
- Resolution: UX §5.1 row: "With no window open, a run that stops to ask waits silently until a window opens or its time limit hits. Failures that the host can see (launch failure, exit non-zero, timeout) still notify." Specify that the host runs `osascript` via `tern.process.run` for host-observed events; verify it works from the daemon (it runs under launchd, no GUI session? `osascript -e 'display notification'` generally works for a user agent, but verify).

### P6 [major] Overnight example vs 3 h catch-up on a laptop
- Location: UX §6.1 "Nightly test sweep: daily 02:00", UX Q2 rationale ("a morning review at 22:00 is noise"), EN D6.
- Problem: A laptop asleep at 02:00 wakes at 07:30: 5.5 h late > 3 h → every night skipped with "Skipped: 5h late, over the 3h limit". The example is a guaranteed non-event for the typical user, and the rationale cited is the reverse of this case.
- Resolution: Change the example to a time the Mac is likely awake (e.g. `weekdays 12:30`), and/or give the example `catch_up=always`. Make the catch-up window relative to the schedule period (Hermes: half the period clamped 2 min-2 h per PA §3i is too small for daily; for daily jobs use max(3 h, ...)) or expose a plain toggle on the job: "If my Mac was asleep: run when it wakes / skip". The existing UX `If missed` choice in Advanced is correct but hidden; promote it to the main section for scheduled-daily jobs or put its default in the empty-state examples.

### P7 [major] "Schedule" naming collision and invisible run session
- Location: UX §2.2 #1, §4.6; EN §1.3 `session_name`.
- Resolution: see D3.

### P8 [major] Interactive panes accumulate
- Location: LA §9 (Keep default; cap M3), UX §4.8/Q4, EN §7.3.
- Problem: `omp` stays interactive after the answer (EN D13), so every successful run leaves a live agent process. LP/PA §6 flag "Process leaks" and "pile-up". The daemon also never exits (side effect: contradicts the "scheduler might die" worry but wastes memory).
- Resolution: ship a global "keep last N finished panes" cap (default 10) in M1; set job default `After = Close if it succeeded` once Open run `--resume` (V23) is verified.

### P9 [major] Role contract inconsistent
- See §1(d) items (1)-(6). Resolution: one authoritative rule in EN §1.1: `role` is the bare name; `model` (optional, pinned) is a separate field validated against `omp models`; roles are read per-cwd (LA §6); roles unreadable → blocked, UX copy updated; one ordering/filter list.

### P10 [major] Form + host-block opening unverified
- Location: UX §4 intro; AR line 55; TP open question K; LA V list contains no item for it.
- Resolution: M1 spike (before building anything else in the UI): (1) palette command → `cx:new_block("schedule.manager")` opens the host block; (2) the block can hold a text field with multiline paste/IME input; (3) `prefs` renders inside a host block with `editing`. If (2) fails, use D5 option C.

### P11 [major] Approval stalls funnel users to Hands-off
- See §2 step 9 and D1.

### P12 [major] HOME default vs `cwd_home` block
- Location: EN §1.1 `cwd` default ("else `$HOME`"); UX §4.5 fallback `~`; LA §5.3 blocks home unless `allow_home`; schema has no `allow_home`.
- Resolution: no fallback: the Folder row is empty and Save disabled with "Pick a project folder." for non-local focus; if the user explicitly picks `~`, store `allow_home=true` and show the omp temp-dir warning copy.

### P13 [minor] Cross-doc inconsistencies a reconciler should fix
1. Prompt argv: AR/EN §0.3 (`-- <prompt>` final arg) vs LA §2.3 (`@file` + fixed sentence). Use LA.
2. Binary resolution order: EN §1.3 (`~/.local/bin/tern` first; omp `/opt/homebrew/bin` → `~/.local/bin/omp` → managed) vs LA §1 (app bundle first; Tern-managed omp first). `~/.local/bin/omp` is 18.8.6 here (LA §1); using it would silently run an older omp. Use LA.
3. `--keep-open`: LA §2.1 adds it; EN §0.3 sequence omits it.
4. State names: EN `finished/needs_input/cancelled`; UX "ok/needs you/stopped"; LA `finished|failed|timed_out|skipped|missed|blocked|cancelled`; UX's "queued" and "caught up" states are not EN states (EN: `scheduled`/`pending`, caught-up is a trigger). Map table needed in UX §5.4/§5.5.
5. Placement default example: EN §1.4 example JSON `"where": "tab"` vs defaults `session`.
6. Quiet marker: UX/EN `[quiet]` alone vs LA `RESULT: [quiet]`.
7. Role list ordering/hidden roles (see P9).
8. Stop: UX/AR use `cx.agents:stop(tostring(block))` (window) which **closes the tab** (PR2) while LA §10 says Stop = `tern close` and "interrupt" is the graceful variant; UX button "Stop" should say what happens ("Stops and keeps the pane" vs closes).
9. `If still running` option "Run after it finishes" depends on EN queue-one, but UX copy says "at most one waits": consistent. Fine.
10. UX §2.2 says status segment/palette read intents "bump kv `rev`" while EN has the host publishing `rev`; direction of `rev` (host→window only) vs UX (window bumps) differs. Windows must not write kv `hot`.

### P14 [minor] Install, update, removal, backup
- No section covers `tern plugin install github.com/…`, updating (package changes reload every plugin), what removing the plugin does to jobs (`plugin-data` survives? run panes stay), or a way to export jobs. Add README requirements and a Settings "Open data folder" action.

### P15 [minor] Copy gaps
- `cwd_unsafe` and `allow_home` validation strings; "not observed" run state in the manager; "late flip" finished runs; Details link target; how a pinned model appears in UX §4.4 chips vs EN schema; first-ever-run toast; Carly draft copy for a first user is fine.

---

## 7. What is good (kept short, for calibration only)
Engine is tested and conservative; honest catch-up/skip history; "never steal focus" principle; single-plugin architecture is the right call. Nothing above argues against the architecture decision, only against the M1 cut line and several user-facing claims.
