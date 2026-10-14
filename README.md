# Agent Scheduler _(tern-agent-scheduler)_

[![test](https://github.com/bmanturner/tern-agent-scheduler/actions/workflows/test.yml/badge.svg)](https://github.com/bmanturner/tern-agent-scheduler/actions/workflows/test.yml)

Scheduled [omp](https://github.com/can1357/oh-my-pi) agent runs for [Tern](https://stencil.so/tern): cron, presets, plain English or one-shot, each launched into its own tab while you keep working.

![The Agent Scheduler manager: a run in progress showing its model, tool calls, cost, running time and the tool it is using now, above four upcoming jobs with their schedules, last results and next run times](docs/screenshots/manager.png)

Write a prompt, pick a folder and say when ("weekdays 9am", "every 2h", `0 9 * * 1-5`). At that time Agent Scheduler starts omp in a background **Scheduled runs** session, watches it, and records how the run ended. Your focus never moves. The status line, toasts and desktop notifications tell you when something needs you or fails, and every run keeps its session so you can open it and carry on.

A job can also wait for something worth doing: new commits on a branch, working hours, a daily run or spend limit, a script of yours, or a model's answer to a question you write. Runs that don't qualify are skipped quietly and noted in the job's history.

- [Install](#install)
- [Create a job](#create-a-job): [Schedules](#schedules), [Only when](#only-when)
- [The manager](#the-manager): [Carly](#carly)
- [Good to know](#good-to-know)
- [Your data](#your-data)
- [Develop](#develop)
- [License](#license)

## Install

Built and tested on Tern 0.8.3. Runs on macOS or Linux (not Windows yet) and needs [omp](https://github.com/can1357/oh-my-pi). On Linux, desktop notifications use `notify-send` (libnotify).

```sh
tern plugin install github.com/bmanturner/tern-agent-scheduler
```

Press `ctrl+alt+shift+m` to open the manager (`ctrl+alt+shift+s` also works on macOS). With no jobs yet, it offers three examples you can save as they are or edit first. To update, run the install command again with `--force`; [CHANGELOG.md](CHANGELOG.md) lists what changed.

## Create a job

Press `n` in the manager, or `ctrl+alt+shift+j` anywhere. The folder starts as the focused pane's directory.

![The New job form: name, prompt, a schedule typed as "every friday 4pm" with a preview of the next three runs, folder and role](docs/screenshots/new-job.png)

| Field | What it sets |
| --- | --- |
| Prompt | What the agent should do, in Markdown. `ctrl+o` opens it in an editor. Images it links to are attached to every run. |
| When | The schedule, with a preview of the next three runs. `ctrl+p` picks a preset. |
| Only when | Conditions a due run must meet, or it's skipped. **Change…** opens the Only when page (see below). |
| If your computer was asleep | Run once when you're back if under 3 h late (default), always catch up, or skip. |
| Folder | Where every run starts. |
| Role | An omp model role such as `@default` or `@smol`, including your project's roles. |
| Approval | **Hands-off** (default), **Ask before commands** or **Ask for everything**. |
| Stop after | The time limit for one run, 5 minutes to 8 hours (default 30 minutes). |
| Quiet when nothing to report | Lets the agent end with `RESULT: [quiet]` when there's nothing worth reading; those runs are marked quiet in the history. |

`ctrl+enter` saves. `ctrl+shift+enter` saves and runs it once in front of you, so you can watch the first run.

> [!WARNING]
> Hands-off runs commands and edits files as you, with your credentials, while you're away. Only use it for prompts you'd trust unattended. The other two modes wait for you, and the run shows as **needs you** until you answer in its tab.

### Schedules

| You type | It means |
| --- | --- |
| `weekdays 9am`, `daily 09:00`, `hourly` | Every weekday / every day at 09:00; every hour |
| `mon,thu 18:30`, `every friday 4pm` | Those weekdays at that time |
| `monthly on the 1st 9am` | The 1st of each month |
| `every 15m`, `every 2h` | A fixed interval (5 minutes at least) |
| `in 30m`, `tomorrow 8am`, `2026-10-14 15:00` | Once |
| `0 9 * * 1-5`, `@daily` | Standard cron |
| `manual` | Only when you press Run now |

Times are local, and daylight-saving changes are handled.

Each run is told it is unattended and to end with a `RESULT:` line, which becomes the run's summary in the manager.

### Only when

The form's second page, **Only when**, has one section per kind of condition. Each is off until you turn it on, and a due run starts only if every condition that's on says yes:

| Section | A due run starts only when |
| --- | --- |
| New commits | The branch you pick (or the folder's current one) has commits since the last successful run, optionally only in some folders. The agent gets the new commits in an attached `trigger.md`. |
| Time | It's on the days and between the times you pick, or, as quiet hours, outside them. |
| Limits | The job is under that many runs or that much spend today, or this week. |
| Your own check | Your script says yes. |
| Ask an AI | A model you pick reads your question, looks at the job's folder (read-only) and answers run. It's checked last, so it's only asked when everything else says yes. |

**Check now** at the top of the page runs every condition that's on without starting anything, and shows each answer in a **Right now** row under that condition.

For example, a nightly review that should only run after someone pushed: set **When** to `daily 02:00`, then on **Only when** turn on **New commits** and pick `main`. Nights with nothing new show up in history as one folded "Skipped N times" row.

A run that doesn't qualify is listed in the job's history as **skipped** with the reason; repeats fold into one row, and nothing notifies you. The first run of a new-commits job notes where the branch is and waits for something new. If a condition can't be checked (not a git folder, a script that fails), the run is blocked and you're told once; after three in a row the job pauses.

Your own check runs in the job's folder with a 30 s limit and gets a JSON file describing the run as its argument. Exit 0 runs, 1 skips, anything else blocks the run. It can print `REASON: …` (shown in history), `CONTEXT: …` lines (passed to the agent) and `CURSOR: …` (handed back to it next time). Saving the job approves the script as it is then; if it changes, runs are blocked until you open the job and save again. Carly can set every condition except your own check.

**Ask an AI** is for judgement calls a script can't easily make, such as *"Are there open pull requests that still need a review?"* Before a due run, omp runs in the background with your question, the job's name, folder, time and last run, and whatever the other conditions found (for example the new commits). It can read and search files (and read web pages) but can't change anything or run commands, and it has 60 s to end with `ANSWER: run` or `ANSWER: skip` and a reason. A skip is listed in history with that reason, and a run hands the reason to the job's agent in `trigger.md`. An answer it can't give blocks the run like a failing script. Each check is one model call (about $0.001 with `@smol`) and counts toward Limits; **Check now** asks it too.

**Run now** checks the conditions first and asks **Run anyway?** when one says no. `i` checks them without running anything.

## The manager

The default **Timeline** shows results since you last looked, a **Now** rule, then each active job at its next run. Running jobs stay at Now with their next time inline; paused, manual-only and broken jobs sit at the bottom. More than eight new results fold into one summary per job, with failures still listed individually. Enter opens the job, not an expanding row.

At 150 columns or wider, details sit beside the list and follow selection. Enter focuses the selected job’s runs; Escape returns to the job list. In narrower panes, Enter opens details full-width. **Settings › Manager › Layout** can restore the **Classic job list**, grouped into Needs you, Needs fixing, Running, Upcoming and Paused & finished.

Job details show the latest result, settings, prompt and a one-line history of each run’s outcome, duration and cost. Failed and missed counts are separate. Every run timestamp uses its start time (or created/scheduled time when it never started), with duration shown separately. **Settings › Manager › Time format** offers **Automatic**, **12-hour** and **24-hour**. Automatic follows the host’s cached system preference, with a 24-hour fallback; the same format applies to schedules, previews, notifications, status and Carly.

New results fade after three seconds in the manager by default; choose **Stay until marked seen** in Settings › Manager to keep them highlighted. Press `s` or click **Mark all seen** to clear them. A failure marker stays on the job until its next success. Tern does not expose a block visibility/close callback, so the last-looked checkpoint advances after the three-second fallback rather than on tab departure. See [manager behavior](docs/design/manager-timeline.md) for limitations.

The screenshots above predate the timeline redesign.

| Key | Does |
| --- | --- |
| `enter` | Open the job, or the tab of a run that needs you |
| `n` / `e` / `c` | New / edit / duplicate |
| `r` | Run now |
| `i` | Check the job's conditions now |
| `o` | Open the run's tab, or resume its session if the tab is gone |
| `space` | Pause or resume |
| `d` `d` | Delete (`u` undoes it for 10 s) |
| `s` | Mark all results seen |
| `?` | Every key |

From anywhere in Tern, the palette has **Agent Scheduler: Open manager** (`ctrl+alt+shift+m`), **New job…** (`ctrl+alt+shift+j`), **Run a job now…** (`ctrl+alt+shift+r`) and **Go to run that needs you** (`ctrl+alt+shift+a`). **Agent Scheduler: Settings** opens the manager’s Manager settings page.

### Carly

Ask Tern's assistant to create, list, run or pause jobs, or to check a job's conditions, for example *"Schedule a job called standup-notes in ~/Dev/app every weekday at 9am that summarises yesterday's commits, only when there are new commits on main."*

> [!NOTE]
> Jobs Carly creates are active immediately with the default approval (Hands-off). You get a toast and a desktop notification, and the manager marks them `by Carly`.

## Good to know

- **Jobs run while Tern's session service is running.** It keeps running after you close every window, as long as a terminal or a run tab is open. Nothing runs while your computer is asleep or after a restart until you open Tern; missed runs follow the job's **If your computer was asleep** setting.
- **A run waiting for your approval** is only noticed while a desktop Tern window is open.
- **In the browser (`tern web serve`) and on iPhone and iPad,** the manager works, but palette commands, the status line, notices of runs that need you and Carly's job tools need a desktop Tern window.
- **With several Tern windows,** runs go to the first window's **Scheduled runs** session.
- **Remote hosts:** jobs run on the machine the plugin is installed on. To schedule runs on a remote host you've attached in Tern, install the plugin there too (run the install command in a pane on that host); it keeps its own jobs and manager, which **Open manager** and **New job…** open while you're in one of that host's sessions. This computer's status line, notifications, Carly and the other palette commands cover only this computer's jobs, and a run on the remote host that waits for your approval isn't noticed.
- **Failures:** a run that hits its time limit is stopped. After three failures in a row the job pauses itself and tells you.
- **Finished run tabs:** the 5 most recent are kept and older ones are closed; their sessions can still be resumed.
- **Settings** (`,` in the manager) cover where runs appear, how many run at once (2), how many finished tabs to keep, and the late limit for missed runs. **Settings › Setup** checks that Tern and omp are found, and lets you set omp's path if it's somewhere unusual.

## Your data

Jobs, prompts and run history live in Tern's plugin data folder (**Settings › Setup › Open data folder**): `~/Library/Application Support/Tern/plugin-data/tern-agent-scheduler/` on macOS, `~/.local/state/tern/plugin-data/tern-agent-scheduler/` on Linux. If its files are ever damaged, the manager offers **Start fresh**.

> [!WARNING]
> Anything that can write to the data folder can create jobs or change what they run, including Hands-off ones. Keep it private to your user.

Agent Scheduler makes no network requests of its own; your runs use omp and whatever your prompts ask for.

To uninstall, run `tern plugin remove tern-agent-scheduler`. Delete the data folder to remove your jobs and history too.

## Develop

```sh
git clone https://github.com/bmanturner/tern-agent-scheduler
cd tern-agent-scheduler
tern plugin link .   # Tern reloads the plugin when a file changes
bun install && bun run test
```

The host half (`host.luau`, `lib/runner.luau`) owns the clock and launching, and `lib/cond_eval.luau` checks a job's Only when conditions; the window half (`window.luau`) adds palette commands, the status line, run observation and Carly. Design notes are in [`docs/design/`](docs/design/).

Bug reports and pull requests are welcome in [GitHub issues](https://github.com/bmanturner/tern-agent-scheduler/issues). CI runs `bun run test` on every pull request.

## License

[MIT](LICENSE)
