# Changelog

User-facing changes per release. Update with `tern plugin install github.com/bmanturner/tern-agent-scheduler --force`.

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
