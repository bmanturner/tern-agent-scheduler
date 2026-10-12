# Agent notes

## Tern version

The plugin states one Tern version: the one it was most recently built and tested on. There is no separate minimum version, and code and docs carry no notes about how older Tern versions behaved. When you build and test against a newer Tern, update all of these to that version together:

- `README.md`, the "Built and tested on Tern X" line under Install.
- `lib/runner.luau`, `setup_rows`: the `version_at_least` check on the Tern row and its "built and tested on" message. Settings › Setup flags any older Tern.
- `test/fake_tern.luau` and `test/runner_io.luau`: the fake `tern --version` output, so the tests run as the tested version.
- `tern.d.luau`: regenerate with `tern plugin types .`.

Then run `bun run test`, and name the version in the next `CHANGELOG.md` entry.

## Releasing

`tern plugin install` clones the tip of `main`, so whatever lands on `main` reaches users on their next update. Keep `main` releasable and CI (`.github/workflows/test.yml`) green.

1. Bump `version` in `plugin.toml` (semver; Tern only displays it).
2. Add a `CHANGELOG.md` section for it: user-facing changes under Added, Changed and Fixed, and the Tern version it was built and tested on. Call out anything users must act on.
3. Commit, tag `vX.Y.Z`, push `main` and the tag.
4. `gh release create vX.Y.Z --title vX.Y.Z --notes-file <that section>`.

## Window budget

Every window-half call has a 50 ms budget. One timer callback over it turns off every timer callback of the plugin in that window until plugins reload (`pcall` can't catch it). Keep timer passes far below it: the status and observer passes log anything over `const.WINDOW_SLOW_MS` (20 ms), and the watchdog in `window.luau` tells the user when the timers have stopped.

## Developing

The plugin is usually linked (`tern plugin link .`), and any write inside the package folder reloads it, including docs, `CHANGELOG.md` and scratch files. Put scratch output outside the repo, and expect a reload after every save while timing anything in a live window.
