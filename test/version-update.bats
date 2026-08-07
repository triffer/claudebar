#!/usr/bin/env bats
# Knowing which version is installed, and noticing when a newer one is out.
# claudebar never installs itself, and several tests below exist to keep it
# that way: an upgrade from the menu costs an Apple Events permission dialog,
# an announcement costs a notification one.
#
# Every test here runs with curl stubbed — a suite that asks GitHub about
# releases would be both slow and, on a rate-limited runner, flaky.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup()    { claudebar_setup; }
teardown() { claudebar_teardown; }

# ------------------------------------------------------------ comparing them

@test "a higher release beats the installed version" {
  load_lib

  run claudebar_version_newer 1.3.0 1.2.9

  [ "$status" -eq 0 ]
}

@test "the version you already run is not an update" {
  load_lib

  run claudebar_version_newer 1.2.0 1.2.0

  [ "$status" -ne 0 ]
}

@test "version fields compare as numbers, not as text" {
  load_lib

  # the string comparison every naive version check gets wrong
  run claudebar_version_newer 1.10.0 1.9.0

  [ "$status" -eq 0 ]
}

@test "anything that is not a plain version never counts as newer" {
  load_lib

  # tag_name arrives from the network and ends up in menu markup, a URL and an
  # osascript string — so anything unexpected is not a version at all
  for junk in "" "dev" "v1.2.3" "1.2.3; rm -rf /" "1.2"; do
    run claudebar_version_newer "$junk" 0.0.1
    [ "$status" -ne 0 ]
  done
}

# --------------------------------------------------------------- the check

@test "a check records the release GitHub reports" {
  load_lib
  stub_reply curl <<<'{"tag_name": "v1.5.0"}'

  claudebar_update_fetch 1000

  [ "$(update_cache_field latest)" = "1.5.0" ]
  [ "$(update_cache_field checked)" = "1000" ]
}

@test "an unreachable GitHub leaves the last answer standing" {
  load_lib
  put_update_cache 1.4.0 1000
  stub_reply curl 7 </dev/null

  run claudebar_update_fetch 2000

  [ "$status" -ne 0 ]
  [ "$(update_cache_field latest)" = "1.4.0" ]
}

@test "a garbled release name is not recorded" {
  load_lib
  put_update_cache 1.4.0 1000
  stub_reply curl <<<'{"tag_name": "nightly-2024-01-01"}'

  run claudebar_update_fetch 2000

  [ "$status" -ne 0 ]
  [ "$(update_cache_field latest)" = "1.4.0" ]
}

@test "a corrupt cache reads back as never checked" {
  load_lib
  printf 'not json at all' > "$CLAUDE_NOTIFY_HOME/claudebar-update.json"

  claudebar_update_cache_read

  [ "$CLAUDEBAR_CHECKED" = "0" ]
  [ -z "$CLAUDEBAR_LATEST" ]
}

# ------------------------------------------------------------ what the board
# shows

@test "the board names the version it is running" {
  stamp_version 1.2.0

  run bash "$BOARD"

  [[ "$output" == *"claudebar v1.2.0"* ]]
}

@test "an unstamped checkout still renders a version row" {
  # no installed.sh: version.sh falls back to the checkout's package.json
  run bash "$BOARD"

  [[ "$output" == *"claudebar v"* ]]
}

@test "a newer release links to its release notes" {
  stamp_version 1.0.0
  install_helper
  put_update_cache 2.0.0 "$(date +%s)"

  run bash "$BOARD"

  # the click leaves claudebar entirely — the release page carries the command
  [[ "$output" == *"⬆ claudebar 2.0.0 available"* ]]
  [[ "$output" == *"href=https://github.com/triffer/claudebar/releases/tag/v2.0.0"* ]]
  [[ "$output" == *"you have v1.0.0 · copy the update command"* ]]
}

@test "no menu row ever runs an upgrade" {
  stamp_version 1.0.0
  install_helper
  put_update_cache 2.0.0 "$(date +%s)"

  run bash "$BOARD"

  # opening Terminal from a plugin costs an Apple Events permission dialog,
  # which is what this whole section is arranged to avoid
  [[ "$output" != *"terminal=true"* ]]
}

