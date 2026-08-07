# Shared setup for the claudebar bats suite.
#
# ISOLATION IS THE POINT OF THIS FILE. The suite runs the real installer and the
# real scripts, so every path they touch must land inside a throwaway tree —
# otherwise a test run edits the developer's own claudebar install.
#
# Redirecting HOME is NOT sufficient on macOS: `defaults` resolves the user's
# home from the password database, so `defaults read com.ameba.SwiftBar` returns
# the real plugin folder no matter what HOME says. install.sh would then write
# its plugin into the real SwiftBar folder, and --uninstall would delete it.
# That is why every host-touching command is stubbed on PATH and the plugin
# directory is passed in explicitly via CLAUDEBAR_PLUGIN_DIR.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOOK="$REPO_ROOT/hooks/claude-notify.sh"
BOARD="$REPO_ROOT/host/claudebar.3s.sh"
WATCHER="$REPO_ROOT/host/claude-signal-watcher.sh"
UPDATE="$REPO_ROOT/host/claudebar-update.sh"

# Commands that would otherwise reach the real machine — or, for curl and npx,
# the real network. Each one records its arguments so a test can assert it was
# never called with anything real.
CLAUDEBAR_STUBBED_COMMANDS=(defaults open launchctl afplay osascript brew curl npx)

claudebar_setup() {
  TEST_ROOT="$(mktemp -d)"

  export HOME="$TEST_ROOT/home"
  export CLAUDE_NOTIFY_HOME="$TEST_ROOT/claude"
  export TMPDIR="$TEST_ROOT/tmp"
  export CLAUDEBAR_LIB="$REPO_ROOT/hooks/claudebar-lib"
  # Set-but-empty forces local delivery: the suite runs on Linux CI, where the
  # bare uname check would otherwise send every record down the sandbox path.
  export CLAUDE_SIGNALS_DIR=""
  export CLAUDE_SIGNALS_INBOX="$TEST_ROOT/signals"
  # Never let install.sh consult the real SwiftBar preferences.
  export CLAUDEBAR_PLUGIN_DIR="$TEST_ROOT/plugins"
  # The board checks GitHub for a newer release once a day. Off by default here
  # so no test reaches for the network by accident; the tests that exercise the
  # check turn it back on (and curl is stubbed regardless).
  export UPDATE_CHECK_HOURS=0

  SESSIONS_DIR="$CLAUDE_NOTIFY_HOME/notifier-sessions"
  STUB_CALLS="$TEST_ROOT/stub-calls.log"
  mkdir -p "$HOME" "$SESSIONS_DIR" "$TMPDIR" "$CLAUDE_SIGNALS_INBOX" \
           "$CLAUDEBAR_PLUGIN_DIR"
  : > "$STUB_CALLS"

  claudebar_install_stubs
  claudebar_assert_isolated

  # git metadata would leak the real repo's branch into every record
  unset GIT_DIR GIT_WORK_TREE
}

claudebar_install_stubs() {
  local bin="$TEST_ROOT/stub" cmd
  mkdir -p "$bin"
  for cmd in "${CLAUDEBAR_STUBBED_COMMANDS[@]}"; do
    { printf '#!/bin/sh\n'
      printf 'printf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$cmd" "$STUB_CALLS"
      printf 'exit 0\n'
    } > "$bin/$cmd"
    chmod +x "$bin/$cmd"
  done
  # install.sh refuses to run anywhere but macOS
  printf '#!/bin/sh\necho Darwin\n' > "$bin/uname"
  chmod +x "$bin/uname"
  export PATH="$bin:$PATH"
}

