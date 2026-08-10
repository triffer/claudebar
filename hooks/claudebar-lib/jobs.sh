# shellcheck shell=bash
# claudebar/lib/jobs.sh — is this session one of Claude Code's background jobs?
#
# A background job is not a sub-agent inside somebody else's session: Claude Code
# runs it as a `claude` process of its own, with its own session id, its own
# transcript and its own hook invocations. Those invocations look exactly like a
# main agent's — same events, same fields, and no `agent_id`, which is the only
# thing the hook had to tell an agent apart. So the board grew a row per job on
# top of the terminal that owns them: three identical "product-system-adapter @
# main — ready for you" rows where one person was looking at one window, two of
# them jobs nobody had prompted yet (one of them parked, i.e. idle by design and
# good for hours).
#
# A job is worth a row once it is doing something — a job blocked wanting a
# go-ahead is exactly what this board is for. It is worth nothing at
# SessionStart, where "ready for you" is simply false. That is the whole use of
# the predicate below, and it is what keeps every way of getting it wrong cheap:
# the row appears one event later than it would have, and no row ever disappears.
#
# Requires paths.sh (for CLAUDEBAR_CC_JOBS_DIR).

# Three signals, cheapest first. The two environment variables are set in a
# background job's process and inherited by the hooks it runs; the directory is
# the fallback for wherever that inheritance is filtered, and cannot be missing —
# Claude Code creates it before the job's process exists, and names it after the
# first 8 characters of the job's session id.
#
# Each one only ever says "this IS a job", never the reverse, so an unknown
# spelling or a moved directory costs the suppression and nothing else.
claudebar_session_is_bg_job() { # $1: session id — 0 when it is a background job
  [ "${CLAUDE_CODE_SESSION_KIND:-}" = "bg" ] && return 0
  [ -n "${CLAUDE_JOB_DIR:-}" ] && return 0

  local short=${1:0:8}
  [ -n "$short" ] && [ -d "$CLAUDEBAR_CC_JOBS_DIR/$short" ]
}
