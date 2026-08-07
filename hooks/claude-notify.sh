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
  TRANSCRIPT=\(.transcript_path // "")
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

# --------------------------------------------------------- transcript titles
# Claude Code streams the conversation to a JSONL transcript (transcript_path
# in every hook payload) and drops title records into it — the strings its
# /resume picker shows, i.e. the most human-readable answer to "what is this
# session about". The board reuses them so rows can be told apart at a glance.
#
# Two spellings are accepted because the record changed shape between versions:
#   {"type":"ai-title","aiTitle":…}   2.1.x
#   {"type":"summary","summary":…}    older
# That JSONL is Claude Code internal and carries no compatibility promise, so
# every step here is best-effort: `fromjson?` swallows malformed/truncated
# lines, `objects`/`strings` drop records that don't match either shape, and a
# scan that finds nothing simply prints nothing — the caller then keeps the
# value it already had. Transcripts also reach tens of MB, so only a bounded
# head and tail are ever read.
SUMMARY_TTL="${CLAUDE_NOTIFY_SUMMARY_TTL:-600}"   # seconds between rescans
JQ_SUMMARY='fromjson? | objects
  | (if   .type == "ai-title" then .aiTitle
     elif .type == "summary"  then .summary
     else empty end)
  | strings | select(length > 0)'

transcript_summary() { # $1: transcript path — stdout: newest title
  # head first, tail second, last match wins: titles rewritten as the session
  # runs (tail) win over the inherited one a resumed transcript opens with
  # (head). `tail` seeks from the end, so file size doesn't matter here.
  { head -n 200 "$1"; tail -n 500 "$1"; } 2>/dev/null \
    | jq -R -r "$JQ_SUMMARY" 2>/dev/null | tail -n 1
}

# Per-session context, carried across hook invocations (5 lines: last state,
# last user prompt, last tool from PreToolUse, session title, and when that
# title was last looked for). The tool line is what makes permission triage
# possible: PreToolUse fires BEFORE the permission prompt resolves, so when a
# permission Notification arrives the pending action is already here. Files
# written by older versions are shorter; the trailing fields then just start
# out empty.
CTX="${TMPDIR:-/tmp}/claude-notify-${SESSION_ID}.ctx"
PREV_STATE=""; PROMPT=""; PENDING=""; SUMMARY=""; SCAN_TS=""
[ -f "$CTX" ] && { IFS= read -r PREV_STATE; IFS= read -r PROMPT; IFS= read -r PENDING
                   IFS= read -r SUMMARY;    IFS= read -r SCAN_TS; } < "$CTX"
case "$SCAN_TS" in ""|*[!0-9]*) SCAN_TS=0 ;; esac

case "$EVENT" in
  # /clear and a fresh start reuse nothing; a resumed session re-derives its
  # title from the transcript right below, so dropping it here is safe.
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

NOW=$(date +%s)

# When to go looking for the title. SessionStart always scans — it happens once
# per session and it is what makes a resumed session show its inherited title
# straight away. After that only the state transitions scan: PreToolUse fires
# on every single tool call and Notification never changes what a session is
# about.
#
# While there is no title yet, every transition scans — Claude Code writes the
# first one within the opening exchanges, and waiting out a TTL to notice would
# leave a fresh row showing a bare prompt for no reason. Once a title exists,
# scans drop to the TTL: a long session otherwise re-reads a big transcript
# every turn to re-find a string that has not moved.
SCAN=""
case "$EVENT" in
  SessionStart)          SCAN=1 ;;
  UserPromptSubmit|Stop) { [ -z "$SUMMARY" ] || [ $(( NOW - SCAN_TS )) -ge "$SUMMARY_TTL" ]; } && SCAN=1 ;;
esac

if [ -n "$SCAN" ] && [ -n "${TRANSCRIPT:-}" ] && [ -f "$TRANSCRIPT" ]; then
  SCAN_TS=$NOW
  TITLE=$(transcript_summary "$TRANSCRIPT")
  # Only a real title ever replaces the stored one — a scan that comes back
  # empty (no title yet, unreadable file, changed format) must not blank it.
  if [ -n "$TITLE" ]; then
    TITLE=${TITLE//$'\n'/ }   # the context file is line-oriented
    SUMMARY=${TITLE:0:200}
  fi
fi

if [ "$STATE" = "ended" ]; then
  rm -f "$CTX"
else
  printf '%s\n%s\n%s\n%s\n%s\n' "$STATE" "$PROMPT" "$PENDING" "$SUMMARY" "$SCAN_TS" > "$CTX" 2>/dev/null
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
  --arg summary "$SUMMARY" \
  --arg event "$EVENT" \
  --argjson ts "$NOW" \
  '{session_id: $session_id, origin: $origin, project: $project, branch: $branch,
    cwd: $cwd, root: $root, state: $state, message: $message,
    prompt: $prompt, pending: $pending, summary: $summary, event: $event, ts: $ts}')

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
