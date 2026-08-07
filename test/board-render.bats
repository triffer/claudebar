#!/usr/bin/env bats
# What the menu bar actually shows: the title line, the grouped dropdown, and
# the per-row details.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup()    { claudebar_setup; }
teardown() { claudebar_teardown; }

board()      { bash "$BOARD"; }
title_line() { board | head -n 1; }

@test "an empty store renders a dim bar and says so" {
  run board

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "✳ | color="* ]]
  [[ "$output" == *"No active Claude sessions"* ]]
}

@test "the detailed title counts each state separately" {
  put_record a state=permission
  put_record b state=waiting
  put_record c state=ready
  put_record d state=ready
  put_record e state=working

  run board

  [ "${lines[0]}" = "✳ 🔴1 🟠1 🟢2 🔵1" ]
}

@test "zero counts are left out of the title" {
  put_record a state=ready

  run board

  [ "${lines[0]}" = "✳ 🟢1" ]
}

@test "BAR_SHOW_WORKING=0 hides the working count" {
  put_record a state=ready
  put_record b state=working

  BAR_SHOW_WORKING=0 run bash "$BOARD"

  [ "${lines[0]}" = "✳ 🟢1" ]
}

@test "the minimal style shows one attention count" {
  put_record a state=permission
  put_record b state=ready

  BAR_STYLE=minimal run bash "$BOARD"

  # red, because a permission prompt is the most urgent state present
  [ "${lines[0]}" = "✳ 2 | color=#ff453a" ]
}

@test "the minimal style stays dim when nothing needs you" {
  put_record a state=working

  BAR_STYLE=minimal run bash "$BOARD"

  [ "${lines[0]}" = "✳ | color=#8e8e93" ]
}

@test "stale sessions drop off the board" {
  put_record fresh state=ready
  put_record old state=ready ts=$(( $(date +%s) - 7200 ))

  STALE_HOURS=1 run bash "$BOARD"

  [ "${lines[0]}" = "✳ 🟢1" ]
}

@test "the title line carries the hotkey that opens the board" {
  put_record a state=ready

  MENU_SHORTCUT="CMD+OPTION+C" run bash "$BOARD"

  # header item = "show this menu"; on a body item SwiftBar would run its action
  [ "${lines[0]}" = "✳ 🟢1 | shortcut=CMD+OPTION+C" ]
}

@test "the hotkey joins the parameters the title already had" {
  MENU_SHORTCUT="cmd+option+c" BAR_STYLE=minimal run bash "$BOARD"

  [ "${lines[0]}" = "✳ | color=#6e6e73 shortcut=CMD+OPTION+C" ]
}

@test "no hotkey configured leaves the title exactly as it was" {
  put_record a state=ready

  run board

  [ "${lines[0]}" = "✳ 🟢1" ]
}

@test "a hotkey cannot smuggle parameters onto the title line" {
  # notify.conf is user-edited bash, sourced into the plugin's own shell
  put_record a state=ready

  MENU_SHORTCUT="CMD+C|href=x" run bash "$BOARD"

  [ "${lines[0]}" = "✳ 🟢1 | shortcut=CMD+CHREFX" ]
}

@test "rows in a group are ordered longest-waiting first" {
  # ids chosen so the store globs them the other way round: the board is walked
  # with arrow keys, so position has to mean something
  put_record zzz state=waiting project=satlongest ts=$(( $(date +%s) - 600 ))
  put_record aaa state=waiting project=justarrived ts=$(( $(date +%s) - 60 ))

  run board

  [[ "$output" == *"satlongest"*"justarrived"* ]]
}

@test "the more urgent state leads within a shared heading" {
  put_record a state=waiting project=merelywaiting ts=$(( $(date +%s) - 600 ))
  put_record b state=permission project=blocked ts=$(( $(date +%s) - 60 ))

  run board

  # NEEDS YOU holds both, and permission wins despite having sat there less long
  [[ "$output" == *"blocked"*"merelywaiting"* ]]
}

@test "sessions are grouped under the right headings" {
  put_record a state=permission
  put_record b state=ready
  put_record c state=working

  run board

  [[ "$output" == *"NEEDS YOU"* ]]
  [[ "$output" == *"READY"* ]]
  [[ "$output" == *"WORKING"* ]]
}

