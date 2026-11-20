# Agent Scheduler _(tern-agent-scheduler)_

[![test](https://github.com/bmanturner/tern-agent-scheduler/actions/workflows/test.yml/badge.svg)](https://github.com/bmanturner/tern-agent-scheduler/actions/workflows/test.yml)

Scheduled [omp](https://github.com/can1357/oh-my-pi) agent runs for [Tern](https://stencil.so/tern): cron, presets, plain English or one-shot, each launched into its own tab while you keep working.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/manager-dark.png">
  <img alt="The Agent Scheduler manager's timeline: results since you last looked (a failed test run, a quiet audit and finished runs with their summaries) above the Now rule, a run in progress on it with its model, tool calls, cost and current tool, then the next runs and a paused job" src="docs/screenshots/manager-light.png">
</picture>

Write a prompt, pick a folder and say when ("weekdays 9am", "every 2h", `0 9 * * 1-5`). At that time Agent Scheduler starts omp in a background **Scheduled runs** session, watches it, and records how the run ended. Your focus never moves. The **Agent Scheduler** widget, toasts and desktop notifications tell you when something needs you or fails, and every run keeps its session so you can open it and carry on.

A job can also wait for something worth doing: new commits on a branch, working hours, a daily run or spend limit, a script of yours, or a model's answer to a question you write. Runs that don't qualify are skipped quietly and noted in the job's history.

- [Install](#install)
- [Create a job](#create-a-job): [Schedules](#schedules), [Only when](#only-when)
- [The manager](#the-manager): [Settings](#settings), [Carly](#carly), [From a script](#from-a-script)
- [Good to know](#good-to-know)
- [Your data](#your-data)
- [Develop](#develop)
- [License](#license)

## Install

Built and tested on Tern 0.9.29. Runs on macOS or Linux (not Windows yet) and needs [omp](https://github.com/can1357/oh-my-pi). On Linux, desktop notifications use `notify-send` (libnotify).

> [!IMPORTANT]
> Jobs run while Tern's session service is running. It keeps running after you close every window, as long as a terminal or a run tab is open. Nothing runs while your computer is asleep, or after a restart until you open Tern; missed runs then follow each job's **If your Mac was asleep** setting.

```sh
tern plugin install github.com/bmanturner/tern-agent-scheduler
```

Press `ctrl+alt+shift+m` to open the manager (`ctrl+alt+shift+s` also works on macOS). With no jobs yet, it offers three examples to start from; Enter opens one in the New job form, and nothing is saved until you save it. To update, run the install command again with `--force`; [CHANGELOG.md](CHANGELOG.md) lists what changed.

To see the scheduler in Tern's widget bar, open the palette's **Edit widgets…** and add **Agent Scheduler** (`tern-agent-scheduler/status`). It shows the next run, runs in progress, and runs that need you or failed; click it to open the manager, or the run that needs you. If your bar has **Plugin segments**, the same status also shows there.

## Create a job

Press `n` in the manager, or `ctrl+alt+shift+j` anywhere. The folder starts as the focused pane's directory.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/new-job-dark.png">
  <img alt="The New job form: name, prompt, a schedule typed as &quot;every friday 4pm&quot; with a preview of the next runs, folder and role" src="docs/screenshots/new-job-light.png">
</picture>

| Field | What it sets |
| --- | --- |
| Prompt | What the agent should do, in Markdown. `ctrl+o` opens it in an editor. Images it links to are attached to every run. |
| When | The schedule, with a preview of the next three runs. `ctrl+p` picks a preset. |
| Only when | Conditions a due run must meet, or it's skipped. **Change…** opens the Only when page (see below). |
| If your Mac was asleep | Run once when you're back if under 3h late (default), run once however late, or skip missed runs. On Linux it reads *If your computer was asleep*. |
| Folder | Where every run starts. |
| Role | An omp model role such as `@default` or `@smol`, including your project's roles. |
| Approval | **Hands-off** (default), **Ask before commands** or **Ask for everything**. |
| Stop after | The time limit for one run, 5 minutes to 8 hours (default 30 minutes). |
| Quiet when nothing to report | Lets the agent end with `RESULT: [quiet]` when there's nothing worth reading; those runs are marked quiet in the history. |

Each run is told it is unattended and to end with a `RESULT:` line, which becomes the run's summary in the manager.

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
| `in 30m`, `tomorrow 8am`, `2026-10-14 15:00`, `at 2026-10-14 15:00` | Once |
| `0 9 * * 1-5`, `@daily` | Standard cron |
| `manual` | Only when you press Run now |

Times are local, and daylight-saving changes are handled.

### Only when

The form's second page, **Only when**, has one section per kind of condition. Each is off until you turn it on, and a due run starts only if every condition that's on says yes:

| Section | A due run starts only when |
| --- | --- |
| New commits | The branch you pick (or the folder's current one) has commits since the last successful run, optionally only in some folders. The agent gets the new commits in an attached `trigger.md`. |
| Time | It's on the days and between the times you pick, or, as quiet hours, outside them. |
| Limits | The job is under that many runs or that much spend today, or this week. |
| Your own check | Your script says yes. |
| Ask an AI | A model you pick reads your question, looks at the job's folder (read-only) and answers run. It's checked last, so it's only asked when everything else says yes. |

Once a condition is on, **Check now** at the top of the page runs every condition that's on without starting anything, and shows each answer in a **Right now** row under that condition. **Run now** checks them too and asks **Run anyway?** when one says no.

For example, a nightly review that should only run after someone pushed: set **When** to `daily 02:00`, then on **Only when** turn on **New commits** and pick `main`. Nights with nothing new show up in history as one folded "Skipped N times" row.

Skipped runs are quiet: they're listed in history with the reason, and nothing notifies you. A condition that can't be checked (not a git folder, a script that fails) blocks the run and tells you; after three in a row the job pauses. [docs/conditions.md](docs/conditions.md) covers each condition in detail, including the script protocol and how Ask an AI decides.

## The manager

The default **Timeline** lists:

- **New results** since you last looked. More than eight fold into one summary per job, with failures still listed one by one. When nothing is new, one line says so ("Nothing new since 08:00.").
- A **Now** rule, with any run in progress on it. It only appears when something is above it or on it.
- **Each active job** at its next run, then paused, manual-only and broken jobs at the bottom.

New results fade three seconds after you open the manager. Press `s` or click **Mark all seen** to clear them sooner. A failure marker stays on the job until its next success.

At 150 columns or wider, the selected job's details sit beside the list; Enter moves to its runs and Escape returns to the jobs. In narrower panes, Enter opens the details full-width.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/job-details-dark.png">
  <img alt="A wide manager with the timeline on the left and the selected job's details on the right: run totals (runs, succeeded, failed, missed), its latest result, schedule, folder, role and prompt, and one line per run with its outcome, duration and cost" src="docs/screenshots/job-details-light.png">
</picture>

Job details show the run totals (runs, succeeded, failed and missed, counted separately), the latest result, the job's settings and prompt, and one line per recent run with its outcome, duration and cost.

| Key | Does |
| --- | --- |
| `enter` | Open the job, or the tab of a run that needs you |
| `n` / `e` / `c` | New / edit / duplicate |
| `p` | Open the job's prompt in an editor |
| `r` | Run now |
| `x` | Stop the run in progress |
| `i` | Check the job's conditions now |
| `o` | Open the run's tab, or resume its session if the tab is gone |
| `a` | Jump to the next run that needs you |
| `space` | Pause or resume |
| `P` | Pause or resume all jobs |
| `d` `d` | Delete (`u` undoes it for 10 s) |
| `s` | Mark all results seen |
| `,` | Settings |
| `?` | Help: every key, and when jobs run |

From anywhere in Tern, the palette has **Agent Scheduler: Open manager** (`ctrl+alt+shift+m`), **New job…** (`ctrl+alt+shift+j`), **New job from selection…** (the selected text becomes the prompt), **Run a job now…** (`ctrl+alt+shift+r`), **Go to run that needs you** (`ctrl+alt+shift+a`) and **Reload** (reloads only this plugin). The Files pane's toolbar has a timer button that starts a new job in the folder it shows.

### Settings

Press `,` in the manager, or pick **Agent Scheduler: Settings** in the palette.

| Section | What's there |
| --- | --- |
| Status | Whether Agent Scheduler is ready to run jobs, and what to fix if it isn't. |
| Display | **Time format** (automatic, 12- or 24-hour, used everywhere including notifications and Carly), **Layout** (Timeline, or the **Classic job list** grouped into Needs you, Needs fixing, Running, Upcoming and Paused & finished), and **New results** (fade, or stay until marked seen). |
| Where runs start | Which session runs appear in, its name, and whether it comes to the front. |
| Limits | How many jobs run at once (2), how many finished run tabs to keep (5), and how late a missed run may still start. |
| Setup | omp's path, if it's somewhere unusual, and the data folder. |

### Carly

Ask Tern's assistant to create, list, run or pause jobs, or to check a job's conditions, for example *"Schedule a job called standup-notes in ~/Dev/app every weekday at 9am that summarises yesterday's commits, only when there are new commits on main."* Carly can also turn on **Quiet when nothing to report**.

With each request, Agent Scheduler tells Carly to use it, rather than her own scheduled tasks, for agent work in a folder that repeats or takes longer than three minutes, and to confirm a job's details with you before creating it.

> [!NOTE]
> Jobs Carly creates are active immediately with the default approval (Hands-off), and Carly can't edit or delete them; change or delete them in the manager. You get a toast and a desktop notification, and the manager marks them `by Carly`.

### From a script

Scripts, CI jobs and other agents can create a job by dropping a JSON request file into the data folder (see [Your data](#your-data)), and read the answer from a reply file:

```json
{ "format": 1, "kind": "script_create", "reply": "k3x9a2bc7q1m", "source": "mytool",
  "name": "nightly-tests", "prompt": "Run the test suite and summarise any failures.",
  "when": "weekdays 2am", "folder": "~/Dev/app",
  "only_when": { "new_commits": true, "branch": "main" } }
```

As with Carly, the job is active immediately with your default approval. [docs/script-api.md](docs/script-api.md) has a complete shell example, every field, the reply format and the file naming rules.

## Good to know

- **A run waiting for your approval** is only noticed while a desktop Tern window is open.
- **In the browser (`tern web serve`) and on iPhone and iPad,** the manager works, but palette commands, the widget, notices of runs that need you and Carly's job tools need a desktop Tern window.
- **With several Tern windows,** each window has its own sessions. A run you start (manager, palette or Carly) opens in that window's **Scheduled runs** session, and scheduled runs open in the window you last used Agent Scheduler from (the first window until you have). **Open run** shows a run's tab in whichever window holds it; a tab can't move between windows, so if it's in another window the manager says so. A run whose tab is gone reopens in the window you opened it from.
- **Remote hosts:** jobs run on the machine the plugin is installed on. To schedule runs on a remote host you've attached in Tern, install the plugin there too (run the install command in a pane on that host). It keeps its own jobs and manager, which **Open manager** and **New job…** open while you're in one of that host's sessions, and the widget shows the jobs of the host your focused pane is on when that host runs Agent Scheduler 0.10.0 or later.
- **Remote host limits:** notifications, Carly and the other palette commands cover only this computer's jobs, and a run on a remote host that waits for your approval isn't noticed.
- **Failures:** a run that hits its time limit is stopped. After three failures in a row the job pauses itself and tells you.
- **Finished run tabs:** the 5 most recent are kept and older ones are closed (**Settings › Limits** changes the number); their sessions can still be resumed.
- **Agent Scheduler paused · it ran too long** in the widget means Tern paused one of the plugin's hooks for exceeding its time budget. It resumes on its own within seconds to minutes; click it to reload the plugin sooner.
- **scheduler stalled** means the scheduler hasn't ticked lately, so due runs aren't starting. If Tern paused it, it resumes on its own; otherwise run **Agent Scheduler: Reload** from the palette.

## Your data

Jobs, prompts and run history live in Tern's plugin data folder (**Settings › Setup › Data folder**): `~/Library/Application Support/Tern/plugin-data/tern-agent-scheduler/` on macOS, `~/.local/state/tern/plugin-data/tern-agent-scheduler/` on Linux. If its files are ever damaged, the manager offers **Start fresh**.

> [!WARNING]
> Anything that can write to the data folder can create jobs or change what they run, including Hands-off ones. Keep it private to your user.

Agent Scheduler makes no network requests of its own; your runs use omp and whatever your prompts ask for.

To uninstall, run `tern plugin remove tern-agent-scheduler`. Delete the data folder to remove your jobs and history too.

## Develop

You need [Bun](https://bun.sh) for the tests; they run the plugin's Luau against fake `tern` and `omp` binaries, so they don't need Tern itself.

```sh
git clone https://github.com/bmanturner/tern-agent-scheduler
cd tern-agent-scheduler
tern plugin link .   # Tern reloads the plugin when a file changes
bun install && bun run test
```

Tests compare output against the files in `test/golden/`; `bun run test --update` rewrites them after an intended change.

- **Host half** (`host.luau`, `lib/runner.luau`): the clock, launching, the widget-bar widget (`lib/host_widget.luau`), reopened run chats (`lib/reopen.luau`) and Only when checks (`lib/cond_eval.luau`).
- **Window half** (`window.luau`): palette commands, the status segment, run observation and Carly.
- **Manager** block: `blocks/manager.luau`, with `lib/mgr_*.luau` and `manager.css`.

[`docs/design/architecture.md`](docs/design/architecture.md) is the overview; the rest of the design notes are in [`docs/design/`](docs/design/).

Bug reports and pull requests are welcome in [GitHub issues](https://github.com/bmanturner/tern-agent-scheduler/issues). CI runs `bun run test` on every pull request.

## License

[MIT](LICENSE)
