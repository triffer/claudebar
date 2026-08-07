#!/usr/bin/env bats
# Knowing which version is installed, noticing a newer one, and installing it.
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
  put_update_cache 1.4.0 1000 ""
  stub_reply curl 7 </dev/null

  run claudebar_update_fetch 2000

  [ "$status" -ne 0 ]
  [ "$(update_cache_field latest)" = "1.4.0" ]
}

@test "a garbled release name is not recorded" {
  load_lib
  put_update_cache 1.4.0 1000 ""
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

@test "a newer release turns the version row into an update action" {
  stamp_version 1.0.0
  install -m 0755 "$UPDATE" "$CLAUDE_NOTIFY_HOME/claudebar-update.sh"
  put_update_cache 2.0.0 "$(date +%s)" 2.0.0

  run bash "$BOARD"

  [[ "$output" == *"⬆ claudebar 2.0.0 available — click to update"* ]]
  [[ "$output" == *"$CLAUDE_NOTIFY_HOME/claudebar-update.sh"* ]]
  [[ "$output" == *"you have v1.0.0"* ]]
}

@test "an older release on GitHub is not offered as an update" {
  stamp_version 2.0.0
  install -m 0755 "$UPDATE" "$CLAUDE_NOTIFY_HOME/claudebar-update.sh"
  put_update_cache 1.0.0 "$(date +%s)" ""

  run bash "$BOARD"

  [[ "$output" != *"click to update"* ]]
  [[ "$output" == *"claudebar v2.0.0"* ]]
}

@test "without the update action installed the version row only links out" {
  stamp_version 1.0.0
  put_update_cache 2.0.0 "$(date +%s)" 2.0.0

  run bash "$BOARD"

  # nothing to click when there is no installed updater to run
  [[ "$output" != *"click to update"* ]]
  [[ "$output" == *"href=https://github.com/triffer/claudebar/releases"* ]]
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
  put_update_cache 1.0.0 "$(date +%s)" ""

  UPDATE_CHECK_HOURS=24 run bash "$BOARD"

  refute_called curl
}

@test "UPDATE_CHECK_HOURS=0 never asks GitHub anything" {
  stamp_version 1.0.0

  UPDATE_CHECK_HOURS=0 run bash "$BOARD"

  refute_called curl
  [ ! -f "$CLAUDE_NOTIFY_HOME/claudebar-update.json" ]
}

# ------------------------------------------------------------- announcing it

@test "a new release is announced once" {
  stamp_version 1.0.0
  put_update_cache 2.0.0 "$(date +%s)" ""

  run bash "$BOARD"

  assert_called_with osascript "display notification.*2\.0\.0"
  [ "$(update_cache_field notified)" = "2.0.0" ]
}

@test "a release already announced stays quiet" {
  stamp_version 1.0.0
  put_update_cache 2.0.0 "$(date +%s)" 2.0.0

  run bash "$BOARD"

  refute_called osascript
}

@test "UPDATE_NOTIFY=0 keeps the update to the menu" {
  stamp_version 1.0.0
  install -m 0755 "$UPDATE" "$CLAUDE_NOTIFY_HOME/claudebar-update.sh"
  put_update_cache 2.0.0 "$(date +%s)" ""

  UPDATE_NOTIFY=0 run bash "$BOARD"

  refute_called osascript
  [[ "$output" == *"click to update"* ]]
}

# ------------------------------------------------------------- updating

@test "the update action pulls the checkout it was installed from" {
  local upstream="$TEST_ROOT/upstream" src="$TEST_ROOT/src"
  git_repo "$upstream" 'printf "installed\n" > "$CLAUDE_NOTIFY_HOME/marker"'
  git clone -q "$upstream" "$src"
  git_commit "$upstream" 'printf "installed by the new version\n" > "$CLAUDE_NOTIFY_HOME/marker"'
  stamp_version 1.0.0 git "$src"

  run bash "$UPDATE"

  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_NOTIFY_HOME/marker")" = "installed by the new version" ]
}

@test "a pull that would not fast-forward stops before installing anything" {
  local upstream="$TEST_ROOT/upstream" src="$TEST_ROOT/src"
  git_repo "$upstream" 'true'
  git clone -q "$upstream" "$src"
  # only the pulled installer leaves the marker, so its absence says the
  # upgrade stopped rather than running the checkout's own stale copy
  git_commit "$upstream" 'printf "pulled\n" > "$CLAUDE_NOTIFY_HOME/marker"'
  git_commit "$src" 'printf "a local edit nobody pushed\n" > /dev/null'
  stamp_version 1.0.0 git "$src"

  run bash "$UPDATE"

  [ "$status" -ne 0 ]
  [ ! -f "$CLAUDE_NOTIFY_HOME/marker" ]
}

@test "a checkout that is gone falls back to the npx installer" {
  stamp_version 1.0.0 git "$TEST_ROOT/moved-away"

  run bash "$UPDATE"

  [ "$status" -eq 0 ]
  assert_called_with npx "github:triffer/claudebar install"
}

@test "an npx install updates through npx" {
  stamp_version 1.0.0 npx ""

  run bash "$UPDATE"

  [ "$status" -eq 0 ]
  assert_called_with npx "github:triffer/claudebar install"
}

@test "a successful update drops the cache so the menu bar re-reads it" {
  put_update_cache 2.0.0 "$(date +%s)" 2.0.0
  stamp_version 1.0.0 npx ""

  run bash "$UPDATE"

  [ ! -f "$CLAUDE_NOTIFY_HOME/claudebar-update.json" ]
  assert_called_with open "swiftbar://refreshallplugins"
}

@test "--check refreshes the cache without installing anything" {
  stamp_version 1.0.0 npx ""
  stub_reply curl <<<'{"tag_name": "v9.9.9"}'

  run bash "$UPDATE" --check

  [ "$(update_cache_field latest)" = "9.9.9" ]
  refute_called npx
}
