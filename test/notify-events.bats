#!/usr/bin/env bats
# The hook's core job: map Claude Code hook events onto the four board states,
# and carry per-session context between invocations.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup()    { claudebar_setup; }
teardown() { claudebar_teardown; }

@test "SessionStart records a ready session" {
  send_event SessionStart s1

  [ -f "$(record_file s1)" ]
  [ "$(record_field s1 state)" = "ready" ]
  [ "$(record_field s1 message)" = "Session started" ]
}

@test "SessionStart from auto-compact leaves the state untouched" {
  send_event UserPromptSubmit s1 prompt="build it"
  [ "$(record_field s1 state)" = "working" ]

  # auto-compaction fires SessionStart without the user doing anything
  send_event SessionStart s1 source=compact

  [ "$(record_field s1 state)" = "working" ]
}

@test "UserPromptSubmit marks the session working and stores the prompt" {
  send_event UserPromptSubmit s1 prompt="refactor the parser"

  [ "$(record_field s1 state)" = "working" ]
  [ "$(record_field s1 prompt)" = "refactor the parser" ]
}

@test "harness-injected prompts are not stored as the user's prompt" {
  send_event UserPromptSubmit s1 prompt="real question"

  send_event UserPromptSubmit s1 prompt="<task-notification>done</task-notification>"

  [ "$(record_field s1 prompt)" = "real question" ]
}

@test "Stop marks the session ready" {
  send_event UserPromptSubmit s1 prompt=go

  send_event Stop s1

  [ "$(record_field s1 state)" = "ready" ]
  [ "$(record_field s1 message)" = "Finished responding" ]
}

@test "SessionEnd removes the record and the context file" {
  send_event SessionStart s1
  [ -f "$(record_file s1)" ]

  send_event SessionEnd s1

  [ ! -f "$(record_file s1)" ]
  [ ! -f "$TMPDIR/claude-notify-s1.ctx" ]
}

@test "a permission Notification maps to the permission state" {
  send_event Notification s1 message="Claude needs your permission to use Bash"

  [ "$(record_field s1 state)" = "permission" ]
}

@test "any other Notification maps to waiting" {
  send_event Notification s1 message="Waiting for your input"

  [ "$(record_field s1 state)" = "waiting" ]
}

@test "Stop with background agents still running is not ready" {
  launch_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609

  send_event Stop s1 transcript_path="$TMPDIR/t.jsonl"

  # the turn ended, but the session has agents out and resumes on its own
  [ "$(record_field s1 state)" = "working" ]
}

@test "Stop once every agent has reported back is ready" {
  launch_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609
  notify_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609

  send_event Stop s1 transcript_path="$TMPDIR/t.jsonl"

  [ "$(record_field s1 state)" = "ready" ]
}

@test "a resumed session is ready however its transcript ends" {
  # the agents in an inherited transcript died with the process that ran them,
  # so an unpaired launch in there says nothing about this session
  launch_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609

  send_event SessionStart s1 transcript_path="$TMPDIR/t.jsonl"

  [ "$(record_field s1 state)" = "ready" ]
}

@test "an idle Notification with background agents still running stays working" {
  # the fan-out: one agent launched, nothing reported back yet
  launch_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609

  send_event Notification s1 message="Claude is waiting for your input" \
    transcript_path="$TMPDIR/t.jsonl"

  # it wakes itself when the last agent finishes — nobody has to go look
  [ "$(record_field s1 state)" = "working" ]
}

@test "once every agent has reported back, an idle Notification does wait" {
  launch_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609
  notify_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609

  send_event Notification s1 message="Claude is waiting for your input" \
    transcript_path="$TMPDIR/t.jsonl"

  [ "$(record_field s1 state)" = "waiting" ]
}

@test "one agent still out keeps the session working" {
  launch_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609
  launch_agent_transcript "$TMPDIR/t.jsonl" af3702b2a3b70bc7d
  notify_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609

  send_event Notification s1 message="Claude is waiting for your input" \
    transcript_path="$TMPDIR/t.jsonl"

  [ "$(record_field s1 state)" = "working" ]
}

@test "a permission prompt outranks running agents" {
  launch_agent_transcript "$TMPDIR/t.jsonl" a37006fee507b4609

  send_event Notification s1 message="Claude needs your permission to use Bash" \
    transcript_path="$TMPDIR/t.jsonl"

  # this one really does block on the user, agents or no agents
  [ "$(record_field s1 state)" = "permission" ]
}

@test "sub-agent events are ignored" {
  # sub-agents carry an agent_id; the main agent never does
  local json
  json=$(jq -n '{hook_event_name: "SessionStart", session_id: "sub",
                 agent_id: "agent_123", cwd: "/tmp"}')

  bash "$HOOK" <<<"$json"

  [ ! -f "$(record_file sub)" ]
}

@test "unknown events produce no record" {
  send_event PostToolUse s1

  [ ! -f "$(record_file s1)" ]
}

@test "PreToolUse records the pending tool and shows it on a permission prompt" {
  # PreToolUse fires before the permission prompt resolves
  send_event PreToolUse s1 tool_name=Bash
  [ "$(record_field s1 state)" = "working" ]

  send_event Notification s1 message="Claude needs your permission to use Bash"

  [ "$(record_field s1 state)" = "permission" ]
  [[ "$(record_field s1 pending)" == Bash* ]]
}

@test "repeat PreToolUse while already working writes no new record" {
  send_event PreToolUse s1 tool_name=Read
  rm -f "$(record_file s1)"   # so a rewrite would show

  send_event PreToolUse s1 tool_name=Grep

  [ ! -f "$(record_file s1)" ]
}

@test "the hook exits 0 even when jq gets malformed input" {
  run bash "$HOOK" <<<'not json at all'

  [ "$status" -eq 0 ]
}

@test "the hook exits 0 when the shared lib is missing" {
  # a hook copied away from its library, i.e. a broken install. From a checkout
  # the repo-relative lookup always succeeds, so this is the only way there.
  mkdir -p "$TEST_ROOT/orphan"
  cp "$HOOK" "$TEST_ROOT/orphan/claude-notify.sh"

  CLAUDEBAR_LIB="" CLAUDE_NOTIFY_HOME="$TEST_ROOT/nope" \
    run bash "$TEST_ROOT/orphan/claude-notify.sh" \
    <<<'{"hook_event_name":"Stop","session_id":"x"}'

  # a hook that dies takes the session's turn down with it
  [ "$status" -eq 0 ]
  [ ! -f "$(record_file x)" ]
}

@test "--deliver applies a record handed over by the watcher" {
  local rec
  rec=$(jq -n --argjson t "$(date +%s)" \
    '{session_id: "relayed", state: "ready", origin: "sbx:box", ts: $t}')

  run bash "$HOOK" --deliver <<<"$rec"

  [ "$status" -eq 0 ]
  [ "$(record_field relayed state)" = "ready" ]
}

@test "--deliver rejects a record with no session id" {
  run bash "$HOOK" --deliver <<<'{"state":"ready"}'

  # a non-zero exit is what parks the file in rejects
  [ "$status" -ne 0 ]
}
