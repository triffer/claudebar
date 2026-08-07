#!/usr/bin/env bash
# <xbar.title>claudebar</xbar.title>
# <xbar.desc>Live status of Claude Code sessions (host + sandboxes) in the menu bar.</xbar.desc>
# <xbar.dependencies>bash, jq</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# Reads the session records that claude-notify.sh maintains and renders them as
# a menu bar item. Two styles (BAR_STYLE in ~/.claude/notify.conf):
#   detailed (default)  per-state counts, zero counts hidden:
#                       🔴2 🟠1 🟢3 🔵2  (permission/waiting/ready/working)
#   minimal             a single ✳: dim when quiet, orange/red + count when
#                       sessions need you

# ------------------------------------------------------------------ bootstrap
# This file is installed into SwiftBar's plugin folder, away from the rest of
# claudebar, so the library is found at its installed location. The
# repo-relative entry is what lets the plugin run straight from a checkout.
for _d in "${CLAUDEBAR_LIB:-}" \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/claudebar-lib" 2>/dev/null && pwd)" \
          "${CLAUDE_NOTIFY_HOME:-$HOME/.claude}/hooks/claudebar-lib"; do
  [ -n "$_d" ] && [ -r "$_d/paths.sh" ] && { CLAUDEBAR_LIB="$_d"; break; }
done

RED="#ff453a"; ORANGE="#ff9f0a"; GREEN="#32d74b"; GRAY="#8e8e93"; DIM="#6e6e73"

# The bar must always render something — a bare failure would leave a blank
# menu item with no hint of what went wrong.
bail() { printf '✳ | color=%s\n---\n%s\n' "$DIM" "$1"; exit 0; }

[ -r "${CLAUDEBAR_LIB:-}/paths.sh" ] || bail "claudebar lib not found — re-run: claudebar install"
. "$CLAUDEBAR_LIB/paths.sh"
. "$CLAUDEBAR_LIB/record.sh"
. "$CLAUDEBAR_LIB/version.sh"

command -v jq >/dev/null 2>&1 || bail "jq is required — brew install jq"

claudebar_load_conf
STALE_HOURS="${STALE_HOURS:-1}"
BAR_STYLE="${BAR_STYLE:-detailed}"
BAR_SHOW_WORKING="${BAR_SHOW_WORKING:-1}"
UPDATE_CHECK_HOURS="${UPDATE_CHECK_HOURS:-24}"
case "$UPDATE_CHECK_HOURS" in ''|*[!0-9]*) UPDATE_CHECK_HOURS=24 ;; esac
# notify.conf is user-edited bash sourced into this shell, so a hotkey holding a
# "|" would not be a broken shortcut — it would be extra SwiftBar parameters on
# the menu bar's own title line.
MENU_SHORTCUT=$(printf '%s' "${MENU_SHORTCUT:-}" | tr -cd 'A-Za-z0-9+' | tr 'a-z' 'A-Z')

# ------------------------------------------------------------------ formatting
age_str() {
  local s=$1
  if   (( s < 60 ));    then echo "${s}s"
  elif (( s < 3600 ));  then echo "$(( s / 60 ))m"
  elif (( s < 86400 )); then echo "$(( s / 3600 ))h $(( (s % 3600) / 60 ))m"
  else                       echo "$(( s / 86400 ))d"
  fi
}

ellipsis() { # $1: text, $2: max length
  if [ "${#1}" -gt "$2" ]; then printf '%s…' "${1:0:$(( $2 - 1 ))}"; else printf '%s' "$1"; fi
}

# SwiftBar treats "|" as its parameter separator, so no record value may carry
# one into the markup. Newlines would split one row into several.
menu_safe() { local s=${1//|/¦}; printf '%s' "${s//$'\n'/ }"; }

# How each state presents itself: bucket icon, and the phrase the row ends on.
state_icon() {
  case "$1" in
    permission) printf '🔴' ;; waiting) printf '🟠' ;;
    ready)      printf '🟢' ;; working) printf '🔵' ;;
    *)          printf '⚪️' ;;
  esac
}

state_verb() { # $1: state  $2: pending tool
  case "$1" in
    # triage from the row itself: which tool does it want to run?
    permission) [ -n "$2" ] && printf 'wants %s' "${2%%:*}" || printf 'needs permission' ;;
    waiting)    printf 'waiting for input' ;;
    ready)      printf 'ready for you' ;;
    working)    printf 'working' ;;
    *)          printf '%s' "$1" ;;
  esac
}

