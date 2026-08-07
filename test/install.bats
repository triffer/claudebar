#!/usr/bin/env bats
# install.sh edits the user's real ~/.claude/settings.json and notify.conf, so
# it gets run for real here — against a throwaway HOME, with the few macOS-only
# commands stubbed out.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup() {
  claudebar_setup
  # install.sh honours CLAUDE_NOTIFY_HOME, which claudebar_setup already points
  # at the throwaway tree; HOME and the stub PATH come from there too.
  CLAUDE_HOME="$CLAUDE_NOTIFY_HOME"
  CONF="$CLAUDE_HOME/notify.conf"
  SETTINGS="$CLAUDE_HOME/settings.json"
  LIB="$CLAUDE_HOME/hooks/claudebar-lib"
}
teardown() { claudebar_teardown; }

install_run() { bash "$REPO_ROOT/install.sh" --no-deps "$@"; }

@test "a fresh install lays down scripts, lib and config" {
  run install_run

  [ "$status" -eq 0 ]
  [ -x "$CLAUDE_HOME/hooks/claude-notify.sh" ]
  [ -x "$CLAUDE_HOME/claude-signal-watcher.sh" ]
  [ -x "$CLAUDE_HOME/claudebar-focus.sh" ]
  [ -x "$CLAUDE_HOME/claudebar-update.sh" ]
  [ -f "$LIB/paths.sh" ]
  [ -f "$LIB/record.sh" ]
  [ -f "$LIB/transcript.sh" ]
  [ -f "$LIB/version.sh" ]
  [ -f "$CONF" ]
}

@test "the install stamps which version it put down, and how to update it" {
  install_run

  # nothing on the installed side sits next to a package.json, so this stamp is
  # the only place the running version exists
  ( . "$LIB/installed.sh"
    [ "$CLAUDEBAR_VERSION" = "$(jq -r .version "$REPO_ROOT/package.json")" ]
    [ "$CLAUDEBAR_INSTALL_METHOD" = "git" ]      # this repo is a checkout
    [ "$CLAUDEBAR_INSTALL_SOURCE" = "$REPO_ROOT" ] )
}

@test "the stamp survives a source path made of shell syntax" {
  # it is sourced as bash, and nobody's directory names are our business
  local weird="$TEST_ROOT/it's \$HOME \`now\`"
  copy_source_tree "$weird"

  bash "$weird/install.sh" --no-deps

  ( . "$LIB/installed.sh"
    [ "$CLAUDEBAR_INSTALL_SOURCE" = "$weird" ] )
}

@test "an install without git history updates through npx instead" {
  # what npx leaves behind: the files, no .git to pull
  copy_source_tree "$TEST_ROOT/npx-cache"

  bash "$TEST_ROOT/npx-cache/install.sh" --no-deps

  ( . "$LIB/installed.sh"; [ "$CLAUDEBAR_INSTALL_METHOD" = "npx" ] )
}

@test "the generated config carries every key and is valid bash" {
  install_run

  bash -n "$CONF"

  for key in IDE_CMD TERMINAL_BUNDLE_ID STALE_HOURS BAR_STYLE BAR_SHOW_WORKING \
             UPDATE_CHECK_HOURS UPDATE_NOTIFY; do
    grep -q "^$key=" "$CONF"
  done
  ( . "$CONF"; [ "$BAR_STYLE" = "detailed" ] && [ "$STALE_HOURS" = "1" ] )
}

@test "hooks are registered for every event" {
  install_run

  for ev in SessionStart UserPromptSubmit PreToolUse Notification Stop SessionEnd; do
    run jq -e --arg e "$ev" '.hooks[$e][0].hooks[0].command | test("claude-notify")' "$SETTINGS"
    [ "$status" -eq 0 ]
  done
}

@test "a default install registers the hook by tilde path, not an absolute one" {
  # the default branch means no CLAUDE_NOTIFY_HOME — still isolated, because
  # HOME already points into the test tree, so this lands in $HOME/.claude
  ( unset CLAUDE_NOTIFY_HOME; install_run )

  run jq -r '.hooks.Stop[0].hooks[0].command' "$HOME/.claude/settings.json"
  # settings.json gets synced between machines; ~ survives a different username
  [ "$output" = "bash ~/.claude/hooks/claude-notify.sh" ]
}

@test "re-installing does not stack duplicate hook entries" {
  install_run

  install_run
  install_run

  local n
  n=$(jq '[.hooks[][].hooks[] | select(.command | test("claude-notify"))] | length' "$SETTINGS")
  [ "$n" -eq 6 ]
}

