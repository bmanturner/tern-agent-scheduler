# Changelog

User-facing changes per release. Update with `tern plugin install github.com/bmanturner/tern-agent-scheduler --force`.

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
