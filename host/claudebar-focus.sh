#!/bin/bash
# claudebar-focus — click action for board session rows.
#
# Focuses the session's IDE project window via the JetBrains launcher, or
# falls back to activating the terminal app. Lives at a SPACE-FREE path on
# purpose: SwiftBar's bash= parameter parsing is unreliable with quoted paths
# containing spaces (the Toolbox launcher sits under ".../Application
# Support/...", which is exactly what broke direct invocation). Real shell
# quoting happens here instead.
#
# Usage: claudebar-focus.sh <project-root|->

for _d in "${CLAUDEBAR_LIB:-}" \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/claudebar-lib" 2>/dev/null && pwd)" \
          "${CLAUDE_NOTIFY_HOME:-$HOME/.claude}/hooks/claudebar-lib"; do
  [ -n "$_d" ] && [ -r "$_d/paths.sh" ] && { CLAUDEBAR_LIB="$_d"; break; }
done
if [ -r "${CLAUDEBAR_LIB:-}/paths.sh" ]; then
  . "$CLAUDEBAR_LIB/paths.sh"
  claudebar_load_conf
else
  # Focusing a window is never worth failing over: fall back to reading the
  # conf straight from its conventional location.
  CONF="${CLAUDE_NOTIFY_HOME:-$HOME/.claude}/notify.conf"
  [ -f "$CONF" ] && . "$CONF" 2>/dev/null
fi

ROOT="${1:-}"

if [ -n "${IDE_CMD:-}" ] && [ -d "$ROOT" ]; then
  "$IDE_CMD" "$ROOT" >/dev/null 2>&1 && exit 0
fi
if [ -n "${TERMINAL_BUNDLE_ID:-}" ]; then
  /usr/bin/open -b "$TERMINAL_BUNDLE_ID" >/dev/null 2>&1
fi
exit 0
