#!/usr/bin/env bash
# UserPromptSubmit hook: answer a trivial prompt from a free model and stop the
# Claude turn from happening at all.
#
# This is the only place in the project where routing can actually save money.
# A route made from inside a Claude turn saves the handful of tokens Claude
# would have spent on the answer, and pays for it with an extra request that
# re-sends the whole conversation — measurably a loss (see README). Answering
# here, before the turn exists, saves the entire turn instead: the context read
# and the output. Same free model, same scripts; three orders of magnitude
# difference, purely from where it is called.
#
# Mechanics (from the hooks contract):
#   stdin  : {"user_prompt": "...", "transcript_path": "...", ...}
#   block  : exit 2 with hookSpecificOutput.permissionDecision = "deny"; the
#            permissionDecisionReason is what the user sees.
#   pass   : exit 0 and print nothing — the prompt proceeds to Claude untouched.
#
# It fails open in every direction. No jq, no scripts, no free model, a prompt
# that is anything other than obviously self-contained, anything sensitive: all
# of it exits 0 and Claude answers, exactly as if this hook were not installed.
# The only outcome that blocks is a complete, clean, successful answer.
#
# Disable with FREELOADER_INTERCEPT=0, or per-prompt by addressing Claude
# ("claude, ...") — triage.sh refuses anything addressed to Claude by name.
set -uo pipefail

[ "${FREELOADER_INTERCEPT:-1}" = "0" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRIAGE="$ROOT/scripts/triage.sh"
ROUTE="$ROOT/scripts/route.sh"

# The user is waiting on this with nothing on screen, so the whole thing gets a
# hard ceiling. Overrun means Claude answers — a few seconds lost, nothing else.
BUDGET="${FREELOADER_INTERCEPT_TIMEOUT:-12}"

command -v jq >/dev/null 2>&1 || exit 0
[ -x "$TRIAGE" ] && [ -x "$ROUTE" ] || exit 0

payload="$(cat)"
prompt=$(printf '%s' "$payload" | jq -r '.user_prompt // empty' 2>/dev/null) || exit 0
[ -n "$prompt" ] || exit 0

# shellcheck source=../scripts/lib.sh
. "$ROOT/scripts/lib.sh" 2>/dev/null || exit 0

# Record how big the conversation is while we have the transcript in hand.
# Nothing else in the project can see this, and without it every cost figure in
# stats.sh reads as zero.
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] && freeloader_record_context "$transcript"

"$TRIAGE" "$prompt" >/dev/null 2>&1 || exit 0

answer=$(FREELOADER_ROUTE_MODE=hook run_with_timeout "$BUDGET" "$ROUTE" "$prompt" 2>/dev/null)
status=$?
[ "$status" -eq 0 ] || exit 0
[ -n "${answer//[[:space:]]/}" ] || exit 0

# Label it. The user asked Claude and is getting an answer from somewhere else;
# that has to be visible in the answer itself, not buried in a log. Naming the
# escape hatch matters as much as naming the source — an unblockable intercept
# would be worse than no intercept.
jq -cn --arg a "$answer" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    permissionDecision: "deny",
    permissionDecisionReason: ($a + "\n\n— answered by a free model, no Claude tokens spent. Ask again starting with \"claude,\" to get Claude instead.")
  }
}'
exit 2
