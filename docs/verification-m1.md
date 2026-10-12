# M1 verification (gate spike), Tern 0.7.2, omp 18.9.1

Run on 2026-10-11. Real-daemon probes used a throwaway `SchedProbe` session (killed afterwards) and the `@tiny` role only. Daemon-lifetime and restart checks used an isolated daemon (`TERN_CONFIG_DIR=/tmp/tas/cfg`, `TERN_DAEMON_SOCKET=/tmp/tas/d.sock`, removed afterwards).

| V | Result | Consequence |
|---|---|---|
| V30 args | `cx:new_block(kind, args: {string}?, how?, reveal?)` and `init(cx, args: {string}, saved)` (types for 0.7.2): args are a **list of strings**, not a table. tern-swarm ships the same pattern (`cx:new_block("swarm.settings", {pid}, "tab")`). A headless `tern serve` window does not load plugins, so it could not be run end-to-end here. | Manager args are `{"list"}` / `{"new", <cwd or "">}`. The user confirms "New job" from the palette in the manual window check. |
| V30 multi-line editor | tern-swarm `blocks/new-task.luau` drives an `editor` node with `textfield.key(f, k, true)` in a host block (shipping). | The Prompt row stays a multi-line editor. No `ctrl+o` fallback needed. |
| V30 `prefs` in host block | tern-swarm `blocks/settings.luau` renders `ui.node("prefs", …)` in a host block (shipping). | Form and Settings use `prefs`. |
| V26 two windows | `tern new --help`: "Every command works on one window's sessions: --window KEY's, else the window of the pane it runs in, else the first window." The host has no window key. | Sessions are per window. Runs land in the **first window**'s "Scheduled runs" session. Setup and Help say so. |
| V28 zero windows | Isolated daemon, no window: with (a) a live kept pane and (b) only an exited `--keep-open` pane, the daemon and the host timer kept running (heartbeat age 4 s after 90 s each). With (c) no pane, the daemon exited within 60 s. | DEC R20 copy holds: the scheduler keeps running while any terminal or kept run pane is open. A kept finished run pane is enough. |
| V29 restart | After a daemon restart the block keeps its id (`3`), `program=/bin/zsh`, **`args=["-l"]`**, `live=true`, but **`command` still holds the old command line**, marker included. | The marker rule must read **`args[3]`** (the `-c` string), not `command`. A block is ours only if `args[2]=="-c"` and `args[3]` contains `/runs/<job>/<run>/`. |
| V1 quoting | `tern new tab … -- /bin/echo 'a b' "it's" '$HOME' -x é` → `/bin/echo 'a b' 'it'\''s' '$HOME' -x 'é'`; output `a b it's $HOME -x é`. Spaced `--session-dir` / `@file` paths survived. | Tern quotes correctly. Keep the unsafe-character gate anyway (defence in depth). |
| V4 keep-open | `sh -c 'exit 0'` with `--keep-open`: block stays, `exited: 0`, `live: true`, `keep_open: true`. `tern close` removes it (exit 0). | As designed. |
| V18 `exited` JSON | Integer exit status (`0`); `null` while running. | `exited ~= nil` means the program ended. |
| V3 no sessions | `{"sessions":[],"detached":[]}`, exit 0. | No text fallback needed (kept harmlessly). |
| V5 new session shown? | After `tern new session SchedProbe`: `SchedProbe shown=false`, shown tab and focused block unchanged. | No focus guard needed for the default placement. |
| V7 `@file` auto-submit | First user message: `<file name="…/prompt.md">Reply with exactly: pong</file>\nRun the scheduled job described in the attached file.`; reply `pong`. | Attachment form ships. |
| V8 spaced path | Same run, under `…/Application Support/…`. Works. | — |
| V6 `--append-system-prompt <file>` | Preamble "end with ZETA-7731" → reply `pong\nZETA-7731`. | File form ships. |
| V2 flags | `--model --approval-mode --max-time --session-dir --append-system-prompt --config --allow-home -e --resume` present in 18.9.1 and 18.8.6. `--approval-mode` values are `always-ask|write|yolo`. | Map `always_ask` → `always-ask`. |
| V14 `ask.enabled:false` | Tool list without `ask`. | Hands-off disables `ask`. |
| V15 `--max-time` | At 8 s the running `bash sleep 60` was aborted ("Command aborted"); omp stayed alive and idle; the pane did **not** exit. | Time limits are enforced by the host deadline (`started + max_runtime_s + MAXRUN_GRACE_S`): classify from the session tail, then `tern close`. |
| V16 `pane_exited.pane` | `{"pane":4294967298,"status":0}` = block id from `tern new`. | Accelerator works; compare as `string.format("%.0f", pane)`. |
| V12 `/bin/test` | `-d` on missing, on a file and on a permission-denied path all exit 1, no stderr. | One copy for all: "doesn't exist or can't be opened". |
| V20 `--session-dir` layout | Flat: `D/<ISO>_<id>.jsonl`, plus a same-named artifacts dir and a hidden `.…jsonl.lock.os`. | Locate = newest `*.jsonl` not starting with `.` in `D`. |
| V21 tail 1 MiB | `tail -c 1048576` on a 2 MiB file: status 0, 1 048 576 bytes. | — |
| V22 cost | Per assistant message `message.usage.cost.total` (e.g. 0.0027). | Run cost = sum over assistant messages in the tail. Sub-agent cost not separately located (not needed in M1). |
| V23 `--resume` | `omp --session-dir D --resume <file> --approval-mode write --config <omp.yml>` continued the same JSONL, model Haiku, cwd `/tmp`. | Open run ships as designed. `tern close` appends a `session_exit` (`sighup`) record. |
| V31 overlay vs project config | `/tmp/ov/.omp/config.yml` with `bash: allow`: with the overlay (`bash: prompt`) the bash call waited for approval; without it, it ran. | Non-yolo overlay ships as designed. |
| V32 osascript argv | Hostile text `x" & (do shell script "touch /tmp/pwn") & "` shown literally; `/tmp/pwn` not created. | Notifications ship. |
| V27 end to end | Job `e2e` (`@tiny`, `/tmp`, `in 2m`, prompt `Reply with exactly: RESULT: pong`) created through the host: it launched 13 s after its slot into a new "Scheduled runs" session (tab `⏲ e2e`), went `scheduled → launching → running → finished` with `summary = "pong"`, cost $0.00029, `session_file` set; the user's focused block was unchanged. One window was open (`observed = true`). The zero-window repeat needs every window closed, so it is left to the user. | M1 shippable. |
| Host clock | In the host, `os.time({…})` reads the table as **UTC** while `os.date("*t")` is local, so `weekdays 9am` first resolved to 08:00 CDT. | `lib/cron.luau`'s default clock now corrects the guess until `os.date("*t")` shows the requested wall time; `test/t9.luau` covers it. `jobs.load` recomputes cached `next_run` from the cursor. (`docs/design/engine-src/cron.luau` is the pre-fix copy.) |

