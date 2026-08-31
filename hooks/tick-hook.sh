#!/usr/bin/env bash
# UserPromptSubmit hook wrapper around scripts/tick.sh.
#
# SKILL.md used to ask Claude to run tick.sh as step 0 of every turn. That made
# conserve mode dependent on the model remembering an instruction — skip it once
# and the rate-limit awareness silently stops working, with nothing to notice.
# As a hook the harness runs it, so it is mechanical and costs no instruction
# budget.
#
# Wired up by scripts/install.sh as:
#   {"hooks": {"UserPromptSubmit": [{"hooks": [{"type":"command","command":"…/tick-hook.sh"}]}]}}
#
# Contract: stdout is injected into the model's context, so it must stay tiny
# and must say nothing at all in the common case. We only speak up when
# conserve mode is ON — that's the only state that changes Claude's behaviour.
# Always exits 0: a broken hook must never block the user's prompt.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICK="$SCRIPT_DIR/../scripts/tick.sh"

[ -x "$TICK" ] || exit 0

state=$("$TICK" 2>/dev/null) || exit 0
[ -n "$state" ] || exit 0

conserve=$(printf '%s' "$state" | jq -r '.conserve_mode // false' 2>/dev/null) || exit 0
[ "$conserve" = "true" ] || exit 0

util=$(printf '%s' "$state" | jq -r '
  [(.last_check.five_hour.utilization // 0), (.last_check.seven_day.utilization // 0)]
  | max | . * 100 | floor' 2>/dev/null)

printf 'freeloader: conserve mode ON (Claude rate-limit utilization ~%s%%). Widen what counts as cheap enough to route to a free model, per the freeloader skill.\n' "${util:-80+}"
exit 0
