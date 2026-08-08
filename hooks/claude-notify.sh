#!/bin/bash
# claude-notify — Claude Code hook: turn hook events into status records.
#
# Modes:
#   (default)   Invoked by Claude Code as a hook (SessionStart, UserPromptSubmit,
#               PreToolUse, Notification, Stop, SessionEnd). Reads the hook event
#               JSON from stdin, derives a session status record, then either
#               updates the status store locally (host) or drops the record into
#               the signal bridge directory (sandbox) for the host-side watcher.
#   --deliver   Reads a status record JSON from stdin and applies it to the
#               status store. Used by the host-side watcher.
#
# In hook mode this script must never fail the calling session: it always
# exits 0. In --deliver mode the exit code tells the watcher whether the
# signal file was valid.
#
# Layout: paths, the record schema and transcript-title scanning live in
# claudebar-lib/ next to this file, shared with the watcher, the focus action
# and the board.

# ------------------------------------------------------------------ bootstrap
# Find the library: explicit override, then next to this script (the repo and
# the installed layout are both hooks/claudebar-lib), then the installed
# location as a last resort. Inside a sandbox this file is reached through a
# symlinked hooks/ directory, so resolving that symlink is what makes the
# library visible there.
for _d in "${CLAUDEBAR_LIB:-}" \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")/claudebar-lib" 2>/dev/null && pwd)" \
          "${CLAUDE_NOTIFY_HOME:-$HOME/.claude}/hooks/claudebar-lib"; do
  [ -n "$_d" ] && [ -r "$_d/paths.sh" ] && { CLAUDEBAR_LIB="$_d"; break; }
done
# A missing lib must not take the session down with it.
[ -r "${CLAUDEBAR_LIB:-}/paths.sh" ] || exit 0
. "$CLAUDEBAR_LIB/paths.sh"
. "$CLAUDEBAR_LIB/record.sh"
. "$CLAUDEBAR_LIB/transcript.sh"

command -v jq >/dev/null 2>&1 || exit 0

# ------------------------------------------------------------ event → state
# The board shows four states; this is the whole mapping from hook events onto
# them. Prints the state, or nothing for events the board ignores.
classify_event() { # $1: event  $2: notification message  $3: SessionStart source
  case "$1" in
    # A fresh/resumed session sits idle at the prompt — that is "ready", not
    # "working" (nothing would ever correct it otherwise: Stop only fires
    # after a response). Auto-compact fires SessionStart mid-task, though —
    # that must not touch the state.
    SessionStart)
      [ "$3" = "compact" ] && return 1
      printf 'ready'
      ;;
    UserPromptSubmit|PreToolUse) printf 'working' ;;
    Stop)                        printf 'ready' ;;
    SessionEnd)                  printf 'ended' ;;
    Notification)
      case "$2" in
        *permission*|*Permission*) printf 'permission' ;;
        *)                         printf 'waiting' ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------- context
# Per-session state carried across hook invocations, one field per line: last
# state, last user prompt, last tool seen at PreToolUse, session title, and
# when that title was last looked for.
#
# The tool line is what makes permission triage possible: PreToolUse fires
# BEFORE the permission prompt resolves, so by the time a permission
# Notification arrives the pending action is already recorded here.
#
# Files written by older versions are shorter; the trailing fields then simply
# read back empty.
context_path() { printf '%s/claude-notify-%s.ctx' "${TMPDIR:-/tmp}" "$1"; }

context_load() { # $1: session id — sets PREV_STATE PROMPT PENDING SUMMARY SCAN_TS
  local ctx; ctx=$(context_path "$1")
  PREV_STATE=""; PROMPT=""; PENDING=""; SUMMARY=""; SCAN_TS=""
  [ -f "$ctx" ] && { IFS= read -r PREV_STATE; IFS= read -r PROMPT; IFS= read -r PENDING
                     IFS= read -r SUMMARY;    IFS= read -r SCAN_TS; } < "$ctx"
  case "$SCAN_TS" in ""|*[!0-9]*) SCAN_TS=0 ;; esac
  return 0
}

context_save() { # $1: session id
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$STATE" "$PROMPT" "$PENDING" "$SUMMARY" "$SCAN_TS" > "$(context_path "$1")" 2>/dev/null
  return 0
}

context_clear() { rm -f "$(context_path "$1")"; }

# What this event contributes to the carried context.
context_update() { # $1: event
  case "$1" in
    # /clear and a fresh start reuse nothing; a resumed session re-derives its
    # title from the transcript right after, so dropping it here is safe.
    SessionStart) PROMPT=""; PENDING=""; SUMMARY=""; SCAN_TS=0 ;;
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
}