## Linux (Ubuntu 24.04, Tern 0.8.0, omp 18.8.3)

Run against an isolated daemon (`TERN_CONFIG_DIR` and socket under `/tmp`, removed afterwards) on a headless home server.

| Check | Result |
|---|---|
| Plugin load | Host half ready (1 block) on Tern 0.8.0. |
| Pane wrapping | Tern runs pane commands as `$SHELL -l -c '<command>'` (`/usr/bin/zsh` here), the same shape as macOS, with correct quoting; the run marker in `args[3]` works unchanged. |
| Binaries | `tern` and `omp` found in `~/.local/bin` and validated with `--version`. No Tern-managed omp on this box; Tern keeps it under `$XDG_DATA_HOME` on Linux, which is now a candidate. |
| Data folder | `~/.config/tern/plugin-data/tern-agent-scheduler` (`$TERN_CONFIG_DIR/plugin-data/…`). |
| Daemon lifetime | With no window and no pane left the daemon stops ("daemon stopped kind=idle"), as on macOS. |
| End to end | A Carly-style `in 2m` job (`@smol`, Hands-off) launched into a new "Scheduled runs" session as `⏲ linux-e2e-2` and finished unobserved (no window) with summary `Linux`, cost $0.056. |
| One-shot regression | The first attempt was cancelled as "Stopped by you": the review fix that cancels waiting runs of paused jobs also caught a one-shot, which turns itself off when its run is claimed. Fixed in the runner, covered by `test/runner_once.luau` (fails before, passes after); affected macOS too. |
| Notifications / Open folder | `notify-send` and `xdg-open` are used when installed; not visible on a headless box, so unverified visually. |

