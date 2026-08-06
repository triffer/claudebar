#!/bin/bash
# claude-notify — unified Claude Code hook + status delivery for the menu bar
# status board (SwiftBar plugin reads the records this maintains).
#
# Modes:
#   (default)   Invoked by Claude Code as a hook (SessionStart, UserPromptSubmit,
#               PreToolUse, Notification, Stop, SessionEnd). Reads the hook event
#               JSON from stdin, derives a session status record, then either
#               updates the status store locally (host) or drops the record into
#               the signal bridge directory (sandbox) for the host-side watcher.
#   --deliver   Reads a status record JSON from stdin and updates
#               ~/.claude/notifier-sessions/<session_id>.json. Used by the watcher.
#
# In hook mode this script must never fail the calling session: it always
# exits 0. In --deliver mode the exit code tells the watcher whether the
# signal file was valid.

CLAUDE_DIR="${CLAUDE_NOTIFY_HOME:-$HOME/.claude}"
# NOT ~/.claude/sessions — that directory belongs to Claude Code itself
# (pid-named session-tracking files); our records must never mix with it.
SESSIONS_DIR="$CLAUDE_DIR/notifier-sessions"

# Mode: on macOS we ARE the host and deliver locally. Anywhere else we assume
# a sandbox and relay through the signal bridge. sbx mounts keep their host
# path inside the microVM, so the bridge (~/.claude-signals on the Mac — a
# sibling of ~/.claude because that mount is read-only) shows up under
# /Users/<user>/.claude-signals.
SIGNALS_DIR=""
if [ "$(uname)" != "Darwin" ]; then
  SIGNALS_DIR="${CLAUDE_SIGNALS_DIR:-}"
  if [ -z "$SIGNALS_DIR" ]; then
    for d in /Users/*/.claude-signals /opt/host-signals; do
      [ -d "$d" ] && SIGNALS_DIR="$d" && break
    done
  fi
fi

command -v jq >/dev/null 2>&1 || exit 0

deliver() { # stdin: status record JSON
  local record
  record=$(cat)

  local session_id state
  eval "$(jq -r '@sh "session_id=\(.session_id // "")
    state=\(.state // "")"' <<<"$record" 2>/dev/null)"
  [ -n "$session_id" ] || return 1

  mkdir -p "$SESSIONS_DIR"
  if [ "$state" = "ended" ]; then
    rm -f "$SESSIONS_DIR/$session_id.json"
  else
    local tmp="$SESSIONS_DIR/.$session_id.tmp"
    printf '%s\n' "$record" > "$tmp" && mv "$tmp" "$SESSIONS_DIR/$session_id.json"
  fi
  return 0
}

if [ "${1:-}" = "--deliver" ]; then
  deliver
  exit $?
fi

# ---------------------------------------------------------------- hook mode

INPUT=$(cat)

# Skip sub-agents (Task tool spawns): they carry an `agent_id`, the main
# agent never does. Otherwise every sub-agent floods the board.
if jq -e '.agent_id // empty' <<<"$INPUT" >/dev/null 2>&1; then
  exit 0
fi

eval "$(jq -r '@sh "EVENT=\(.hook_event_name // "")
  SESSION_ID=\(.session_id // "unknown")
  MESSAGE=\(.message // "")
  CWD=\(.cwd // "")
  PROMPT_IN=\(.prompt // "")
  SOURCE=\(.source // "")
  TOOL_NAME=\(.tool_name // "")
  TOOL_ARG=\(.tool_input.command // .tool_input.file_path // ((.tool_input // {}) | tostring))"' <<<"$INPUT" 2>/dev/null)"
[ -n "${CWD:-}" ] || CWD="$PWD"
[ "${TOOL_ARG:-}" = "{}" ] && TOOL_ARG=""

case "${EVENT:-}" in
  # A fresh/resumed session sits idle at the prompt — that's "ready", not
  # "working" (nothing would ever correct it otherwise: Stop only fires
  # after a response). Auto-compact fires SessionStart mid-task, though —
  # that must not touch the state.
  SessionStart)
    [ "${SOURCE:-}" = "compact" ] && exit 0
    STATE="ready"; MESSAGE="Session started"
    ;;
  UserPromptSubmit|PreToolUse) STATE="working" ;;
  Stop)       STATE="ready"; MESSAGE="${MESSAGE:-Finished responding}" ;;
  SessionEnd) STATE="ended" ;;
  Notification)
    case "$MESSAGE" in
      *permission*|*Permission*) STATE="permission" ;;
      *)                         STATE="waiting" ;;
    esac
    ;;
  *) exit 0 ;;
esac

# Per-session context, carried across hook invocations (3 lines: last state,
# last user prompt, last tool from PreToolUse). The tool line is what makes
# permission triage possible: PreToolUse fires BEFORE the permission prompt
# resolves, so when a permission Notification arrives the pending action is
# already here.
CTX="${TMPDIR:-/tmp}/claude-notify-${SESSION_ID}.ctx"
PREV_STATE=""; PROMPT=""; PENDING=""
[ -f "$CTX" ] && { IFS= read -r PREV_STATE; IFS= read -r PROMPT; IFS= read -r PENDING; } < "$CTX"

case "$EVENT" in
  SessionStart) PROMPT=""; PENDING="" ;;
  UserPromptSubmit)
    PROMPT_IN=${PROMPT_IN//$'\n'/ }
    case "$PROMPT_IN" in
      "<"*) ;;   # harness-injected (<task-notification>, <system-…>) — not the user
      "")   ;;
      *)    PROMPT=${PROMPT_IN:0:100} ;;
    esac
    ;;
  PreToolUse)
    TOOL_ARG=${TOOL_ARG//$'\n'/ }
    PENDING="$TOOL_NAME${TOOL_ARG:+: ${TOOL_ARG:0:120}}"
    ;;
esac

if [ "$STATE" = "ended" ]; then
  rm -f "$CTX"
else
  printf '%s\n%s\n%s\n' "$STATE" "$PROMPT" "$PENDING" > "$CTX" 2>/dev/null
fi

# Dedupe the chatty event: PreToolUse fires on every tool call, but only the
# first transition into "working" needs a record — the context above has
# already captured the pending tool either way.
if [ "$EVENT" = "PreToolUse" ] && [ "$PREV_STATE" = "working" ]; then
  exit 0
fi

PROJECT=$(basename "$CWD")
BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)
# Project root for focus actions. sbx mounts keep their host path, so a root
# recorded inside a sandbox is valid on the host too.
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")

if [ -d /run/sandbox/source ]; then
  # sbx --clone mode: the working tree is a standalone clone, but it sits at
  # the same path string as the host repo — so ROOT stays valid for focusing
  # the host IDE window. Derive the repo name from the origin remote anyway:
  # it survives the agent switching to its own branch/naming.
  REPO=$(git -C "$CWD" remote get-url origin 2>/dev/null | sed 's|/*$||; s|\.git$||')
  [ -n "$REPO" ] && PROJECT=$(basename "$REPO")
fi

if [ -n "$SIGNALS_DIR" ] && [ -d "$SIGNALS_DIR" ]; then
  ORIGIN="sbx:${SANDBOX_VM_ID:-$(hostname 2>/dev/null | cut -c1-8)}"
else
  ORIGIN="host"
fi

RECORD=$(jq -n \
  --arg session_id "$SESSION_ID" \
  --arg origin "$ORIGIN" \
  --arg project "$PROJECT" \
  --arg branch "$BRANCH" \
  --arg cwd "$CWD" \
  --arg root "$ROOT" \
  --arg state "$STATE" \
  --arg message "$MESSAGE" \
  --arg prompt "$PROMPT" \
  --arg pending "$PENDING" \
  --arg event "$EVENT" \
  --argjson ts "$(date +%s)" \
  '{session_id: $session_id, origin: $origin, project: $project, branch: $branch,
    cwd: $cwd, root: $root, state: $state, message: $message,
    prompt: $prompt, pending: $pending, event: $event, ts: $ts}')

if [ -n "$SIGNALS_DIR" ] && [ -d "$SIGNALS_DIR" ]; then
  # Sandbox: hand the record to the host via the signal bridge. Write-then-move
  # so the watcher never reads a half-written file.
  NAME="evt_$(date +%s)_$$_${RANDOM}"
  TMP="$SIGNALS_DIR/.$NAME.tmp"
  printf '%s\n' "$RECORD" > "$TMP" 2>/dev/null && mv "$TMP" "$SIGNALS_DIR/$NAME.json" 2>/dev/null
else
  deliver <<<"$RECORD"
fi

exit 0
