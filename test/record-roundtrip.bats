#!/usr/bin/env bats
# The record is the contract between the hook and the board. These tests are
# what makes it a contract rather than a convention: whatever the producer puts
# in, the consumer must get back out unchanged.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup()    { claudebar_setup; load_lib; }
teardown() { claudebar_teardown; }

@test "every schema field survives a build/read round trip" {
  # the builder reads shell variables named after the fields
  session_id=abc123 origin=host project=claudebar branch=main
  cwd=/work root=/work state=ready message=done prompt="do the thing"
  pending="Bash: ls" summary="A session title" event=Stop ts=1700000000

  local rec; rec=$(claudebar_record_build)
  session_id=x origin=x project=x branch=x cwd=x root=x state=x   # clobber, so a
  message=x prompt=x pending=x summary=x event=x ts=0             # field that
  eval "$(claudebar_record_read <<<"$rec")"                       # fails is visible

  [ "$session_id" = "abc123" ]
  [ "$origin" = "host" ]
  [ "$project" = "claudebar" ]
  [ "$branch" = "main" ]
  [ "$cwd" = "/work" ]
  [ "$root" = "/work" ]
  [ "$state" = "ready" ]
  [ "$message" = "done" ]
  [ "$prompt" = "do the thing" ]
  [ "$pending" = "Bash: ls" ]
  [ "$summary" = "A session title" ]
  [ "$event" = "Stop" ]
  [ "$ts" = "1700000000" ]
}

@test "shell metacharacters in a prompt survive the round trip" {
  # the reader's output gets eval'd, so this is the dangerous case
  session_id=meta state=ready ts=1
  prompt="it's \$dangerous; rm -rf / \`whoami\` \"quoted\" | piped"
  local sent=$prompt

  local rec; rec=$(claudebar_record_build)
  prompt=clobbered
  eval "$(claudebar_record_read <<<"$rec")"

  [ "$prompt" = "$sent" ]
}

@test "unset fields become empty rather than an error" {
  session_id=sparse state=working ts=5
  unset origin project branch cwd root message prompt pending summary event

  run claudebar_record_build

  [ "$status" -eq 0 ]
  [ "$(jq -r '.project' <<<"$output")" = "" ]
  [ "$(jq -r '.session_id' <<<"$output")" = "sparse" ]
}

@test "a non-numeric timestamp degrades to 0 instead of aborting jq" {
  session_id=badts state=ready ts="not-a-number"

  local rec; rec=$(claudebar_record_build)

  # --argjson would abort on junk, taking the whole record with it
  [ "$(jq -r '.ts' <<<"$rec")" = "0" ]
}

@test "the reader stays silent on input that is not JSON" {
  run claudebar_record_read <<<'garbage {{{'

  # silence is what makes the caller skip the record
  [ -z "$output" ]
}

@test "the reader and the writer agree on the field list" {
  session_id=fields state=ready ts=1

  local rec written read_back
  rec=$(claudebar_record_build)
  written=$(jq -r 'keys_unsorted[]' <<<"$rec" | sort)
  read_back=$(printf '%s\n' "${CLAUDEBAR_RECORD_TEXT_FIELDS[@]}" \
                            "${CLAUDEBAR_RECORD_NUM_FIELDS[@]}" | sort)

  # if one side ever grows a field the other lacks, this catches it
  [ "$written" = "$read_back" ]
}

@test "storing a record writes it under the session id" {
  session_id=stored state=ready ts=1

  claudebar_record_build | claudebar_record_store

  [ -f "$SESSIONS_DIR/stored.json" ]
  [ "$(jq -r .state "$SESSIONS_DIR/stored.json")" = "ready" ]
}

@test "storing an ended record removes the session" {
  session_id=gone state=ready ts=1
  claudebar_record_build | claudebar_record_store
  [ -f "$SESSIONS_DIR/gone.json" ]

  state=ended
  claudebar_record_build | claudebar_record_store

  [ ! -f "$SESSIONS_DIR/gone.json" ]
}

@test "a record with no session id is rejected" {
  run claudebar_record_store <<<'{"state":"ready"}'

  [ "$status" -ne 0 ]
}

@test "a session id that would escape the store is rejected" {
  # the id becomes a filename, and records arrive from inside sandboxes
  run claudebar_record_store <<<'{"session_id":"../../evil","state":"ready"}'

  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/evil.json" ]
}

@test "relaying drops a complete file into the bridge, never a partial one" {
  session_id=relay state=ready ts=1

  claudebar_record_build | claudebar_record_relay "$CLAUDE_SIGNALS_INBOX"

  local files=("$CLAUDE_SIGNALS_INBOX"/evt_*.json)
  local tmps=("$CLAUDE_SIGNALS_INBOX"/.evt_*.tmp)
  [ "${#files[@]}" -eq 1 ]
  [ "$(jq -r .session_id "${files[0]}")" = "relay" ]
  [ ! -e "${tmps[0]}" ]
}

@test "the watcher applies bridged records and clears the bridge" {
  session_id=fromsbx state=permission origin=sbx:box ts="$(date +%s)"
  claudebar_record_build | claudebar_record_relay "$CLAUDE_SIGNALS_INBOX"

  run bash "$WATCHER"

  # launchd re-fires while the directory is non-empty, so it must drain
  local left=("$CLAUDE_SIGNALS_INBOX"/evt_*.json)
  [ "$status" -eq 0 ]
  [ "$(record_field fromsbx state)" = "permission" ]
  [ ! -e "${left[0]}" ]
}

@test "the watcher parks an unusable record instead of looping on it" {
  printf '%s\n' '{"state":"ready"}' > "$CLAUDE_SIGNALS_INBOX/evt_bad.json"

  run bash "$WATCHER"

  # moved out of the bridge, kept for diagnosis
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SIGNALS_INBOX/evt_bad.json" ]
  [ -f "$CLAUDE_NOTIFY_HOME/signals-rejected/evt_bad.json" ]
}