@test "a heading is omitted when its group is empty" {
  put_record a state=working

  run board

  [[ "$output" != *"NEEDS YOU"* ]]
  [[ "$output" != *"READY"* ]]
  [[ "$output" == *"WORKING"* ]]
}

@test "a pipe in a prompt cannot break SwiftBar's markup" {
  # SwiftBar treats "|" as its parameter separator
  put_record a state=ready prompt="grep foo | wc -l"

  run board

  [[ "$output" == *"grep foo ¦ wc -l"* ]]
  [[ "$output" != *"grep foo | wc -l"* ]]
}

@test "the session title is preferred over the last prompt" {
  # a follow-up that says nothing about what the session is
  put_record a state=ready prompt="yes, do that" summary="Rework the installer"

  run board

  [[ "$output" == *"↳ Rework the installer"* ]]
  [[ "$output" != *"yes, do that"* ]]
}

@test "the last prompt is shown while there is no title yet" {
  put_record a state=ready prompt="add a dark mode"

  run board

  # the ❯ marks which of the two you are looking at
  [[ "$output" == *"↳ ❯ add a dark mode"* ]]
}

@test "a permission row names the tool it is blocked on" {
  put_record a state=permission pending="Bash: rm -rf build"

  run board

  [[ "$output" == *"wants Bash"* ]]
  [[ "$output" == *"↳ wants: Bash: rm -rf build"* ]]
}

@test "a permission row with no pending tool still reads sensibly" {
  put_record a state=permission

  run board

  [[ "$output" == *"needs permission"* ]]
}

@test "sandbox rows lead with the box name" {
  # with --clone boxes the repo/branch alone rarely identifies the right session
  put_record a state=ready origin=sbx:mybox project=repo branch=feat

  run board

  [[ "$output" == *"📦 mybox · repo @ feat"* ]]
}

@test "host rows show project and branch without a box marker" {
  put_record a state=ready project=repo branch=main

  run board

  [[ "$output" == *"repo @ main"* ]]
  [[ "$output" != *"📦"* ]]
}

@test "every row offers an alt-click dismiss action" {
  put_record a state=ready

  run board

  [[ "$output" == *"dismiss | alternate=true"* ]]
}

@test "a long title is truncated rather than wrapped" {
  put_record a state=ready summary="$(printf 'x%.0s' {1..200})"

  run board

  [[ "$output" == *"…"* ]]
}

@test "a corrupt record is skipped without taking the board down" {
  put_record good state=ready
  printf '%s\n' 'not json' > "$SESSIONS_DIR/bad.json"

  run board

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "✳ 🟢1" ]
}

@test "the demo fixture renders the board it advertises" {
  run bash "$REPO_ROOT/examples/demo-board.sh"

  # if the schema or the counting drifts, the screenshot fixture goes stale first
  [ "$status" -eq 0 ]
  [[ "$output" == *"✳ 🔴2 🟠2 🟢2 🔵3"* ]]
  [ "$(title_line)" = "✳ 🔴2 🟠2 🟢2 🔵3" ]
}

@test "the demo fixture clears only its own sessions" {
  put_record mine state=working
  bash "$REPO_ROOT/examples/demo-board.sh" >/dev/null

  run bash "$REPO_ROOT/examples/demo-board.sh" --clear

  [ "$status" -eq 0 ]
  [ -f "$SESSIONS_DIR/mine.json" ]
  [ "$(title_line)" = "✳ 🔵1" ]
}

@test "the board still renders when the shared lib is missing" {
  # the plugin copied somewhere with no sibling hooks/, i.e. a half-finished
  # install. From a checkout the repo-relative path always resolves.
  mkdir -p "$TEST_ROOT/plugins"
  cp "$BOARD" "$TEST_ROOT/plugins/claudebar.3s.sh"

  CLAUDEBAR_LIB="" CLAUDE_NOTIFY_HOME="$TEST_ROOT/nope" \
    run bash "$TEST_ROOT/plugins/claudebar.3s.sh"

  # a blank menu item with no hint would be the worst outcome
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "✳ | color="* ]]
  [[ "$output" == *"claudebar install"* ]]
}