# ------------------------------------------------------------------- one row
# Emits the row itself, its ⌥-click variant, and the detail lines beneath it.
render_row() { # $1: record file, plus the record fields already in scope
  local label focus block

  # Sandbox rows lead with the box name — with --clone boxes the repo/branch
  # alone rarely identifies the right session.
  if [ "$origin" != "host" ]; then
    label="📦 ${origin#sbx:} · $project${branch:+ @ $branch}"
  else
    label="$project${branch:+ @ $branch}"
  fi

  # One-click focus: the session row runs the focus helper, which sources the
  # conf and does proper shell quoting (IDE launcher paths contain spaces,
  # which SwiftBar's own bash= parsing cannot handle reliably).
  focus=""
  [ -x "$CLAUDEBAR_FOCUS_CMD" ] && focus="bash=$CLAUDEBAR_FOCUS_CMD param1=${root:--} terminal=false"

  block="$(state_icon "$state") $label — $(state_verb "$state" "$pending") · $(age_str "$age") | size=13${focus:+ $focus}"
  # ⌥-click variant of the same row: dismiss the session
  block+=$'\n'"$(state_icon "$state") $label — dismiss | alternate=true size=13 bash=/bin/rm param1=-f param2=\"$1\" terminal=false refresh=true"

  # Details as flat, non-clickable lines right under the row. (A row that
  # carries a click action can't also be a submenu parent — macOS menus don't
  # support both, so "--" children would silently not show.)
  #
  # One subtitle says what the session is: its /resume title, which the hook
  # lifts out of the transcript, or — until Claude Code has written one — the
  # last thing you asked for. The title wins because it survives follow-ups
  # ("yes, do that") that say nothing about the session. The ❯ marks which of
  # the two you are looking at.
  if [ -n "$summary" ]; then
    block+=$'\n'"↳ $(ellipsis "$summary" 70) | size=12 disabled=true"
  elif [ -n "$prompt" ]; then
    block+=$'\n'"↳ ❯ $(ellipsis "$prompt" 70) | size=12 color=$GRAY disabled=true"
  fi
  if [ "$state" = "permission" ] && [ -n "$pending" ]; then
    block+=$'\n'"↳ wants: ${pending:0:100} | size=11 color=$RED disabled=true"
  fi

  printf '%s' "$block"
}

# ------------------------------------------------------- collect the sessions
n_permission=0; n_waiting=0; n_ready=0; n_working=0
# Every row, plus a "rank ts index" line per row that decides what order they
# come out in. The board is walked with the arrow keys (see MENU_SHORTCUT), so a
# row's position has to be a property of the session — the store globs in
# session-id order, which is a UUID, so a new session used to land anywhere in
# the list and shuffle the rest.
rows=(); row_keys=""; row_order=""
states_now=""

# Urgency first, and within one state the session that has sat there longest.
state_rank() {
  case "$1" in
    permission) printf 1 ;; waiting) printf 2 ;;
    ready)      printf 3 ;; *)       printf 4 ;;
  esac
}

