#!/bin/bash
# Installer for claudebar — Claude Code session status in your menu bar (SwiftBar).
#
# Run on your Mac host (not inside a sandbox):
#   ./claudebar/install.sh              install / upgrade
#   ./claudebar/install.sh --uninstall  remove everything (keeps notify.conf)
#
# Idempotent: safe to re-run after pulling updates to this repo.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CONF="$CLAUDE_DIR/notify.conf"
HOOK_CMD='bash ~/.claude/hooks/claude-notify.sh'
HOOK_EVENTS=(SessionStart UserPromptSubmit PreToolUse Notification Stop SessionEnd)
PLIST_LABEL="com.claude.notify.watcher"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/com.local.claude-watcher.plist"
# Entries installed by this script, plus the ones from the original draft
# (hooks/notify.sh), are both matched so re-installs and upgrades don't stack.
HOOK_MATCH='claude-notify\.sh|hooks/notify\.sh'

info()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Run this on your Mac host, not inside a sandbox."
command -v jq >/dev/null 2>&1 || die "jq is required: brew install jq"

filter_hooks() { # remove our (and legacy) entries from every hook event
  local tmp; tmp=$(mktemp)
  jq --arg re "$HOOK_MATCH" '
    .hooks = ((.hooks // {})
      | with_entries(.value |= map(select(
          ((.hooks // []) | map(.command // "") | join(" ")) | test($re) | not)))
      | with_entries(select(.value | length > 0)))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
}

uninstall() {
  echo "Uninstalling…"
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  [ -f "$SETTINGS" ] && filter_hooks && info "hook entries removed from settings.json"
  rm -f "$CLAUDE_DIR/hooks/claude-notify.sh" "$CLAUDE_DIR/claude-signal-watcher.sh" \
        "$CLAUDE_DIR/claudebar-focus.sh" \
        "$CLAUDE_DIR/claudebar-open.sh" "$CLAUDE_DIR/notify-sounds-on"   # opener: removed feature, clean up if present
  local plugin_dir
  plugin_dir=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
  [ -n "$plugin_dir" ] && rm -f "$plugin_dir/claudebar.3s.sh" "$plugin_dir/claude-sessions.3s.sh"
  info "scripts and launchd agent removed"
  warn "kept: $CONF, $CLAUDE_DIR/notifier-sessions, $HOME/.claude-signals (delete manually if unwanted)"
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --with-menubar) ;;              # deprecated: the menu bar is now the default
    --uninstall)    uninstall ;;
    *) die "unknown option: $arg (use --uninstall)" ;;
  esac
done

echo "Installing claudebar…"

# 1. Directories -------------------------------------------------------------
# The signal bridge is a SIBLING of ~/.claude: sandboxes mount ~/.claude
# read-only and sbx mounts keep their host path, so the writable bridge must
# live outside of it.
mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/notifier-sessions" "$HOME/.claude-signals"
info "directories ready ($CLAUDE_DIR/{hooks,notifier-sessions}, ~/.claude-signals)"

# 2. Scripts ------------------------------------------------------------------
install -m 0755 "$SCRIPT_DIR/hooks/claude-notify.sh" "$CLAUDE_DIR/hooks/claude-notify.sh"
install -m 0755 "$SCRIPT_DIR/host/claude-signal-watcher.sh" "$CLAUDE_DIR/claude-signal-watcher.sh"
install -m 0755 "$SCRIPT_DIR/host/claudebar-focus.sh" "$CLAUDE_DIR/claudebar-focus.sh"
info "hook, watcher and focus scripts installed"

# 3. Legacy cleanup (first draft of this setup) -------------------------------
if [ -f "$LEGACY_PLIST" ] || [ -f "$CLAUDE_DIR/hooks/notify.sh" ]; then
  launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
  rm -f "$LEGACY_PLIST" "$CLAUDE_DIR/notifier.sh" "$CLAUDE_DIR/hooks/notify.sh"
  info "legacy draft (com.local.claude-watcher, notify.sh) removed"
fi
rm -f "$HOME/.claude-signals"/ping_* 2>/dev/null || true
# Earlier versions stored status records in ~/.claude/sessions, which turned
# out to be Claude Code's OWN session-tracking directory. Remove only our
# records (identified by our schema); never touch Claude Code's files there.
for f in "$CLAUDE_DIR/sessions"/*.json; do
  [ -e "$f" ] || continue
  if jq -e '.origin and .state and .session_id' "$f" >/dev/null 2>&1; then
    rm -f "$f"
  fi
done

# 4. Hooks in settings.json ---------------------------------------------------
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON — fix it and re-run"
filter_hooks
for ev in "${HOOK_EVENTS[@]}"; do
  tmp=$(mktemp)
  jq --arg ev "$ev" --arg cmd "$HOOK_CMD" '
    .hooks = (.hooks // {})
    | .hooks[$ev] = ((.hooks[$ev] // []) + [{hooks: [{type: "command", command: $cmd}]}])
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
done
info "hooks registered in settings.json (${HOOK_EVENTS[*]})"

# 5. Config (created once; new keys are appended on upgrades) -----------------
# JetBrains CLI launcher: `idea <project>` focuses the window of an already
# open project, which gives us per-session focus without any AppleScript.
IDE=""
if command -v idea >/dev/null 2>&1; then
  IDE=$(command -v idea)
elif [ -x "$HOME/Library/Application Support/JetBrains/Toolbox/scripts/idea" ]; then
  IDE="$HOME/Library/Application Support/JetBrains/Toolbox/scripts/idea"
fi

if [ ! -f "$CONF" ]; then
  case "${TERM_PROGRAM:-}" in
    iTerm.app)      TB="com.googlecode.iterm2" ;;
    Apple_Terminal) TB="com.apple.Terminal" ;;
    WezTerm)        TB="com.github.wez.wezterm" ;;
    ghostty)        TB="com.mitchellh.ghostty" ;;
    vscode)         TB="com.microsoft.VSCode" ;;
    *)              TB="" ;;
  esac
  cat > "$CONF" <<EOF
# Claude notifier configuration — sourced by the menu bar plugin.
# Plain bash; edit freely.

# JetBrains CLI launcher. When set, the menu bar "Focus IDE project" action
# opens/focuses the session's project window.
# Leave empty to fall back to TERMINAL_BUNDLE_ID.
IDE_CMD="$IDE"

# App the "Focus terminal" action activates when IDE_CMD is empty.
TERMINAL_BUNDLE_ID="$TB"

# Menu bar: hide sessions with no update for this many hours.
STALE_HOURS=12

# Menu bar style: "detailed" = per-state counts (🔴 permission, 🟠 waiting,
# 🟢 ready, 🔵 working, zero counts hidden); "minimal" = a single ✳ that only
# lights up with a count when sessions need you.
BAR_STYLE="detailed"
# Include the working-session count in the detailed bar (0 = hide).
BAR_SHOW_WORKING=1
EOF
  info "config created: $CONF${TB:+ (terminal: $TB)}${IDE:+ (IDE: idea)}"
else
  # Upgrade path: append keys this version introduced, keep everything else.
  if ! grep -q '^IDE_CMD=' "$CONF"; then
    printf '\n# JetBrains CLI launcher: focuses the session'"'"'s project window on click.\n# Leave empty to fall back to TERMINAL_BUNDLE_ID.\nIDE_CMD="%s"\n' "$IDE" >> "$CONF"
    info "config upgraded: IDE_CMD added${IDE:+ ($IDE)}"
  fi
  if ! grep -q '^BAR_STYLE=' "$CONF"; then
    printf '\n# Menu bar style: "detailed" = per-state counts, "minimal" = single ✳.\nBAR_STYLE="detailed"\n# Include the working-session count in the detailed bar (0 = hide).\nBAR_SHOW_WORKING=1\n' >> "$CONF"
    info "config upgraded: BAR_STYLE/BAR_SHOW_WORKING added"
  fi
  info "config kept: $CONF"
fi

# 6. launchd watcher for sandbox signals --------------------------------------
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/.claude/claude-signal-watcher.sh</string>
    </array>
    <key>QueueDirectories</key>
    <array>
        <string>$HOME/.claude-signals</string>
    </array>
    <key>ThrottleInterval</key>
    <integer>2</integer>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.claude/watcher.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude/watcher.error.log</string>
</dict>
</plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
info "launchd watcher loaded ($PLIST_LABEL)"

# 7. Menu bar status board -----------------------------------------------------
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
if [ -n "$PLUGIN_DIR" ] && [ -d "$PLUGIN_DIR" ]; then
  rm -f "$PLUGIN_DIR/claude-sessions.3s.sh"   # pre-rename plugin filename
  install -m 0755 "$SCRIPT_DIR/host/claudebar.3s.sh" "$PLUGIN_DIR/claudebar.3s.sh"
  open -g "swiftbar://refreshallplugins" 2>/dev/null || true
  info "SwiftBar plugin installed to $PLUGIN_DIR"
else
  warn "SwiftBar not set up — the status board needs it:"
  warn "  brew install --cask swiftbar   # then launch it and pick a plugin folder"
  warn "  re-run: ./claudebar/install.sh"
fi

echo
echo "Done. Next steps:"
echo "  • Restart running Claude Code sessions to pick up the hooks."
echo "  • Sandboxes: add the signal bridge mount and the notifier kit when creating them:"
echo "      sbx create claude . ~/.claude:ro ~/.claude-signals \\"
echo "        --kit <this-repo>/claudebar/sbx-kit"
