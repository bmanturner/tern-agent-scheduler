# Only when: conditions in detail

A job's **Only when** page decides whether a due run starts. The [README](../README.md#only-when) introduces the five kinds of condition; this page covers how each one behaves.

## Skipped and blocked runs

A run that doesn't qualify is listed in the job's history as **skipped** with the reason; repeats fold into one "Skipped N times" row, and nothing notifies you.

If a condition can't be checked (not a git folder, a script that fails), the run is **blocked** and you're told once. After three blocked runs in a row the job pauses.

**Run now** checks the conditions first and asks **Run anyway?** when one says no. `i` in the manager, and **Check now** on the Only when page, check them without starting anything.

## New commits

A due run starts only when the branch you pick (or the folder's current one) has commits since the last successful run, optionally only in some folders. The agent gets the new commits in an attached `trigger.md`.

The first run of a new-commits job notes where the branch is and waits for something new.

## Time

A due run starts only on the days and between the times you pick, or, with quiet hours, outside them.

## Limits

A due run starts only while the job is under that many runs or that much spend today, or this week.

## Your own check

Your script runs in the job's folder with a 30 s limit, and gets the path to a JSON file that describes the run as its argument:

| Your script | Means |
| --- | --- |
| Exits 0 | Run |
| Exits 1 | Skip |
| Exits with anything else | The run is blocked |
| Prints `REASON: …` | Shown in history |
| Prints `CONTEXT: …` lines | Passed to the agent |
| Prints `CURSOR: …` | Handed back to your script next time |

Saving the job approves the script as it is then; if it changes, runs are blocked until you open the job and save again. Carly can set every condition except this one.

## Ask an AI

For judgement calls a script can't easily make, such as *"Are there open pull requests that still need a review?"* Before a due run, omp runs in the background with your question, the job's name, folder, time and last run, and whatever the other conditions found (for example the new commits). It's checked last, so it's only asked when everything else says yes.

- It can read and search files (and read web pages) but can't change anything or run commands.
- It has 60 s to end with `ANSWER: run` or `ANSWER: skip` and a reason. A skip is listed in history with that reason; a run hands the reason to the job's agent in `trigger.md`. An answer it can't give blocks the run, like a failing script.
- Each check is one model call with the role you pick, so use a small one such as `@smol`. Its cost counts toward Limits, and **Check now** asks it too.
