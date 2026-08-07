#!/bin/bash
# claude-signal-watcher — host-side bridge for sandboxed Claude sessions.
#
# Launched by launchd (QueueDirectories) whenever the signal bridge becomes
# non-empty. Sandboxed hooks drop status records there; this script applies
# each one to the status store, which the SwiftBar plugin renders.
#
# The bridge is a SIBLING of ~/.claude (not inside it) because ~/.claude is
# mounted read-only into sandboxes, and sbx mounts keep their host path.
#
# launchd re-launches the job as long as the directory is non-empty, so every
# file must end up removed or moved OUT of the directory — otherwise launchd
# spins on it forever.

for _d in "${CLAUDEBAR_LIB:-}" \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/claudebar-lib" 2>/dev/null && pwd)" \
          "${CLAUDE_NOTIFY_HOME:-$HOME/.claude}/hooks/claudebar-lib"; do
  [ -n "$_d" ] && [ -r "$_d/paths.sh" ] && { CLAUDEBAR_LIB="$_d"; break; }
done
[ -r "${CLAUDEBAR_LIB:-}/paths.sh" ] || {
  echo "claudebar lib not found — re-run: claudebar install" >&2; exit 1; }
. "$CLAUDEBAR_LIB/paths.sh"
. "$CLAUDEBAR_LIB/record.sh"

# Tiny buffer so the sandbox's write+rename has settled on the shared mount.
sleep 0.2

shopt -s nullglob
for f in "$CLAUDEBAR_SIGNALS_INBOX"/evt_*.json; do
  # Applying the record directly (rather than re-invoking the hook with
  # --deliver) means one process per file instead of two, and the store logic
  # is the same function the hook itself calls.
  if claudebar_record_store < "$f"; then
    rm -f "$f"
  else
    mkdir -p "$CLAUDEBAR_REJECTS_DIR"
    mv "$f" "$CLAUDEBAR_REJECTS_DIR"/ 2>/dev/null || rm -f "$f"
  fi
done

# Hygiene: orphaned tmp files (and ping_* files from the first draft of this
# setup) would keep launchd retriggering, and abandoned session records would
# sit in the menu bar forever.
find "$CLAUDEBAR_SIGNALS_INBOX" -name '.evt_*.tmp' -mmin +10 -delete 2>/dev/null
find "$CLAUDEBAR_SIGNALS_INBOX" -name 'ping_*' -delete 2>/dev/null
find "$CLAUDEBAR_SESSIONS_DIR" -name '*.json' -mtime +2 -delete 2>/dev/null

exit 0
