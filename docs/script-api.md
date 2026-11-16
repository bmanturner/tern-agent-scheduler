# Creating jobs from a script

Scripts, CI jobs and other agents can create an Agent Scheduler job by dropping a request file into the plugin's data folder. Tern must be running. Agent Scheduler picks the request up on its next pass, usually within 2–3 seconds, deletes it, and answers in `replies/<reply>.json`.

This request and its reply are a stable, public format: fields are only ever added as optional ones, and `format` changes only for a breaking change.

```sh
D="$HOME/Library/Application Support/Tern/plugin-data/tern-agent-scheduler"   # macOS
# D="$HOME/.local/state/tern/plugin-data/tern-agent-scheduler"                # Linux
ID=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 12)
F="$D/intents/$(date +%s)000-mytool-1.json"
cat >"$F.tmp" <<EOF
{ "format": 1, "kind": "script_create", "reply": "$ID", "source": "mytool",
  "name": "nightly-tests", "prompt": "Run the test suite and summarise any failures.",
  "when": "weekdays 2am", "folder": "~/Dev/app",
  "only_when": { "new_commits": true, "branch": "main" } }
EOF
mv "$F.tmp" "$F"
for _ in $(seq 20); do [ -f "$D/replies/$ID.json" ] && break; sleep 0.5; done
cat "$D/replies/$ID.json"
```

## The request

The request is one JSON object:

| Field | |
| --- | --- |
| `format` | `1` |
| `kind` | `"script_create"` |
| `reply` | Required. Exactly 12 lowercase letters and digits; names the reply file. Make it unique per request: nothing checks, and a reused ID overwrites the earlier reply. |
| `prompt`, `when`, `folder` | Required. What the agent should do, the schedule as you'd type it in the form, and the project folder (a full path or `~/…`). Your home folder itself is refused; pick a project folder. |
| `name` | Optional. When missing, it's made from the prompt's first five words, with `-2`, `-3` and so on added if that name is taken. |
| `role` | Optional omp role, e.g. `@smol`; `@default` when missing. |
| `quiet_ok` | Optional `true` or `false`: **Quiet when nothing to report**. |
| `only_when` | Optional object, described below. |
| `source` | Optional. Your tool's name, 1–24 letters, digits, `-` or `_`; the manager marks the job `by <source>` (`by script` without one). |
| `expires` | Optional unix seconds. A request still waiting after that is refused instead of applied late. |

Any other field is refused, so a typo can't quietly make a job you didn't ask for. The job is active immediately with your default approval (**Hands-off** unless you've changed it in Settings); a request can't choose its approval. You get a toast and a desktop notification, as with Carly.

### `only_when`

Every key is optional, and an unknown key is refused like an unknown top-level field.

| Key | |
| --- | --- |
| `new_commits` | `true` or `false`: run only when the branch has new commits. |
| `branch` | The branch to watch; the folder's current branch when missing. |
| `folders` | Only count commits touching these folders: a list, or comma-separated text. |
| `days` | `weekdays`, `weekends`, `every day` (or `daily`), or days such as `mon,wed`. |
| `from`, `to` | Times of day such as `09:00` or `6pm`. |
| `quiet_hours` | `true` runs outside `from`–`to` instead of inside it. |
| `max_runs`, `max_usd`, `per` | Run or spend limit, per `day` or `week`. |
| `ask`, `ask_model` | A question for a model to answer before each run, and the role it uses. |

See [conditions.md](conditions.md) for how each condition behaves.

## The reply

On success, the reply is `{"format":1,"ok":true,...}` with `job_id`, `name`, `when`, `next` (text), `next_at` (unix seconds; missing for manual-only jobs), `folder`, `role`, `approval`, `only_when`, `quiet_ok` and `source`.

On failure, it's `{"format":1,"ok":false,"error":"..."}` with the message the form would show.

Read the reply right away. Replies are cleaned up by an hourly pass, between one and two hours after they're written.

## Request files

- Name request files `<digits>-<letters and digits>-<digits>.json`; they're applied in name order, and files with other names are ignored.
- Write them under another name first and rename them into place, as above, so a half-written file is never read.
- Files over 16 KiB are deleted without a reply, and so is a file that still isn't valid JSON after a minute.
- These are dropped without a reply: a request without a valid `reply`, and one whose `format` isn't `1` or whose `kind` isn't one Agent Scheduler knows.
