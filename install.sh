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
# Same overrides the runtime library honours (hooks/claudebar-lib/paths.sh), so
# installer and installed scripts agree on where things go — and so a test run
# can redirect the whole install somewhere harmless.
CLAUDE_DIR="${CLAUDE_NOTIFY_HOME:-$HOME/.claude}"
SIGNALS_INBOX="${CLAUDE_SIGNALS_INBOX:-$HOME/.claude-signals}"
SETTINGS="$CLAUDE_DIR/settings.json"
CONF="$CLAUDE_DIR/notify.conf"
# Keep the tilde form for a normal install: settings.json is a file people sync
# between machines, and `~` survives a different username where an absolute path
# would not. Only a redirected CLAUDE_NOTIFY_HOME needs the literal path.
if [ "$CLAUDE_DIR" = "$HOME/.claude" ]; then
  HOOK_CMD='bash ~/.claude/hooks/claude-notify.sh'
else
  HOOK_CMD="bash $CLAUDE_DIR/hooks/claude-notify.sh"
fi
HOOK_EVENTS=(SessionStart UserPromptSubmit PreToolUse Notification Stop SessionEnd)
PLIST_LABEL="com.claude.notify.watcher"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/com.local.claude-watcher.plist"

# Where SwiftBar loads plugins from. The lookup is a function with an override
# because `defaults` resolves the user's home from the password database, NOT
# from $HOME — so a test that redirects HOME still reads (and would clobber)
# the real SwiftBar preferences. CLAUDEBAR_PLUGIN_DIR is the only way to keep
# an install run off the real menu bar.
swiftbar_plugin_dir() {
  if [ -n "${CLAUDEBAR_PLUGIN_DIR+set}" ]; then
    printf '%s' "$CLAUDEBAR_PLUGIN_DIR"
    return 0
  fi
  defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true
}
# Entries installed by this script, plus the ones from the original draft
# (hooks/notify.sh), are both matched so re-installs and upgrades don't stack.
HOOK_MATCH='claude-notify\.sh|hooks/notify\.sh'

info()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Run this on your Mac host, not inside a sandbox."

# Dependency handling. By default claudebar installs any missing prerequisites
# (jq, SwiftBar) via Homebrew so a single run gets you a working menu bar. Pass
# --no-deps to skip this and wire up only against what is already installed.
AUTO_DEPS=1

ensure_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  die "Homebrew is needed to auto-install dependencies — get it at https://brew.sh
    and re-run, or install jq/SwiftBar yourself and re-run with --no-deps."
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  [ "$AUTO_DEPS" = 1 ] || die "jq is required: brew install jq (or drop --no-deps)"
  ensure_brew
  info "installing jq…"
  brew install jq >/dev/null || die "brew install jq failed"
  info "jq installed"
}

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
  [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1 && filter_hooks && info "hook entries removed from settings.json"
  rm -f "$CLAUDE_DIR/hooks/claude-notify.sh" "$CLAUDE_DIR/claude-signal-watcher.sh" \
        "$CLAUDE_DIR/claudebar-focus.sh" \
        "$CLAUDE_DIR/claudebar-open.sh" "$CLAUDE_DIR/notify-sounds-on"   # opener: removed feature, clean up if present
  # Only remove the library if it is ours — see the install path for why.
  if [ -f "$CLAUDE_DIR/hooks/claudebar-lib/.claudebar" ]; then
    rm -rf "$CLAUDE_DIR/hooks/claudebar-lib"
  elif [ -e "$CLAUDE_DIR/hooks/claudebar-lib" ]; then
    warn "left $CLAUDE_DIR/hooks/claudebar-lib alone — no claudebar marker in it"
  fi
  local plugin_dir
  plugin_dir=$(swiftbar_plugin_dir)
  [ -n "$plugin_dir" ] && rm -f "$plugin_dir/claudebar.3s.sh" "$plugin_dir/claude-sessions.3s.sh"
  info "scripts and launchd agent removed"
  warn "kept: $CONF, $CLAUDE_DIR/notifier-sessions, $SIGNALS_INBOX (delete manually if unwanted)"
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --with-menubar) ;;              # deprecated: the menu bar is now the default
    --no-deps)      AUTO_DEPS=0 ;;  # don't auto-install jq / SwiftBar
    --uninstall)    uninstall ;;
    *) die "unknown option: $arg (use --uninstall or --no-deps)" ;;
  esac
