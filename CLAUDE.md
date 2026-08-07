# claudebar

Claude Code session status in the macOS menu bar (SwiftBar). Pure bash + jq.
See the README for architecture; this file covers conventions only.

## Tests

`npm test` runs the bats suite in `test/`. Add tests for behaviour changes.

Structure every test as **arrange / act / assert**, with the three blocks
separated by blank lines and no section-label comments. Comments explain *why*,
not which phase you're in:

```bash
@test "stale sessions drop off the board" {
  put_record fresh state=ready
  put_record old state=ready ts=$(( $(date +%s) - 7200 ))

  STALE_HOURS=1 run bash "$BOARD"

  [ "${lines[0]}" = "✳ 🟢1" ]
}
```

Tests run the real scripts against a throwaway tree (see `test/helper.bash`) —
never the developer's own install.

**Redirecting `HOME` is not enough on macOS.** `defaults` resolves the user's
home from the password database, so `defaults read com.ameba.SwiftBar` returns
the *real* plugin folder however `HOME` is set — which is how a test run once
deleted a developer's installed menu bar plugin. Anything that reaches the
machine rather than the filesystem needs an explicit seam:

- host-touching commands (`defaults`, `open`, `launchctl`, `afplay`, `brew`,
  `osascript`) are stubbed onto `PATH` and log their calls; `refute_called`
  asserts one was never used,
- the SwiftBar plugin folder is passed in via `CLAUDEBAR_PLUGIN_DIR`,
- `claudebar_assert_isolated` refuses to run the suite at all if any of those
  point outside the temp tree.

When adding a script that shells out to a macOS command, stub it and add it to
`CLAUDEBAR_STUBBED_COMMANDS` before writing the test.

## Shell conventions

- Shared code lives in `hooks/claudebar-lib/`; scripts source it rather than
  re-deriving paths or re-describing the status record.
- Everything the library exports is prefixed `CLAUDEBAR_*` / `claudebar_*` —
  `notify.conf` is user-edited bash sourced into the same shell.
- Target **bash 3.2**: that's `/bin/bash` on macOS. No associative arrays, and
  under `set -u` never expand a possibly-empty array (`${#arr[@]}` on an empty
  array aborts there). Brace any expansion that touches a non-ASCII character —
  3.2 reads the high bytes as part of the name, so `"$VERSION…"` looks up a
  variable called `VERSION…`. `test/bash32.bats` scans for both; CI runs bash 5
  and cannot reproduce either.
- `~/.claude/` is shared space. Namespace anything written into it, and never
  `rm -rf` a path without first proving claudebar created it.
- The hook must never fail a Claude session: it exits 0 no matter what.

## Commits

Conventional Commits — `semantic-release` derives the version from them, and CI
lints every commit in a PR. Don't bump `package.json` by hand.

**Max line length is 100** — enforced by commitlint on the header *and* on every
body and footer line, so wrap the body rather than writing one long paragraph.
Dependabot's own commits are exempt (`ignores` in `commitlint.config.js`): it
generates compare links that are longer than 100 characters on one line.
