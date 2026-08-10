#!/usr/bin/env bash
# render-screens.sh — draw the README's menu bar and dropdown pictures from the
# demo sessions, without a Mac and without a screenshot.
#
#   ./examples/render-screens.sh            # writes assets/bar.svg, assets/board.svg
#   ./examples/render-screens.sh --check    # fail if the committed SVGs are stale
#
# The pictures are not mock-ups: this seeds examples/demo-board.sh into a
# throwaway store, runs the real SwiftBar plugin, and draws exactly the lines it
# printed. A row that the plugin stops emitting disappears from the README the
# next time this runs, which is the whole point — the old screenshots could
# only ever be re-checked by a human opening the menu.
#
# What it cannot do is prove SwiftBar draws those lines the way we say it does;
# the panel styling here is a redrawing of the macOS menu, matched by eye once.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/assets"
mode="write"
[ "${1:-}" = "--check" ] && mode="check"

command -v jq >/dev/null 2>&1 || { echo "jq is required — brew install jq" >&2; exit 1; }

# The plugin reads the store, the config and the update cache out of
# CLAUDE_NOTIFY_HOME. Pointing it at a throwaway tree keeps the developer's own
# sessions out of the picture and, just as important, keeps their notify.conf
# (theme, BAR_STYLE, STALE_HOURS) from changing what the README shows.
work="$(mktemp -d "${TMPDIR:-/tmp}/claudebar-screens.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
export CLAUDE_NOTIFY_HOME="$work/claude"
export CLAUDE_SIGNALS_DIR=""
export CLAUDE_SIGNALS_INBOX="$work/signals"
export UPDATE_CHECK_HOURS=0   # never reach for the network while rendering
mkdir -p "$HOME" "$CLAUDE_NOTIFY_HOME" "$CLAUDE_SIGNALS_INBOX"

"$REPO_ROOT/examples/demo-board.sh" >/dev/null
plugin="$work/plugin.txt"
bash "$REPO_ROOT/host/claudebar.3s.sh" > "$plugin"

# SwiftBar's own split: everything before the first `---` is the menu bar item,
# everything after it is the dropdown.
sed -n '1,/^---$/p' "$plugin" | sed '$d' > "$work/bar.txt"
sed -n '/^---$/,$p'  "$plugin" | sed '1d' > "$work/board.txt"

# LC_ALL=C so length() counts bytes and the [\200-\277] class matches UTF-8
# continuation bytes — that is how nchars() gets a character count out of an awk
# that may or may not be multibyte-aware.
render() { LC_ALL=C awk -v panel="$1" -f "$REPO_ROOT/examples/swiftbar-to-svg.awk"; }

render board < "$work/board.txt" > "$work/board.svg"
render bar   < "$work/bar.txt"   > "$work/bar.svg"

status=0
for name in bar board; do
  if [ "$mode" = "check" ]; then
    if ! cmp -s "$work/$name.svg" "$OUT_DIR/$name.svg"; then
      echo "assets/$name.svg is out of date — run examples/render-screens.sh" >&2
      status=1
    fi
  else
    cp "$work/$name.svg" "$OUT_DIR/$name.svg"
    echo "wrote assets/$name.svg"
  fi
done
exit "$status"
