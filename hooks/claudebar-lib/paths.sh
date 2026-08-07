# shellcheck shell=bash
# claudebar/lib/paths.sh — the one place that knows where claudebar keeps things.
#
# Sourced by every claudebar script (hook, watcher, focus action, SwiftBar
# plugin) so each path is spelled out once and cannot drift. It had already
# drifted before this file existed: the watcher hardcoded ~/.claude while the
# other three honoured CLAUDE_NOTIFY_HOME, so pointing that variable elsewhere
# silently split the store in two.
#
# Everything defined here is CLAUDEBAR_*-prefixed. notify.conf is plain
# user-edited bash that gets sourced into the same shell, and the prefix is
# what guarantees a stray assignment in it can never shadow a path.

CLAUDEBAR_HOME="${CLAUDE_NOTIFY_HOME:-$HOME/.claude}"

# NOT $CLAUDEBAR_HOME/sessions — that directory belongs to Claude Code itself
# (pid-named session-tracking files); our records must never mix with it.
CLAUDEBAR_SESSIONS_DIR="$CLAUDEBAR_HOME/notifier-sessions"
CLAUDEBAR_CONF="$CLAUDEBAR_HOME/notify.conf"
CLAUDEBAR_HOOK="$CLAUDEBAR_HOME/hooks/claude-notify.sh"
CLAUDEBAR_FOCUS_CMD="$CLAUDEBAR_HOME/claudebar-focus.sh"
CLAUDEBAR_UPDATE_CMD="$CLAUDEBAR_HOME/claudebar-update.sh"
CLAUDEBAR_SOUNDS_FLAG="$CLAUDEBAR_HOME/notify-sounds-on"

# What the last update check found. Namespaced like everything else we put in
# ~/.claude, which is shared space. See version.sh for the shape.
CLAUDEBAR_UPDATE_CACHE="$CLAUDEBAR_HOME/claudebar-update.json"

# Host side of the signal bridge: where the watcher picks records up, and where
# rejects are parked. A SIBLING of ~/.claude on purpose — sandboxes mount
# ~/.claude read-only, so the writable bridge has to live outside it.
CLAUDEBAR_SIGNALS_INBOX="${CLAUDE_SIGNALS_INBOX:-$HOME/.claude-signals}"
CLAUDEBAR_REJECTS_DIR="$CLAUDEBAR_HOME/signals-rejected"

# Sandbox side of the same bridge: where a hook drops records for the host.
# Empty stdout means "no bridge — deliver locally".
#
# CLAUDE_SIGNALS_DIR overrides the probe when it is set, *including when it is
# set to the empty string* — that is how a Linux CI box or a test run forces
# local delivery, which the bare uname check alone offers no way to do.
claudebar_signals_outbox() {
  if [ -n "${CLAUDE_SIGNALS_DIR+set}" ]; then
    printf '%s' "$CLAUDE_SIGNALS_DIR"
    return 0
  fi
  # On macOS we ARE the host. Anywhere else, assume a sandbox and look for the
  # bridge: sbx mounts keep their host path inside the microVM, so the Mac's
  # ~/.claude-signals shows up as /Users/<user>/.claude-signals.
  [ "$(uname)" = "Darwin" ] && return 0
  local d
  for d in /Users/*/.claude-signals /opt/host-signals; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 0
}

# notify.conf holds the user's display/behaviour preferences (BAR_STYLE,
# STALE_HOURS, IDE_CMD, …). Missing or unreadable is normal, never fatal —
# every consumer defaults its own keys.
claudebar_load_conf() {
  [ -f "$CLAUDEBAR_CONF" ] && . "$CLAUDEBAR_CONF" 2>/dev/null
  return 0
}
