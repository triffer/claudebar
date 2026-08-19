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
# Both halves of the pairing are in the transcript, and the completion half has
# one spelling: a `<task-notification>` carrying `<task-id>`. The launch half
# has two, because Claude Code registers two kinds of background run and their
# tool results do not agree on how to name it:
#
#   async agent    …"status":"async_launched","agentId":"br0uvqnfv"…
#                  …"outputFile":"…/tasks/br0uvqnfv.output"…
#   Workflow       …"status":"async_launched","taskId":"br0uvqnfv",
#                   "taskType":"local_workflow","runId":"wf_…",
#                   "transcriptDir":"…/subagents/workflows/wf_…"…
#
# Only the first names an output file — a workflow's `transcriptDir` points at
# `subagents/workflows/` and never at `tasks/`. Matching the output file alone
# is what made a session that had just fanned out a whole workflow read as
# "waiting for input": five agents out, nothing in the transcript to say so.
# Hence the second pattern. It is anchored on `"status":"async_launched"`
# rather than reading any `taskId` it finds, because plenty of other records
# carry one — and a taskId mistaken for a launch never gets its notification,
# which pins the row to "working" and hides a session that really does want you.
# The bounded `[^}]` keeps the anchor and the id inside one JSON object without
# insisting they stay adjacent.
#
# An id that was launched and never notified is still running. Blocking
# sub-agents (a plain Task/Agent call the main loop waits on) leave neither
# marker, and could not idle the session anyway.
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
claudebar_transcript_running_ids() { # $1: transcript path — stdout: ids, space-separated
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0

  grep -F -e '/tasks/' -e 'async_launched' -e '<task-id>' "$1" 2>/dev/null \
    | grep -oE '/tasks/[A-Za-z0-9_-]{4,}\.output|<task-id>[A-Za-z0-9_-]{4,}</task-id>|"status":"async_launched"[^}]{0,80}"taskId":"[A-Za-z0-9_-]{4,}"' \
    | awk '
    /^<task-id>/ {
      id = $0; gsub(/<\/?task-id>/, "", id)
      notified[id] = 1; delete running[id]
      next
    }
    {
      id = $0
      if (sub(/^\/tasks\//, "", id)) sub(/\.output$/, "", id)
      else { sub(/^.*"taskId":"/, "", id); sub(/"$/, "", id) }
      # A notification names the same run it is reporting on, so an id already
      # heard from never counts as launched again. `order` keeps the output
      # stable: awk iterates an array in whatever order it likes.
      if (id in notified || id in running) next
      running[id] = 1; order[++n] = id
    }
    END {
      out = ""
      for (i = 1; i <= n; i++)
        if (order[i] in running) out = out (out == "" ? "" : " ") order[i]
      print out
    }
  '
}

# The predicate the hook asks: is anything still out that belongs to THIS run of
# the session? Ids in $2 were already running when the session started, so they
# were launched by the run before it and their processes are long gone — see the
# SessionStart handling in claude-notify.sh. Without that subtraction a single
# launch that never got its notification (an aborted workflow, a session killed
# mid-fan-out) reads as pending for as long as the transcript lives, and the row
# stops asking for you at all.
claudebar_transcript_pending_agents() { # $1: transcript  $2: ids to ignore — 0 if any running
  local ids id
  ids=$(claudebar_transcript_running_ids "${1:-}")
  [ -n "$ids" ] || return 1

  for id in $ids; do
    case " ${2:-} " in
      *" $id "*) ;;
      *)         return 0 ;;
    esac
  done
  return 1
}
