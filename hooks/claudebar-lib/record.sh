# shellcheck shell=bash
# claudebar/lib/record.sh — the status record: schema, I/O, and delivery.
#
# A record is the only thing the hook (producer) and the SwiftBar plugin
# (consumer) ever exchange. They used to describe it twice — a `jq -n` object
# on one side, a hand-written `@sh` reader on the other — with nothing tying
# the two lists together, so renaming or adding a field broke the board
# silently: the reader just yielded empty strings and rows rendered blank.
#
# Here the field list below IS the schema. Both directions are generated from
# it, so a new field is one array entry and the two ends cannot disagree.
#
# Requires paths.sh (for CLAUDEBAR_SESSIONS_DIR) and jq.

CLAUDEBAR_RECORD_TEXT_FIELDS=(
  session_id origin project branch cwd root
  state message prompt pending summary event
)
CLAUDEBAR_RECORD_NUM_FIELDS=(ts)

# Build a record from shell variables named after the fields, e.g. set
# `state`, `project`, `ts`, … then call this. Unset fields become "" / 0
# rather than an error, so a caller only has to set what it knows.
claudebar_record_build() { # stdout: record JSON
  local jq_args=() prog="" sep="" f v
  for f in "${CLAUDEBAR_RECORD_TEXT_FIELDS[@]}"; do
    jq_args+=(--arg "$f" "${!f-}")
    prog+="$sep$f: \$$f"; sep=", "
  done
  for f in "${CLAUDEBAR_RECORD_NUM_FIELDS[@]}"; do
    v="${!f-}"
    case "$v" in ''|*[!0-9]*) v=0 ;; esac   # --argjson would abort on junk
    jq_args+=(--argjson "$f" "$v")
    prog+="$sep$f: \$$f"; sep=", "
  done
  jq -n "${jq_args[@]}" "{$prog}"
}

# The inverse: read a record and emit `field='value'` assignments for the
# caller to eval. Shell-quoted by jq's @sh, so quotes, spaces and newlines in
# a prompt or tool argument survive intact.
#
#   eval "$(claudebar_record_read < "$f")"
#
# Prints nothing when the input is not valid JSON — the caller sees empty
# fields and should skip the record.
claudebar_record_read() { # stdin: record JSON — stdout: shell assignments
  local prog="" sep="" f
  for f in "${CLAUDEBAR_RECORD_TEXT_FIELDS[@]}"; do
    prog+="${sep}$f=\\(.$f // \"\")"; sep=$'\n'
  done
  for f in "${CLAUDEBAR_RECORD_NUM_FIELDS[@]}"; do
    prog+="${sep}$f=\\(.$f // 0)"; sep=$'\n'
  done
  jq -r "@sh \"$prog\"" 2>/dev/null
}

# Apply a record to the local status store — the board reads exactly this
# directory. Write-then-rename so a plugin refresh mid-write never sees half a
# file. Returns 1 on a record the store refuses, which is what tells the
# watcher to park the signal file in rejects instead of deleting it.
claudebar_record_store() { # stdin: record JSON
  local record session_id state
  record=$(cat)

  eval "$(jq -r '@sh "session_id=\(.session_id // "")
    state=\(.state // "")"' <<<"$record" 2>/dev/null)"
  [ -n "$session_id" ] || return 1
  # The id becomes a filename, and records arrive from inside sandboxes —
  # anything that could climb out of the store is not a session id.
  case "$session_id" in */*|*\\*|.*) return 1 ;; esac

  mkdir -p "$CLAUDEBAR_SESSIONS_DIR" || return 1
  if [ "$state" = "ended" ]; then
    rm -f "$CLAUDEBAR_SESSIONS_DIR/$session_id.json"
  else
    local tmp="$CLAUDEBAR_SESSIONS_DIR/.$session_id.tmp"
    printf '%s\n' "$record" > "$tmp" && mv "$tmp" "$CLAUDEBAR_SESSIONS_DIR/$session_id.json"
  fi
}

# Hand a record to the host across the signal bridge (sandbox side). Same
# write-then-rename discipline, for the same reason: the watcher must never
# read a partial file. The name only has to be unique within the directory.
claudebar_record_relay() { # $1: bridge dir — stdin: record JSON
  local dir="$1" name tmp
  [ -d "$dir" ] || return 1
  name="evt_$(date +%s)_$$_${RANDOM}"
  tmp="$dir/.$name.tmp"
  cat > "$tmp" 2>/dev/null && mv "$tmp" "$dir/$name.json" 2>/dev/null
}
