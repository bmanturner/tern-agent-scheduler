# Changelog

User-facing changes per release. Update with `tern plugin install github.com/bmanturner/tern-agent-scheduler --force`.

## 0.8.0 (2026-11-10)

Built and tested on Tern 0.9.16. **Update Tern to 0.9.16:** on an older Tern, Settings › Setup flags the Tern version.

### Changed

- With several Tern windows, runs open in a window you use: a run you start from the manager, the palette or Carly opens in that window, and scheduled runs open in the window you last used Agent Scheduler from. They used to always go to the first window.
- After a plugin reload, a run whose launch was still finishing is picked up right away instead of on the next check.
- Run records are saved before the plugin reloads or is turned off.

### Fixed

- **Open run** (Enter or a double-click on a run) works when the run's tab is in another Tern window. It used to do nothing visible, or resume the session in a window you weren't looking at. When the tab is in your other window, the manager now says so.
- A run whose tab is in a window other than the first is no longer recorded as closed by you.
- When a run's tab can't be shown, the manager says why instead of doing nothing.

## 0.7.2 (2026-11-05)

Built and tested on Tern 0.9.12.

### Fixed

- A job's folder can have quotes, `$` or `!` in its name. The form used to refuse these folders; now it refuses only control characters, such as a newline.
- **Stop after** offers 6 and 8 hours, the limits the form already accepted.
- After a validation error in the job form, every field can still be reached: Tab and Shift-Tab leave the prompt editor with its text kept, and clicking another row finishes an open text edit.