done

echo "Installing claudebar…"
ensure_jq

# 1. Directories -------------------------------------------------------------
# The signal bridge is a SIBLING of ~/.claude: sandboxes mount ~/.claude
# read-only and sbx mounts keep their host path, so the writable bridge must
# live outside of it.
mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/notifier-sessions" "$SIGNALS_INBOX"
info "directories ready ($CLAUDE_DIR/{hooks,notifier-sessions}, ~/.claude-signals)"

# 2. Scripts ------------------------------------------------------------------
install -m 0755 "$SCRIPT_DIR/hooks/claude-notify.sh" "$CLAUDE_DIR/hooks/claude-notify.sh"
install -m 0755 "$SCRIPT_DIR/host/claude-signal-watcher.sh" "$CLAUDE_DIR/claude-signal-watcher.sh"
install -m 0755 "$SCRIPT_DIR/host/claudebar-focus.sh" "$CLAUDE_DIR/claudebar-focus.sh"

# The shared library goes INSIDE hooks/ deliberately: sbx-kit symlinks exactly
# that one directory into a sandbox, so the library riding along is what keeps
# the hook working there. Anywhere else it would resolve on the host and be
# missing in the microVM.
#
# ~/.claude/hooks is shared space that the user and other tools also write to,
# hence the claudebar- prefix rather than a bare lib/ — and hence the guard
# below. We only ever delete a directory we can positively identify as our
# own, so a name clash costs an error message instead of somebody's files.
LIB_DST="$CLAUDE_DIR/hooks/claudebar-lib"
if [ -e "$LIB_DST" ] && [ ! -f "$LIB_DST/.claudebar" ]; then
  die "$LIB_DST exists and was not created by claudebar — move it aside and re-run"
