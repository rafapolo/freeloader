#!/usr/bin/env bash
# Per-turn "tick" for freeloader's usage-aware conserve mode.
#
# Call this once per user turn from SKILL.md's workflow. Cheap on all but every
# REFRESH_EVERY-th call (pure local file I/O) -- that Nth call shells out to
# usage.sh, which spends a few real tokens on a live Messages API call to read
# the anthropic-ratelimit-unified-* headers.
#
# Usage: tick.sh
# Output (stdout, one line of JSON):
#   {"conserve_mode":bool,"turns_since_check":int,"checked_at":...,"last_check":{...}}
#
# conserve_mode flips true once five_hour.utilization or seven_day.utilization
# from the last refresh exceeds FREELOADER_UTIL_THRESHOLD (default 0.8).
# SKILL.md reads it to decide how aggressively to route prompts to free models.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${FREELOADER_STATE:-$HOME/.cache/freeloader-state.json}"
REFRESH_EVERY="${FREELOADER_REFRESH_EVERY:-5}"
UTIL_THRESHOLD="${FREELOADER_UTIL_THRESHOLD:-0.8}"
USAGE_TIMEOUT="${FREELOADER_USAGE_TIMEOUT:-30}"

if ! command -v jq >/dev/null 2>&1; then
  echo '{"error":"jq not found on PATH"}' >&2
  exit 1
fi

# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

mkdir -p "$(dirname "$STATE")"

# Load prior state, tolerating a missing or corrupt file.
if [ -f "$STATE" ] && jq -e . "$STATE" >/dev/null 2>&1; then
  prior=$(cat "$STATE")
else
  prior='{"turns_since_check":0,"conserve_mode":false,"checked_at":null,"last_check":null}'
fi

turns=$(printf '%s' "$prior" | jq -r '.turns_since_check // 0')
turns=$((turns + 1))

if [ "$turns" -ge "$REFRESH_EVERY" ]; then
  usage_json=$(run_with_timeout "$USAGE_TIMEOUT" "$SCRIPT_DIR/usage.sh" --json 2>/dev/null)
  if [ -n "$usage_json" ] && printf '%s' "$usage_json" | jq -e . >/dev/null 2>&1; then
    # jq does the float comparison; bash can't compare 0.74 > 0.8 natively.
    conserve=$(printf '%s' "$usage_json" | jq --argjson t "$UTIL_THRESHOLD" \
      '((.five_hour.utilization // 0) > $t) or ((.seven_day.utilization // 0) > $t)')
    prior=$(printf '%s' "$prior" | jq \
      --argjson conserve "$conserve" \
      --argjson usage "$usage_json" \
      --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.conserve_mode = $conserve
       | .turns_since_check = 0
       | .checked_at = $checked_at
       | .last_check = $usage')
  else
    # Refresh failed (no credentials, network, bad JSON). Keep the previous
    # conserve_mode and don't reset the counter, so the next turn retries
    # instead of waiting out another full cycle.
    turns=$((turns - 1))
    prior=$(printf '%s' "$prior" | jq --argjson turns "$turns" '.turns_since_check = $turns')
  fi
else
  prior=$(printf '%s' "$prior" | jq --argjson turns "$turns" '.turns_since_check = $turns')
fi

# Atomic write, so a concurrent reader never sees a half-written file.
tmp="${STATE}.tmp.$$"
printf '%s\n' "$prior" > "$tmp" && mv "$tmp" "$STATE"

printf '%s' "$prior" | jq -c '{conserve_mode, turns_since_check, checked_at, last_check}'