Thanks to @roverdude24 for these fixes (#4).

## 0.7.1 (2026-11-05)

Built and tested on Tern 0.9.12. **Update Tern to 0.9.12:** on an older Tern, Settings › Setup flags the Tern version.

### Changed

- Agent Scheduler is now built and tested on Tern 0.9.12.

## 0.7.0 (2026-11-05)

Built and tested on Tern 0.9.9.

### Added

- Scripts, CI jobs and other agents can create jobs by writing a `script_create` request into the data folder and reading the reply. The fields and reply are a stable contract, and unknown fields are refused. See [From a script](README.md#from-a-script). Thanks to @roverdude24, whose #4 prompted it.
- Jobs made this way are active immediately with your default approval. The manager marks them `by <source>` (or `by script`), and a toast and a desktop notification name who scheduled them.

## 0.6.0 (2026-10-31)

Built and tested on Tern 0.9.9. **Update Tern to 0.9.9:** on an older Tern, Settings › Setup flags the Tern version.

### Added

- **Agent Scheduler: New job from selection…** in the palette opens the New job form with the selected text as the prompt.
- A timer button in the Files pane's toolbar starts a new job in the folder the pane shows.
- Job details show the run totals (runs, succeeded, failed, missed) as a row of tiles above the history.
- A run whose tab or session is closed is recorded as soon as Tern reports the session ended, instead of on the next check up to 15 seconds later.

### Changed

- The manager's buttons are Tern's own buttons, with keycaps, one highlighted action, and red for destructive ones.
- Dialogs have an icon in their title and their buttons in a footer bar; the conditions dialog names the job beside its title.
- The manager uses Tern's sans-serif face for its text.

## 0.5.0 (2026-10-28)

Built and tested on Tern 0.9.6. **Update Tern to 0.9.6:** on an older Tern, Settings › Setup flags the Tern version.

### Added

- **Agent Scheduler: Reload** in the palette reloads only this plugin, not every plugin.
- A run that starts waiting for you, goes idle or starts working again is noticed as soon as Tern reports it, instead of on the next check a few seconds later.

### Changed

- When Tern pauses the plugin for running too long, the status line says **Agent Scheduler paused** and clears itself when Tern resumes it. It used to say the plugin had stopped and ask you to reload every plugin.
- When the scheduler hasn't ticked for a while, the notice and Settings › Setup say it may resume on its own, and point to **Agent Scheduler: Reload** instead of reloading every plugin.

## 0.4.2 (2026-10-17)

Built and tested on Tern 0.9.2.

### Fixed

- A run whose last model request failed right at its time limit (omp reports "Deadline exceeded") is now recorded as stopped at the time limit and counts as a failure. It used to show as finished.

## 0.4.1 (2026-10-17)

Built and tested on Tern 0.9.2. **Update Tern to 0.9.2:** on an older Tern, the manager asks you to check setup and Settings › Status flags the Tern version.

### Added

- Carly can turn on **Quiet when nothing to report** when she creates a job (`quiet_ok = true`).
- A one-off time can start with `at`, as in `at 2026-10-20 09:00` or `at tomorrow 9am`, the way Carly writes her own scheduled tasks. When a schedule isn't understood, the suggestions now include a date.

### Changed

- With every request, Carly is told to use Agent Scheduler instead of her own scheduled tasks for agent work in a folder that repeats or takes longer than three minutes, how to call `job_add`, and to confirm a job's details with you first because she can't edit or delete it. Until now this was only in her help text, which she doesn't always get to read.
- Carly's help for `job_add` says the job goes live at once, that the run is already told to work unattended and end with a summary, and that a name is optional.

## 0.4.0 (2026-10-16)

Built and tested on Tern 0.9.0. **Update Tern to 0.9.0:** on an older Tern, the manager asks you to check setup and Settings › Status flags the Tern version.

### Added

- **Timeline**, the manager's new default view: results since you last looked, a **Now** rule, then each active job at its next run, with paused, manual-only and broken jobs at the bottom. A run in progress sits on the Now rule. When nothing is new, one line says so ("Nothing new since 08:00."), and on a first visit it names the first run. More than eight new results fold into one summary per job, with failures still listed one by one. **Settings › Display › Layout** brings back the **Classic job list**.
- In panes 150 columns or wider, a job's details sit beside the list and follow the selection. They call out the latest result and list each run on one line with its outcome, duration and cost.
- New results fade after three seconds, or stay highlighted until you mark them seen (**Settings › Display › New results**). `s` or **Mark all seen** clears them, and a failure marker stays on the job until its next success.
- **Time format**: Automatic (follows your system, with a 24-hour fallback), 12-hour or 24-hour, used for schedules, previews, notifications, the status line and Carly. Until now times were always 24-hour.
- **Agent Scheduler: Settings** in the palette.

### Changed

- Settings is one page, **Agent Scheduler Settings**, with Status, Display, Where runs start, Limits and Setup sections. **Status** says whether Agent Scheduler is ready to run jobs, lists each problem with what to do about it, and **Check again** checks in place. The Check setup dialog is gone; what it said about when jobs run is now in Help.
- In Settings, Time format and Layout are buttons (←/→ also switch them), number rows take a typed value after Enter, a rejected value stays in its field with the reason above it, and a changed setting shows a dot and **Reset**. Tab and Shift+Tab move between rows; a key legend sits at the bottom.
- Help (`?`) groups the keys into The selected job, Move and open, and All jobs, written the way you type them (`P` is shift+p).
- One look for every button in the manager, the job form and its dialogs, each with its key inside. The default action, the one Enter does, is highlighted.
- On the job form's **Only when** page, a condition that's off shows only its switch, and its settings appear when you turn it on (nothing you set is lost). **Check now** appears once a condition is on.
- With no jobs, the manager offers its examples under a "Start from an example" heading; Enter opens the selected one as a draft that's saved only when you save it.
- A job's history is one line per run instead of a chart.

### Fixed

- On Tern 0.9.0, a scheduled run no longer ends as "Closed by you." a few seconds after it starts while omp keeps running in its tab. Agent Scheduler didn't recognise its own run tabs in the shape Tern 0.9.0 lists them.
- Runs missed while your computer was asleep no longer count as failures.
- Schedules with a cron step read naturally ("Every 2 hours").
- Every run is listed at its start time, and countdowns round up to the minute.
- With window glass on, Settings no longer lets the job list show through.
- "Invalid job id." no longer ends in two periods.

## 0.3.2 (2026-10-13)

Built and tested on Tern 0.8.3.

### Fixed

- The manager no longer says "Agent Scheduler needs attention · Check setup" when nothing is wrong. Right after Tern reloaded the plugin, and right after your Mac woke, the scheduler's heartbeat looked stale for a second, and the manager kept showing that until you pressed a key in it. The heartbeat now only counts as stopped when the scheduler misses its tick while your Mac is awake, and an open manager redraws by itself whenever its setup checks change.

## 0.3.1 (2026-10-13)

Built and tested on Tern 0.8.3.

### Added

- **Ask an AI**, a fifth section on the Only when page: write a question, pick a model role (`@smol` by default), and before each due run omp answers run or skip after looking at the job's folder with read-only tools. It sees the job's facts and what the other conditions found, such as the new commits, and is asked last, so it only costs a model call when everything else says yes. A skip is listed in history with the model's reason (repeats on the same day fold into one row), a run passes the reason to the agent in `trigger.md`, and an answer it can't give blocks the run like a failing script. Its spend counts toward Limits.
- Carly can add the question when she creates a job (`only_when = {ask = "…", ask_model = "smol"}`)

## 0.3.0 (2026-10-12)

Built and tested on Tern 0.8.3.

### Added

- **Only when**, a second page in the job form: conditions a due run must meet, each with its own section and switch. Runs can wait for new commits on a branch (optionally in some folders), stay within days and hours or outside quiet hours, stop at a number of runs or an amount spent per day or week, or ask a script of yours. Runs that don't qualify are listed as skipped with the reason, repeats fold into one row, and nothing notifies you. A new-commits job gives the agent the new commits in an attached `trigger.md`.
- Your own check is approved when you save the job; a script changed afterwards blocks runs until you save the job again
- **Run now** checks a job's conditions first and asks **Run anyway?** when one says no
- **Check now** on the Only when page, and `i` in a job's details, show what each condition says right now without running anything; **Forget what it has seen** resets a new-commits job
- **Quiet when nothing to report**: the agent may end with `RESULT: [quiet]`, and the run is marked quiet instead of showing a summary
- Carly can set conditions when it creates a job (`only_when`, except your own check) and check a job's conditions (`job_check`)

### Changed

- A condition that can't be checked (not a git folder, a failing script) blocks the run and notifies you once; after three in a row the job pauses itself

## 0.2.3 (2026-10-12)

Built and tested on Tern 0.8.3 (macOS, and a Linux remote host).

### Added

- Images a prompt links to (`![](shot.png)` beside the prompt file, or a path such as `~/Desktop/shot.png`) are attached to every run, so the model sees them. Up to 10 per prompt, 20 MB each. An image that can't be attached doesn't stop the run: the agent is told which ones are missing, and the run's row in the job's details says how many weren't attached.

### Changed

- Settings › Setup expects Tern 0.8.3 and flags older versions
- Drafts opened with `ctrl+o` in the job form are kept beside the job prompts, so an image saved beside a draft still works after you save the job
- Images beside your prompts that no prompt has linked to for a week are cleaned up

### Fixed

- A run where omp stopped with an error now shows omp's error message instead of a generic "omp exited with status N"

## 0.2.2 (2026-10-12)

Built and tested on Tern 0.8.2.

### Added

- README: what works when Tern is attached to a remote host

### Fixed

- Every window and reload drew the same "random" ids, so two windows could collide on the requests they send the scheduler; ids now differ per window and per load
- **Open manager** and **New job…** in a remote host's session open that host's manager, in the focused pane's folder there, instead of focusing this computer's manager
- README: the Linux data folder is `~/.local/state/tern/plugin-data/tern-agent-scheduler/`

## 0.2.1 (2026-10-12)

Built and tested on Tern 0.8.2 (macOS, and Linux without a desktop window).

### Fixed

- Open manager has a shortcut on Linux: `ctrl+alt+shift+m`. Tern's Linux keys already use `ctrl+alt+shift+s`, so that shortcut was never bound there; it still works on macOS.

## 0.2.0 (2026-10-12)

Built and tested on Tern 0.8.2.

### Added

- Linux support: notifications through `notify-send`, Open data folder through `xdg-open`, and `tern` and omp found in the usual Linux locations
- Runs in progress show their model, tool calls, cost so far, running time and the tool in use; upcoming jobs due within the hour count down
- A job's detail shows a bar per recent run (red for failures), a runs, failures, median time and cost summary, and the prompt as Markdown
- If this window's background updates stop, the status line says so and a click reloads plugins (they stay stopped until then)

### Changed

- Runs finish as soon as omp reports the end of its turn instead of after six idle seconds, and a turn omp reports as failed fails the run
- Settings › Setup expects Tern 0.8.2 and flags older versions
- Carly lists a job she just created right away, reports a job with a run in progress as running, and `job_add` accepts named fields
- Pause and Pause all also stop runs still waiting to start
- Placement and bring-to-front settings apply to existing jobs

### Fixed

- One-shot jobs (`in 30m`, `tomorrow 8am`, a date) were cancelled as "Stopped by you" before they ran
- A provider error in the agent's last message is reported as a failure, not a success
- Missed-run bookkeeping survives long sleeps and clock changes
- Built-in omp roles such as `@default` and `@smol` no longer block jobs on a fresh omp setup
- A resumed run opened with Open run is no longer closed by the finished-tab limit
- A damaged `cache.json` no longer pauses every job, and damaged data offers Start fresh
- A save that fails rolls back instead of reporting success; undoing a delete restores the job's history
- False "stopped ticking" toasts after the computer wakes

## 0.1.0 (2026-10-11)

First release: scheduled omp runs from cron, presets, plain English or one-shot times, launched into a background Scheduled runs session; a manager with jobs and run history; palette commands, a status-line segment, toasts, macOS notifications and Carly tools.
