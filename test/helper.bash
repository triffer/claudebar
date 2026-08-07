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

# Commands that would otherwise reach the real machine. Each one records its
# arguments so a test can assert it was never called with anything real.
CLAUDEBAR_STUBBED_COMMANDS=(defaults open launchctl afplay osascript brew)

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

claudebar_teardown() {
  [ -n "${TEST_ROOT:-}" ] && rm -rf "$TEST_ROOT"
  return 0
}

# Source the library directly, for unit-level tests.
load_lib() {
  . "$REPO_ROOT/hooks/claudebar-lib/paths.sh"
  . "$REPO_ROOT/hooks/claudebar-lib/record.sh"
  . "$REPO_ROOT/hooks/claudebar-lib/transcript.sh"
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
