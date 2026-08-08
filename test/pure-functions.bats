#!/usr/bin/env bats
# Unit tests for the decisions claudebar makes in isolation: which state a hook
# event means, and how a session is worded and ordered on the board.
#
# The rest of the suite drives whole scripts, which is the right way to test
# that the pieces fit together but a slow and indirect way to pin down a case
# table. These functions are pure — arguments in, string out — so they are
# sourced and called directly (see load_hook / load_board in helper.bash).
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup()    { claudebar_setup; }
teardown() { claudebar_teardown; }

# ------------------------------------------------------------ event → state

@test "a fresh session starts out ready, not working" {
  load_hook

  run classify_event SessionStart "" startup

  [ "$output" = "ready" ]
}

@test "auto-compact restarts a session without touching its state" {
  # SessionStart fires mid-task when the context is compacted. Reporting
  # "ready" there would park a working session in the READY group until its
  # next tool call.
  load_hook

  run classify_event SessionStart "" compact

  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "asking for something, and acting on it, both read as working" {
  load_hook

  run classify_event UserPromptSubmit "" ""
  [ "$output" = "working" ]

  run classify_event PreToolUse "" ""
  [ "$output" = "working" ]
}

@test "the end of a response hands the session back to you" {
  load_hook

  run classify_event Stop "" ""

  [ "$output" = "ready" ]
}

@test "a closed session is ended, which is what drops its row" {
  load_hook

  run classify_event SessionEnd "" ""

  [ "$output" = "ended" ]
}

@test "a permission prompt is told apart from an ordinary notification" {
  # Both arrive as Notification; only the message distinguishes them, and only
  # one of the two is a session actually blocked on you.
  load_hook

  run classify_event Notification "Claude needs your permission to use Bash" ""
  [ "$output" = "permission" ]

  run classify_event Notification "Claude is waiting for your input" ""
  [ "$output" = "waiting" ]
}

@test "an event the board has no state for is ignored rather than guessed at" {
  load_hook

  run classify_event PostToolUse "" ""

  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ------------------------------------------------------------- row wording

@test "a permission row names the tool it is blocked on" {
  # Triage from the row itself: which session wants what is the whole reason
  # the pending tool is carried through PreToolUse.
  load_board

  run state_verb permission "Bash: git push origin main"

  [ "$output" = "wants Bash" ]
}

@test "a permission row with no tool recorded still says what it needs" {
  load_board

  run state_verb permission ""

  [ "$output" = "needs permission" ]
}

@test "each remaining state has its own phrase" {
  load_board

  run state_verb waiting ""
  [ "$output" = "waiting for input" ]

  run state_verb ready ""
  [ "$output" = "ready for you" ]

  run state_verb working ""
  [ "$output" = "working" ]
}

# ------------------------------------------------------------------- ages

@test "an age is worded at the coarsest unit that still says something" {
  load_board

  run age_str 45
  [ "$output" = "45s" ]

  run age_str 90
  [ "$output" = "1m" ]

  run age_str 3700
  [ "$output" = "1h 1m" ]

  run age_str 90000
  [ "$output" = "1d" ]
}

# -------------------------------------------------------------- truncation

@test "text within the limit is left exactly as it is" {
  load_board

  run ellipsis "short" 10

  [ "$output" = "short" ]
}

@test "text over the limit is cut to the limit, ellipsis included" {
  # The ellipsis replaces the last character kept rather than being appended,
  # so a row never grows past the width it was budgeted. Asserted on the string
  # and not on ${#output}: outside a UTF-8 locale that counts the ellipsis as
  # its three bytes.
  load_board

  run ellipsis "abcdef" 4

  [ "$output" = "abc…" ]
}

# ---------------------------------------------------- SwiftBar-safe values

@test "a pipe in a record can never become a SwiftBar parameter" {
  # SwiftBar splits a row on "|", so a prompt containing one would turn the
  # rest of the row into menu item parameters.
  load_board

  run menu_safe 'fix the a|b parser'

  [ "$output" = 'fix the a¦b parser' ]
}

@test "a newline in a record can never split one row into two" {
  load_board

  run menu_safe 'first
second'

  [ "$output" = "first second" ]
}

# --------------------------------------------------------------- ordering

@test "rows sort by how much the session needs you" {
  # The board is walked with the arrow keys, so this ordering is the row's
  # position — it must not depend on the session id the store globs in.
  load_board

  run state_rank permission
  [ "$output" = "1" ]

  run state_rank waiting
  [ "$output" = "2" ]

  run state_rank ready
  [ "$output" = "3" ]

  run state_rank working
  [ "$output" = "4" ]
}
