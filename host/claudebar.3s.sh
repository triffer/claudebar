#!/usr/bin/env bash
# <xbar.title>claudebar</xbar.title>
# <xbar.desc>Live status of Claude Code sessions (host + sandboxes) in the menu bar.</xbar.desc>
# <xbar.dependencies>bash, jq</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# Reads the session records that claude-notify.sh maintains under
# ~/.claude/notifier-sessions and renders them as a menu bar item. Two styles
# (BAR_STYLE in ~/.claude/notify.conf):
#   detailed (default)  per-state counts, zero counts hidden:
#                       🔴2 🟠1 🟢3 🔵2  (permission/waiting/ready/working)
#   minimal             a single ✳: dim when quiet, orange/red + count when
#                       sessions need you

CLAUDE_DIR="${CLAUDE_NOTIFY_HOME:-$HOME/.claude}"
# NOT ~/.claude/sessions — that one belongs to Claude Code itself.
SESSIONS_DIR="$CLAUDE_DIR/notifier-sessions"
FOCUS_CMD="$CLAUDE_DIR/claudebar-focus.sh"
CONF="$CLAUDE_DIR/notify.conf"
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
STALE_HOURS="${STALE_HOURS:-12}"

RED="#ff453a"; ORANGE="#ff9f0a"; GREEN="#32d74b"; GRAY="#8e8e93"; DIM="#6e6e73"

if ! command -v jq >/dev/null 2>&1; then
  echo "✳ | color=$DIM"
  echo "---"
  echo "jq is required — brew install jq"
  exit 0
fi

now=$(date +%s)

age_str() {
  local s=$1
  if   (( s < 60 ));    then echo "${s}s"
  elif (( s < 3600 ));  then echo "$(( s / 60 ))m"
  elif (( s < 86400 )); then echo "$(( s / 3600 ))h $(( (s % 3600) / 60 ))m"
  else                       echo "$(( s / 86400 ))d"
  fi
}

n_permission=0; n_waiting=0; n_ready=0; n_working=0
blocks_permission=(); blocks_waiting=(); blocks_ready=(); blocks_working=()
states_now=""

