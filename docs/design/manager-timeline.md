# Manager timeline behavior

The approved surface brief is `.impeccable/briefs/manager.md`. The implementation keeps Tern’s native nodes and semantic theme colors; `manager.css` contains the scoped layout rules. No chart remains.

## Checkpoints and visibility

The host owns `settings.last_looked`, `manager_layout` (`timeline` or `classic`) and `manager_results` (`fade` or `stay`). Window Settings only opens a manager block with `settings` args; no new write intent was added.

Tern’s BlockDef has init, view, key, event, resize and save, but no closed, hidden or visible callback. The fallback starts a host `tern.timer(3000, ...)` when a new result is rendered. It checks `tern.pane.list()` for liveness and refuses to clear while a sheet or form covers the list. A timer checkpoint excludes later completions. The current visit keeps its result rows and baseline, while their semantic fresh role is removed; the next visit starts at the persisted checkpoint. Stay until marked seen disables these timers. `s` clears immediately.

Limit: pane existence is not visibility. A background tab can remain alive, and the native API does not report which result rows have actually scrolled into view. Consequently this fallback approximates an open-manager visit, not a measured viewport impression. Select Stay until marked seen when explicit acknowledgement is important. Last-looked advances on the fallback, not on actual departure.

## Retention and migration

Each job’s host state has `manager_history`: total and pending outcome counters, latest outcome id, and a failure flag. The runner updates these for terminal outcomes before ledger pruning, including skipped and missed slots. Missed and cancelled outcomes are not failures; a success clears the failure flag. The timeline aggregates above eight new outcomes, while retained failure records still receive individual rows. Enter opens details rather than expanding a summary.

Existing installations seed counters from their retained ledger. Outcomes deleted before this feature was installed cannot be reconstructed, so migrated totals initially describe retained history. Thereafter the counters survive the 50-record default retention. A failure whose record has already been pruned is represented by the aggregate failure count, not a fabricated individual row. The run list states `latest N of M` when its retained/displayed history is shorter than the counter.

All displayed run timestamps now use start time (created/scheduled time when no terminal started). Completion remains the new-result checkpoint, not the displayed clock. Header and rows share a render-time reference and ceil future minutes; durations remain separate.

## Structure and keyboard

`C.SPLIT_COLS = 150` is the single split breakpoint. At that width, selection updates the adjacent details; Enter focuses its run list and Escape restores job-list keys. Narrow layouts open details full-width. `s` marks all seen in the job list. Existing list job-action keys remain available, and `?` documents the new key.

Semantic CSS hooks include `tas.split`, `tas.timeline`, `tas.detail`, `tas.job-row`, `tas.live-row`, `tas.now-rule`, `tas.last-looked`, `tas.timeline-heading`, `tas.new`, `tas.new-failed`, `tas.seen`, `tas.latest`, `tas.latest-failed`, `tas.detail-title`, `tas.detail-status`, `tas.detail-settings`, `tas.detail-prompt`, `tas.prompt-action`, `tas.run-heading`, `tas.run-list`, `tas.run-row`, `tas.dock-actions`, `tas.dock-job`, `tas.dock-global`, `tas.dock-action` and `tas.dock-danger`. All CSS is scoped to `plugin.tern-agent-scheduler.manager`.

## Approved visual pass and clock preferences

`manager.css` scopes UI-font labels, mono/tabular measurements, 2px new-result markers (accent/failure), accent selection outlines, a filled now pill/rule, live gradient/dot, raised detail card, failure callout/badge, recessed settings and one outlined button style with inline keycaps (docks, forms, dialogs) to this plugin. Seen markers transition for 600ms with `--out`. Native selection is retained: `-stencil-follow` requires explicit translation targets and would fight the list's own row selection, so no follower overlay is installed. Numeric effects are attached to changing clock/measurement spans. Reduced-motion media and `.sf-still` disable authored motion. Static captures verify paint/layout, not animation trajectories; the seeded matrix has no running-agent row.

`timefmt` is the shared display-clock module. `time_host` resolves Automatic once using host process calls and caches `time_format` in cache.json; macOS force preferences take precedence over locale, and Linux reads only locale `t_fmt` (including `%r` shorthand). Failure falls back to 24-hour. Snapshots carry the resolved format; window readers never run a detection process. Explicit 12-hour/24-hour preferences persist in settings. Previously stored free-text reasons and agent-authored summaries are not rewritten (the fixture's old “02:00” missed reason remains literal).

Review fixes also give selected results matching detail-history selection, strip heading markers from the first two meaningful prompt lines, use a compact prompt button, and consistently name the acknowledgement option “Stay until marked seen”. Classic countdowns now use the same ceil-minute text rather than a separate seconds timer.

Final captures: `~/Dev/personal/tern-agent-scheduler-audit/redesign2/` — wide dark/light, narrow dark/details, Manager settings plus time choices, explicit 12-hour, Classic, Nord, Catppuccin and a sandbox-only backlog (12 appended runs; 14 PR-triage records). Vision inspection completed in two batches. No clipping/overlap defects remain; native ellipsis and Settings overlay occlusion are expected. Nord's theme-provided red is visually less prominent than its body ink; no measured contrast certification is claimed. The Linux host reported `t_fmt="%r"`, cached and resolved as 12-hour. Tests and git diff whitespace checks pass. No user Tern configuration was changed.

## Verification

`npx --yes bun run test` runs the existing suite plus `runner_manager`. Bun was not on PATH; npx Bun works without installing into the user’s Tern configuration. The new tests cover ordering, in-flight deduplication, manual grouping, separate missed/failure counts, 84-result aggregation after pruning, checkpoint races, stay/fade behavior, covered-list guards, cron steps and settings validation. Palette tests cover Settings launch args.

Headless captures use only the isolated `~/.hermes/cache/scratch/ternshot` sandbox. Wide timeline/details, narrow timeline, narrow details, Classic and Manager settings were captured in both themes at 1440×900 or 760×800 logical pixels (PNG output is 2×). Final files live under `~/Dev/personal/tern-agent-scheduler-audit/redesign/`. Two inspection rounds found and corrected the prompt-hint wrap. Backlog fixture reseeding requested tool approval and did not execute; no backlog screenshot is claimed. Live running/needs-you grouping has model coverage but no real-agent screenshot.
