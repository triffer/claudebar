#!/usr/bin/env bats
# Titles come out of Claude Code's own transcript JSONL, which carries no
# compatibility promise — so the parsing is deliberately forgiving, and these
# tests pin down exactly how forgiving.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup()    { claudebar_setup; load_lib; }
teardown() { claudebar_teardown; }

@test "reads the 2.1.x ai-title record" {
  printf '%s\n' '{"type":"ai-title","aiTitle":"Refactor the parser"}' > "$TMPDIR/t.jsonl"

  run claudebar_transcript_title "$TMPDIR/t.jsonl"

  [ "$output" = "Refactor the parser" ]
}

@test "reads the older summary record" {
  printf '%s\n' '{"type":"summary","summary":"Fix the flaky test"}' > "$TMPDIR/t.jsonl"

  run claudebar_transcript_title "$TMPDIR/t.jsonl"

  [ "$output" = "Fix the flaky test" ]
}

@test "the newest title wins over an inherited one" {
  # a resumed transcript opens with the title it inherited, then gets retitled
  # as the session finds its actual subject
  {
    printf '%s\n' '{"type":"summary","summary":"Inherited from resume"}'
    printf '%s\n' '{"type":"user","message":"…"}'
    printf '%s\n' '{"type":"ai-title","aiTitle":"What it is actually about"}'
  } > "$TMPDIR/t.jsonl"

  run claudebar_transcript_title "$TMPDIR/t.jsonl"

  [ "$output" = "What it is actually about" ]
}

@test "malformed and truncated lines are skipped, not fatal" {
  # a transcript being appended to while we read it
  {
    printf '%s\n' 'not json'
    printf '%s\n' '{"type":"ai-title","aiTit'
    printf '%s\n' '{"type":"ai-title","aiTitle":"Survived"}'
  } > "$TMPDIR/t.jsonl"

  run claudebar_transcript_title "$TMPDIR/t.jsonl"

  [ "$output" = "Survived" ]
}

@test "records of neither shape yield nothing" {
  printf '%s\n' '{"type":"user","message":"hello"}' > "$TMPDIR/t.jsonl"

  run claudebar_transcript_title "$TMPDIR/t.jsonl"

  [ -z "$output" ]
}

@test "empty titles are not treated as titles" {
  printf '%s\n' '{"type":"ai-title","aiTitle":""}' > "$TMPDIR/t.jsonl"

  run claudebar_transcript_title "$TMPDIR/t.jsonl"

  [ -z "$output" ]
}

@test "a missing transcript yields nothing and does not fail" {
  run claudebar_transcript_title "$TMPDIR/absent.jsonl"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "SessionStart always scans" {
  local now; now=$(date +%s)

  run claudebar_transcript_should_scan SessionStart "already have one" "$now" "$now"

  # it happens once per session, and is what shows a resumed title right away
  [ "$status" -eq 0 ]
}

@test "transitions scan while there is no title yet" {
  local now; now=$(date +%s)

  run claudebar_transcript_should_scan Stop "" "$now" "$now"

  # a fresh row must not sit on a bare prompt waiting for a timer
  [ "$status" -eq 0 ]
}

@test "with a title in hand, transitions wait out the TTL" {
  local within beyond

  # 100 s since the last scan, then 700 s (default TTL is 600)
  run claudebar_transcript_should_scan Stop "have one" 1000 1100
  within=$status
  run claudebar_transcript_should_scan Stop "have one" 1000 1700
  beyond=$status

  [ "$within" -ne 0 ]
  [ "$beyond" -eq 0 ]
}

@test "chatty events never scan" {
  local now pretool notification; now=$(date +%s)

  run claudebar_transcript_should_scan PreToolUse "" 0 "$now"
  pretool=$status
  run claudebar_transcript_should_scan Notification "" 0 "$now"
  notification=$status

  # PreToolUse fires on every tool call; neither changes what a session is about
  [ "$pretool" -ne 0 ]
  [ "$notification" -ne 0 ]
}

@test "the title reaches the record as summary" {
  printf '%s\n' '{"type":"ai-title","aiTitle":"Menu bar titles"}' > "$TMPDIR/t.jsonl"

  send_event SessionStart s1 transcript_path="$TMPDIR/t.jsonl"

  [ "$(record_field s1 summary)" = "Menu bar titles" ]
}

@test "a later scan that finds nothing keeps the title already stored" {
  printf '%s\n' '{"type":"ai-title","aiTitle":"Keep me"}' > "$TMPDIR/t.jsonl"
  send_event SessionStart s1 transcript_path="$TMPDIR/t.jsonl"
  [ "$(record_field s1 summary)" = "Keep me" ]
  : > "$TMPDIR/t.jsonl"   # transcript rotated away / unreadable

  CLAUDE_NOTIFY_SUMMARY_TTL=0 send_event Stop s1 transcript_path="$TMPDIR/t.jsonl"

  # an empty scan must never blank a title
  [ "$(record_field s1 summary)" = "Keep me" ]
}
