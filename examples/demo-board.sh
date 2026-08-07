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

CLAUDE_DIR="${CLAUDE_NOTIFY_HOME:-$HOME/.claude}"
SESSIONS_DIR="$CLAUDE_DIR/notifier-sessions"

command -v jq >/dev/null 2>&1 || { echo "jq is required — brew install jq" >&2; exit 1; }

if [ "${1:-}" = "--clear" ]; then
  rm -f "$SESSIONS_DIR"/demo-*.json
  echo "Removed demo sessions from $SESSIONS_DIR"
  exit 0
fi

mkdir -p "$SESSIONS_DIR"
now=$(date +%s)

# write <id> <ago-seconds> <origin> <project> <branch> <state> <summary> <prompt> <pending>
write() {
  local id="$1" ago="$2" origin="$3" project="$4" branch="$5" state="$6"
  local summary="$7" prompt="$8" pending="$9"
  local ts=$(( now - ago ))
  local root="$HOME/IdeaProjects/$project"
  jq -n \
    --arg session_id "demo-$id" \
    --arg origin "$origin" \
    --arg project "$project" \
    --arg branch "$branch" \
    --arg cwd "$root" \
    --arg root "$root" \
    --arg state "$state" \
    --arg message "" \
    --arg summary "$summary" \
    --arg prompt "$prompt" \
    --arg pending "$pending" \
    --arg event "demo" \
    --argjson ts "$ts" \
    '{session_id:$session_id, origin:$origin, project:$project, branch:$branch,
      cwd:$cwd, root:$root, state:$state, message:$message, summary:$summary,
      prompt:$prompt, pending:$pending, event:$event, ts:$ts}' \
    > "$SESSIONS_DIR/demo-$id.json"
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

n=$(ls "$SESSIONS_DIR"/demo-*.json | wc -l | tr -d ' ')
cat <<EOF
Seeded $n demo sessions into $SESSIONS_DIR

Menu bar will read:  ✳ 🔴2 🟠2 🟢2 🔵3

Open the ✳ menu to take your screenshot, then run:
  ./examples/demo-board.sh --clear
EOF