shopt -s nullglob
for f in "$SESSIONS_DIR"/*.json; do
  eval "$(jq -r '@sh "state=\(.state // "")
    session_id=\(.session_id // "")
    project=\(.project // "?")
    branch=\(.branch // "")
    origin=\(.origin // "host")
    message=\(.message // "")
    prompt=\(.prompt // "")
    pending=\(.pending // "")
    cwd=\(.cwd // "")
    root=\(.root // "")
    ts=\(.ts // 0)"' < "$f" 2>/dev/null)" || continue
  [ -n "$state" ] || continue

  age=$(( now - ts ))
  (( age > STALE_HOURS * 3600 )) && continue

  # keep menu markup safe: SwiftBar treats "|" as the parameter separator
  message=${message//|/¦}; message=${message//$'\n'/ }
  prompt=${prompt//|/¦};   prompt=${prompt//$'\n'/ }
  pending=${pending//|/¦}; pending=${pending//$'\n'/ }
  project=${project//|/¦}; branch=${branch//|/¦}

  # Sandbox rows lead with the box name — with --clone boxes the repo/branch
  # alone rarely identifies the right session. The last prompt sits on the
  # detail line below the row, same for host and sandbox sessions.
  if [ "$origin" != "host" ]; then
    label="📦 ${origin#sbx:} · $project${branch:+ @ $branch}"
  else
    label="$project${branch:+ @ $branch}"
  fi

  case "$state" in
    permission)
      icon="🔴"
      # triage from the row itself: which tool does it want to run?
      if [ -n "$pending" ]; then verb="wants ${pending%%:*}"; else verb="needs permission"; fi
      ;;
    waiting)    icon="🟠"; verb="waiting for input" ;;
    ready)      icon="🟢"; verb="ready for you" ;;
    working)    icon="🔵"; verb="working" ;;
    *)          icon="⚪️"; verb="$state" ;;
  esac

  # One-click focus: the session row runs the focus helper, which sources the
  # conf and does proper shell quoting (IDE launcher paths contain spaces,
  # which SwiftBar's own bash= parsing cannot handle reliably).
  focus=""
  if [ -x "$FOCUS_CMD" ]; then
    focus="bash=$FOCUS_CMD param1=${root:--} terminal=false"
  fi

  block="$icon $label — $verb · $(age_str "$age") | size=13${focus:+ $focus}"
  # ⌥-click variant of the same row: dismiss the session
  block+=$'\n'"$icon $label — dismiss | alternate=true size=13 bash=/bin/rm param1=-f param2=\"$f\" terminal=false refresh=true"
  # Details as flat, non-clickable lines right under the row. (A row that
  # carries a click action can't also be a submenu parent — macOS menus don't
  # support both, so "--" children would silently not show.)
  if [ "$state" = "permission" ] && [ -n "$pending" ]; then
    block+=$'\n'"↳ wants: ${pending:0:100} | size=11 color=$RED disabled=true"
  fi
  [ -n "$prompt" ] && \
    block+=$'\n'"↳ ❯ ${prompt:0:80} | size=11 color=$GRAY disabled=true"

  case "$state" in
    permission) blocks_permission+=("$block"); (( n_permission++ )) ;;
    waiting)    blocks_waiting+=("$block");    (( n_waiting++ )) ;;
    ready)      blocks_ready+=("$block");      (( n_ready++ )) ;;
    *)          blocks_working+=("$block");    (( n_working++ )) ;;
  esac

  [ -n "$session_id" ] && states_now+="$session_id $state"$'\n'
done

n_attention=$(( n_permission + n_waiting + n_ready ))

# ---- sounds on state changes (🔔 toggle below; deliberately hardcoded) ----
# Played from the plugin because SwiftBar is long-lived and in the GUI
# session — hooks and the launchd watcher get their process groups reaped,
# which kills a backgrounded afplay before it makes a sound.
SOUNDS_FLAG="$CLAUDE_DIR/notify-sounds-on"
STATE_CACHE="${TMPDIR:-/tmp}/claudebar-states"
if [ -f "$SOUNDS_FLAG" ] && [ -f "$STATE_CACHE" ] && command -v afplay >/dev/null 2>&1; then
  while read -r sid st; do
    [ -n "$sid" ] || continue
    prev=$(grep -m1 "^$sid " "$STATE_CACHE" 2>/dev/null | cut -d' ' -f2)
    [ "$st" = "$prev" ] && continue
    case "$st" in
      permission) snd="Submarine" ;;
      waiting)    snd="Glass" ;;
      ready)      snd="Purr" ;;
      *)          snd="" ;;
    esac
    # >/dev/null keeps the backgrounded afplay from holding the plugin's
    # stdout pipe open — SwiftBar reads until EOF.
    [ -n "$snd" ] && afplay "/System/Library/Sounds/$snd.aiff" >/dev/null 2>&1 &
  done <<<"${states_now:-}"
fi
# Always refresh the snapshot (also while sounds are off / on first run), so
# enabling the toggle never triggers a burst for already-known states.
printf '%s' "${states_now:-}" > "$STATE_CACHE"

# ---- menu bar title ----
BAR_STYLE="${BAR_STYLE:-detailed}"
BAR_SHOW_WORKING="${BAR_SHOW_WORKING:-1}"

if [ "$BAR_STYLE" = "minimal" ]; then
  if   (( n_permission > 0 )); then echo "✳ $n_attention | color=$RED"
  elif (( n_attention  > 0 )); then echo "✳ $n_attention | color=$ORANGE"
  elif (( n_working    > 0 )); then echo "✳ | color=$GRAY"
  else                              echo "✳ | color=$DIM"
  fi
else
  # The leading ✳ identifies this status item as the Claude board among
  # other menu bar apps.
  title=""
  (( n_permission > 0 )) && title+="🔴${n_permission} "
  (( n_waiting    > 0 )) && title+="🟠${n_waiting} "
  (( n_ready      > 0 )) && title+="🟢${n_ready} "
  (( n_working > 0 )) && [ "$BAR_SHOW_WORKING" = "1" ] && title+="🔵${n_working} "
  if [ -n "$title" ]; then
    echo "✳ ${title% }"
  else
    echo "✳ | color=$DIM"
  fi
fi

# ---- dropdown ----
echo "---"
echo "✳ Claude Code sessions | size=11 color=$GRAY disabled=true"
echo "---"
total=$(( n_attention + n_working ))
if (( total == 0 )); then
  echo "No active Claude sessions | color=$GRAY"
else
  if (( n_permission + n_waiting > 0 )); then
    echo "NEEDS YOU | size=10 color=$ORANGE"
    for b in "${blocks_permission[@]}" "${blocks_waiting[@]}"; do printf '%s\n' "$b"; done
    echo "---"
  fi
  if (( n_ready > 0 )); then
    echo "READY | size=10 color=$GREEN"
    for b in "${blocks_ready[@]}"; do printf '%s\n' "$b"; done
    echo "---"
  fi
  if (( n_working > 0 )); then
    echo "WORKING | size=10 color=$GRAY"
    for b in "${blocks_working[@]}"; do printf '%s\n' "$b"; done
    echo "---"
  fi
fi

SOUNDS_FLAG="$CLAUDE_DIR/notify-sounds-on"
if [ -f "$SOUNDS_FLAG" ]; then
  echo "🔔 Sounds on — click to mute | bash=/bin/rm param1=-f param2=\"$SOUNDS_FLAG\" terminal=false refresh=true"
else
  echo "🔕 Sounds off — click to enable | bash=/usr/bin/touch param1=\"$SOUNDS_FLAG\" terminal=false refresh=true"
fi
echo "Clear all sessions | bash=/bin/sh param1=-c param2=\"rm -f $SESSIONS_DIR/*.json\" terminal=false refresh=true"
echo "Open sessions folder | bash=/usr/bin/open param1=\"$SESSIONS_DIR\" terminal=false"
