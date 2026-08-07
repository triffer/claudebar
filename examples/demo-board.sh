#!/usr/bin/env bash
# demo-board.sh — seed claudebar with a realistic set of sessions for a
# screenshot, then clear them again.
#
#   ./examples/demo-board.sh          # seed the demo sessions
#   ./examples/demo-board.sh --clear  # remove ONLY the demo sessions
#
# The demo sessions all carry session ids prefixed with "demo-", so --clear
# never touches your real sessions. Timestamps are stamped at seed time, so
# ages stay fresh and nothing looks stale in the screenshot.
#
# After seeding, click the ✳ menu bar item (SwiftBar refreshes on open) or run
# the plugin once to update immediately.

set -euo pipefail

for _d in "${CLAUDEBAR_LIB:-}" \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/claudebar-lib" 2>/dev/null && pwd)" \
          "${CLAUDE_NOTIFY_HOME:-$HOME/.claude}/hooks/claudebar-lib"; do
  [ -n "$_d" ] && [ -r "$_d/paths.sh" ] && { CLAUDEBAR_LIB="$_d"; break; }
done
[ -r "${CLAUDEBAR_LIB:-}/paths.sh" ] || { echo "claudebar lib not found" >&2; exit 1; }
. "$CLAUDEBAR_LIB/paths.sh"
. "$CLAUDEBAR_LIB/record.sh"

command -v jq >/dev/null 2>&1 || { echo "jq is required — brew install jq" >&2; exit 1; }

if [ "${1:-}" = "--clear" ]; then
  rm -f "$CLAUDEBAR_SESSIONS_DIR"/demo-*.json
  echo "Removed demo sessions from $CLAUDEBAR_SESSIONS_DIR"
  exit 0
fi

mkdir -p "$CLAUDEBAR_SESSIONS_DIR"
now=$(date +%s)

# write <id> <ago-seconds> <origin> <project> <branch> <state> <summary> <prompt> <pending>
#
# The record is assembled by the shared builder, so demo rows can never drift
# out of the schema the board reads — which is what a screenshot fixture would
# otherwise do quietly the next time a field is added.
write() {
  local ago="$2"
  local session_id="demo-$1" origin="$3" project="$4" branch="$5" state="$6"
  local summary="$7" prompt="$8" pending="$9"
  local ts=$(( now - ago ))
  local root="$HOME/IdeaProjects/$project" cwd="$HOME/IdeaProjects/$project"
  local message="" event="demo"
  claudebar_record_build > "$CLAUDEBAR_SESSIONS_DIR/$session_id.json"
}

# Rows show their /resume title; the ones with an empty summary fall back to
# the prompt (what a session looks like before Claude Code has titled it).
#
#      id            ago  origin           project           branch                  state        summary (the /resume title)                          prompt (your last message)                       pending
# --- NEEDS YOU: permission prompts (🔴) ---------------------------------------
write  perm-push     18   host             api-gateway       feat/rate-limiter       permission   "Per-IP rate limiting for the /v1 endpoints"         "ship it once the load test is green"            "Bash: git push origin feat/rate-limiter"
write  perm-write    42   "sbx:auth-box"   auth-service      claude/oauth-refresh    permission   "OAuth refresh-token rotation"                       "rotate on every use, not just on expiry"        "Write: src/auth/token_rotation.ts"

# --- NEEDS YOU: waiting for input (🟠) ----------------------------------------
write  wait-input    95   host             claudebar         main                    waiting      ""                                                   "add examples for an expressive screenshot"      ""
write  wait-sbx      240  "sbx:etl"        data-pipeline     claude/backfill         waiting      "Backfill the 2024 event archive"                    "ask me before you drop anything"                ""

# --- READY: finished, sitting at the prompt (🟢) ------------------------------
write  ready-chart   30   host             web-dashboard     fix/chart-legend        ready        "Revenue chart legend overlap"                       "now do the same for the tooltips"               ""
write  ready-docs    310  "sbx:docs"       docs-site         main                    ready        "Regenerate the API reference from the OpenAPI spec" "drop the deprecated v1 routes while you're in there" ""

# --- WORKING: busy right now (🔵) ---------------------------------------------
write  work-sync     6    host             mobile-app        feat/offline-sync       working      ""                                                   "implement the offline write queue with retry"   ""
write  work-deps     12   host             payments          chore/bump-deps         working      "Dependency bump and green test suite"               "keep react on 18 for now"                       ""
write  work-index    58   "sbx:search"     search-index      claude/reindex          working      "Reindex the catalog with the new analyzer"          "run it against staging first"                   ""

n=$(ls "$CLAUDEBAR_SESSIONS_DIR"/demo-*.json | wc -l | tr -d ' ')
cat <<EOF
Seeded $n demo sessions into $CLAUDEBAR_SESSIONS_DIR

Menu bar will read:  ✳ 🔴2 🟠2 🟢2 🔵3

Open the ✳ menu to take your screenshot, then run:
  ./examples/demo-board.sh --clear
EOF