fi
rm -rf "$LIB_DST"
mkdir -p "$LIB_DST"
install -m 0644 "$SCRIPT_DIR"/hooks/claudebar-lib/*.sh "$LIB_DST/"
: > "$LIB_DST/.claudebar"   # ownership marker, read by the guard above
info "hook, watcher, focus scripts and shared lib installed"

# 3. Legacy cleanup (first draft of this setup) -------------------------------
if [ -f "$LEGACY_PLIST" ] || [ -f "$CLAUDE_DIR/hooks/notify.sh" ]; then
  launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
  rm -f "$LEGACY_PLIST" "$CLAUDE_DIR/notifier.sh" "$CLAUDE_DIR/hooks/notify.sh"
  info "legacy draft (com.local.claude-watcher, notify.sh) removed"
fi
rm -f "$SIGNALS_INBOX"/ping_* 2>/dev/null || true
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

case "${TERM_PROGRAM:-}" in
  iTerm.app)      TB="com.googlecode.iterm2" ;;
  Apple_Terminal) TB="com.apple.Terminal" ;;
  WezTerm)        TB="com.github.wez.wezterm" ;;
  ghostty)        TB="com.mitchellh.ghostty" ;;
  vscode)         TB="com.microsoft.VSCode" ;;
  *)              TB="" ;;
esac

# One table, both paths. Creating the file writes every entry; upgrading an
# existing one appends just the entries whose key is not there yet. Adding a
# config key used to mean editing a heredoc AND writing another bespoke
# grep-and-append block that could drift from it — now it is one conf_def.
CONF_KEYS=(); CONF_VALUES=(); CONF_COMMENTS=()
conf_def() { CONF_KEYS+=("$1"); CONF_VALUES+=("$2"); CONF_COMMENTS+=("$3"); }

conf_def IDE_CMD "\"$IDE\"" \
'JetBrains CLI launcher. When set, the menu bar "Focus IDE project" action
opens/focuses the session'"'"'s project window.
Leave empty to fall back to TERMINAL_BUNDLE_ID.'

conf_def TERMINAL_BUNDLE_ID "\"$TB\"" \
'App the "Focus terminal" action activates when IDE_CMD is empty.'

conf_def STALE_HOURS '1' \
'Menu bar: hide sessions with no update for this many hours.'

conf_def BAR_STYLE '"detailed"' \
'Menu bar style: "detailed" = per-state counts (🔴 permission, 🟠 waiting,
🟢 ready, 🔵 working, zero counts hidden); "minimal" = a single ✳ that only
lights up with a count when sessions need you.'

conf_def BAR_SHOW_WORKING '1' \
'Include the working-session count in the detailed bar (0 = hide).'

conf_block() { # $1: index — comment lines followed by the assignment
  local line
  while IFS= read -r line; do printf '# %s\n' "$line"; done <<<"${CONF_COMMENTS[$1]}"
  printf '%s=%s\n' "${CONF_KEYS[$1]}" "${CONF_VALUES[$1]}"
}

if [ ! -f "$CONF" ]; then
  {
    printf '%s\n' '# Claude notifier configuration — sourced by the menu bar plugin.' \
                  '# Plain bash; edit freely.'
    for i in "${!CONF_KEYS[@]}"; do printf '\n'; conf_block "$i"; done
  } > "$CONF"
  info "config created: $CONF${TB:+ (terminal: $TB)}${IDE:+ (IDE: idea)}"
else
  # Upgrade path: append keys this version introduced, keep everything else.
  # `added` is a string, not an array, on purpose: this script runs under
  # `set -u` and macOS ships bash 3.2, where expanding an EMPTY array counts as
  # an unbound variable and would abort the installer on the common no-op path.
  added=""
  for i in "${!CONF_KEYS[@]}"; do
    grep -q "^${CONF_KEYS[$i]}=" "$CONF" && continue
    { printf '\n'; conf_block "$i"; } >> "$CONF"
    added="$added ${CONF_KEYS[$i]}"
  done
  if [ -n "$added" ]; then
    info "config upgraded:$added added"
  else
    info "config kept: $CONF"
  fi
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
        <string>$CLAUDE_DIR/claude-signal-watcher.sh</string>
    </array>
    <key>QueueDirectories</key>
    <array>
        <string>$SIGNALS_INBOX</string>
    </array>
    <key>ThrottleInterval</key>
    <integer>2</integer>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$CLAUDE_DIR/watcher.log</string>
    <key>StandardErrorPath</key>
    <string>$CLAUDE_DIR/watcher.error.log</string>
</dict>
</plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
info "launchd watcher loaded ($PLIST_LABEL)"

# 7. Menu bar status board -----------------------------------------------------
PLUGIN_DIR=$(swiftbar_plugin_dir)

# Fresh machine: install SwiftBar and pick a plugin folder for the user so the
# board comes up without SwiftBar's first-launch GUI folder picker. SwiftBar
# honours a PluginDirectory default that is set before its first launch.
if { [ -z "$PLUGIN_DIR" ] || [ ! -d "$PLUGIN_DIR" ]; } && [ "$AUTO_DEPS" = 1 ] \
   && [ -z "${CLAUDEBAR_PLUGIN_DIR+set}" ]; then
  if [ ! -d "/Applications/SwiftBar.app" ]; then
    ensure_brew
    info "installing SwiftBar…"
    brew install --cask swiftbar >/dev/null 2>&1 || warn "brew install --cask swiftbar failed — install it manually and re-run"
  fi
  if [ -d "/Applications/SwiftBar.app" ]; then
    PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"
    mkdir -p "$PLUGIN_DIR"
    defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
    open -a SwiftBar 2>/dev/null || true
    info "SwiftBar plugin folder set to $PLUGIN_DIR"
  fi
fi

if [ -n "$PLUGIN_DIR" ] && [ -d "$PLUGIN_DIR" ]; then
  rm -f "$PLUGIN_DIR/claude-sessions.3s.sh"   # pre-rename plugin filename
  install -m 0755 "$SCRIPT_DIR/host/claudebar.3s.sh" "$PLUGIN_DIR/claudebar.3s.sh"
  open -g "swiftbar://refreshallplugins" 2>/dev/null || true
  info "SwiftBar plugin installed to $PLUGIN_DIR"
else
  warn "SwiftBar not set up — the status board needs it:"
  warn "  brew install --cask swiftbar   # then launch it and pick a plugin folder"
  warn "  re-run: claudebar install"
fi

echo
echo "Done. Next steps:"
echo "  • Restart running Claude Code sessions to pick up the hooks."
echo "  • Sandboxes: add the signal bridge mount and the notifier kit when creating them:"
echo "      sbx create claude . ~/.claude:ro ~/.claude-signals \\"
echo "        --kit <this-repo>/claudebar/sbx-kit"
