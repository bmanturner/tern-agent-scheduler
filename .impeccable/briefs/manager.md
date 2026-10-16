# Surface brief: manager list + job details

Mode: Operate. Visual authority: Tern itself (user's theme, Tern view nodes); no new world. Code-led.
Approved by Brendan 2026-10-13 after shape (sketch: .impeccable/mocks/decision/hybrid.png).

## Job and audience
Tern users checking agent work. First question answered: what happened since I last looked; then what needs me; then what runs next. Typical 3–10 jobs, rarely >20.

## Structure
- **Default list layout: Timeline.** Results since the user last looked above a "now" rule; every active recurring job exactly once below it, at its next run (time-ordered). The now rule appears only when there are results above it or runs in progress at it; sections with no rows are never shown. When nothing is new, a single muted quiet line follows the header ("Nothing new since 08:00." / "Nothing has run yet. <job> runs first, 18:00 (in 9h 52m)."). Running / needs-you runs sit on the now rule (running job shows "next HH:MM" inline instead of a second row). One-shot jobs below until they run. Bottom group: paused, needs fixing, manual-only.
- **Classic layout (setting):** today's grouped job list (Needs you, Needs fixing, Running, Upcoming, Paused & finished), with the shared row/toolbar fixes.
- **Job details:** layout-3 detail: header (name, state, next run), latest result line called out (failure tone when failed), settings as key/value, run list with one-line summary, duration, cost. No chart.
- **Width:** at ≥ ~150 cols (cx.cols; tune with screenshots) details sit beside the list and follow selection, in both layouts. Narrower: Enter opens details full-width.

## New / seen
- New results highlighted until visible in the open manager briefly, then fade (default). Setting "New results": fade once seen | stay until cleared.
- A failure keeps its ✗ on the job until its next success.
- Last-looked marker advances when leaving the manager.
- Backlog: ≤ ~8 new results → one row each. More → one row per job ("PR triage · 84 runs since Mon · 70 ✓ · 12 ↷ · 2 ✗ · latest …"); failures and needs-you always get their own rows above. Rows do NOT expand; opening the job shows all its runs. "Mark all seen" key and button appear only when something is unseen. Counts tracked independently of the 50-run retention; run lists say "latest 50 of N" when truncated.

## Toolbar
Job actions and global actions are two groups of the same buttons, apart by space, with the selected job named above the job group; keys shown inside buttons; Delete and Pause all last in their groups, in muted text; separate hint row removed. Forms and dialogs use the same buttons.

## Settings
Manager Settings sheet gains a "Manager" page: Layout (Timeline default | Classic job list), New results (fade once seen | stay until cleared). Palette command "Agent Scheduler: Settings".

## Styling (approved 2026-10-13: "B with A's markers"; mocks .impeccable/mocks/style/)
- UI font (--sans) for names/summaries; mono with tabular digits for times/durations/costs.
- New results: thin left-edge marker (accent; --bad for failures), not full-row wash; fades once seen.
- Selection: accent outline + light tint; glides between rows (spring-follow).
- Now rule: accent rule (no glow) with a filled "now · HH:MM" pill; countdown digits roll (-stencil-text-effect: numeric).
- Running row on the now rule: --live gradient wash + slow pulsing dot.
- Details: raised card (--card, --r-card, soft shadow); failure called out in a bordered --bad tint block + "Last run failed" badge; settings in a recessed --l1 block.
- Dock: one outlined button style everywhere (no tray); the Enter/default action is accent-tinted.
- All motion off under prefers-reduced-motion. Light theme: times use --t2 not --t3; status glyphs slightly larger. Verify against 2+ real omp themes in Tern.

## Time format
Setting "Time format": Automatic (default; follow system, 24-hour fallback) | 12-hour | 24-hour. Centralize all time formatting in one helper (lib currently has ~29 os.date calls); applies to manager, notifications, status line, Carly text. Parsing already accepts both.

## Keep
All current keys, section vocabulary, Tern theme/components, plain-English copy.

## Anti-goals
No charts/stat tiles (remove the run-duration bar chart). No inline expanding rows.

## Also fix
Missed ≠ failed in counts; `0 */2 * * *` reads "every 2 hours"; "Invalid job id.." double period; "d d" spacing.

## Open
Exact width cutoff (tune on screenshots).
