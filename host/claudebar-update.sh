#!/bin/bash
# claudebar-update — the click action behind the board's version row.
#
#   claudebar-update.sh            upgrade in place, the way claudebar was
#                                  installed, then refresh the menu bar
#   claudebar-update.sh --check    ask GitHub for the newest release now and
#                                  record it; upgrade nothing
#
# SwiftBar opens the upgrade in Terminal (terminal=true), so `git pull` and
# `npx` print where the user can see them: an upgrade that fails silently
# behind a menu is worse than no button at all.
#
# Like claudebar-focus.sh this lives at a space-free path, because SwiftBar's
# bash= parameter parsing is unreliable with quoted paths.

set -u

for _d in "${CLAUDEBAR_LIB:-}" \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/claudebar-lib" 2>/dev/null && pwd)" \
          "${CLAUDE_NOTIFY_HOME:-$HOME/.claude}/hooks/claudebar-lib"; do
  [ -n "$_d" ] && [ -r "$_d/paths.sh" ] && { CLAUDEBAR_LIB="$_d"; break; }
done
[ -r "${CLAUDEBAR_LIB:-}/paths.sh" ] || {
  echo "claudebar lib not found — re-run: npx github:triffer/claudebar install" >&2
  exit 1; }
. "$CLAUDEBAR_LIB/paths.sh"
. "$CLAUDEBAR_LIB/version.sh"

REPO_URL="https://github.com/$CLAUDEBAR_REPO"

info() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# The board only ever reads the cache, so dropping it is what makes the menu
# reflect the new version on the next refresh instead of an interval later.
refresh_board() {
  rm -f "$CLAUDEBAR_UPDATE_CACHE" 2>/dev/null
  open -g "swiftbar://refreshallplugins" 2>/dev/null || true
}

upgrade_git() { # $1: checkout to pull
  local src="$1"
  info "updating the checkout at $src"
  git -C "$src" pull --ff-only || die "git pull failed — resolve it in $src, then re-run"
  bash "$src/install.sh" || die "the installer failed"
}

upgrade_npx() {
  info "fetching the latest release from GitHub"
  command -v npx >/dev/null 2>&1 || die "npx not found — install Node, or clone $REPO_URL"
  npx -y "github:$CLAUDEBAR_REPO" install || die "npx install failed"
}

main() {
  if [ "${1:-}" = "--check" ]; then
    claudebar_update_fetch "$(date +%s)"
    open -g "swiftbar://refreshallplugins" 2>/dev/null || true
    exit 0
  fi

  claudebar_update_cache_read
  printf '\nclaudebar %s' "${CLAUDEBAR_VERSION:-(unknown version)}"
  claudebar_update_available && printf ' → %s' "$CLAUDEBAR_LATEST"
  printf '\n\n'

  # The recorded method is how it was installed; the checkout still being there
  # is what decides whether that is still the way to update. Someone who has
  # since moved or deleted their clone gets the npx path rather than an error.
  if [ "${CLAUDEBAR_INSTALL_METHOD:-}" = "git" ] && [ -d "${CLAUDEBAR_INSTALL_SOURCE:-}/.git" ]; then
    upgrade_git "$CLAUDEBAR_INSTALL_SOURCE"
  else
    upgrade_npx
  fi

  refresh_board
  printf '\n'
  info "claudebar is up to date — restart running Claude Code sessions to pick up the hooks"
  exit 0
}

# `main "$@"; exit 0` on ONE line, deliberately: the upgrade rewrites this very
# file, and bash reads a script incrementally. Anything after this line would be
# read back from the *new* file at the old byte offset — mid-token, mid-word,
# whatever happens to sit there.
main "$@"; exit 0