@test "an unrelated hook in settings.json is left alone" {
  mkdir -p "$CLAUDE_HOME"
  jq -n '{hooks: {Stop: [{hooks: [{type: "command", command: "my-own-thing.sh"}]}]}}' > "$SETTINGS"

  install_run

  run jq -e '[.hooks.Stop[].hooks[] | select(.command == "my-own-thing.sh")] | length == 1' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "install refuses to touch settings.json that is not valid JSON" {
  mkdir -p "$CLAUDE_HOME"
  printf '{ broken' > "$SETTINGS"

  run install_run

  [ "$status" -ne 0 ]
  [ "$(cat "$SETTINGS")" = "{ broken" ]
}

@test "upgrading appends only the missing keys and keeps user edits" {
  mkdir -p "$CLAUDE_HOME"
  cat > "$CONF" <<'EOF'
# my own notes
IDE_CMD="/usr/local/bin/mine"
STALE_HOURS=42
EOF

  install_run

  ( . "$CONF"
    [ "$IDE_CMD" = "/usr/local/bin/mine" ]   # untouched
    [ "$STALE_HOURS" = "42" ]                # untouched
    [ "$BAR_STYLE" = "detailed" ] )          # appended
  [ "$(grep -c '^IDE_CMD=' "$CONF")" -eq 1 ]
  grep -q 'my own notes' "$CONF"
}

@test "upgrading twice is a no-op the second time" {
  install_run
  local before; before=$(md5sum < "$CONF")

  install_run

  [ "$(md5sum < "$CONF")" = "$before" ]
}

@test "the hook works from its installed location, with no checkout nearby" {
  install_run

  # exactly how Claude Code invokes it — the lib must resolve from
  # hooks/claudebar-lib next to it, not from the repo
  CLAUDEBAR_LIB="" CLAUDE_NOTIFY_HOME="$CLAUDE_HOME" CLAUDE_SIGNALS_DIR="" \
    bash "$CLAUDE_HOME/hooks/claude-notify.sh" \
    <<<'{"hook_event_name":"SessionStart","session_id":"installed","cwd":"/tmp"}'

  [ -f "$CLAUDE_HOME/notifier-sessions/installed.json" ]
  [ "$(jq -r .state "$CLAUDE_HOME/notifier-sessions/installed.json")" = "ready" ]
}

@test "the lib rides along on the symlink sbx-kit makes into a sandbox" {
  install_run
  # what sbx-kit/spec.yaml does: link the host's hooks/ into the sandbox
  local box="$TEST_ROOT/sandbox/.claude"
  mkdir -p "$box"
  ln -s "$CLAUDE_HOME/hooks" "$box/hooks"

  CLAUDEBAR_LIB="" CLAUDE_NOTIFY_HOME="$box" CLAUDE_SIGNALS_DIR="" \
    bash "$box/hooks/claude-notify.sh" \
    <<<'{"hook_event_name":"Stop","session_id":"inbox","cwd":"/tmp"}'

  # the library living INSIDE hooks/ is the whole reason it comes too
  [ -r "$box/hooks/claudebar-lib/paths.sh" ]
  [ -f "$box/notifier-sessions/inbox.json" ]
}

@test "install never consults the real SwiftBar preferences" {
  run install_run

  # `defaults` ignores $HOME (it resolves the home from the password database),
  # so consulting it at all would return the developer's real plugin folder —
  # and the next line would install into it. CLAUDEBAR_PLUGIN_DIR must win.
  [ "$status" -eq 0 ]
  refute_called defaults
}

@test "uninstall never consults the real SwiftBar preferences" {
  install_run

  run install_run --uninstall

  # this is the path that deleted a developer's installed plugin
  [ "$status" -eq 0 ]
  refute_called defaults
}

@test "the plugin is installed into, and removed from, the given plugin dir" {
  install_run
  [ -x "$CLAUDEBAR_PLUGIN_DIR/claudebar.3s.sh" ]

  install_run --uninstall

  [ ! -e "$CLAUDEBAR_PLUGIN_DIR/claudebar.3s.sh" ]
}

@test "install writes nothing outside the test tree" {
  run install_run

  # every path the installer creates has to be under TEST_ROOT
  [ "$status" -eq 0 ]
  [ -d "$CLAUDE_HOME/hooks" ]
  [ -d "$CLAUDE_SIGNALS_INBOX" ]
  [ -f "$HOME/Library/LaunchAgents/com.claude.notify.watcher.plist" ]
  grep -q "$TEST_ROOT" "$HOME/Library/LaunchAgents/com.claude.notify.watcher.plist"
  ! grep -q "/Users/riffer" "$HOME/Library/LaunchAgents/com.claude.notify.watcher.plist"
}

@test "install refuses to overwrite a foreign claudebar-lib directory" {
  # ~/.claude/hooks is shared space; nothing claudebar does may delete a
  # directory it cannot prove it created
  mkdir -p "$LIB"
  printf 'someone else\n' > "$LIB/theirs.sh"

  run install_run

  [ "$status" -ne 0 ]
  [ -f "$LIB/theirs.sh" ]
}

@test "uninstall leaves a foreign claudebar-lib directory in place" {
  mkdir -p "$LIB"
  printf 'someone else\n' > "$LIB/theirs.sh"

  run install_run --uninstall

  [ "$status" -eq 0 ]
  [ -f "$LIB/theirs.sh" ]
}

@test "a re-install replaces claudebar's own lib without complaint" {
  install_run
  printf 'stale\n' > "$LIB/removed-in-a-later-version.sh"

  run install_run

  [ "$status" -eq 0 ]
  [ ! -e "$LIB/removed-in-a-later-version.sh" ]
  [ -f "$LIB/paths.sh" ]
}

@test "unrelated files in ~/.claude/hooks are never touched" {
  mkdir -p "$CLAUDE_HOME/hooks"
  printf '#!/bin/sh\n' > "$CLAUDE_HOME/hooks/my-other-hook.sh"

  install_run
  install_run --uninstall

  [ -f "$CLAUDE_HOME/hooks/my-other-hook.sh" ]
}

@test "uninstall removes scripts, lib and hook entries but keeps the config" {
  install_run

  run install_run --uninstall

  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_HOME/hooks/claude-notify.sh" ]
  [ ! -e "$LIB" ]
  [ ! -e "$CLAUDE_HOME/claude-signal-watcher.sh" ]
  [ ! -e "$CLAUDE_HOME/claudebar-update.sh" ]
  [ ! -e "$CLAUDE_HOME/claudebar-update.json" ]
  [ -f "$CONF" ]
  run jq -e '.hooks // {} | length == 0' "$SETTINGS"
  [ "$status" -eq 0 ]
}
