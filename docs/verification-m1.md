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