collect_sessions() {
  local f age now; now=$(date +%s)
  shopt -s nullglob
  for f in "$CLAUDEBAR_SESSIONS_DIR"/*.json; do
    local session_id origin project branch cwd root state message prompt pending summary event ts
    eval "$(claudebar_record_read < "$f")" || continue
    [ -n "$state" ] || continue
    [ -n "$project" ] || project="?"
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac

    age=$(( now - ts ))
    (( age > STALE_HOURS * 3600 )) && continue

    message=$(menu_safe "$message"); prompt=$(menu_safe "$prompt")
    pending=$(menu_safe "$pending"); summary=$(menu_safe "$summary")
    project=$(menu_safe "$project"); branch=$(menu_safe "$branch")

    rows+=("$(render_row "$f")")
    row_keys+="$(state_rank "$state") $ts $(( ${#rows[@]} - 1 ))"$'\n'
    case "$state" in
      permission) (( n_permission++ )) ;;
      waiting)    (( n_waiting++ )) ;;
      ready)      (( n_ready++ )) ;;
      *)          (( n_working++ )) ;;
    esac

    [ -n "$session_id" ] && states_now+="$session_id $state"$'\n'
  done
  row_order=$(printf '%s' "$row_keys" | sort -k1,1n -k2,2n -k3,3n)
  return 0
}

# ---------------------------------------------------------------- sound cues
# Played from the plugin because SwiftBar is long-lived and in the GUI
# session — hooks and the launchd watcher get their process groups reaped,
# which kills a backgrounded afplay before it makes a sound. Only collect the
# sounds here; playback is deferred to the end so the bar repaints first.
sounds_to_play=()
collect_sounds() {
  local cache="${TMPDIR:-/tmp}/claudebar-states" sid st prev snd
  if [ -f "$CLAUDEBAR_SOUNDS_FLAG" ] && [ -f "$cache" ] && command -v afplay >/dev/null 2>&1; then
    while read -r sid st; do
      [ -n "$sid" ] || continue
      prev=$(grep -m1 "^$sid " "$cache" 2>/dev/null | cut -d' ' -f2)
      [ "$st" = "$prev" ] && continue
      case "$st" in
        permission) snd="Submarine" ;;
        waiting)    snd="Glass" ;;
        ready)      snd="Purr" ;;
        *)          snd="" ;;
      esac
      [ -n "$snd" ] && sounds_to_play+=("/System/Library/Sounds/$snd.aiff")
    done <<<"${states_now:-}"
  fi
  # Always refresh the snapshot (also while sounds are off / on first run), so
  # enabling the toggle never triggers a burst for already-known states.
  printf '%s' "${states_now:-}" > "$cache"
  return 0
}

# ------------------------------------------------------------------ updates
# This plugin reruns every three seconds, so the check never happens inline:
# the board reads the cache, and at most once per UPDATE_CHECK_HOURS spawns a
# detached fetch whose result the *next* refresh renders. Nothing here waits
# on the network.
check_updates() {
  claudebar_update_cache_read
  (( UPDATE_CHECK_HOURS == 0 )) && return 0
  local now; now=$(date +%s)
  (( now - CLAUDEBAR_CHECKED < UPDATE_CHECK_HOURS * 3600 )) && return 0

  # Stamp the cache BEFORE fetching, not after. The next refresh is three
  # seconds away, and a machine that is offline (or a GitHub that is rate
  # limiting) must cost one attempt per interval — not one every refresh.
  claudebar_update_cache_write "$CLAUDEBAR_LATEST" "$now"
  ( claudebar_update_fetch "$now" ) >/dev/null 2>&1 &
  return 0
}

# A new release is news for the menu only. Posting it as a macOS notification
# meant asking for notification permission, and a status bar plugin that opens
# a permission dialog to tell you about ITSELF has its priorities backwards —
# the version row below says the same thing, for free, where you were going to
# look anyway.

# ------------------------------------------------------------ menu bar title
# The hotkey belongs on the title line and nowhere else: SwiftBar registers a
# header item's shortcut as "show this menu", while a body item's shortcut runs
# that item's action instead. Opening the menu is the whole point — from there
# macOS makes the board keyboard-navigable for free (arrow keys skip the
# disabled headings and ↳ detail lines, Return clicks the highlighted row).
bar_line() { # $1: title text  $2: parameters, may be empty
  local params="$2"
  [ -n "$MENU_SHORTCUT" ] && params="${params:+$params }shortcut=$MENU_SHORTCUT"
  printf '%s' "$1"
  [ -n "$params" ] && printf ' | %s' "$params"
  printf '\n'
}

render_title() {
  local n_attention=$(( n_permission + n_waiting + n_ready ))
  if [ "$BAR_STYLE" = "minimal" ]; then
    if   (( n_permission > 0 )); then bar_line "✳ $n_attention" "color=$RED"
    elif (( n_attention  > 0 )); then bar_line "✳ $n_attention" "color=$ORANGE"
    elif (( n_working    > 0 )); then bar_line "✳" "color=$GRAY"
    else                              bar_line "✳" "color=$DIM"
    fi
    return
  fi
  # The leading ✳ identifies this status item as the Claude board among
  # other menu bar apps.
  local title=""
  (( n_permission > 0 )) && title+="🔴${n_permission} "
  (( n_waiting    > 0 )) && title+="🟠${n_waiting} "
  (( n_ready      > 0 )) && title+="🟢${n_ready} "
  (( n_working > 0 )) && [ "$BAR_SHOW_WORKING" = "1" ] && title+="🔵${n_working} "
  if [ -n "$title" ]; then bar_line "✳ ${title% }" ""; else bar_line "✳" "color=$DIM"; fi
}

# ---------------------------------------------------------------- dropdown
render_group() { # $1: heading  $2: color  $3: state ranks it covers
  local heading=$1 color=$2 ranks=$3 rank ts idx shown=0
  while read -r rank ts idx; do
    [ -n "$rank" ] || continue
    case " $ranks " in *" $rank "*) ;; *) continue ;; esac
    (( shown == 0 )) && echo "$heading | size=10 color=$color"
    printf '%s\n' "${rows[$idx]}"
    shown=$(( shown + 1 ))
  done <<<"$row_order"
  (( shown > 0 )) && echo "---"
  return 0
}

render_dropdown() {
  echo "---"
  echo "✳ Claude Code sessions | size=11 color=$GRAY disabled=true"
  echo "---"
  if (( n_permission + n_waiting + n_ready + n_working == 0 )); then
    echo "No active Claude sessions | color=$GRAY"
  else
    render_group "NEEDS YOU" "$ORANGE" "1 2"
    render_group "READY"     "$GREEN"  "3"
    render_group "WORKING"   "$GRAY"   "4"
  fi

  if [ -f "$CLAUDEBAR_SOUNDS_FLAG" ]; then
    echo "🔔 Sounds on — click to mute | bash=/bin/rm param1=-f param2=\"$CLAUDEBAR_SOUNDS_FLAG\" terminal=false refresh=true"
  else
    echo "🔕 Sounds off — click to enable | bash=/usr/bin/touch param1=\"$CLAUDEBAR_SOUNDS_FLAG\" terminal=false refresh=true"
  fi
  echo "Clear all sessions | bash=/bin/sh param1=-c param2=\"rm -f $CLAUDEBAR_SESSIONS_DIR/*.json\" terminal=false refresh=true"
  echo "Open sessions folder | bash=/usr/bin/open param1=\"$CLAUDEBAR_SESSIONS_DIR\" terminal=false"
  render_about
}

# The last section of the menu is where claudebar says what it is: which
# version you are running, and — when there is one — the newer one, as a link
# to its release notes, which carry the command that installs it. Clicking
# never upgrades anything: see claudebar-update.sh for why the plugin stays
# out of that business. The version row doubles as the manual check on
# ⌥-click, which is also the only check left when UPDATE_CHECK_HOURS=0.
render_about() {
  local v="${CLAUDEBAR_VERSION:-}" helper=0
  claudebar_version_sane "$v" || v="dev"
  [ -x "$CLAUDEBAR_UPDATE_CMD" ] && helper=1

  echo "---"
  if claudebar_update_available; then
    echo "⬆ claudebar $CLAUDEBAR_LATEST available — read the release notes | color=$ORANGE size=13 href=$(claudebar_release_url "$CLAUDEBAR_LATEST")"
    if [ "$helper" = 1 ]; then
      echo "↳ you have v$v · copy the update command | size=11 color=$GRAY bash=$CLAUDEBAR_UPDATE_CMD param1=--copy terminal=false"
    else
      echo "↳ you have v$v | size=11 color=$GRAY disabled=true"
    fi
    return 0
  fi
  echo "claudebar v$v | size=11 color=$GRAY href=$(claudebar_release_url)"
  if [ "$helper" = 1 ]; then
    echo "claudebar v$v — check for updates now | alternate=true size=11 bash=$CLAUDEBAR_UPDATE_CMD param1=--check terminal=false refresh=true"
  fi
  return 0
}

# --------------------------------------------------------------------- main
collect_sessions
collect_sounds
check_updates
render_title
render_dropdown

# Played after all output is emitted so SwiftBar repaints the bar first; the
# brief sleep lets that paint land before the chime. Detached, stdout to
# /dev/null so it never holds the plugin's stdout pipe open (would delay EOF).
if (( ${#sounds_to_play[@]} > 0 )); then
  ( sleep 0.25; for s in "${sounds_to_play[@]}"; do afplay "$s"; done ) >/dev/null 2>&1 &
fi
