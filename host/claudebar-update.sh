#!/bin/bash
# claudebar-update — the two update helpers behind the board's version row.
#
#   claudebar-update.sh --check   ask GitHub for the newest release now and
#                                 record it (the ⌥-click on the version row)
#   claudebar-update.sh --copy    put the command that upgrades THIS install
#                                 on the clipboard
#
# Neither of them installs anything, and that is the design: claudebar tells
# you a release exists and hands you the line to run, you run it where you can
# see it. Upgrading from the menu meant driving Terminal over Apple Events,
# and announcing a release meant asking for notification permission — two
# system permission dialogs for a status bar plugin talking about itself.
#
# Like claudebar-focus.sh this lives at a space-free path, because SwiftBar's
# bash= parameter parsing is unreliable with quoted paths.

set -u

for _d in "${CLAUDEBAR_LIB:-}" \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/claudebar-lib" 2>/dev/null && pwd)" \
          "${CLAUDE_NOTIFY_HOME:-$HOME/.claude}/hooks/claudebar-lib"; do
  [ -n "$_d" ] && [ -r "$_d/paths.sh" ] && { CLAUDEBAR_LIB="$_d"; break; }
done
[ -r "${CLAUDEBAR_LIB:-}/paths.sh" ] || {
  echo "claudebar lib not found — re-run: npx github:triffer/claudebar install" >&2
  exit 1; }
. "$CLAUDEBAR_LIB/paths.sh"
. "$CLAUDEBAR_LIB/version.sh"

case "${1:-}" in
  --check)
    claudebar_update_fetch "$(date +%s)"
    open -g "swiftbar://refreshallplugins" 2>/dev/null || true
    ;;
  --copy)
    claudebar_update_cache_read
    # No trailing newline: this is going straight into somebody's prompt.
    claudebar_update_command "$CLAUDEBAR_LATEST" | pbcopy
    ;;
  *)
    echo "usage: claudebar-update.sh --check | --copy" >&2
    exit 2
    ;;
esac
exit 0
