# shellcheck shell=bash
# claudebar/lib/transcript.sh — what the transcript can tell us about a session:
# its title, and whether it is waiting on background agents of its own.
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

# ------------------------------------------------------- background agents
# Is the session waiting on agents it launched itself?
#
# Claude Code's idle Notification ("Claude is waiting for your input") fires
# whenever the main loop sits at the prompt — including when it only sits there
# because a fan-out of background agents has not reported back yet. Such a
# session needs nobody: whichever agent finishes last wakes it up again.
#
# Both halves of the pairing are in the transcript. Launching a background
# agent names the file its output will go to, `…/tasks/<id>.output`; the
# completion arrives as a `<task-notification>` carrying `<task-id>`. An id
# that was launched and never notified is still running. Blocking sub-agents
# (a plain Task/Agent call the main loop waits on) leave neither marker, and
# could not idle the session anyway.
#
# Best-effort like the title scan, and biased the same way — towards reporting
# nothing pending, which is the behaviour without this check:
#   - an absent or unreadable transcript reports nothing,
#   - so does a transcript in a format that has moved on,
#   - compaction only ever drops the older half of a pair, i.e. the launch,
#   - an agent resumed with SendMessage has notified once already, so it counts
#     as reported until it notifies again.
#
# This runs on `Stop`, i.e. once per turn on a transcript that can be tens of
# MB, so the file itself is only ever crossed by a fixed-string match — the
# regex that picks the ids apart then sees a handful of lines. macOS `grep`
# compiles an ERE per line and is an order of magnitude slower at it than at
# -F, which is the difference between a hook you notice and one you don't.
#
# `grep -q -v` would have been shorter than the awk, but not every grep inverts
# an exit status the same way (ugrep, which some distributions install as
# /usr/bin/grep, reports the pattern's own match rather than the inverted one).
claudebar_transcript_pending_agents() { # $1: transcript path — 0 if any is running
  [ -n "${1:-}" ] && [ -f "$1" ] || return 1

  grep -F -e '/tasks/' -e '<task-id>' "$1" 2>/dev/null \
    | grep -oE '/tasks/[A-Za-z0-9_-]{4,}\.output|<task-id>[A-Za-z0-9_-]{4,}</task-id>' \
    | awk '
    /^\/tasks\// {
      id = $0; sub(/^\/tasks\//, "", id); sub(/\.output$/, "", id)
      # A notification names the same output file it is reporting on, so an id
      # already heard from never counts as launched again.
      if (!(id in notified)) running[id] = 1
      next
    }
    { id = $0; gsub(/<\/?task-id>/, "", id); notified[id] = 1; delete running[id] }
    END { for (id in running) exit 0; exit 1 }
  '
}
