# claudebar

A [SwiftBar](https://swiftbar.app) plugin that puts the live state of every
Claude Code session in your menu bar — whether it runs on your Mac or inside
a Docker sandbox (`sbx`).

Running several Claude sessions in parallel means losing track of which one
needs you. This board fixes that — no popups, no context switching: the menu
bar is the whole interface.

![The claudebar menu bar item among other status items, reading a count per session state](assets/bar.png)

*At rest it is one status item among the others: a `✳` and a count per state —
permission, waiting, ready, working, left to right, zero counts hidden.*

![The claudebar dropdown showing host and sandbox sessions across all four states](assets/board.png)

*Open it and every session is a row: state, repo `@` branch, how long it has
sat there, and — underneath — what the session is about. That subtitle is the
session's `/resume` title, or the last thing you asked for (`❯`) until Claude
Code has written one. Sandbox sessions lead with 📦 and their box name; red
rows spell out the command awaiting your approval. Seed this board yourself
with [`examples/demo-board.sh`](examples/demo-board.sh).*

## Features

- 🚦 **Per-state counts in the menu bar** — `✳ 🔴1 🟠2 🔵3` = one permission
  prompt, two sessions waiting, three working (zero counts hidden). A dim `✳`
  when nothing is running; the leading `✳` marks the item as the Claude board
  among your other menu bar apps, and the dropdown opens with a "✳ Claude
  Code sessions" header. Prefer quieter? `BAR_STYLE="minimal"` shows a
  single `✳` that only lights up with a count when sessions need you.
  `BAR_THEME="cow"` swaps the leading marker for 🐮, permission for 🐽 and
  ready for 🥛; waiting/working keep their default dots, since color is what
  tells those two apart. More themes are a case arm away in
  [`hooks/claudebar-lib/themes.sh`](hooks/claudebar-lib/themes.sh).
- 🕵️ **Permission triage from the menu** — a red row says *what* Claude wants
  (`wants Bash`), and the full pending command (`↳ wants: Bash: git push
  origin main`) sits right under it. Decide whether it's rubber-stamp or
  worth switching, without leaving what you're doing.
- 🏷️ **Sessions show what they're about** — every row carries a subtitle
  saying what the session *is*: its `/resume` title (`↳ Wire dry-run through
  the deploy script`), lifted straight out of the transcript Claude Code
  writes. Until one exists the last prompt you gave the session stands in
  (`↳ ❯ now also run the integration tests`) — the `❯` tells you which you're
  looking at. Either way parallel sessions on the same repo stay
  tellable-apart. Harness-injected pseudo-prompts (task notifications) are
  filtered out.
- 🖱️ **One-click focus** — clicking a session row focuses its IntelliJ
  project window via the JetBrains launcher (any of `idea`/`goland`/
  `pycharm`; terminal app as fallback). **⌥-click dismisses** a stale entry.
- ⌨️ **Reachable without the mouse** — set `MENU_SHORTCUT` and a global hotkey
  opens the board; from there ↑/↓ walk the sessions and Return focuses the
  highlighted one. Rows sort longest-waiting first within each group, so where
  a session sits in the list is a fact about the session and not about the
  order its file happened to land in.
- 📦 **Sandboxes included** — sessions inside Docker sandboxes (`sbx`) report
  through a signal bridge and appear on the same board. Their rows lead with
  the box name (`📦 mybox · repo @ branch`) — with `--clone` boxes the branch
  alone rarely tells you which box you're looking at.
- ⬆️ **Tells you when it's out of date** — the bottom of the dropdown always
  names the version you're running. Once a day it asks GitHub whether there's
  a newer release; when there is, that row turns orange and links to the
  release notes, which end with the command that installs it. A second row
  copies that command to your clipboard. claudebar never updates itself and
  never notifies you — both would cost a macOS permission dialog, and the menu
  row says the same thing for free.
- 🔊 **Optional sounds** — off by default; the 🔕/🔔 toggle at the bottom of
  the dropdown enables a distinct system sound per state change (permission →
  Submarine, waiting → Glass, ready → Purr — fixed on purpose, so every
  teammate's setup sounds the same).

## Install (Mac host)

### Via npx (recommended)

One command, fully set up — no clone required, and nothing to install from a
package registry (it runs straight from this GitHub repo):

```bash
npx github:triffer/claudebar install
```

Pin a specific release with a tag or semver range if you want:

```bash
npx github:triffer/claudebar#v1.0.0 install       # exact release
npx "github:triffer/claudebar#semver:^1" install  # latest 1.x
```

Missing prerequisites (`jq`, [SwiftBar](https://swiftbar.app)) are installed
automatically via Homebrew, and SwiftBar's plugin folder is configured for you,
so the menu bar comes up without any manual folder picking. Pass `--no-deps` to
skip the auto-install and wire up only against what's already installed. Remove
everything with `npx github:triffer/claudebar uninstall`.

> Requires [Homebrew](https://brew.sh) for the auto-install step. Restart running
> Claude Code sessions afterwards so the hooks load.

### From a clone

Requires `jq` and [SwiftBar](https://swiftbar.app):

```bash
brew install jq && brew install --cask swiftbar   # launch SwiftBar once, pick a plugin folder
./claudebar/install.sh
```

The installer is idempotent — re-run it after pulling updates. It:

- copies the hook and watcher scripts into `~/.claude/`, plus the shared
  library into `~/.claude/hooks/claudebar-lib/`,
- merges the hook entries into `~/.claude/settings.json` (without duplicating
  them, and cleaning up entries from earlier versions of this setup),
- loads a launchd agent (`com.claude.notify.watcher`) that watches
  `~/.claude-signals` for events from sandboxes,
- writes `~/.claude/notify.conf` once (kept on re-install, new keys appended on
  upgrades), auto-detecting the JetBrains `idea` launcher and your terminal,
- copies the plugin into your SwiftBar plugin folder.

Restart running Claude Code sessions afterwards so the hooks load.

Remove everything with `./claudebar/install.sh --uninstall` (or `npx
github:triffer/claudebar uninstall`).

## Staying up to date

The last row of the dropdown is the version you are running — click it for the
releases page, ⌥-click it to check for a newer one right now.

Once a day the board asks GitHub for the newest release. When one turns up that
row becomes an orange **⬆ claudebar X.Y.Z available — read the release notes**,
and clicking it opens that release. Every release ends with the command that
installs it, ready to copy:

```bash
npx github:triffer/claudebar#v1.3.0 install
```

Underneath sits **↳ you have vX.Y.Z · copy the update command**, which puts the
same line on your clipboard — tailored to how you installed, so a clone gets
`cd "<your checkout>" && git pull && ./install.sh` instead.

The only thing that reaches the network is one `curl` a day,
and `UPDATE_CHECK_HOURS=0` stops even that (the ⌥-click still works).

The version lives in `installed.sh`, which the installer generates inside
`~/.claude/hooks/claudebar-lib/`. `claudebar version` prints both what a 
package would install and what is currently installed.

## Sandboxes

Mount the signal bridge (read-write, the default) when creating a sandbox, and
add the bundled kit — it symlinks your `~/.claude/hooks/` into the sandbox (the
hook and the `claudebar-lib/` it sources, in one link) and merges the hook
registrations into the sandbox settings:

```bash
sbx create claude . \
  ~/.claude:ro \
  ~/.claude-signals \
  --kit <this-repo>/claudebar/sbx-kit
```

The kit is self-contained: teammates only need this folder, `jq` in the sandbox
image (the default Claude sbx image has it), and the two mounts above. If you
already use a richer kit that links hooks and merges settings itself (like this
repo's `sbx/claude-config`), you don't need `sbx-kit` on top.

sbx mounts keep their host path inside the microVM, which dictates two things:
the bridge appears at `/Users/<you>/.claude-signals` in the sandbox, and it has
to be a *sibling* of `~/.claude` rather than a subdirectory — the `~/.claude`
mount is read-only, so nothing inside it would be writable.

On non-macOS the hook auto-discovers the bridge via the `/Users/*/.claude-signals`
glob and drops status records there; the launchd watcher on your Mac applies
them to the status store within a couple of seconds. `CLAUDE_SIGNALS_DIR`
overrides the probe if your layout differs — and setting it to the *empty*
string forces local delivery instead, which is how the test suite runs the hook
on Linux CI without it guessing it's in a sandbox.

**`--clone` boxes**: in clone mode the working tree is a standalone clone
(kept at the same path as the host repo), and the hook (detecting
`/run/sandbox/source`) derives the repo name from the clone's `origin` remote,
so the row still reads `📦 mybox · repo @ branch` even after the agent
switches to its own branch. Clicking the row focuses the repo's IDE window on
the host — note that window shows the *host's* state of the repo; the box's
commits appear there only after `git fetch sandbox-<name>`.

## Configuration — `~/.claude/notify.conf`

| Variable             | Default       | Meaning                                            |
|----------------------|---------------|----------------------------------------------------|
| `IDE_CMD`            | auto-detected | JetBrains CLI launcher; "Focus IDE project" opens/focuses the session's project window with it |
| `TERMINAL_BUNDLE_ID` | auto-detected | App the fallback "Focus terminal" action activates when `IDE_CMD` is empty |
| `STALE_HOURS`        | `1`           | Menu bar hides sessions idle longer than this      |
| `BAR_STYLE`          | `detailed`    | `detailed` = per-state counts in the bar; `minimal` = single ✳ |
| `BAR_SHOW_WORKING`   | `1`           | Show the 🔵 working count in the detailed bar      |
| `BAR_THEME`          | `default`     | Icon set for the state markers: `default` or `cow` |
| `MENU_SHORTCUT`      | `CTRL+OPTION+CMD+C` | Global hotkey that opens the board; empty = none |
| `UPDATE_CHECK_HOURS` | `24`          | How often to ask GitHub for a newer release; `0` = never |

The file is plain bash, sourced by the menu bar plugin.

**Focus behavior**: each session records its git toplevel, and `idea <root>`
focuses the window of an already-open project (and opens it otherwise) — so the
menu bar action jumps to the *right* IntelliJ window, for host and sandbox
sessions alike (sbx keeps working trees at their host path in both mount and
clone mode, so the recorded root is valid on the Mac). Works with any
JetBrains launcher; point `IDE_CMD` at `goland`, `pycharm`, etc. if that's
your IDE.

**Keyboard navigation**: `MENU_SHORTCUT` is registered by SwiftBar as a global
hotkey on the menu bar item itself, which is what makes it *open the board*
rather than run some particular row's action. Everything after that is stock
macOS menu behaviour — ↑/↓ move between rows and skip the group headings and
`↳` detail lines (they are disabled items), Return activates the highlighted
row, Esc closes.

The default is **⌃⌥⌘C**, and three modifiers is not an accident. A global
hotkey outranks the frontmost app's own, so a collision doesn't fail loudly —
it silently stops that shortcut working everywhere, with nothing to point the
blame back here. That rules out the crowded neighbourhoods: `⌘Space`/`⌥Space`
(Spotlight, Raycast, Alfred), `⌃⌘Space` (emoji), `⌘⇧3/4/5` (screenshots), and
plain `⌘⌥<letter>`, which is where JetBrains keeps its refactorings. Any
combination of `CMD`, `OPTION`, `CTRL`, `SHIFT` and `FN` works; empty turns the
hotkey off.

## Troubleshooting

- **Board never changes** — check that the hooks are registered:
  `jq .hooks ~/.claude/settings.json`, and restart Claude sessions started
  before the install.
- **Sandbox sessions missing** — is the watcher loaded?
  `launchctl list | grep com.claude.notify` — and check
  `~/.claude/watcher.error.log`. Verify the sandbox was created with the
  `~/.claude-signals` mount (inside the sandbox,
  `ls -d /Users/*/.claude-signals` must exist and be writable) and the
  `sbx-kit` kit.
- **Malformed events** land in `~/.claude/signals-rejected/` instead of looping.
- **Menu bar shows stale sessions** — sessions from crashed/killed Claude
  processes never send `SessionEnd`; they fade out after `STALE_HOURS` and are
  deleted after 2 days, or use the per-session *Dismiss* / *Clear all* actions.


## Contributing & releases

Releases are fully automated with [semantic-release](https://semantic-release.gitbook.io/).
Every merge to `main` runs the `Release` workflow, which reads the commit
messages, decides the next version, tags it (`vX.Y.Z`), updates `CHANGELOG.md`,
and creates a GitHub Release. There's no npm-registry publish — the tool is
distributed straight from this repo (`npx github:triffer/claudebar`), so the
git tag *is* the release artifact and `#semver:` ranges resolve against it.

Every release's notes end with the command that installs that exact version
(`npx github:triffer/claudebar#vX.Y.Z install`), appended by
`@semantic-release/exec` in `.releaserc.json`. That line is what the menu bar
points people at, so it has to be on every release, not just the ones somebody
remembered to write it into.

Because the version is derived from commits, **commit messages must follow
[Conventional Commits](https://www.conventionalcommits.org/)**:

| Commit prefix                     | Release        |
|-----------------------------------|----------------|
| `fix: …`                          | patch (`x.y.Z`)|
| `feat: …`                         | minor (`x.Y.0`)|
| `feat!: …` / `BREAKING CHANGE:`   | major (`X.0.0`)|
| `chore:`, `docs:`, `refactor:`, … | no release     |

Every PR runs `commitlint` against its commits, so a non-conforming message is
caught before merge. Don't bump the version in `package.json` by hand — it is
managed by the release pipeline.

### Tests

```bash
npm install
npm test
npx bats test/board-render.bats   # one file
```

The suite runs the real scripts — the hook, the watcher, the SwiftBar plugin
and `install.sh` — against a throwaway `HOME`, so nothing touches your own
sessions or `~/.claude`. `install.sh` is exercised for real (with `uname` and
`launchctl` stubbed) because it edits your `settings.json`, which makes it the
riskiest file in the repo. `curl` is stubbed too, so the update check is tested
without a suite that depends on GitHub being up and un-rate-limited. It runs on Linux CI too, which is why the hook
accepts `CLAUDE_SIGNALS_DIR=""` to force local delivery instead of guessing
host-vs-sandbox from `uname`.

## How it works

```
   host session                     sandbox session
        │                                 │
        ▼ hooks                           ▼ hooks
  claude-notify.sh                  claude-notify.sh
        │                                 │ writes evt_*.json
        │                                 ▼
        │                  /Users/<you>/.claude-signals (rw mount of ~/.claude-signals)
        │                                                              │
        │                                          launchd (QueueDirectories)
        │                                                              │
        │                                              claude-signal-watcher.sh
        │                                                              │
        └───────────► claudebar-lib/record.sh (the store) ◄────────────┘
                                      │
                                      ▼
                         ~/.claude/notifier-sessions/*.json
                                      │
                                      ▼
                    SwiftBar plugin (claudebar.3s.sh)
```

### Repository layout

Everything shared sits in `hooks/claudebar-lib/`, and every script sources it
rather than re-deriving paths or re-describing the record:

| File                                | Responsibility |
|-------------------------------------|----------------|
| `hooks/claudebar-lib/paths.sh`      | Where things live: the store, the config, both ends of the signal bridge. The single place any of those paths is spelled out. |
| `hooks/claudebar-lib/record.sh`     | The status record — its field list, building it, reading it back, storing it, relaying it. |
| `hooks/claudebar-lib/transcript.sh` | Lifting a session's `/resume` title out of the transcript, and deciding when to look. |
| `hooks/claudebar-lib/version.sh`    | Which version is installed (from the stamp `install.sh` generates beside it), comparing it against the newest release, and the cache that keeps the check off the network. |
| `hooks/claude-notify.sh`            | The hook: hook event → state → record. |
| `host/claudebar.3s.sh`              | The SwiftBar plugin: records → menu bar. |
| `host/claude-signal-watcher.sh`     | Applies records a sandbox left on the bridge. |
| `host/claudebar-focus.sh`           | The click action behind a session row. |
| `host/claudebar-update.sh`          | The version row's two actions: `--check` asks GitHub now, `--copy` puts the update command on the clipboard. It installs nothing. |

The library lives **inside** `hooks/` on purpose: `sbx-kit/spec.yaml` symlinks
exactly that one directory into a sandbox, so the library rides along with the
hook. A sibling directory would resolve on the host and be missing inside the
microVM — a break you'd only ever see in sandboxed sessions.

That makes `~/.claude/hooks/` the landing site, and it is **shared space** —
your own hook scripts live there, and so may other tools'. Hence two rules the
installer follows:

- The directory is `claudebar-lib/`, not `lib/`. A generic name in a shared
  folder is a collision waiting to happen.
- Install drops a `.claudebar` marker file inside it, and neither install nor
  uninstall will `rm -rf` that directory without finding the marker first. If
  something else ever owns the name, you get an error telling you to move it
  aside — never a silently deleted directory. Files elsewhere in
  `~/.claude/hooks/` are never touched.

Everything the library exports is prefixed `CLAUDEBAR_*` / `claudebar_*`, for
the same reason at the shell level: `notify.conf` is user-edited bash sourced
into the same shell, and the prefix is what stops a stray assignment there from
shadowing a path.

The record is the contract between the hook that writes it and the plugin that
renders it. Both directions are generated from the one field list in
`record.sh`, so adding a field is a single edit and the two ends cannot drift
apart — which they previously could, silently, since a reader that misses a
field just yields an empty string.

One hook script handles six Claude Code events and tracks a state per session:

| Event                                            | State           |
|--------------------------------------------------|-----------------|
| `UserPromptSubmit`, `PreToolUse`                 | 🔵 `working`    |
| `Notification` (permission)                      | 🔴 `permission` |
| `Notification` (idle / other)                    | 🟠 `waiting`    |
| `SessionStart` (new/resumed, sitting at prompt), `Stop` (response finished) | 🟢 `ready` |
| `SessionEnd`                                     | removed         |

(`SessionStart` from auto-compaction is ignored — it fires mid-task and must
not flip a busy session.)

`PreToolUse` is registered for two reasons: a session flips back to `working`
right after you answer a permission prompt, and — since `PreToolUse` fires
*before* the permission prompt resolves — it captures the pending tool + input
into a per-session context file, which is how permission rows can say what
Claude wants to run. `UserPromptSubmit` stores your prompt in the same context
file so every status record carries it. Repeated tool calls are deduped down
to a context-file update (no record churn).

### Session titles

Every hook payload carries a `transcript_path` pointing at the JSONL Claude
Code streams the conversation to, and Claude Code drops title records into it —
the strings its `/resume` picker lists. The hook picks the newest one out of
that file and parks it in the context file, where it becomes the row's
subtitle. No title yet just means the row shows your last prompt instead.

Two spellings are accepted, because the record changed shape between versions:

| Claude Code | record                                |
|-------------|---------------------------------------|
| 2.1.x       | `{"type": "ai-title", "aiTitle": …}`  |
| older       | `{"type": "summary", "summary": …}`   |

Three properties this leans on, because the transcript format is Claude Code
internal and gets no compatibility promise:

- **Scans that back off.** `SessionStart` always scans — it happens once per
  session and it's what makes a resumed session show its inherited title
  right away. After that only `UserPromptSubmit` and `Stop` scan: while the
  session has no title they scan every time, since Claude Code writes the
  first one within the opening exchanges and a fresh row shouldn't sit on a
  bare prompt waiting for a timer. Once a title exists they drop to once every
  10 minutes — a long session would otherwise re-read a big transcript every
  turn to re-find a string that hasn't moved. Set
  `CLAUDE_NOTIFY_SUMMARY_TTL=<seconds>` to tighten or loosen that.
- **Bounded reads.** Only a 200-line head and a 500-line tail are ever
  scanned, and `tail` seeks from the end — a 100 MB+ transcript costs ~30 ms.
  The plugin never opens a transcript at all; its 3 s refresh only reads the
  status records, so transcript size cannot slow the menu down.
- **Fail-silent parsing.** Malformed, truncated or reshaped records are
  dropped rather than raised — a scan that finds nothing leaves the previous
  title in place. If the format ever changes, rows quietly fall back to the
  last prompt instead of the hook breaking your session.
