# shellcheck shell=bash
# claudebar/lib/version.sh — which version is installed, and is a newer one out.
#
# Releases are cut by semantic-release, so the only version that exists is the
# one in package.json at install time. Nothing on the installed side has a
# package.json next to it (the hook, the watcher and the plugin end up in three
# different directories), so install.sh stamps what it knows into installed.sh
# beside this file and every script reads it back from here.
#
# The update check that follows is deliberately timid. It runs off a menu bar
# plugin that reruns every three seconds, so this file never calls out to the
# network on its own: it reads a cache, and the caller decides — at most once
# per interval, detached — when to refresh it.
#
# Requires paths.sh (for CLAUDEBAR_UPDATE_CACHE) and jq.

CLAUDEBAR_REPO="triffer/claudebar"

# The installed version, and how it got installed — set by install.sh in the
# generated installed.sh. Resolved through BASH_SOURCE rather than
# CLAUDEBAR_LIB because a sandbox reaches this file through a symlinked hooks/
# directory, where only the resolved path leads back to its own siblings.
CLAUDEBAR_VERSION=""
CLAUDEBAR_INSTALL_METHOD=""
CLAUDEBAR_INSTALL_SOURCE=""
_claudebar_version_init() {
  local dir
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || return 0
  if [ -r "$dir/installed.sh" ]; then
    . "$dir/installed.sh"
    return 0
  fi
  # No stamp: we are running straight from a checkout, two levels below its
  # package.json. Report what that checkout would install.
  local repo="$dir/../.."
  [ -r "$repo/package.json" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  CLAUDEBAR_VERSION=$(jq -r '.version // ""' "$repo/package.json" 2>/dev/null)
  CLAUDEBAR_INSTALL_METHOD="git"
  CLAUDEBAR_INSTALL_SOURCE=$(cd "$repo" && pwd)
  return 0
}
_claudebar_version_init

# Versions come off the network, get pasted into menu markup and into an
# osascript string, and name a release URL. Rather than escape them everywhere,
# nothing that isn't a plain MAJOR.MINOR.PATCH is treated as a version at all —
# which is exactly what semantic-release produces for this repo.
claudebar_version_sane() { # $1: version
  case "${1:-}" in
    *[!0-9.]*|'') return 1 ;;
    *.*.*)        return 0 ;;
    *)            return 1 ;;
  esac
}

claudebar_version_newer() { # $1: candidate  $2: baseline — true when $1 > $2
  claudebar_version_sane "${1:-}" || return 1
  claudebar_version_sane "${2:-}" || return 1
  local a1 a2 a3 b1 b2 b3 rest i x y
  IFS=. read -r a1 a2 a3 rest <<<"$1"
  IFS=. read -r b1 b2 b3 rest <<<"$2"
  for i in 1 2 3; do
    case $i in
      1) x=$a1; y=$b1 ;;
      2) x=$a2; y=$b2 ;;
      *) x=$a3; y=$b3 ;;
    esac
    # 10# so a zero-padded field is still read as decimal, not octal.
    x=$(( 10#${x:-0} )); y=$(( 10#${y:-0} ))
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 1
}

claudebar_release_url() { # $1: version, or empty for the release list
  if claudebar_version_sane "${1:-}"; then
    printf 'https://github.com/%s/releases/tag/v%s' "$CLAUDEBAR_REPO" "$1"
  else
    printf 'https://github.com/%s/releases' "$CLAUDEBAR_REPO"
  fi
}

# The line that upgrades THIS install, for the clipboard. claudebar never
# installs itself — it hands you the command and you run it where you can see
# it. A checkout pulls; anything else re-runs npx pinned at the release, which
# is the same line the release notes carry.
claudebar_update_command() { # $1: version to move to
  if [ "${CLAUDEBAR_INSTALL_METHOD:-}" = "git" ] && [ -d "${CLAUDEBAR_INSTALL_SOURCE:-}/.git" ]; then
    printf 'cd "%s" && git pull && ./install.sh' "$CLAUDEBAR_INSTALL_SOURCE"
  elif claudebar_version_sane "${1:-}"; then
    printf 'npx github:%s#v%s install' "$CLAUDEBAR_REPO" "$1"
  else
    printf 'npx github:%s install' "$CLAUDEBAR_REPO"
  fi
}

# ------------------------------------------------------------- update cache
# Everything the board knows about upstream: the newest release seen and when
# we last asked. Missing, unreadable or corrupt all read back as "never
# checked".
claudebar_update_cache_read() { # sets CLAUDEBAR_LATEST CLAUDEBAR_CHECKED
  CLAUDEBAR_LATEST=""; CLAUDEBAR_CHECKED=0
  [ -r "${CLAUDEBAR_UPDATE_CACHE:-}" ] || return 0
  eval "$(jq -r '@sh "CLAUDEBAR_LATEST=\(.latest // "")
    CLAUDEBAR_CHECKED=\(.checked // 0)"' "$CLAUDEBAR_UPDATE_CACHE" 2>/dev/null)"
  claudebar_version_sane "$CLAUDEBAR_LATEST" || CLAUDEBAR_LATEST=""
  case "$CLAUDEBAR_CHECKED" in ''|*[!0-9]*) CLAUDEBAR_CHECKED=0 ;; esac
  return 0
}

claudebar_update_cache_write() { # $1: latest  $2: checked
  local checked="${2:-0}" tmp
  case "$checked" in ''|*[!0-9]*) checked=0 ;; esac   # --argjson aborts on junk
  tmp="${CLAUDEBAR_UPDATE_CACHE}.tmp"
  mkdir -p "$(dirname "$CLAUDEBAR_UPDATE_CACHE")" 2>/dev/null
  jq -n --arg l "${1:-}" --argjson c "$checked" '{latest: $l, checked: $c}' > "$tmp" 2>/dev/null &&
    mv "$tmp" "$CLAUDEBAR_UPDATE_CACHE"
}

# Ask GitHub for the newest release and record it. Short-fused and silent on
# purpose: this runs detached from a menu bar refresh, where a slow or absent
# network must cost nothing more than a "latest" that stays as it was.
claudebar_update_fetch() { # $1: unix time
  local now="${1:-}" body tag
  case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
  command -v curl >/dev/null 2>&1 || return 1
  body=$(curl -fsS --max-time 8 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$CLAUDEBAR_REPO/releases/latest" 2>/dev/null) || return 1
  tag=$(jq -r '.tag_name // ""' <<<"$body" 2>/dev/null)
  claudebar_version_sane "${tag#v}" || return 1
  claudebar_update_cache_write "${tag#v}" "$now"
}

# True when the cached release beats what is installed. Both halves have to be
# real versions, so an unstamped checkout or a failed check simply never claims
# an update is waiting.
claudebar_update_available() {
  claudebar_version_newer "${CLAUDEBAR_LATEST:-}" "${CLAUDEBAR_VERSION:-}"
}