# Refresh SUMMARY from the transcript when it is due.
refresh_title() { # $1: event  $2: transcript path  $3: now
  claudebar_transcript_should_scan "$1" "$SUMMARY" "$SCAN_TS" "$3" || return 0
  [ -n "$2" ] && [ -f "$2" ] || return 0

  SCAN_TS=$3
  local title; title=$(claudebar_transcript_title "$2")
  # Only a real title ever replaces the stored one — a scan that comes back
  # empty (no title yet, unreadable file, changed format) must not blank it.
  [ -n "$title" ] || return 0
  title=${title//$'\n'/ }   # the context file is line-oriented
  SUMMARY=${title:0:200}
}

# ------------------------------------------------------------------ identity
# Where the session is, as the board should label it.
resolve_project() { # $1: cwd — sets PROJECT BRANCH ROOT
  PROJECT=$(basename "$1")
  BRANCH=$(git -C "$1" branch --show-current 2>/dev/null || true)
  # Project root for focus actions. sbx mounts keep their host path, so a root
  # recorded inside a sandbox is valid on the host too.
  ROOT=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || echo "$1")

  if [ -d /run/sandbox/source ]; then
    # sbx --clone mode: the working tree is a standalone clone, but it sits at
    # the same path string as the host repo — so ROOT stays valid for focusing
    # the host IDE window. Derive the repo name from the origin remote anyway:
    # it survives the agent switching to its own branch/naming.
    local repo
    repo=$(git -C "$1" remote get-url origin 2>/dev/null | sed 's|/*$||; s|\.git$||')
    [ -n "$repo" ] && PROJECT=$(basename "$repo")
  fi
  return 0
}

# ------------------------------------------------------------------ hook mode
hook_mode() {
  local input; input=$(cat)

  # Skip sub-agents (Task tool spawns): they carry an `agent_id`, the main
  # agent never does. Otherwise every sub-agent floods the board.
  jq -e '.agent_id // empty' <<<"$input" >/dev/null 2>&1 && return 0

  local EVENT SESSION_ID MESSAGE CWD PROMPT_IN SOURCE TRANSCRIPT TOOL_NAME TOOL_ARG
  eval "$(jq -r '@sh "EVENT=\(.hook_event_name // "")
    SESSION_ID=\(.session_id // "unknown")
    MESSAGE=\(.message // "")
    CWD=\(.cwd // "")
    PROMPT_IN=\(.prompt // "")
    SOURCE=\(.source // "")
    TRANSCRIPT=\(.transcript_path // "")
    TOOL_NAME=\(.tool_name // "")
    TOOL_ARG=\(.tool_input.command // .tool_input.file_path // ((.tool_input // {}) | tostring))"' \
    <<<"$input" 2>/dev/null)"
  [ -n "${CWD:-}" ] || CWD="$PWD"
  [ "${TOOL_ARG:-}" = "{}" ] && TOOL_ARG=""

  local STATE PREV_STATE PROMPT PENDING SUMMARY SCAN_TS
  STATE=$(classify_event "${EVENT:-}" "$MESSAGE" "${SOURCE:-}") || return 0

  # Two events say the session is idle: Stop, where the main loop hands the
  # prompt back, and — a minute later — the "Claude is waiting for your input"
  # Notification. Neither is true while a fan-out of background agents is still
  # out. That session is not ready for you and not waiting for you: the last
  # agent to finish wakes it up again. It is working, and the agents are what
  # is working. A permission prompt is never second-guessed this way — that one
  # really does block on you.
  #
  # SessionStart is deliberately not in here: a resumed transcript can carry
  # launches whose agents died with the process that ran them, and those would
  # read as pending for as long as the row lives.
  case "$EVENT" in
    Stop|Notification)
      if [ "$STATE" != "permission" ] \
         && claudebar_transcript_pending_agents "${TRANSCRIPT:-}"; then
        STATE="working"
        MESSAGE="Waiting on its own background agents"
      fi
      ;;
  esac

  case "$EVENT" in
    SessionStart) MESSAGE="Session started" ;;
    Stop)         MESSAGE="${MESSAGE:-Finished responding}" ;;
  esac

  context_load "$SESSION_ID"
  context_update "$EVENT"

  local ts; ts=$(date +%s)
  refresh_title "$EVENT" "${TRANSCRIPT:-}" "$ts"

  if [ "$STATE" = "ended" ]; then
    context_clear "$SESSION_ID"
  else
    context_save "$SESSION_ID"
  fi

  # Dedupe the chatty event: PreToolUse fires on every tool call, but only the
  # first transition into "working" needs a record — the context above has
  # already captured the pending tool either way.
  [ "$EVENT" = "PreToolUse" ] && [ "$PREV_STATE" = "working" ] && return 0

  local PROJECT BRANCH ROOT
  resolve_project "$CWD"

  # Field names below are the record schema — claudebar-lib/record.sh reads
  # them by name.
  local outbox; outbox=$(claudebar_signals_outbox)
  local session_id="$SESSION_ID" project="$PROJECT" branch="$BRANCH" root="$ROOT"
  local state="$STATE" message="$MESSAGE" prompt="$PROMPT" pending="$PENDING"
  local summary="$SUMMARY" event="$EVENT" cwd="$CWD" origin
  if [ -n "$outbox" ] && [ -d "$outbox" ]; then
    origin="sbx:${SANDBOX_VM_ID:-$(hostname 2>/dev/null | cut -c1-8)}"
  else
    origin="host"
  fi

  local record; record=$(claudebar_record_build) || return 0
  if [ -n "$outbox" ] && [ -d "$outbox" ]; then
    claudebar_record_relay "$outbox" <<<"$record"
  else
    claudebar_record_store <<<"$record"
  fi
  return 0
}

# ---------------------------------------------------------------------- main
if [ "${1:-}" = "--deliver" ]; then
  claudebar_record_store
  exit $?
fi

hook_mode
exit 0
