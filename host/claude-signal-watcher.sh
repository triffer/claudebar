#!/bin/bash
# claude-signal-watcher — host-side bridge for sandboxed Claude sessions.
#
# Launched by launchd (QueueDirectories) whenever ~/.claude-signals becomes
# non-empty. Sandboxed hooks drop status records there; this script applies
# each one to the status store (~/.claude/sessions) via claude-notify.sh
# --deliver, which the SwiftBar menu bar plugin renders.
#
# The bridge is a SIBLING of ~/.claude (not inside it) because ~/.claude is
# mounted read-only into sandboxes, and sbx mounts keep their host path.
#
# launchd re-launches the job as long as the directory is non-empty, so every
# file must end up removed or moved OUT of the directory — otherwise launchd
# spins on it forever.

SIGNALS_DIR="$HOME/.claude-signals"
REJECTS_DIR="$HOME/.claude/signals-rejected"
HOOK="$HOME/.claude/hooks/claude-notify.sh"

# Tiny buffer so the sandbox's write+rename has settled on the shared mount.
sleep 0.2

shopt -s nullglob
for f in "$SIGNALS_DIR"/evt_*.json; do
  if bash "$HOOK" --deliver < "$f"; then
    rm -f "$f"
  else
    mkdir -p "$REJECTS_DIR"
    mv "$f" "$REJECTS_DIR"/ 2>/dev/null || rm -f "$f"
  fi
done

# Hygiene: orphaned tmp files (and ping_* files from the first draft of this
# setup) would keep launchd retriggering, and abandoned session records would
# sit in the menu bar forever.
find "$SIGNALS_DIR" -name '.evt_*.tmp' -mmin +10 -delete 2>/dev/null
find "$SIGNALS_DIR" -name 'ping_*' -delete 2>/dev/null
find "$HOME/.claude/notifier-sessions" -name '*.json' -mtime +2 -delete 2>/dev/null

exit 0