@test "the board never posts a notification" {
  stamp_version 1.0.0
  install_helper
  put_update_cache 2.0.0 "$(date +%s)"

  run bash "$BOARD"

  # announcing a release asked for notification permission; the row above says
  # the same thing where the user was already looking
  refute_called osascript
}

@test "an older release on GitHub is not offered as an update" {
  stamp_version 2.0.0
  install_helper
  put_update_cache 1.0.0 "$(date +%s)"

  run bash "$BOARD"

  [[ "$output" != *"available"* ]]
  [[ "$output" == *"claudebar v2.0.0"* ]]
}

@test "without the helper installed the update row still links out" {
  stamp_version 1.0.0
  put_update_cache 2.0.0 "$(date +%s)"

  run bash "$BOARD"

  # the link needs nothing installed; only the clipboard action does
  [[ "$output" == *"⬆ claudebar 2.0.0 available"* ]]
  [[ "$output" != *"copy the update command"* ]]
}

# --------------------------------------------------- how often it checks

@test "a due check is stamped before the network call, not after" {
  stamp_version 1.0.0
  stub_reply curl 7 </dev/null

  UPDATE_CHECK_HOURS=24 run bash "$BOARD"

  # the fetch is detached; the stamp is what stops the next refresh — three
  # seconds away — from starting another one
  [ "$(update_cache_field checked)" != "0" ]
}

@test "a check that just ran is not repeated" {
  stamp_version 1.0.0
  put_update_cache 1.0.0 "$(date +%s)"

  UPDATE_CHECK_HOURS=24 run bash "$BOARD"

  refute_called curl
}

@test "UPDATE_CHECK_HOURS=0 never asks GitHub anything" {
  stamp_version 1.0.0

  UPDATE_CHECK_HOURS=0 run bash "$BOARD"

  refute_called curl
  [ ! -f "$CLAUDE_NOTIFY_HOME/claudebar-update.json" ]
}

# ------------------------------------------------------ the update helper
# It has two jobs and neither of them installs anything.

@test "--check refreshes the cache and repaints the bar" {
  stamp_version 1.0.0 npx ""
  stub_reply curl <<<'{"tag_name": "v9.9.9"}'

  run bash "$UPDATE" --check

  [ "$(update_cache_field latest)" = "9.9.9" ]
  assert_called_with open "swiftbar://refreshallplugins"
}

@test "--copy puts the pinned npx command on the clipboard" {
  stamp_version 1.0.0 npx ""
  put_update_cache 2.0.0 "$(date +%s)"

  run bash "$UPDATE" --copy

  [ "$(clipboard)" = "npx github:triffer/claudebar#v2.0.0 install" ]
}

@test "--copy tells a checkout to pull instead" {
  local src="$TEST_ROOT/my checkout"
  git_repo "$src" 'true'
  stamp_version 1.0.0 git "$src"
  put_update_cache 2.0.0 "$(date +%s)"

  run bash "$UPDATE" --copy

  # quoted, because the path is the user's and may hold spaces
  [ "$(clipboard)" = "cd \"$src\" && git pull && ./install.sh" ]
}

@test "--copy falls back to npx when the checkout is gone" {
  stamp_version 1.0.0 git "$TEST_ROOT/moved-away"
  put_update_cache 2.0.0 "$(date +%s)"

  run bash "$UPDATE" --copy

  [ "$(clipboard)" = "npx github:triffer/claudebar#v2.0.0 install" ]
}

@test "neither mode installs anything" {
  stamp_version 1.0.0 git "$TEST_ROOT/moved-away"
  put_update_cache 2.0.0 "$(date +%s)"

  bash "$UPDATE" --copy; bash "$UPDATE" --check

  refute_called npx
  refute_called osascript
}

@test "an unknown argument is refused rather than guessed at" {
  stamp_version 1.0.0 npx ""

  run bash "$UPDATE" --upgrade-everything

  [ "$status" -eq 2 ]
}