# Refuse to run at all unless everything points into the throwaway tree. A bug
# in this file must not be able to reach the developer's machine quietly.
claudebar_assert_isolated() {
  local var
  for var in HOME CLAUDE_NOTIFY_HOME TMPDIR CLAUDE_SIGNALS_INBOX CLAUDEBAR_PLUGIN_DIR; do
    case "${!var}" in
      "$TEST_ROOT"/*) ;;
      *) printf 'claudebar tests: %s=%s is outside the test tree — refusing to run\n' \
           "$var" "${!var}" >&2; return 1 ;;
    esac
  done
  for var in "${CLAUDEBAR_STUBBED_COMMANDS[@]}"; do
    case "$(command -v "$var" 2>/dev/null)" in
      "$TEST_ROOT"/stub/*) ;;
      "") ;;   # absent on this box (Linux CI) — nothing to reach
      *) printf 'claudebar tests: %s is not stubbed — refusing to run\n' "$var" >&2
         return 1 ;;
    esac
  done
}

# Assert a host-touching command was never invoked during this test.
refute_called() { # $1: command name
  ! grep -q "^$1 " "$STUB_CALLS"
}

# Assert one was, with arguments matching a pattern.
assert_called_with() { # $1: command name  $2: grep -E pattern over its arguments
  grep -E "^$1 .*$2" "$STUB_CALLS"
}

# Give a stub a canned reply for the rest of this test. It keeps logging its
# arguments, then prints what it was handed here.
stub_reply() { # $1: command  $2: exit status (default 0)  stdin: its stdout
  local cmd=$1 code=${2:-0} out="$TEST_ROOT/stub-$1.out"
  cat > "$out"
  { printf '#!/bin/sh\n'
    printf 'printf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$cmd" "$STUB_CALLS"
    printf 'cat "%s"\n' "$out"
    printf 'exit %s\n' "$code"
  } > "$TEST_ROOT/stub/$cmd"
  chmod +x "$TEST_ROOT/stub/$cmd"
}

# A copy of the library carrying a version stamp, exactly as install.sh writes
# one. Anything that renders or acts on a version must use this rather than the
# repo's own lib: with no installed.sh, version.sh falls back to package.json
# and points CLAUDEBAR_INSTALL_SOURCE at this very checkout — which the update
# action would then happily `git pull`.
stamp_version() { # $1: version  $2: install method  $3: install source
  export CLAUDEBAR_LIB="$TEST_ROOT/lib"
  mkdir -p "$CLAUDEBAR_LIB"
  cp "$REPO_ROOT"/hooks/claudebar-lib/*.sh "$CLAUDEBAR_LIB/"
  { printf 'CLAUDEBAR_VERSION="%s"\n' "$1"
    printf 'CLAUDEBAR_INSTALL_METHOD="%s"\n' "${2:-git}"
    printf 'CLAUDEBAR_INSTALL_SOURCE="%s"\n' "${3:-$TEST_ROOT/src}"
  } > "$CLAUDEBAR_LIB/installed.sh"
}

# Seed what the last update check found.
put_update_cache() { # $1: latest  $2: checked (unix time)  $3: notified
  jq -n --arg l "$1" --argjson c "${2:-0}" --arg n "${3:-}" \
    '{latest: $l, checked: $c, notified: $n}' \
    > "$CLAUDE_NOTIFY_HOME/claudebar-update.json"
}

update_cache_field() { # $1: field
  jq -r --arg f "$1" '.[$f]' "$CLAUDE_NOTIFY_HOME/claudebar-update.json"
}

# A throwaway checkout for the update action to pull, whose install.sh does
# whatever the caller asks. HOME points into the test tree, so there is no
# global git identity to inherit — every commit brings its own.
git_repo() { # $1: dir  $2: body of its install.sh
  git init -q "$1"
  git_commit "$1" "$2"
}

# Everything install.sh needs, minus the .git that decides how updates run —
# which is exactly the tree npx unpacks.
copy_source_tree() { # $1: destination
  mkdir -p "$1"
  cp -R "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" \
        "$REPO_ROOT/hooks" "$REPO_ROOT/host" "$1/"
}

git_commit() { # $1: repo  $2: body of its install.sh
  printf '#!/bin/bash\n%s\n' "$2" > "$1/install.sh"
  git -C "$1" add -A
  git -C "$1" -c user.email=test@claudebar -c user.name=claudebar commit -qm "install.sh"
}

claudebar_teardown() {
  [ -n "${TEST_ROOT:-}" ] && rm -rf "$TEST_ROOT"
  return 0
}

# Source the library directly, for unit-level tests.
load_lib() {
  . "$REPO_ROOT/hooks/claudebar-lib/paths.sh"
  . "$REPO_ROOT/hooks/claudebar-lib/record.sh"
  . "$REPO_ROOT/hooks/claudebar-lib/transcript.sh"
  . "$REPO_ROOT/hooks/claudebar-lib/version.sh"
}

# Feed a hook event to claude-notify.sh. Args are jq-style key=value pairs.
send_event() { # $1: event  $2: session id  rest: extra JSON via jq --arg
  local event=$1 sid=$2; shift 2
  local json; json=$(jq -n --arg e "$event" --arg s "$sid" \
    '{hook_event_name: $e, session_id: $s, cwd: "/tmp"}')
  local kv
  for kv in "$@"; do
    json=$(jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' <<<"$json")
  done
  bash "$HOOK" <<<"$json"
}

record_file() { printf '%s/%s.json' "$SESSIONS_DIR" "$1"; }

# Read one field out of a stored record.
record_field() { # $1: session id  $2: field
  jq -r --arg f "$2" '.[$f] // ""' "$(record_file "$1")"
}

# Write a record straight into the store, bypassing the hook — for board tests
# that need a specific state without driving a whole session.
put_record() { # $1: session id  rest: field=value
  local sid=$1; shift
  local json; json=$(jq -n --arg s "$sid" --argjson t "$(date +%s)" \
    '{session_id: $s, origin: "host", project: "proj", branch: "", cwd: "/tmp",
      root: "/tmp", state: "working", message: "", prompt: "", pending: "",
      summary: "", event: "Stop", ts: $t}')
  local kv
  for kv in "$@"; do
    local k=${kv%%=*} v=${kv#*=}
    case "$k" in
      ts) json=$(jq --argjson v "$v" '.ts = $v' <<<"$json") ;;
      *)  json=$(jq --arg k "$k" --arg v "$v" '.[$k] = $v' <<<"$json") ;;
    esac
  done
  printf '%s\n' "$json" > "$SESSIONS_DIR/$sid.json"
}
