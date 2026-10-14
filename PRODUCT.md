# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

"web" here means Tern's own view engine, not a browser: the plugin draws its screens with Tern view nodes (`tern.ui`), an HTML-like element subset and a CSS subset that Tern renders natively. There is no JavaScript, no browser layout engine and no custom fonts. The plugin runs on Tern desktop for macOS and Linux. The manager also opens in Tern's web client and on iPhone/iPad, but palette commands, the status line, needs-you notices and Carly tools need a desktop window.

## Users

Primary users are Tern closed-beta users: power users who live in the terminal and already run omp agents in Tern panes. They want agent work to happen on a schedule while they keep working, and to check in on it without leaving Tern. The plugin's author is one of these users, but design decisions favor the wider Tern user base over personal preference.

They open the manager for two reasons equally often: to see what ran, what failed and what needs them, and to create or adjust jobs.

## Product Purpose

Agent Scheduler gives Tern the scheduled agent tasks that the Claude and ChatGPT desktop apps already have, built natively into Tern. On top of that it adds things terminal-heavy users expect: cron and plain-English schedules, conditions that hold a run back (new commits, hours, run and spend limits, a user script, an AI check), and runs that land in real Tern tabs.

Success means Stencil adopts it into Tern. To get there it has to be trusted with unattended work and used by a large share of Tern users.

## Positioning

It's meant to match what other tools already offer, not to stand apart from them: what the Claude and ChatGPT desktop apps do for scheduled tasks, delivered inside Tern and fitting Tern's way of working. Where it goes further, it's because terminal power users need it: each run is a real omp session in a Tern tab that can be opened and continued, conditions decide whether a due run is worth starting, and all jobs, prompts and history stay on the user's machine.

## Operating Context

- A job is a saved prompt plus a schedule, a folder, an omp role, an approval mode and a time limit. A run is one execution of it.
- Runs start in a background **Scheduled runs** session without taking focus. The user hears about them through the status line, toasts and desktop notifications when something needs them or fails.
- Jobs run only while Tern's session service is running. Nothing runs while the computer is asleep. Missed runs follow the job's catch-up setting.
- The manager is a Tern block. The palette has Open manager, New job, Run a job now and Go to run that needs you. Carly, Tern's assistant, can create, list, run and pause jobs.
- Remote hosts each keep their own jobs and manager.

## Capabilities and Constraints

- **Terminology** (use exactly these words): job, run, needs you, needs fixing, Hands-off, Only when, skipped, missed, quiet.
- **Agent support:** omp only for now. UI wording should stay agent-neutral so other agents can be added later without rewriting copy. Undecided: which agents, and when.
- **Security model:** only the host half creates or changes jobs and settings. Windows send allowlisted intents only. Hands-off is the default approval mode and always shows its warning.
- **Platform limits:** window-half calls have a 50 ms budget. Views use Tern's built-in node kinds and its CSS subset. Plugin CSS must be scoped to the plugin's surfaces.
- **Data:** stored in Tern's plugin data folder. The plugin makes no network requests of its own.

## Brand Commitments

- **Looks like part of Tern.** Follow the user's Tern theme through Tern's theme variables and semantic tones. No separate brand, palette or logo.
- **Keyboard-first, never keyboard-only.** Everything doable by key must also be clickable.
- **Plain-English voice.** Sentence case, short, no jargon, no exclamation marks, no emoji in copy. Errors say what happened, then what to do. Times are concrete and local (`Mon 12 Oct 09:00`), in 24-hour or 12-hour form per the user's Time format setting (Automatic follows the system).

## Evidence on Hand

- README (`README.md`) and the changelog (`CHANGELOG.md`).
- Design history in `docs/DESIGN.md` and `docs/design/` (ux.md, decisions.md, engine.md, launch.md, architecture.md). These are historical; the code and README win where they disagree.
- Screenshots in `docs/screenshots/`.
- A UI audit with screenshots of every manager screen in dark, light and narrow layouts (seeded test data, not real usage): `~/Dev/personal/tern-agent-scheduler-audit/`.
- The public GitHub repo has 13 stars. There are no usage numbers, testimonials or adoption data yet; don't invent any.

## Product Principles

1. **Trust before features.** Users have to be willing to leave unattended runs going, so every run's outcome, cost and reason is visible, and nothing fails or gets skipped silently.
2. **Outcomes and authoring are equal.** The manager has to make "what happened / what needs me" and "create or change a job" both fast. Neither should be buried behind the other.
3. **Never steal focus.** Runs start in the background. The user goes to a run only when they choose to.
4. **Native to Tern.** It should feel like a part of Tern that Stencil could ship as-is: Tern's theme, Tern's components, Tern's keyboard conventions.
5. **Parity first, power second.** Cover what other desktop agent apps offer for scheduled tasks plainly, then add terminal-power-user depth without making the simple path harder.

## Accessibility & Inclusion

Status is never shown by color alone: every state has a glyph and words. Tern's simulated preferences (reduced motion, increased contrast, differentiate without color) should be respected where the plugin's views are affected. No other product-specific requirement has been established.