## Linux, v0.2.0 (Ubuntu 24.04.5, Tern 0.8.2, omp 18.8.3)

Run on 2026-10-12 on the same headless server: the host half against an isolated daemon (`TERN_CONFIG_DIR` under `/tmp`, socket in a `0700` directory, which the daemon requires), the window half in a headless `tern serve` window. Everything was removed afterwards.

| Check | Result |
|---|---|
| Install | `tern plugin install github.com/bmanturner/tern-agent-scheduler` installed 0.2.0; host half ready (1 block). |
| Binaries and Setup | `tern` and `omp` found in `~/.local/bin`; cached `tern_version` is `tern 0.8.2 (44c7f76)`, which passes the Setup check; `setup_ok` true. |
| End to end | A Carly-style `in 2m` job (`@smol`, Hands-off, `/tmp`) fired on its slot (09:20:00, started 09:20:03) into a new "Scheduled runs" session as `⏲ linux-e2e-0-2-0` and finished unobserved at 09:20:49 with summary `Linux`, cost $0.052. No plugin warnings in `tern-daemon.log`. |
| Window half | `tern serve` pins the clock, so timer callbacks never run and the staged loader in `window.luau` never starts. A throwaway copy that loads the modules at top level loaded every module, registered the commands, and **Open manager** opened the manager, which rendered its welcome view with the three examples. |
| Key binds | Tern's Linux preset already binds `ctrl+alt+shift+s`, so **Open manager**'s shortcut was left out (`plugin bind left out: the preset binds these keys`). `ctrl+alt+shift+j`, `r` and `a` bind. Of the other chords probed, `e`, `g`, `k` and `o` are taken on Linux and `m`, `l`, `d` and `q` are free on both Linux and macOS. 0.2.1 adds `ctrl+alt+shift+m` and keeps `s` for macOS. |
| Not covered headless | `agent_finished`, the status line, the timer watchdog and notifications need a desktop Linux window. |

## Linux as a remote host of the macOS window, v0.2.1 (Tern 0.8.2)

0.2.1 installed into the Linux host's real Tern (`~/.config/tern/plugins`), driven from the macOS window that has it attached as host `foglet-herdr`, then removed with its data folder.

| Check | Result |
|---|---|
| Data folder | `~/.local/state/tern/plugin-data/tern-agent-scheduler` (Tern's `<state>` directory on Linux), not `~/.config/tern/…`; the README said the latter. |
| Manager on the remote host | With the window switched to the host (`cx.hosts:switch`), `cx:new_block("tern-agent-scheduler.manager", …)` opened the Linux host half's manager in the macOS window. The list, the New job form and its rows rendered, keys sent with `tern send` reached the block, and `r` on a job started it. |
| Remote run | The run opened in the Linux host's own "Scheduled runs" session and finished `ok_unobserved` (summary `remote`, $0.0057) while the macOS window showed it: the macOS window half reads only the macOS data folder, so it never sampled the run (`observed = false`; the macOS snapshot listed no in-flight run). |
| Open manager from the remote host | Read from the code, not exercised: `open_manager` focused any manager listed in this machine's snapshot before opening one on the window's current host, so with the macOS manager open it would focus that one instead of the remote host's. 0.2.2 skips that check on a remote host and starts the manager in the remote pane's folder (`test/runner_commands.luau`). |
| Ids | Two fresh Linux setups both named their first job `j_cafy5vvk`: `math.randomseed` repeats one sequence for every seed past the 32-bit range, and the seed was a millisecond timestamp. 0.2.2 folds it into 31 bits (`test/runner_ids.luau`). |
| `tern open` from a remote pane | Not routed through the macOS window's `tern.route.open`: the Linux daemon opened the file itself. |
