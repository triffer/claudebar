# shellcheck shell=bash
# claudebar/lib/transcript.sh — pull a session's title out of its transcript.
#
# Claude Code streams the conversation to a JSONL transcript (transcript_path
# in every hook payload) and drops title records into it — the strings its
# /resume picker shows, i.e. the most human-readable answer to "what is this
# session about". The board reuses them so rows can be told apart at a glance.
#
# Two spellings are accepted because the record changed shape between versions:
#   {"type":"ai-title","aiTitle":…}   2.1.x
#   {"type":"summary","summary":…}    older
# That JSONL is Claude Code internal and carries no compatibility promise, so
# every step is best-effort: `fromjson?` swallows malformed/truncated lines,
# `objects`/`strings` drop records matching neither shape, and a scan that
# finds nothing prints nothing — the caller then keeps the value it had.
#
# Requires jq.

CLAUDEBAR_JQ_TITLE='fromjson? | objects
  | (if   .type == "ai-title" then .aiTitle
     elif .type == "summary"  then .summary
     else empty end)
  | strings | select(length > 0)'

claudebar_transcript_title() { # $1: transcript path — stdout: newest title
  # head first, tail second, last match wins: titles rewritten as the session
  # runs (tail) beat the inherited one a resumed transcript opens with (head).
  # Transcripts reach tens of MB, so only a bounded head and tail are read —
  # `tail` seeks from the end, so file size does not matter to it.
  { head -n 200 "$1"; tail -n 500 "$1"; } 2>/dev/null \
    | jq -R -r "$CLAUDEBAR_JQ_TITLE" 2>/dev/null | tail -n 1
}

# When to go looking. SessionStart always scans — it happens once per session
# and is what makes a resumed session show its inherited title straight away.
# After that only the state transitions scan: PreToolUse fires on every single
# tool call, and Notification never changes what a session is about.
#
# While there is no title yet every transition scans — Claude Code writes the
# first one within the opening exchanges, and waiting out a TTL to notice it
# would leave a fresh row showing a bare prompt for no reason. Once a title
# exists, scans drop to the TTL: a long session would otherwise re-read a big
# transcript every turn to re-find a string that has not moved.
claudebar_transcript_should_scan() { # $1: event  $2: current title  $3: last scan ts  $4: now
  local ttl="${CLAUDE_NOTIFY_SUMMARY_TTL:-600}"
  case "$1" in
    SessionStart)          return 0 ;;
    UserPromptSubmit|Stop) [ -z "$2" ] || [ $(( $4 - $3 )) -ge "$ttl" ] ;;
    *)                     return 1 ;;
  esac
}
